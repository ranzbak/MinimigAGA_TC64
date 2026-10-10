# SerRx -- what does the Amiga's serial receive really get?

ZMODEM from the PC to the Amiga works at 38400 baud. At 57600 every header is
rejected, and at 115200 there are many retries. Plain text at 57600 looks fine
in NComm, but NComm strips bit 7 on screen, so the screen cannot show whether
8-bit bytes arrive intact. `Copy SER: file` does not help either: it never
sees EOF, and ^C deletes the file.

SerRx answers the question directly. The PC sends a known pattern (byte i =
i & 255, `sertx.py`). SerRx reads it through serial.device and reports whether
bytes went **missing** (overrun or buffer overflow), were **changed** (bit
errors), or were **filtered** (XON/XOFF).

## Usage

    SerRx [BAUD=n] [COUNT=n] [TIMEOUT=s] [IDLE=s] [BUF=n] [UNIT=n] [XON]
          [SHARED] [BOOGIE|NOBOOGIE] [SAVE=file] [FROM=file] [SELFTEST]

| option | default | meaning |
|---|---|---|
| `BAUD=n` | 57600 | io_Baud, 112..1000000 |
| `COUNT=n` | 4096 | bytes expected; reading stops when this many have arrived |
| `TIMEOUT=s` | 10 | how long to wait for the **first** byte |
| `IDLE=s` | 2 | after the first byte, stop when no byte has come for this long |
| `BUF=n` | 65536 | io_RBufLen, the device's read buffer (64 or more, a multiple of 64) |
| `UNIT=n` | 0 | serial.device unit |
| `XON` | off | keep XON/XOFF on (SERF_XDISABLED clear). Default: XON/XOFF off |
| `SHARED` | off | open shared (SERF_SHARED). Default: exclusive |
| `BOOGIE` / `NOBOOGIE` | on above 38400 without `XON` | force SERF_RAD_BOOGIE on or off |
| `SAVE=file` | | write the raw received bytes to a file |
| `FROM=file` | | analyse a saved file instead of the serial port |
| `SELFTEST` | | analyse a built-in damaged stream (COUNT 4096) |

The settings are always 8N1 with no handshake (SERF_7WIRE clear). io_CtlChar
is $11130000 and io_ExtFlags is 0.

**SERF_RAD_BOOGIE** is serial.device's "high-speed mode". The autodoc
(SDCMD_SETPARAMS, note 6) says it "skips checks for parity, x-OFF handling,
character lengths other than 8 bits, and testing for a break signal", and that
setting it also sets XDISABLED. It is meant for MIDI and for high rates.
SerRx prints which mode it used. Run one rate both ways to see whether the
mode makes a difference.

Exit code: 0 if the stream is perfect, 5 if anything differs, 10 on a usage or
device error.

## How it reads

SerRx opens the device, sends `SDCMD_SETPARAMS`, and then sends `CMD_CLEAR` to
drop anything that was already waiting. After that it loops:

- `SDCMD_QUERY` gives `io_Actual`, the number of bytes the device holds.
  SerRx reads exactly that many with `CMD_READ`, which returns at once.
- If the device holds no bytes, SerRx sends a 1-byte `CMD_READ` and a
  timer.device request (TIMEOUT before the first byte, IDLE after it). It then
  `Wait`s for whichever finishes first, or for ^C. The request that is still
  pending is aborted with `AbortIO`/`WaitIO`.

Every non-zero `io_Error` is recorded with the byte count at which it
happened. `IOERR_ABORTED` from aborting the 1-byte read is not counted. The
`io_Status` from every `SDCMD_QUERY` is kept.

## Output, line by line

    SerRx: serial.device unit 0 exclusive, Prefs default io_Baud 9600
    SETPARAMS io_Error 0 ok: io_Baud 57600 io_RBufLen 65536 io_ReadLen 8 ... io_CtlChar $11130000
    io_SerFlags $90: XDISABLED on RAD_BOOGIE on 7WIRE off SHARED off PARITY off EOFMODE off
    SERPER (PAL 3546895 Hz; NTSC would be 3579545): 3546895/baud-1 = 60 -> 58146 baud (+0.94%), rounded 61 -> 57208 baud (-0.68%)
    waiting up to 10 s for the first byte; stop at COUNT 4096 or after 2 s without a byte; ^C stops
    stop: COUNT reached, 4096 bytes received
    first to last byte 0.71 s, 5760 bytes/s (8N1 line maximum 5760 bytes/s)
    device errors 0
    io_Status last $00F0, high byte ORed over the run $00: overrun off, break received off, receive XOFFed off, transmit XOFFed off; bytes left unread 0

- **Prefs default io_Baud**: the rate the device handed out before SETPARAMS
  (the Prefs value).
- **SETPARAMS / io_SerFlags**: the IOExtSer fields as the request holds them
  after SETPARAMS, so a value the device clamped or changed shows here.
  `io_Error` non-zero means SETPARAMS failed, and SerRx stops.
- **SERPER**: the Paula divisor the rate implies, on the PAL clock. The first
  value truncates (3546895/baud - 1), the second rounds. Each comes with the
  real rate it gives and the error. At 115200 the error is +2.6 % truncated and
  -0.68 % rounded, so the two candidates are far apart. Which one serial.device
  writes is not known here; the ILA can show the real SERPER.
- **stop**: why reading ended. `COUNT reached`, `IDLE` (a gap after data),
  `TIMEOUT` (no byte at all), `^C`, or 1000 device errors.
- **first to last byte**: the effective receive rate, from DateStamp (1/50 s
  resolution).
