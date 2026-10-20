# rvdebug: Vivado hw_server bridge for OpenOCD (GDB on the RISC-V OSD CPU)

Paul's Xilinx Platform Cable USB II has no OpenOCD driver. This bridge lets
OpenOCD 0.12 use it anyway: it serves OpenOCD's `remote_bitbang` adapter on
`127.0.0.1:33582` and turns the bit-level traffic into whole JTAG scans that
Vivado's hardware manager runs through `hw_server` and the cable.

```text
GDB --3333--> OpenOCD 0.12 --remote_bitbang--> rv_jtag_bridge.tcl (in Vivado)  --hw_server--> cable
  (xPack)     minimig-rv-bscan.cfg             rbb_core.tcl                       -> XC7A100T TAP
              riscv use_bscan_tunnel 6 1       scan_ir/scan_dr/run_state/runtest  -> BSCANE2 USER4
                                                                                  -> VexOsd_DMT debug module
```

| File | What it is |
|---|---|
| `rbb_core.tcl` | The core, plain Tcl (no Vivado command): `remote_bitbang` parser, TAP state tracker, scan aggregation and splitting, the back-end interface, the self-test, the TCP server |
| `rv_jtag_bridge.tcl` | Vivado entry point: the back end with `scan_ir_hw_jtag` / `scan_dr_hw_jtag` / `run_state_hw_jtag` / `runtest_hw_jtag`, target selection, self-test, serving |
| `shim_rbb_backend.tcl` | Test back end: Vivado's documented scan semantics replayed as TMS/TDI bits, to the Verilator bench (`sim/rv_dbg`, `run.sh bridge_sim`) or to the unit tests' reference TAP |
| `test/run_all.tcl` | The unit tests (`tclsh`) |
| `test/testlib.tcl` | Reference TAP, OpenOCD-shaped stream generator, random streams, the equivalence runner |
| `test/test_core.tcl`, `test/test_equiv.tcl`, `test/test_hex.tcl` | The tests |
| `test/fixtures/attach1.rbb.in` | OpenOCD 0.12's real byte stream of `sim/rv_dbg/run.sh attach1` (Task 1, `+rbblog`) |

The board session (programming the lab bitstream, starting the bridge,
OpenOCD and GDB) is in `findings/osd-riscv/debug-board-session.md`.

## Prerequisites

- **tclsh 8.6** for the unit tests and the simulation bridge:
  `sudo apt install tcl8.6` (`/usr/bin/tclsh`; `echo 'puts [info patchlevel]' | tclsh`).
- **Vivado 2023.2** (`/opt/Xilinx/Vivado/2023.2`) for the real bridge. Its Tcl
  is **8.5.14** (not 8.6): the code uses nothing newer than 8.5, and the
  unit tests pass in Vivado's interpreter too (see "Tests"). On this machine
  Vivado needs the libtinfo5 shim: `LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C`.
- **OpenOCD 0.12.0** with the `remote_bitbang` adapter: `sudo apt install openocd`.
- For `bridge_sim`: everything of `sim/rv_dbg/README.md` (Verilator 5.020,
  the xPack RISC-V toolchain and GDB, `ccache`, `python3`).

`bridge_sim` takes about 35 s (the GDB session alone 14 s): about 18,300
scans (none split, the longest 672 bits: the autoprobe, answered ahead),
36,500 `be_goto`, 1.4 MB from OpenOCD (2026-10-20, load average 8).

## Tests

From the repository root:

```sh
# unit tests (about 5 minutes): "=== RVDEBUG TESTS: <n> passed, 0 failed"
tclsh tools/rvdebug/test/run_all.tcl
# fewer random streams / a fixed seed
RANDOM_STREAMS=100 SEED=1234 tclsh tools/rvdebug/test/run_all.tcl

# end to end: OpenOCD -> rbb_core.tcl + shim (tclsh) -> Verilator harness
# (DEBUG = 1, BSCANE2 tunnel) -> sim/rv_dbg's GDB session
bash sim/rv_dbg/run.sh bridge_sim      # "=== GDB PASS DEBUG=1 ... through the bridge"
bash sim/rv_dbg/run.sh bridge_teeth    # "=== GDB_TEETH PASS through the bridge"
# the two findings, reproduced (both expected to FAIL):
BRIDGE_SPLIT=7 bash sim/rv_dbg/run.sh bridge_sim      # Error: Unsupported DTM version: 9
BRIDGE_READAHEAD=0 bash sim/rv_dbg/run.sh bridge_sim  # Unexpected idcode after end of chain: 256 ...

# Vivado batch: load rv_jtag_bridge.tcl without running it, hex-conversion test
# (no hw_server, no hardware target)
cat > /tmp/rvb_check.tcl <<'EOF'
set ::env(RVBRIDGE_NO_MAIN) 1
source tools/rvdebug/rv_jtag_bridge.tcl
source tools/rvdebug/test/test_hex.tcl
EOF
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado \
    -mode batch -nojournal -log /tmp/rvb_check.log -source /tmp/rvb_check.tcl
# -> "=== HEX TEST PASS <n> vectors"
```

What the unit tests cover:

- every protocol byte (`0`..`7`, `R`, `r`..`u`, `B`, `b`, `Q`) and the refusal
  of any other byte (with its offset);
- the TAP state from TMS on each rising TCK edge (all 16 states, all 32
  transitions), and `R` answering the TDO the state presents before the next
  rising edge;
- one `be_scan` per shift, the end-state mapping (the back-end calls and the
  Update/Capture counts of every path below), the mid-shift splits, the hold
  rules, the TMS-only moves, the self-test, the TCP server (a real socket);
- equivalence: a bit-level reference TAP (IR 6, IDCODE, BYPASS, a 48-bit
  USER4 whose capture value depends on every Update and Capture) answers each
  stream directly; the core + shim + a second reference TAP driven scan-wise
  must give the identical reply bytes and the same Capture/Update/
  Test-Logic-Reset/Run-Test-Idle counts, IR and USER4 contents. Streams:
  OpenOCD-shaped (reset, the 704-bit autoprobe, IR 6-bit scans, 41-bit
  DMI-shaped scans with idle clocks, scans ending in Pause states), 1,000
  random legal streams, and OpenOCD's recorded `attach1` session; each fed
  whole, at OpenOCD's own flush points (where every read must be answered
  without a timer: OpenOCD blocks there), in random 1..300-byte chunks and
  byte by byte;
- the two non-IEEE behaviours `bridge_sim` found, modelled in the reference
  TAP (`reftap::new ... {idreload tunnel}`): the IDCODE reload of
  `JTAG_SIME2` (a split autoprobe is wrong, the read-ahead right) and the
  tunnel's free-running 9-TCK TDI delay (OpenOCD's tunnel scans are never
  split; forced splits are caught);
- teeth: a naive back-to-back mapping, reversed TDO, a drain that never
  splits, a wrong known IDCODE and split tunnel scans are each caught;
- the hex conversion of `rv_jtag_bridge.tcl` against hand-computed vectors.

## How it works

### The remote_bitbang stream

`0`..`7` set TCK (bit 2), TMS (bit 1), TDI (bit 0); a rising edge is a
write with TCK 1 after one with TCK 0, and the TAP moves on it with that
write's TMS and TDI. `R` asks for TDO: the bridge answers what the TAP
presents before the next rising edge, i.e. in Shift-DR/IR the bit the next
edge shifts out, elsewhere `1` (TDO is high-Z there; the Verilator bench and
a pulled-up line read 1). `t`/`u` assert TRST (Test-Logic-Reset, held until
`r`/`s`); SRST and `B`/`b` are counted and ignored; `Q` ends the connection;
any other byte is logged and closes the connection.

### When OpenOCD 0.12 waits for replies

From `src/jtag/drivers/remote_bitbang.c` and `bitbang.c` (tag `v0.12.0`,
commit `9ea7f3d6`):

- `remote_bitbang.c:224` `.buf_size = sizeof(remote_bitbang_recv_buf) - 1`
  = **255**: at most 255 `R` are outstanding.
- `bitbang.c:226-248` per scan bit: `write(0, tms, tdi)`, then `sample()`
  (queues `R`, `remote_bitbang.c:182-188`), then `write(1, tms, tdi)`: the
  `R` comes before the bit's rising edge.