- **device errors**: up to 16 entries such as
  `#1 at byte 2113: CMD_READ io_Error 12 SerErr_BufOverflow (read buffer full)`.
  12 means serial.device's own buffer was full (software overflow, too slow to
  read). 6 `SerErr_LineErr` is Paula's hardware overrun: a byte arrived before
  the interrupt took the previous one, so interrupt latency is too high. Other
  values are 1 DevBusy, 2 BaudMismatch, 4 BufErr, 5 InvParam, 9 ParityErr,
  11 TimerErr, 13 NoDSR and 15 DetectedBreak (NDK 3.5 devices/serial.i).
- **io_Status**: the last value, plus the high byte ORed over the whole run.
  The high byte's bits are 0 overrun, 2 break received, 3 transmit XOFFed and
  4 receive XOFFed. The low byte holds the handshake lines, all active low.
- **bytes left unread**: what the device still held at the end, for example
  when the PC sent more than COUNT.

Then the comparison:

    received 4076 expected 4096
    same-offset mismatches 3976
      @100 exp $64 got $67 xor $03                 (first 16)
    aligned: changed 2, lost 11 in 9 gaps, extra 1 in 1 places, tail missing 10
      @100 lost 3 exp $64 got $67                  (first 16 events)
      @297 changed exp $2C got $AC xor $80
      @1038 lost 1 exp $11 got $12
      @2489 extra 1 exp $C4 got $55
    xor bits b7..b0: 1 0 0 0 0 1 0 0
    lost values: $11 4, $13 4, other 3
    verdict: LOST 11 bytes in 9 gaps
    verdict: CHANGED 2 bytes (bit errors, see xor bits)
    verdict: EXTRA 1 bytes in 1 places
    verdict: SHORT 10 bytes missing at the end

- **same-offset mismatches**: received byte i compared with i & 255. After the
  first lost byte, every later byte mismatches. This line only tells whether
  the stream is perfect and where the first problem is.
- **aligned**: a walk that follows the stream. At each mismatch SerRx tries
  these explanations in order, each confirmed by the next bytes (a window of
  up to 4):
  1. **changed**: this one byte is wrong and the next bytes go on as
     expected (a bit error).
  2. **lost k**: the stream continues k bytes further on (k = 1..255).
  3. **extra j**: the expected byte comes j = 1..8 bytes later (bytes that
     were never sent, such as noise or a framing glitch).

  If two gaps fall inside the window (for example $11 and $13 both filtered),
  a fallback applies. If the next byte is the expected one plus 1, this byte
  counts as changed. Otherwise, if this byte and the next both step forward
  by at most 64, the gap counts as lost. Offsets are positions in the
  received data, `exp` is the expected byte and `got` the received byte. A
  loss of 256 bytes or more cannot be seen in the pattern, but it shows as
  `tail missing`.
- **xor bits**: over the changed bytes, how often each bit was wrong. If only
  b7 is wrong, the bit-7 path is the problem. Errors in the low bits, or in
  bits next to each other, point to bit timing (baud error or sampling).
- **lost values**: which values the lost bytes had. If $11 and $13 are lost
  and nothing else, the bytes were filtered (XON/XOFF), not lost on the line.
- **verdict**: one line for each kind of damage found, or `PERFECT`.

## On the board

On the PC, use `amiga_sw/SerRx/sertx.py` (pyserial). On the Amiga, run SerRx
from the TestTools disk. Start **SerRx first**: it clears its buffer and waits
up to TIMEOUT seconds for byte 0. Then start sertx.py within that time. Close
NComm (or any other program that has the serial port open) before running
SerRx, because SerRx opens the port exclusively.

| rate | Amiga | PC |
|---|---|---|
| 38400 (the reference, should be PERFECT) | `SerRx BAUD=38400` | `./sertx.py --baud 38400` |
| 57600 | `SerRx BAUD=57600` | `./sertx.py --baud 57600` |
| 57600 without high-speed mode | `SerRx BAUD=57600 NOBOOGIE` | `./sertx.py --baud 57600` |
| 115200 | `SerRx BAUD=115200` | `./sertx.py --baud 115200` |
| 115200, PC paced | `SerRx BAUD=115200` | `./sertx.py --baud 115200 --gap-us 200` |
| 57600 with XON/XOFF on (should show FILTERED) | `SerRx BAUD=57600 XON` | `./sertx.py --baud 57600` |
| more data, keep it | `SerRx BAUD=115200 COUNT=65536 SAVE=RAM:rx.bin` | `./sertx.py --baud 115200 --count 65536` |

`sertx.py` uses `/dev/ttyUSB1` unless you give `--port`. How to read the
results:

- **LOST + SerErr_LineErr**: hardware overrun. Paula's receive buffer holds
  only one byte, so the interrupt came too late.
- **LOST + SerErr_BufOverflow**: serial.device's buffer was full. Try a bigger
  BUF.
- **LOST without errors**: look at `lost values` and at the gaps.
- **CHANGED**: look at the xor bits.
- If `--gap-us` makes a lossy rate clean, the receive path is too slow
  (latency) rather than wrong (bit timing).

## Test

`make test` (vamos from amitools, python3.10) runs `test_serrx.sh`:

- argument checking;
- SELFTEST against its known injections;
- FROM= on a clean stream, an XON/XOFF-filtered stream, a short stream, a
  late-start stream and 30 random damaged streams, each compared line for line
  with a Python model;
- SAVE;
- the path without a device (vamos has no serial.device, so it must refuse
  with rc 10).

The receive path itself only runs on the board.