- `bitbang.c:251-267`: after the rising write, when 255 samples are buffered
  **or after the last bit of the scan** (the TAP is then in Exit1-DR/IR), it
  reads them back; `read_sample()` blocks (`remote_bitbang.c:190-201`),
  and blocking first flushes the send buffer (`remote_bitbang.c:98-101`).
  So OpenOCD stops sending in the middle of any scan longer than 255 bits,
  and at the end of every scan that reads, before the TMS path to the end
  state.
- `remote_bitbang.c:29, 142-149`: bytes go out when the 512-byte send
  buffer is full, at those blocking reads, at `r`..`u` (`:209-215`), at
  `B`/`b` (`:217-221`; `bitbang.c:299-302, 365-368`: one `B` at the start
  and one `b` at the end of every queue) and at `Q` (`:151-166`).
- OpenOCD 0.12's autoprobe (`core.c:1084-1100, 1215-1235`) is one DR scan of
  `(max(taps, 20) + 1) * 32` bits = **672 bits** with one TAP configured (the
  plan's 704 = 22 x 32 is also tested), ending in Pause-DR, then
  Test-Logic-Reset.

### TAP tracking and the target-visible events

The core follows the TAP state OpenOCD drives (the "virtual" TAP) and turns
its path into the events a target can see: entering Test-Logic-Reset,
entering Run-Test/Idle, n clocks in Run-Test/Idle, Capture-DR/IR, the
shifted bits, Update-DR/IR. Pause, Exit and Select states are invisible
(an IEEE register keeps its contents there; the `BSCANE2` SHIFT/CAPTURE/
UPDATE outputs are low). The back end has only Vivado's operations:

```text
be_scan  ir|dr <nbits> <tdi-bits> <end-state>   -> TDO bits (index 0 = first bit shifted)
be_goto  <stable-state> ?<path>?                 run_state_hw_jtag [-state <path>] <state>
be_idle  <n>                                     runtest_hw_jtag -tck <n> (in IDLE)
be_reset                                         run_state_hw_jtag RESET
```

### End-state mapping

**Every scan starts and ends in the scan's own pause state.** The back
end's TAP rests in DRPAUSE/IRPAUSE while the virtual TAP is anywhere in the
DR/IR column; Update is held until the next event shows where the path goes.

| Virtual TAP (OpenOCD) | Back end (Vivado) |
|---|---|
| Idle/Update -> ... -> Capture-xR | `be_goto xRPAUSE` via Capture-xR, Exit1-xR (the capture happens here) |
| Shift-xR bits, until TMS 1 (or a split) | `be_scan x n bits xRPAUSE` from xRPAUSE: Exit2 -> Shift (no capture), ends in xRPAUSE |
| Exit1 -> Pause -> Exit2 -> Shift (OpenOCD's own continuation) | another `be_scan` from xRPAUSE (no capture) |
| Exit1 -> Update -> Run-Test/Idle, n clocks | `be_goto IDLE {xREXIT2 xRUPDATE IDLE}`, `be_idle n` |
| Exit1 -> Update -> Select-DR -> Capture-DR -> Shift-DR (back to back) | `be_goto DRPAUSE {xREXIT2 xRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}`, `be_scan` |
| Exit1 -> Update -> Select-DR -> Select-IR -> Capture-IR | `be_goto IRPAUSE {xREXIT2 xRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}` |
| any path into Test-Logic-Reset (>= 5 TMS 1) | `be_reset` (from a pause state Vivado's path passes Update, as the virtual one did) |
| Test-Logic-Reset -> Run-Test/Idle | `be_goto IDLE {IDLE}` |

Every Update and every Capture the virtual TAP passes happens exactly once
in the back end, in the same order, and so do the Run-Test/Idle clocks; the
back end's TAP additionally rests in the pause states (and, for a held
Update, see below, visits Run-Test/Idle once without a clock). Why pause
states and not IDLE: a Vivado scan ends in IDLE or in the state of the last
`run_state_hw_jtag`; ending a scan in IDLE would perform Update before the
bridge knows whether OpenOCD goes to Update at all (it might go Exit1 ->
Pause -> Exit2 -> Shift), and OpenOCD blocks for its replies in Exit1,
before it sends the rest of the path. The cost: a DMI access (capture,
scan, update + idle) takes 3-4 Vivado commands instead of 2. Every
`be_goto` passes the explicit `-state` path, so nothing depends on Vivado's
default table (whose help text has typos).

### Mid-shift reads (splits) and the hold rules

A shift is split only where OpenOCD must be waiting for its replies: the
input is drained (no byte readable), replies are owed, the TAP is still in
Shift-DR/IR and the `R` count of this visit of Shift-xR (one OpenOCD scan)
is a multiple of **255** (OpenOCD reads back after every 255th sample of a
scan). Then the bridge scans the bits shifted so far as a partial scan
ending in the pause state, answers, and continues the same shift from there
(Vivado `DRPAUSE -> DREXIT2 -> DRSHIFT`, no capture), so a scan longer than
255 bits completes. At the end of a scan OpenOCD waits in Exit1, where the
scan is complete and is issued anyway.

Anywhere else in a shift OpenOCD is not waiting (its 512-byte send buffer
went out in the middle of a scan: a TCP segment boundary), and the bridge
**holds** instead of splitting, for up to **100 ms**; when that expires (a
client other than OpenOCD) it splits. Why not split freely: a split is not
transparent to the debug module's tunnel (next section). Also held:

- an `R` whose rising edge has not arrived (a segment boundary between
  OpenOCD's `R` and its rising write; OpenOCD queues the rising write
  before it waits, `bitbang.c:226-253`, so it never waits there): the same
  100 ms, then a split before that bit, the reads before it answered, that
  read waiting for its edge;
- a trailing Update (the virtual TAP passed Update and nothing after it has
  arrived): 2 ms, then performed through Run-Test/Idle
  (`be_goto IDLE {xREXIT2 xRUPDATE IDLE}`, an extra Run-Test/Idle visit
  without a clock), so the target sees the Update (a DMI write) without
  waiting for OpenOCD's next command.

Every split forced by an expired hold (no OpenOCD block explains it) is
counted (`forced by a timer` in the connection's close line) and logged
(`rbb: WARNING: DR shift split after a 100 ms hold ...`): with OpenOCD it
means OpenOCD stalled for 100 ms inside a scan, and a tunnel scan split
there is corrupted. Run-Test/Idle clocks are passed on at every drain;
shift bits with no read owed are never split at a drain.

### The BSCANE2 tunnel is not pause-transparent

Found with `bridge_sim` and `BRIDGE_SPLIT=7` (every shift split after 7
bits): OpenOCD fails at once with `Error: Unsupported DTM version: 9`.
VexRiscv's `JtagTunnel` (the `riscv use_bscan_tunnel` decoder in
`rtl/host/vexriscv/VexOsd_DMT.v`, module
`VexOsd_DMT_DebugTransportModuleTunneled`) delays TDI by 9 and TDO by 4 TCK
cycles through registers clocked on **every** TCK, SHIFT or not
(`io_instruction_tdi_delay_1..8` -> `tap_tdiBuffer`, `VexOsd_DMT.v:6201-6209`;
`tap_tdoBuffer_delay_1..3` -> `tap_tdoShifter`, `:6210-6213`); the DTM's
DMI/DTMCS registers shift `tap_tdiBuffer` while SHIFT is high (`:6226-6227`).
The 3+ extra TCKs of Exit1/Pause/Exit2 inside a shift therefore shift the
data against SHIFT. Extra TCKs **before** a shift (the bridge always enters
from Pause-DR) are harmless: they only change the first 9 bits shifted,
which OpenOCD's tunnel scan (53 bits for the 41-bit DMI) pushes out again;
`bridge_sim` passes with every scan entered that way. OpenOCD's tunnel scans
are shorter than 255 bits, so with the hold rule they are never split.

### IDCODE read-ahead

Found with `bridge_sim` (`BRIDGE_READAHEAD=0` reproduces it): the XC7 TAP as
Vivado models it (`JTAG_SIME2`, and
`sim/rv_dbg/xc7_tap.v`, cross-checked against it) reloads the IDCODE
register on **every rising edge outside Shift-DR** while IR = IDCODE (IEEE
1149.1 loads it in Capture-DR only). A pause split is therefore not
transparent for IDCODE: OpenOCD's 672-bit autoprobe, split at 255 and 510,
read the IDCODE again after each split (`Unexpected idcode after end of
chain: 256 0x81b18849`, `Error: double-check your JTAG setup`). Whether
the silicon does the same is not known; the `BSCANE2` user register (the
debug module) is not affected (its SHIFT is low outside Shift-DR).

So, after the self-test has proven the chain (one TAP, IR 6 bits, 32-bit
IDCODE, BYPASS delay 1) and recorded the IDCODE, a DR shift with IDCODE
selected (after Test-Logic-Reset, or after an Update-IR whose last 6 bits
were the IDCODE instruction `0x09`) is answered ahead: TDO bit i = IDCODE bit i for i < 32, else TDI bit i - 32. The shift
is not split; the real scan runs when it ends and is compared with what was
answered (`rbb: WARNING: IDCODE read-ahead ...` and `readahead_bad` in the
connection's close line if they differ). `-idcode_readahead 0` (bridge and
shim) splits instead; without a passed self-test there is no read-ahead.

### TRST and other limits

- Vivado has no TRST: TRST asserted inside a DR/IR column is replayed with
  TMS, which passes Update in the back end (the virtual TAP does not). OpenOCD
  with `minimig-rv-bscan.cfg` never asserts TRST (`reset_config` none); the
  random unit streams use TRST outside the columns only.
- An `R` in Shift-xR whose rising edge never comes (TRST, or the end of the
  connection) cannot be answered by a scan: after TRST it is answered `1`,
  at the end of the connection not at all.
- `R` is answered as sampled with TCK low before the next rising edge, also
  when OpenOCD would read with TCK high (OpenOCD never does).
- One OpenOCD connection at a time; a second one is refused.

## Vivado semantics in the shim

`shim_rbb_backend.tcl` replays the back-end calls the way the help text of
Vivado 2023.2 describes them (`help scan_dr_hw_jtag` etc., printed in a batch
run without a board), so that `bridge_sim` tests the core against those
semantics and not against an idealised back end:

- `run_state_hw_jtag [-state path] S`: the documented default paths (table
  of `help run_state_hw_jtag`; its typos "IDLE -> DRPAUSE -> IRSELECT" and
  "IREXIT12" read as DRSELECT and IREXIT1) or the given path (every step a
  legal transition, ending in S). S becomes the scans' end state.
- `scan_xr_hw_jtag n`: the documented entry path from the current stable
  state (`help scan_ir_hw_jtag`'s "IDLE: IRSELECT" read as DRSELECT >
  IRSELECT), n bits, TMS 1 on the last, then to the end state. Only the
  scan's own pause state and IDLE are accepted as end states; anything else
  is undocumented and an error, so the core may not depend on it.
- `runtest_hw_jtag -tck n`: to IDLE, n clocks with TMS 0; IDLE becomes the
  end state (pessimistic: the help leaves open whether `runtest`'s end state
  applies to scans; the core always sets the pause state before a scan).
- Each bit: write TCK 0 with TMS/TDI, `R` where TDO is wanted, write TCK 1;
  a command without TDO still waits for one `R` (so each command completes
  before the next, as in Vivado; it also avoids ~40 ms Nagle/delayed-ACK
  stalls, Tcl sockets having no TCP_NODELAY).
- Every call is logged (`-log`), e.g. `scan dr 53 end DRPAUSE (from DRPAUSE)`.

## The Vivado bridge

```sh
# board (Platform Cable USB II on localhost:3121's hw_server); close every
# other hardware manager first (hw_server owns the cable)
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado \
    -mode batch -nojournal -log ~/rvbridge.log -source tools/rvdebug/rv_jtag_bridge.tcl
# then, in another terminal
openocd -f tools/openocd/minimig-rv-bscan.cfg
```

| Option (`-tclargs`) | Environment | Default |
|---|---|---|
| `-port <p>` | `RBB_PORT` | `33582` (in use: a free port, printed in the listening line) |
| `-url <host:port>` | `HW_SERVER_URL` | `localhost:3121` |
| `-xvc_url <host:port>` | `XVC_URL` | none (`open_hw_target -jtag_mode on -xvc_url ...` when set) |
| `-target <pattern>` | `TARGET` | `*`: the only target; more than one -> listed, exit 2 |
| `-freq <Hz>` | `JTAG_FREQ` | the cable's own (6 MHz); sets the target's `PARAM.FREQUENCY` before opening it |
| `-exit_on_disconnect 1` | | `0`: serve OpenOCD connections until killed |
| `-self_test 0` | | `1` |
| `-idcode_readahead 0` | | `1` |

Sequence: `open_hw_manager`, `connect_hw_server -url`, the target
(`get_hw_targets`, `current_hw_target`, `PARAM.FREQUENCY`, `open_hw_target
-jtag_mode on`), then the self-test, then serving. **Self-test:** first the
raw Vivado commands (`run_state_hw_jtag RESET`, `IDLE`, `scan_ir_hw_jtag 6
-tdi 09`, `scan_dr_hw_jtag 32`; the returned hex strings are printed), then
the same through the core (IR capture `..01`, IDCODE `0x?3631093`, BYPASS:
8 DR bits come back delayed by one). A mismatch prints the value read and
exits 1: a wrong value points at the bit order (the hex convention below)
or the chain length. Log lines: `=== RVBRIDGE SELF-TEST PASS ...`,
`=== RBB BRIDGE listening 127.0.0.1:33582`, one line per connection opened
and closed (bytes, edges, reads, scans, partial scans, longest scan,
read-ahead, Vivado commands), and `rbb: HH:MM scans in the last minute: n`.

Hex convention (`rvb::bits_to_hex`, `rvb::hex_to_bits`, the only place that
knows it): the scan's first bit is the LSB of `-tdi` and of the returned
TDO (`help scan_dr_hw_jtag`: "a 24 bit value 0x00_0010 (LSB first)");
`-tdi` is given on every call (the length changes); TDO may come with or
without `0x`, in either case, with or without leading zeros.

## XVC dress rehearsal (not run)

A rehearsal of the whole chain with real Vivado and `hw_server` but no
board was planned: a private `hw_server` on `tcp::3131`, Vivado
`connect_hw_server -url localhost:3131` and `open_hw_target -jtag_mode on
-xvc_url localhost:<port>` into `sim/rv_dbg`'s harness in XVC mode
(`+xvc=<port>`, `DEBUG = 1`), then OpenOCD and the GDB session through the
bridge. **It was not run** (2026-10-20, Phase 5.4 Task 4): the Platform
Cable USB II is plugged into the build machine (`lsusb -d 03fd:` shows
`03fd:0008`, firmware not loaded), and the rule was to start `hw_server`
only if its own documented options provably keep it off USB cables. None
does:

- `hw_server -h` (2023.2) lists `-e <command>` and `--init=<file>`
  ("evaluate initialization command") but no setting names.
- UG908 "Advanced Options" documents `-e "set ..."` settings. The only
  cable-related ones are `jtag-port-filter` ("hw_server ignores JTAG ports
  that do not match the filter", e.g. `-e "set jtag-port-filter
  Xilinx/DLC10/<serial>"`) and `auto-open-ports` ("controls automatic open
  of ports"). Neither says that USB enumeration, or the firmware download
  that turns `03fd:0008` into a working cable, is skipped: a filter on a
  port's name or serial can only apply once the cable is enumerated, and
  the serial needs the firmware. "Standard hw_server Options", "Init
  Option", "Command Line Options for hw_server" and "JTAG Cables and
  Devices Supported by hw_server" have no way to disable cable drivers.
- No text file in `/opt/Xilinx/Vivado/2023.2` mentions these settings.

So these remain unproven against real Vivado; the first board session
checks them, the bridge's self-test first (IR capture and IDCODE, raw and
through the core):

1. Bit order: the first bit shifted is the LSB of `-tdi` and of the
   returned TDO (from `help scan_dr_hw_jtag` only). A swap fails the
   self-test (wrong IDCODE) before OpenOCD connects.
2. `runtest_hw_jtag` (`be_idle`): whether `-wait_state`/`-end_state` from
   an earlier call carry over into later scans. The core always sets the
   pause state before a scan, so it does not depend on this.
3. `JTAG_FREQ` has no effect together with `XVC_URL`: the XVC branch opens
   the target without setting `PARAM.FREQUENCY`; the log line still
   prints the requested TCK.

A rehearsal without the board is possible only with no Xilinx or FTDI JTAG
cable on the USB bus at all (`lsusb -d 03fd:` and `lsusb -d 0403:` empty),
which needs the cable unplugged by hand.
