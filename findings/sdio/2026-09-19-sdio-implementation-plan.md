# SD card: from SPI mode to SD bus mode -- implementation plan

Date 2026-09-19. Status: **plan only, nothing implemented.** Builds on the
backlog entry "The SD card is SPI, and should be SDIO" in
`findings/ap68040/plan-v2-with-ddr3.md:2007-2027`. Extended the same day with
Paul's second requirement: removing and re-inserting the card must bring it
back to the Amiga without a reboot (section 8).

Naming: "SDIO" is strictly the I/O-card spec; what we want is the SD memory
card's native bus protocol (CMD/CLK/DAT0-3, CRC7 + CRC16). This document says
"SD bus mode" for that and keeps "SDIO" only where the backlog uses it.

## 1. Goal

**Integrity first.** Every command, response and data block on the SD bus
carries a CRC the card and host both check: CRC7 on CMD, CRC16 per DAT line.
A flipped bit on the wire becomes a detected error that can be retried instead
of a silently corrupt sector handed to a mounted filesystem (or written back to
the card). That is the reason to do this.

**Hot-swap second.** Pull the card, put it (or another one) back, and the
drives come back without a power cycle or a full reboot. This is mostly
firmware, but it needs two things from the RTL from day one: every card
transaction must end in bounded time, and the host block must report *why* it
ended (section 8).

**Speed third.** 4-bit DAT at 25 MHz is roughly 10 MB/s raw against today's
~2 MB/s raw SPI ceiling (`SPI_fast()` = `spi_speed` 1, `cfide.vhd:405-475`:
3 sysclk cycles per half bit at 113.4 MHz = 18.9 MHz bit clock, minus byte
handshake overhead). Nice, not the point, and it only materialises after the
4-bit stage.

## 2. Pin availability -- verified

`fpga/openaars/aars_v5.0/xc7a100t/sd_card.xdc`:

| Signal   | Line | Pin | Today (`rtl/soc/minimig_openaars_top.v`)          |
|----------|------|-----|----------------------------------------------------|
| sd_m_clk | 11   | D26 | output, `= sd_clk` (line 279)                      |
| sd_m_cmd | 12   | E25 | output, `= sd_mosi` (line 280)                     |
| sd_m_d0  | 13   | E26 | **input**, `sd_miso = sd_m_d0` (line 281)          |
| sd_m_d1  | 14   | D25 | output, driven `1'b1` (line 282)                   |
| sd_m_d2  | 15   | H26 | output, driven `1'b1` (line 283)                   |
| sd_m_d3  | 16   | G26 | output, `= sd_cs` (line 284) -- SPI chip select    |

All six lines needed for 4-bit SD bus mode are placed and constrained
(IOSTANDARD LVTTL, `sd_card.xdc:20-21`; bank voltage 3.3 V, `generic.xdc:20`).
So the user's recollection is right: **the pins are there.** What is not there:

- **Port directions.** In SD bus mode CMD and DAT0-3 are all bidirectional.
  The top declares `sd_m_d0` as `input` and cmd/d1-d3 as `output`
  (`minimig_openaars_top.v:59-64`). They become `inout` with tristate assigns
  in the style of the PS/2 lines (`minimig_openaars_top.v:262-273`).
- **Pull-ups.** The SD spec wants 10-100 kOhm pull-ups on CMD and DAT0-3 at
  the host. **Not verifiable from the repo** whether the AARS v5 I/O board has
  them; no `PULLTYPE PULLUP` is set on these ports (only PS/2 has them,
  `ps2.xdc:27-30`). Stage 0 measures this. The FPGA's internal pull-up is the
  fallback and is probably adequate at 18.9 MHz.
- **Card detect.** `sd_m_cdet` has an IOSTANDARD (`sd_card.xdc:21`, grouped
  with `sd_m_d0`) but **no PACKAGE_PIN in any XDC**, and the RTL never reads it
  (declared `minimig_openaars_top.v:65`, no other reference in `rtl/` or
  `fw/`). It is unplaced and almost certainly trimmed as unused. Whether the
  socket's CD contact is wired to an FPGA pin at all is a board question --
  there is no schematic in `doc/` -- and section 8.1 plans for both answers.
- **Timing.** `sd_card.xdc:26` false-paths `sd_m_d0` in, `wizard.xdc:7`
  false-paths `sd_m_cmd`/`sd_m_d3` out, `sd_card.xdc:33-34` defines the SPI
  bit clock as a /70 generated clock on `mycfide/sck_reg` in an async group.
  `sd_m_clk` has `SLEW SLOW` (`sd_card.xdc:20`). All fine for SPI at 19 MHz;
  Stage 4 revisits them.

## 3. What the existing code actually does (and one correction to the backlog)

### 3.1 RTL: one shift register serves four SPI slaves

`rtl/host/cfide.vhd:377-489` is a single 8/16-bit SPI shift engine on
`sysclk` (= `CLK_114`, `minimig_virtual_top.v:1294`). Chip selects `scs(7:0)`
are set by the firmware through `HW_SPI_CS` (`fw/ctrl_832/hardware.h:53-62`):

| scs bit | firmware macro   | goes to                                                                 |
|---------|------------------|-------------------------------------------------------------------------|
| 1       | `EnableCard()`   | `SD_CS` -> `sd_m_d3` (`minimig_virtual_top.v:1056`, openaars top 284)   |
| 4       | `EnableFpga()`   | `SPI_SS2` -> minimig `_scs` (paula_floppy / gayle data, `1203`)         |
| 5       | `EnableOsd()`    | `SPI_SS3` -> userio OSD                                                 |
| 6       | `EnableDMode()`  | `SPI_SS4` -> minimig `direct_scs`                                        |
| 7       | `EnableRTC()`    | `RTC_CS`                                                                |

MOSI/SCK are shared by all of them: `SD_CLK = SPI_SCK`, `SD_MOSI = SPI_DI`
(`minimig_virtual_top.v:1055-1057`). The card therefore sees every OSD/FPGA
SPI clock and data byte while its CS is high, which SPI mode tolerates. MISO is
muxed inside cfide (`cfide.vhd:384-388`): card `sd_dimm` when scs(1) or scs(7)
is active, else the minimig's `SPI_DO`. `spimux` (`cfide.vhd:31`, default 0 in
`minimig_virtual_top.v:17`, not set by the openaars top) adds four extra divider
ticks and a `sd_ack` wait for boards whose SPI goes through an external mux;
openaars ties `SD_ACK` to 1 (`minimig_openaars_top.v:567`). **Neither spimux
nor SD_ACK matters on our board; leave them alone.**

Consequence for the plan: the OSD/FPGA/RTC SPI traffic must keep working
untouched. The SD card is only the *external* consumer of this engine, so the
clean cut is: leave the cfide SPI engine exactly as it is, stop routing it to
the card pins, and hand those pins to a new block.

### 3.2 The direct path: HDF reads never pass through the 832

`fw/ctrl_832/hdd.c:451` (card partitions) and `hdd.c:438` via
`FileReadEx(..., 0, blk)` (HDF files) call `MMC_ReadMultiple(lba, NULL, n)`.
With a NULL buffer `mmc.c:367-373` asserts `EnableDMode()` and does one
`SPI(0xFF)`; cfide sees scs(6) and clocks **4096 bits** in one go
(`cfide.vhd:451-453`, `shiftcnt <= "10111111111111"`). During this,
`paula_floppy.v:236-239` selects `direct_sdi` (= card MISO, wired from
`SD_MISO` at `minimig_virtual_top.v:1204`) and writes every 16 bits straight
into Gayle's sector FIFO (`paula_floppy.v:343`). Gayle raises DRQ the moment
the FIFO is full (`gayle.v:358`, `drq = fifo_full & pio_in`).

**So on the main HDD path a bad sector is visible to the Amiga before anyone
could check it.** Any integrity scheme that wants to *retry* rather than merely
*count* must buffer the block and verify it before it reaches paula_floppy.
This is the single most important design constraint below, and the backlog
entry does not mention it. It is also what makes a card pulled mid-sector
dangerous today (section 8.3).

### 3.3 Firmware: CRCs are on the wire today, nobody looks at them

Correction to `plan-v2-with-ddr3.md:2011-2016` ("the data CRC is optional in
SPI mode and commonly disabled"). More precisely:

- `MMC_Command()` (`mmc.c:457-493`) computes and sends a correct CRC7 on every
  command. The card ignores it because CRC checking is off by default in SPI
  mode and the firmware never issues CMD59 (defined at `mmc.h:261`, never used).
- On reads the card **always** appends CRC16 to the data block in SPI mode; the
  firmware reads the two bytes and drops them (`mmc.c:256-257`, `294-295`,
  `388-389`; boot ROM `fw/ctrl_boot_832/spi.c:330` skips them by disabling CS).
- On writes the firmware sends `0xFF 0xFF` as CRC (`mmc.c:423-424`); the card
  accepts because CRC is off.

The backlog's conclusion stands ("no protection worth the name"), but the
mechanism matters for staging: **read-data integrity can be checked in SPI
mode with no protocol change at all**, and write-data integrity needs only
CMD59 plus a host-computed CRC16. That makes a cheap Stage 0 possible that also
answers the question nobody has asked yet: *how often does a CRC actually fail
on this board?*

### 3.4 Boot ROM

`fw/ctrl_boot_832/boot.c:103-135`: `spi_init()` then FAT walk then
`LoadFile("832OSDAD.BIN", 0x2000)` then jump. `spi.c` there is a second,
independent SPI/SD driver (init `spi.c:225-268`, read `spi.c:280-334`, writes
stubbed). The ROM lives in `OSDBoot_832_ROM.vhd`, instantiated at
`rtl/host/832_bridge.vhd:131-134` with `maxAddrBitBRAM => 12`: **8 KB**,
selected for `cpu_addr(23 downto 13) = 0` (`832_bridge.vhd:147`), and it is
writable (bss and stack live in it). Current use per `OSDBoot_832.map`:
`__bss_end__ = 0x1354` (4.9 KB) plus `STACKSIZE 0x240` -> **about 2.5 KB
free**. The main firmware is linked at `-b 0x2000` (`fw/ctrl_832/Makefile:29`)
immediately above; growing the ROM to 16 KB would move `prg_start`,
`rom_select`, and both Makefiles together. Avoid unless forced.

Per the dirty-files memory note, `OSDBoot_832_ROM.vhd` is a generated artifact
that goes into the bitstream: every boot ROM change is a resynthesis.

Note in passing: the boot ROM already handles "no card at power-up" by
looping on `spi_init()` forever (`boot.c:103-135`), i.e. it is an insertion
poller. Once it speaks SD bus mode, a card inserted late is initialised in SD
bus mode like any other.

### 3.5 What the firmware does today when the card goes away

Every block-layer failure in `mmc.c` is `FatalError(ERROR_SDCARD, ...)`
(`mmc.c:220, 232, 274, 284, 348, 362, 412, 436, 447`). `main()`'s error loop
(`main.c:312-320`) then spins `while(ErrorMask)` and, because `ErrorFatal` is
set, **stops calling `HandleFpga()`**. Any IDE command the Amiga has issued is
never answered: Gayle holds `busy` (`gayle.v:296-302`, cleared only by the
host's status write), the Amiga sits in scsi.device's wait, and the only exit
is the OSD's error page (`menu.c:2257-2275`, since commit 21729c5 it retries
`ColdBoot()` for fatal errors, which resets the Amiga). So today a pulled card
is a fatal error and a reboot, by construction. Floppies are no better: a
failed `FileRead` in `ReadTrack` is not checked (`fdd.c:171-300`), and the
track is sent from whatever `sector_buffer` holds.

`MMC_Init()` itself is not fatal: with no card it prints "No memory card
detected" (`mmc.c:197`) and returns 0 with `ErrorMask` clear. `ColdBoot()`
(`main.c:140-238`) then returns 0 with the CPU still held (it is only released
when a ROM loaded, `main.c:220-223`) and interrupts re-enabled (single exit,
`main.c:236-237`); `main()` prints "ROM loading failed" (`main.c:277`) and
enters its loop. **That is the state a card-insertion event has to pick up
from** (section 8.6).

## 4. The bootstrap problem -- and why hot-swap makes it easier, not harder

The card is initialised twice per power-up: by the boot ROM (to fetch the
firmware file) and again by the firmware's `MMC_Init()` (`fw/ctrl_832/main.c:152`).
The SD spec (Part 1, 7.2.1 "Mode Selection") fixes what is possible:

- A card powers up in SD bus mode. CMD0 with CS (DAT3) low switches it to SPI
  mode. **Only a power cycle returns it to SD bus mode.**
- The reverse *is* allowed: a card in SD bus mode can be sent CMD0 with DAT3
  low at any time and drops into SPI mode.

The FPGA cannot power-cycle the socket (no power-enable pin in `sd_card.xdc`).
Therefore:

1. **A "boot ROM in SPI, firmware in SD bus mode" staging is impossible.** Once
   the boot ROM has done its SPI CMD0 the firmware cannot get the card back.
2. **"Boot ROM in SD bus mode, firmware in SPI" does work** (firmware sends CMD0
   with CS low and carries on as today). That is the safety net: an *old*
   `832OSDAD.BIN` on the card still boots on a new bitstream, provided the SPI
   engine can still reach the pins (see 5.1, pin ownership).
3. **Card-state reset between boot ROM and firmware.** After the boot ROM has
   selected the card (CMD7, tran state), `MMC_Init()` must not assume idle:
   it starts with CMD0 (`mmc.c:71`), which resets an SD-bus-mode card to idle
   as well, so the existing sequencing survives. RCA is reassigned by CMD3.
4. **Hot-swap and the mode constraint help each other.** A card that leaves
   the socket loses power; the one that comes back (the same or another) is
   in SD bus mode by definition. So re-insertion never meets a card stuck in
   SPI mode, and the re-init after insertion is exactly the power-up ladder in
   6.1 -- no special "recover the mode" path exists or is needed. The one
   thing hot-swap adds is on the *host* side: the sd_host and the firmware
   must be able to abandon a card mid-transaction and start the ladder again
   from CMD0, which is section 8.

**Recommendation:** convert the boot ROM and the main firmware in the *same*
stage, both talking to the same new RTL block, and keep the old SPI engine and
old `spi.c` compiled in behind a build switch so a bitstream with the switch
off is byte-for-byte today's behaviour. Test new bitstreams over JTAG only
until the boot ROM has proven itself; the flash keeps the last good image and
the reset button reloads it.

## 5. RTL design

### 5.1 New module `rtl/host/sd_host.vhd` (or `.sv`), one clock domain

Runs entirely on `sysclk` (`CLK_114`), like the SPI engine it sits next to. No
new MMCM output, no CDC. The SD clock is a registered toggle: default speed
`CLK_114/6` = **18.9 MHz** (3 sysclk cycles per phase; 25 MHz is the spec
ceiling and `/4` = 28.4 MHz exceeds it). After CMD6 high-speed switching (Stage
4, optional) `/4` = 28.4 MHz or `/2` = 56.7 MHz (exceeds 50 MHz; do not). Host
drives CMD/DAT on the sysclk cycle where SD_CLK falls and samples on the cycle
before it rises, i.e. half a period (26 ns) after the card's launching edge --
comfortable against the 14 ns default-speed output delay.

Blocks inside:

- **Command unit.** 48-bit framer (start, tx, 6-bit index, 32-bit arg, CRC7,
  end), response capture for R1/R1b/R3/R6 (48-bit) and R2 (136-bit), CRC7
  check on 48-bit responses (R3 has no CRC: mask it), response timeout (64
  clocks), busy detection on DAT0 for R1b **with its own timeout** (a card that
  vanishes while signalling busy leaves DAT0 at the pull-up, i.e. "not busy",
  but one that was pulled a clock earlier may leave the line floating; bound
  the wait at 500 ms regardless).
- **Data unit.** 512-byte block buffer (one RAMB18, 256 x 16). Read: wait for
  start bit on DAT0 (timeout 100 ms), shift 1-bit or 4-bit, four parallel
  CRC16 (x^16+x^12+x^5+1) checkers, one per lane, compare with the 16 CRC bits
  after the block, flag per-lane mismatch. Write: start bit, data, CRC16 per
  lane, end bit, then capture the 3-bit CRC status token on DAT0 (010
  accepted, 101 CRC error, 110 write error; timeout if none) and wait for busy
  release (timeout 500 ms).
- **Every wait is bounded and every exit sets a reason bit.** This is the
  hot-swap requirement in RTL form and it is in Stage 1, not later: the
  firmware must be able to tell "CRC error, retry" from "nothing answered,
  card is probably gone", and nothing on the host bus may hang. The 832 bridge
  has no ack timeout (`832_bridge.vhd:190-207`, per the reset review) and
  there is no watchdog anywhere (`findings/reset/2026-09-19-reset-logic-review.md`,
  "There is no watchdog"), so a data phase that could wait forever would wedge
  the host CPU with no recovery except the reset button. The timeouts here
  are the substitute for the watchdog we do not have, on this one path.
- **Abort.** A CTRL bit that forces command and data units to idle, drops
  buffer-valid, stops the clock, and releases CMD/DAT to input. The firmware
  uses it before re-running the init ladder after a removal, so no state from
  the old card survives in the block.
- **Replay serialiser** (the direct-path replacement, see 3.2). When armed, it
  substitutes for the card's MISO at cfide's `sd_dimm` input: on each falling
  edge of cfide's internal `sck` it presents the next bit of the verified
  block buffer, MSB first, so the existing `EnableDMode(); SPI(0xFF)` 4096-bit
  shift delivers a CRC-checked sector to `paula_floppy` **with paula_floppy,
  Gayle and hdd.c unchanged**. `sck` is a sysclk flop (`cfide.vhd:395,459`), so
  this is same-domain logic. Replay only ever runs from a buffer that has
  passed CRC; it does not need to know about the card at all, which is what
  makes it safe under removal (8.3).
- **Line monitors.** Raw, synchronised levels of CMD and DAT3 readable in
  STATUS, and, if the board turns out to have a CD contact wired (8.1), a
  debounced (50 ms) card-detect bit plus a sticky "changed" bit the firmware
  clears. Cheap, and the only way to do the DAT3-sense experiment.
- **Pin ownership mux.** Generic `havesdbus : boolean` on cfide. False: today's
  wiring, bit-identical. True: `sd_m_clk/cmd/d0..d3` are driven by sd_host,
  cfide's SPI engine keeps only the internal slaves. *Optional robustness
  (decide in Stage 2):* ownership falls back to the SPI engine while `scs(1)`
  is asserted, so an old firmware's `EnableCard(); CMD0` still gets the card
  in SPI mode. It is cheap but adds a mode-switch hazard; the alternative is to
  document "firmware must match bitstream" and rely on the boot ROM to always
  load whatever is on the card.

### 5.2 MMIO interface

cfide decodes `addr(7 downto 4)` (`cfide.vhd:200-212`); E is SPI, 4..F are
taken, **0..3 are free**. Take `X"2"` and `X"3"`: host addresses
`0x0fffff20..0x0fffff3f` (main firmware) / `0xffffff20..` (boot ROM, same
decode via `addr(23)`). Registers are 16-bit at word offsets, read on
`addr(3 downto 2)`, accessed as `unsigned short` at `+2` the way `PLATFORM`
is (`fw/ctrl_boot_832/spi.h:373`). The host data bus is 16 bits wide
(`cfide.vhd:39`), so the 32-bit argument takes two writes.

| Addr        | Write                                                                  | Read                                                                                               |
|-------------|------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| 0x...20 +2  | CTRL: bit0 soft reset, bit1 4-bit mode, bit2 clock enable, bit3 **abort**, bits 7:4 clock divider, bit8 arm replay, bit9 clear error counters, bit10 clear card-changed | STATUS: bit0 busy, bit1 cmd done, bit2 cmd CRC7 err, bit3 resp timeout, bit4 data done, bit5 data CRC err, bit6 data timeout, bit7 write status != 010, bit8 DAT0 busy, bit9 buffer valid, bit10 raw CMD level, bit11 raw DAT3 level, bits 15:12 CRC-failing lane mask |
| 0x...24 +2  | ARG_HI (arg 31:16)                                                     | CRC error counter (data)                                                                            |
| 0x...28 +2  | ARG_LO (arg 15:0)                                                      | CRC error counter (cmd/resp)                                                                        |
| 0x...2C +2  | CMD: bits 5:0 index, bits 7:6 resp type (0 none, 1 48-bit, 2 48-bit busy, 3 136-bit), bit8 data read, bit9 data write, bit10 no-CRC response (R3). Writing starts the transaction. | RESP: each read pops the next 16 bits of the captured response, MSB first (3 reads for R1, 8 for R2), then wraps |
| 0x...30 +2  | DATA: push 16 bits into the block buffer (write pointer auto-increments) | DATA: pop 16 bits (read pointer auto-increments)                                                     |
| 0x...34 +2  | pointer reset (any write)                                              | buffer pointer / fill level (debug)                                                                 |
| 0x...38 +2  | -                                                                      | last CRC16 computed on lane 0 (debug, used by the Stage 0 SPI monitor too)                           |
| 0x...3C +2  | -                                                                      | CORE_SDBUS caps: bit0 sd_host present, bit1 4-bit supported, bit2 card-detect pin wired, bit3 card present (debounced, if wired), bit4 card changed (sticky), bits 11:8 RTL revision |

`ack` for these addresses: follow the SPI path, which asserts `IOcpuena` when
the engine is not busy (`cfide.vhd:351-355`, sysclk) and passes it out through
the `clk_28` ack process (`cfide.vhd:181-193`). Make DATA reads block while a
transfer is in flight, the same way `SD_busy` blocks SPI, so the boot ROM's
read loop needs no polling -- but *only* while in flight: because every
transfer ends by completion or timeout (5.1), a blocked read returns within
the longest timeout with the error bits set, never later. Do **not** copy the
i2c_master_mmio arrangement (`cfide.vhd:524-544`, on `clk_28`) -- it needed the
multicycle exceptions at `wizard.xdc:29-32` and the SPI engine's sysclk pattern
is the simpler precedent.

### 5.3 Top-level and constraints

- `minimig_virtual_top.v`: new ports for the six card lines as tristate pairs
  (`_i/_o/_t`), routed to cfide; `SD_MISO/SD_MOSI/SD_CLK/SD_CS` remain for
  boards without `havesdbus`. Other tops (`minimig_mist_top.v`,
  `minimig_de0_nano_top.vhd`, `minimig_de10lite_top.vhd`) are unmodified and
  get default values; per the project rule they may still break and the last
  tag that builds them should be named in the commit.
- `minimig_openaars_top.v:59-64,279-284`: ports become `inout`, driven with the
  PS/2-style `assign x = t ? 1'bZ : o` pattern. `sd_m_cdet` either gets a real
  pin and a `PULLTYPE PULLUP` or is deleted from the port list (8.1).
- `sd_card.xdc`: add `PULLTYPE PULLUP` on cmd/d0-d3 (decision after Stage 0);
  new `create_generated_clock` on the sd_host clock flop (`-divide_by 6`),
  `set_output_delay`/`set_input_delay` on cmd/dat relative to it, or, if we keep
  the false-path philosophy of `sd_card.xdc:25-32`, a comment stating the
  half-period margin argument; consider `SLEW FAST` on `sd_m_clk` only if Stage
  4 goes above 19 MHz. Lines 33-34 stay (the SPI engine still exists for the
  OSD).
- Register the new source in `project_1/project_1.xpr`.

## 6. Firmware design

### 6.1 Main firmware (`fw/ctrl_832`)

New `sdbus.c/.h` with the register accessors and a command primitive
`sd_cmd(idx, arg, resptype, flags) -> status`. `mmc.c` keeps its API
(`MMC_Init/Read/ReadMultiple/Write/GetCSD/GetCapacity`, `mmc.h:267-272`) so
`fat.c`, `hdd.c`, `fdd.c` do not change, and gets a compile-time (later:
`CORE_SDBUS` capability bit, runtime) switch between the SPI body and the
SD-bus body. `spi.c` stays for the OSD/FPGA/RTC (`spi.c:5-42`).

Init ladder in SD bus mode (replaces `mmc.c:52-199`):

1. Abort (CTRL bit3), clock on at 18.9 MHz or slower, 74+ clocks with CMD high.
2. CMD0 (no response).
3. CMD8 arg 0x1AA, R7: echo check -> v2 card. No response -> v1 card.
4. ACMD41 (CMD55 + CMD41) arg HCS|voltage, R3 (no CRC), loop until bit31
   ready, up to 1 s; CCS bit -> `CARDTYPE_SDHC` else `CARDTYPE_SD`.
5. CMD2, R2 (136 bits): CID. **Keep it** -- it is the card's identity for
   hot-swap (8.4).
6. CMD3, R6: RCA in bits 31:16 of the response.
7. CMD9 arg RCA<<16, R2: CSD -- replaces `MMC_GetCSD()` (`mmc.c:265-299`,
   which reads it as a data block; in SD bus mode it is a response).
8. CMD7 arg RCA<<16, R1b: select, wait busy release.
9. CMD16 512 (SDSC only; SDHC is fixed).
10. Stage 4: ACMD42 arg 0 (disconnect DAT3 pull-up), ACMD6 arg 2 (4-bit), set
    CTRL bit1.
11. Drop MMC (CMD1) support: MMC uses a different bus protocol in native mode.
    The loss is `CARDTYPE_MMC` (`mmc.c:165-193`); nobody has such a card in a
    micro-SD slot.

Block I/O:

- `MMC_Read(lba, buf)`: CMD17 with data-read flag, wait STATUS done, check
  bit5/6, pop 256 halfwords.
- `MMC_Read(lba, NULL)` and `MMC_ReadMultiple(lba, NULL, n)`: per block --
  CMD17 (or CMD18 once, then buffer per block; the controller stalls the card
  clock between blocks if the buffer is not yet drained -- **decide in Stage 3;
  CMD17-per-block is simpler and costs latency only**), verify, then
  `CTRL.arm_replay; EnableDMode(); SPI(0xFF); RDSPI; DisableDMode();` exactly
  as `mmc.c:369-372`. Retry happens *before* the replay, so Gayle never sees
  a bad sector.
- `MMC_Write(lba, buf)`: push 256 halfwords, CMD24 with data-write flag, wait
  done, check bit7 (CRC status token) and busy release.
- **Failures are no longer fatal.** The `FatalError` calls listed in 3.5
  become `SetError(ERROR_SDCARD, ...)` plus a return of 0, and the block layer
  additionally sets a module-level `card_state` (PRESENT / GONE / CHANGED)
  that the main loop reads (8.6). `FatalError` stays only for things that
  really cannot continue (none identified in `mmc.c`).

### 6.2 Boot ROM (`fw/ctrl_boot_832`)

`spi.c` gains a `#ifdef SDBUS` body for `spi_init()` and `sd_read_sector()`
(`spi.c:225-268`, `280-334`) using the same register map; `boot.c` unchanged.
With CRC and framing in hardware the SD-bus body is *smaller* than the SPI one
(no `cmd_write` byte loop, no 0xFE token hunt). Budget: 2.5 KB free, target
under 1 KB added. Verify with `OSDBoot_832.map` before synthesis. The boot
ROM needs no hot-swap logic of its own: its outer loop (`boot.c:103`) already
retries init until a card answers.

## 7. Error handling and retry -- the payoff

Concrete policy, same in boot ROM and firmware:

| Event                                  | Action                                                                                                                                   |
|----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| Response CRC7 error                    | Re-issue the command up to 3 times. On CMD17/18/24 also send CMD12 first if the card may be in data state. Count in `cmd_crc_errors`.     |
| Response timeout                       | Re-issue up to 3 times, then CMD13; if CMD13 also times out the card is **gone** (section 8): abort, mark `card_state = GONE`, `SetError` (non-fatal), return 0. |
| Read data CRC16 error (any lane)       | Discard buffer, re-issue CMD17 for that LBA up to 4 times with the clock divider stepped down one notch on the 3rd. Count in `data_crc_errors`, keep last bad LBA and lane mask. |
| Write CRC status 101                   | Re-send the block up to 4 times. 110 (write error): fail the write, `SetError(ERROR_SDCARD, ...)`, return 0.                              |
| Write CRC status absent / busy timeout | Card gone mid-write. Abort, `GONE`, return 0. The block is lost; the FAT may be inconsistent (8.4).                                        |
| Data timeout (no start bit)            | CMD12, CMD13 to learn the card state; if not `tran`, CMD7 reselect; retry once; CMD13 timeout -> **gone**.                               |
| 4 consecutive failures on one LBA      | Firmware: return 0 to the caller, `SetError` (non-fatal so `HandleFpga()` keeps running, `main.c:315-317`). Boot ROM: fall back to 1-bit (Stage 4) then to retrying the whole init, as `boot.c:103` already loops forever. |
| Error counters                         | Exposed in the OSD's system/about page and printed at boot on the UART, so a marginal card or socket shows as a number, not as a mystery crash. |

The counters are the thing to look at first after Stage 0: if they stay at
zero for weeks on real cards, the integrity gain of the remaining stages is
insurance rather than a fix, and Paul can decide whether the speed gain
justifies continuing.

## 8. Hot-swap: remove and re-insert without a reboot

> **CLOSED 2026-09-19, and NOT by anything in this plan.** Paul's actual
> requirement -- "removing and inserting the SD-card again makes it available to
> the Amiga without the whole machine needing a reboot" -- turned out to be
> satisfied by machinery that already existed, once the firmware boot path was
> fixed that morning (commit 21729c5).
>
> Confirmed on hardware: selecting a floppy image from the OSD after a card swap
> works; triggering I/O after a swap raises the error screen, and pressing Enter
> reboots cleanly. The error page has always rendered "Reboot" for a fatal error
> (`menu.c:2238`) and always called `ColdBoot()` on select (`menu.c:2260`); what
> was missing was that `ColdBoot()`'s failure paths left the CPU halted with
> interrupts off, so pressing Reboot could wedge the machine instead of
> retrying. With that fixed the flow works end to end.
>
> **Consequences for this plan.** The elaborate design below -- `CardRemount()`,
> CID compare to keep hardfiles and floppies mounted, removal detection per
> `sd_host` state, the direct-path replay under removal -- is **no longer
> required**. It buys transparency (a running Workbench surviving a swap) that
> nobody asked for, and Paul explicitly accepted a reboot. Treat section 8 as a
> design study for a goal that has been met more cheaply, not as scope.
>
> What this removes from the schedule: the +3 days added for hot-swap, the
> Stage 3 `CardRemount()` work, and the Stage 1 register-interface additions
> that existed only to report removal reasons. Bounded timeouts in `sd_host`
> stay -- those are good practice regardless and guard against the no-watchdog
> problem in `findings/reset/2026-09-19-reset-logic-review.md`.
>
> Optional polish, firmware-only, if it ever irritates: the screen says
> `CMD17 Read block` rather than "SD card removed -- re-insert and press Enter",
> and the error only appears on the next disk access rather than the moment the
> card leaves (a CMD13 poll would fix that). Neither is needed for the flow to
> work.

What Paul asked for: "removing and inserting the SD-card again makes it
available to the Amiga without the whole machine needing a reboot." Split into
the four things that have to be true: the host notices the card is gone
(8.1, 8.2), nothing hangs while it is gone (8.2, 8.3), the firmware rebuilds
its state when a card comes back (8.4), and the Amiga is told the truth
throughout (8.5). 8.6 ties it to the boot path fixed in 21729c5.

### 8.1 Card detect

Three candidate sources, in order of preference:

**a. A real CD contact.** Most micro-SD sockets have one. The port name
`sd_m_cdet` (`minimig_openaars_top.v:65`) says the AARS board was meant to
route it, but no XDC places it and there is no schematic in `doc/` to check.
**Paul has to answer this from the board:** find the socket's CD pin on the
schematic or with a meter, and which FPGA pin (if any) it reaches. If it does:
`PACKAGE_PIN` + `PULLTYPE PULLUP` in `sd_card.xdc`, a two-flop synchroniser and
50 ms debounce in sd_host, the `present`/`changed` bits in the caps register
(5.2). Both edges are then known within 50 ms, which is what makes removal
*during* a transfer attributable (8.2) rather than inferred.

**b. DAT3 sensing.** An SD card has an internal 10-90 kOhm pull-up on DAT3
enabled at power-up (that is what the "CD/DAT3" pin name means). With the
host's DAT3 as an input with a weak pull-down, a freshly inserted card reads 1
and an empty slot reads 0. It only works if the board has **no** external
pull-up on DAT3 (Stage 0a finds out), only in 1-bit mode before ACMD42 (in
4-bit mode DAT3 carries data), and the divider between the card's pull-up and
the FPGA's internal pull-down is not guaranteed to land on a valid logic level.
Kept as an experiment behind the raw DAT3 level bit (STATUS bit11), not as the
plan.

**c. Polling.** With no CD line, presence is inferred: while a card is mounted,
CMD13 (SEND_STATUS, R1) every 500 ms from the main loop when no transfer is in
progress -- one 48-bit exchange, well under 10 us. A response timeout on the
poll, or on any real transaction, means **gone**. While gone, the same timer
sends CMD0 + CMD8 every 500 ms; a CMD8 echo means a card is present and in SD
bus mode (4.4), and the full ladder runs. The main loop already has a 250 ms
service timer for the ADV7511 (`main.c:283-300`, `adv_timer`); the card poll
sits next to it.

**Decision:** implement (c) regardless, because it also covers a wired CD
contact that is bouncing or a card that is electrically present but dead; add
(a) if the pin exists, which turns "noticed on the next poll or the next
failed transfer" into "noticed within 50 ms". Insertion detection is what
matters for the user experience and (c) gives it within half a second, so the
plan does not depend on the CD pin.

### 8.2 Detecting removal, including mid-transfer

A card leaves the socket at any instant, so the sd_host must survive it in
every state, and the firmware must learn which state it was in:

| sd_host state at removal | What the lines do                                        | Bounded exit (5.1)                       | Firmware sees                          |
|--------------------------|----------------------------------------------------------|------------------------------------------|----------------------------------------|
| Idle                     | CMD/DAT float to pull-ups                                | -                                        | next CMD13 poll times out -> GONE      |
| Command sent, awaiting response | no start bit on CMD                               | response timeout, 64 clocks              | STATUS bit3 -> retry ladder -> GONE    |
| Data read, before start bit | DAT0 stays high                                       | data timeout, 100 ms                     | STATUS bit6                            |
| Data read, mid-block     | DAT lines float high; the rest of the block is 1s        | block completes, CRC16 mismatch          | STATUS bit5; buffer **not** marked valid |
| Data write, mid-block    | card never sends the CRC status token                    | status-token timeout                     | STATUS bit7 + timeout                  |
| R1b / write busy wait    | DAT0 floats high = "not busy" (harmless) or floats low   | busy timeout, 500 ms                     | bit3/bit6                              |
| Replay to paula_floppy   | nothing -- replay reads the buffer, not the card         | completes normally                       | -                                      |

Two rules make this safe: **a block is only ever marked valid after its CRC
passes**, so partial data from a vanishing card never reaches anything; and
**no wait is unbounded**, so the 832 never blocks on a DATA read for longer
than the longest timeout (500 ms), which is short enough that `HandleFpga()`
can still answer the Amiga's IDE command with an error (8.5). Without the
timeouts the host CPU would be wedged with nothing to release it -- that is
the "no watchdog, no ack timeout" finding of the reset review applied to this
path.

The firmware decides "gone" rather than the RTL, because a single timeout is
also what a marginal card or a bad contact produces: the ladder in section 7
retries first, and only a CMD13 that also times out (or, with a CD pin, a
`present = 0`) sets `card_state = GONE`. After that the firmware writes CTRL
abort, stops the clock, and stops issuing transfers until 8.1 sees a card.

### 8.3 The direct path under removal

Today (3.2): `EnableDMode()` clocks 4096 bits unconditionally into Gayle's
FIFO from whatever is on MISO. Pull the card and the FIFO fills with 1s, DRQ
rises (`gayle.v:358`), the Amiga reads 512 bytes of 0xFF as a valid sector,
and the firmware only notices on the *next* block when `MMC_ReadMultiple`
gets no data token -- and then goes fatal (3.5). Silent corruption followed by
a hang: the worst possible combination.

With the replay serialiser (5.1) the direct path is card -> sd_host buffer
(CRC checked) -> replay -> paula_floppy. The card is only involved in the
first hop. So under removal:

- A block that did not verify is never replayed. Gayle's FIFO stays empty,
  DRQ stays low, and the Amiga is still waiting on BSY -- which the firmware
  can now resolve honestly: `WriteStatus(IDE_STATUS_END | IDE_STATUS_RDY |
  IDE_STATUS_ERR)` clears `busy` (`gayle.v:299`) and sets `err`. The Amiga's
  scsi.device gets an I/O error for the command. `hdd.c:451` currently
  ignores `MMC_ReadMultiple`'s return value; it must take the error branch
  the file case already has (`hdd.c:443`), and `ATA_WriteSectors` needs the
  same for `MMC_Write` (`hdd.c:539`).
- A multi-sector command interrupted after N good sectors: the N sectors are
  already in the Amiga (that is inherent to PIO, not a defect); the command
  ends with ERR and the correct residual sector count, which is what a real
  drive does on a media error.
- `FileReadEx(..., 0, blk)` (`hdd.c:438`) returns through `fat.c:1477-1500`;
  its return value is ignored there too and must be propagated.

So the serialiser as proposed **covers it without extension**; the work is in
hdd.c's error paths, and the Stage 1 bench needs a "yank mid-block" test that
asserts the replay never starts and `buffer valid` never rises.

Resuming after re-insertion is then an ordinary retry: the Amiga's filesystem
reissues the read (8.5), the firmware's block layer is back in PRESENT, and the
same LBA maps to the same card sectors if it is the same card (8.4).

### 8.4 Firmware recovery on re-insertion

The ladder in 6.1 runs again from CMD0 (via `MMC_Init()`); then the firmware
decides between **same card** and **different card** by comparing the CID
(6.1 step 5, 128 bits, unique per card) with the one saved at mount time.
Volume serial from the boot sector would do as a fallback but is weaker.

**Same card back** -- everything that was true is true again, because every
piece of firmware state is expressed in card sectors and cluster numbers of a
volume that has not changed:

| State                              | Where                                                     | Action                                          |
|------------------------------------|-----------------------------------------------------------|-------------------------------------------------|
| `CardType`, capacity, RCA          | `mmc.c:42`, ladder                                        | Re-established by `MMC_Init()`. RCA is new; nothing else stores it. |
| Volume geometry (`fat_start`, `data_start`, `cluster_size`, ...) | `fat.c:56-72`                          | `FindDrive()` re-reads MBR and boot sector; results are identical. Cheap, do it anyway as a check. |
| Cached FAT sector `fat_buffer`, `buffered_fat_index` | `fat.c:80`                              | Invalidate (`buffered_fat_index = -1`): a write to the FAT could have been in flight. |
| `sector_buffer`                    | `fat.c:74`                                                | Nothing to do; it is transient.                 |
| Current directory, dir cache       | `fat.c:82-93`                                             | Re-scan on next OSD use; menu state already handles a directory change. |
| Open hardfiles `hdf[0..1]`         | `hdd.h:36-48`: `file` (start cluster, size), `index[]` (cluster chain every N sectors, `BuildHardfileIndex`), geometry, `offset` | Valid for the same volume. Keep; optionally re-run `FileOpen` on `config.hardfile[unit].name` (`hdd.c:770-800`) to confirm the file still exists and has the same size. |
| Card-partition hardfiles (`HDF_CARD*`) | `hdf[].offset`, `partition`                           | Valid for the same card. Keep.                  |
| Inserted floppies `df[0..3]`       | `fdd.h:16-25`: `cache[track]` = cluster of each track, `name`, `status` | Valid for the same volume. **Keep inserted**: the Amiga never sees a disk change, which is the best possible outcome. |
| Drive sounds, config, kickstart    | Loaded into RAM at boot                                   | Nothing to do. The Kickstart stays in SDRAM -- **no** `ColdBoot()`, no CPU reset. |

**Different card** -- nothing above can be trusted:

| State                | Action                                                                                                   |
|----------------------|----------------------------------------------------------------------------------------------------------|
| Floppies             | Eject all four (`df[i].status = 0`, `UpdateDriveStatus()`, `fdd.c:670-676`, as the OSD's eject does at `menu.c:550-553`). The Amiga sees "no disk", which trackdisk handles. |
| Hardfiles            | `hdf[unit].type = HDF_DISABLED`. Try `OpenHardfile(unit)` from `config.hardfile[unit].name` on the new card; if a file of the same name and size exists, re-enable, else leave disabled and say so in the OSD. Card-partition units (`HDF_CARD*`): re-enable only if the new card has the partition table the config expects -- simplest is to disable and let the user re-select. |
| Directory / config   | Re-scan root. Do not reload the config file (it would change screen modes under a running machine). |
| Kickstart, RAM       | Untouched. The running Amiga keeps running.                                                              |

**Not recoverable transparently**, and the plan should not pretend otherwise:

- A write that was in flight at removal (`MMC_Write`, `FileWrite`, the FAT
  update sequence at `fat.c:1576-1636` which writes FAT copies and the
  directory entry as separate sectors). The block is lost and the FAT can be
  inconsistent. Report it in the OSD ("card removed during write; check the
  card on a PC") and count it. The card's own write-atomicity per sector is
  the only protection.
- A different card with different files: the user re-selects images in the
  OSD. The firmware can only report what it could not re-open.
- A card removed while the boot ROM was loading `832OSDAD.BIN`: the boot ROM
  loop handles it (`boot.c:103-135`), by starting over.

### 8.5 What the Amiga sees -- honestly

Removal cannot be hidden from the Amiga, and should not be. What is achievable:

- **The 832 keeps running and keeps answering.** Card-gone is a non-fatal
  error, so `HandleFpga()` keeps being called (`main.c:315-317`) and every IDE
  command completes with ERR instead of leaving Gayle `busy` forever. This is
  the difference between "the Amiga shows a requester" and "the Amiga is dead".
- **Hardfiles: an I/O error, then a Retry requester.** scsi.device returns
  the error to the filesystem; FFS/PFS put up "Volume X has a read/write
  error" with Retry/Cancel. With the *same* card back and the firmware
  remounted, **Retry succeeds** and the volume continues -- open files
  included, because nothing on the card changed. This is exactly the
  behaviour of a real IDE drive that lost power briefly, and it is unverified
  on this core until Stage 3 tries it: if the Amiga's driver has already
  re-read a directory block and got ERR, some filesystems mark the volume
  invalid (`Cancel` route, "not a DOS disk" until reboot). Expect it to work
  for FFS; treat any stronger claim as untested. A *different* card: the
  volume is gone; a running Workbench with files open on it does not survive,
  and no plan can change that.
- **Floppies: a normal disk change.** Ejecting via `df[].status` is what
  trackdisk.device expects (it polls for disk change); re-inserting the same
  ADF later is a normal insert. For the same card the plan does not even
  eject, so the Amiga sees nothing at all beyond one slow track read.
- **The OSD says what happened.** "SD card removed" while gone (non-fatal
  page, `ShowError`, `menu.c:2557`), "SD card back: same card, N images
  remounted" or "different card: images ejected, re-select" on return; error
  counters from section 7.

Not achievable, and the plan does not claim it: a machine mid-DMA on the HDF
that notices nothing; a different card that transparently replaces the old
one; a write that was interrupted being completed later.

### 8.6 Hooking into the boot path fixed in 21729c5

Commit 21729c5 made `ColdBoot()` safe to call again: one exit that always
re-installs the interrupt handler and re-enables interrupts
(`main.c:229-237`), the CPU released only when a ROM actually loaded
(`main.c:220-223`), and error dismissal that clears `ErrorMask` instead of
latching (`menu.c:2257-2275`). The reset review's recommendation 3 ("retry
instead of giving up; a card inserted after power-up is currently never
noticed") is therefore the same feature as hot-swap at boot time, and the
plan uses that path rather than adding another:

- `main()` keeps `booted = ColdBoot()` (`main.c:277` today discards it) and a
  `card_state` from the block layer.
- The main-loop poll (8.1c) runs beside `adv_timer` (`main.c:283-300`). On a
  card appearing: if `!booted`, call `ColdBoot()` again -- it is the full
  power-up path (MMC_Init, FindDrive, config, Kickstart, CPU release) and
  since 21729c5 it is idempotent and safe. If `booted`, call a new
  `CardRemount()` (8.4) instead -- **not** `ColdBoot()`, which would reset
  the running Amiga (`main.c:143`).
- On a card disappearing: `card_state = GONE`, `SetError(ERROR_SDCARD, "SD
  card removed", ...)` non-fatal, so the error loop keeps servicing the FPGA;
  when the card returns and the remount succeeds, `ClearError(ERROR_SDCARD)`
  dismisses the page automatically.
- The fatal-error retry in `menu.c:2264-2265` is left alone; it is for ROM
  errors. Card errors no longer reach it (6.1, last bullet).

Nothing here touches the RTL half of the reset review (cpurst without a reset
term, no 832 restart, no watchdog). Those stay open; hot-swap only needs the
firmware half, which is done, plus the bounded timeouts in sd_host.

## 9. Staged plan

Each stage is a separate branch off `e2-t4` (or wherever E2 has landed by
then), builds the openaars image, and can be reverted by not merging it.
Hot-swap pieces are marked **[HS]** and sit in the stage whose interface they
change, not at the end.

### Stage 0 -- measure and de-risk (2 days)

Cheap experiments, no protocol change, no boot ROM change:

a. **Pin probe.** Make `sd_m_d1/d2` inputs (they are driven 1 today and the
   card leaves them high-Z in SPI mode, so this is electrically safe), read
   them back in cfide's `platformdata` (`cfide.vhd:178`, 12 free bits). Build
   once without and once with `PULLTYPE PULLUP`. Without pull-ups reading 1
   means the board has them; 0/random means it does not and the FPGA's must be
   used. This settles the pull-up question in 5.3 and confirms DAT1/DAT2 reach
   the FPGA at all. **[HS]** Read `sd_m_d3` back the same way with the card
   deselected, with and without a card: answers whether DAT3 sensing (8.1b)
   is even possible on this board.
b. **Software CRC16 on buffered SPI reads.** In `MMC_Read()` with a buffer
   (`mmc.c:246-257`) compute CRC16 over the 512 bytes (table-driven, 256 x 16
   bits in RAM) and compare with the two bytes currently discarded. Count
   mismatches; do not retry yet, just report. Same in the boot ROM if it fits.
c. **Hardware CRC16 monitor on the direct path.** ~40 lines in cfide: a CRC16
   LFSR over `sd_di_in` on the sampling edge while scs(6) is active, latched
   at the end of the 4096-bit shift; the firmware reads the next two SPI bytes
   (`mmc.c:388-389`) and compares against a new cfide read register. Counts
   only -- Gayle already has the sector (3.2). This is the number that says
   how bad the HDF path is today.
d. **[HS] Removal probe, firmware only, SPI mode.** CMD13 poll every 500 ms
   from the main loop; on timeout mark GONE and print it on the UART; on
   return run `MMC_Init()` and compare CID (CMD10 works in SPI mode). Turn the
   `mmc.c` `FatalError`s into `SetError` + return 0 and make `hdd.c:451`
   finish the IDE command with ERR. This alone converts "pull the card, reboot"
   into "pull the card, requester" on the current bitstream, and shows what
   the Amiga does with a Retry -- the answer to 8.5 before any RTL exists.
   **[HS] Card-detect pin:** Paul checks the board; if a CD line reaches an
   FPGA pin, note it here and in `sd_card.xdc`.

Riskiest assumption at this stage: that the board's DAT1-3 traces are
actually connected to the socket. If (a) shows them floating with no pull-up
and still floating *with* the internal pull-up enabled, something is wrong on
the board and only 1-bit mode is possible. **The plan still delivers the CRC
and hot-swap benefits in 1-bit mode; only Stage 4 evaporates.**

### Stage 1 -- sd_host in simulation, 1-bit (5-7 days)

- Write `sim/sdbus/sd_card_model.sv`: behavioural SD memory card, SD bus mode
  only. CMD0/8/55/ACMD41/2/3/7/9/10/13/16/17/18/24/12, ACMD6/42, CRC7/CRC16
  generation and checking, 1-bit and 4-bit data, sparse sector store,
  plusargs for error injection: flip a bit in block N, corrupt the CRC of
  block N, drop response to command K, hold busy for T, **[HS] and "remove
  at time T / re-insert at time T2"** (all lines to Z, CID changes on
  re-insert if asked, state machine back to idle-in-SD-mode). **No SD model
  exists in the repo** (`sim/minimig/nc/run/spi_memory.sv` is an SPI memory
  for the retired NC flow; `sim/rtc_spi_clock/rtc_spi_slave.sv` is an SPI
  slave), so this is new work and is most of the stage.
- Write `sim/sdbus/sd_host_tb.sv` driving cfide's host bus the way
  `sim/hostcpu-i2c-bridge/i2c_bridge_tb.sv:30-38,200-230` does
  (`addr/d/q/req/wr/ack`), with an xsim `run.sh` copied from `sim/ddr3_cpu/run.sh`
  (prj file, `xvhdl`/`xvlog`/`xelab`/`xsim`, `run_<variant>/` directories,
  PASS/FAIL grep). Include mutant legs that MUST fail, per the project habit:
  CRC checker disabled, replay serialiser off by one bit, **[HS] data timeout
  removed (the bench must then hang and be killed by its own watchdog -- that
  is the pass criterion for the mutant)**.
- Implement `sd_host` (5.1), the register map (5.2) **including abort, raw
  line levels, the bounded timeouts and their reason bits [HS]**, the replay
  serialiser, the `havesdbus` generic. Bench asserts: init ladder completes,
  single/multi block reads match the model's store, injected bit flip ->
  STATUS bit5 with the right lane, retry reads clean, write with injected CRC
  error -> bit7, replay delivers the exact 4096 bits into a paula_floppy-style
  slave stub, **[HS] removal in each row of the 8.2 table ends within the
  stated timeout with the stated bit, `buffer valid` never rises on a
  truncated block, abort returns the block to idle, and the ladder succeeds
  again on the re-inserted model**.

### Stage 2 -- boot ROM and firmware on SD bus mode, 1-bit, hardware (3-5 days)

- Boot ROM `spi.c` SDBUS body (6.2); firmware `sdbus.c` + `mmc.c` SD-bus body
  (6.1) with retries (7) and non-fatal errors. Card-state reset between boot
  ROM and firmware (4.3).
- Top-level inout ports, XDC changes (5.3), **[HS] CD pin if Stage 0d found
  one**.
- Bring-up over JTAG with the UART (`debugTxD`) showing the boot ROM's
  progress and an ILA on the six card lines if it does not talk. Vivado lab
  gotchas apply (memory note).
- Acceptance: boots Workbench from an HDF on three different cards (old SDSC,
  SDHC, SDXC) ten times each; error counters read zero or the retries are
  visible and the machine keeps going; OSD file browser, ADF and HDF writes
  work; the SPI-mode fallback in 4.2 verified once by putting an old
  `832OSDAD.BIN` on the card (only if the optional pin-ownership fallback in
  5.1 is built). **[HS] Pull the card at the Workbench: the machine does not
  hang, the OSD reports it, `ColdBoot()` is not triggered.**

Riskiest assumption: the spec's promise that CMD0 after the boot ROM's CMD7
resets the card cleanly and that the SD-mode-to-SPI-mode fallback works on real
cards. Both are tested here, before anything is flashed.

### Stage 3 -- direct path replay, retry, remount (4-5 days)

- Switch `MMC_ReadMultiple(lba, NULL, n)` to buffer-verify-replay (6.1).
- CMD17-per-block vs CMD18 decision by measuring HDF throughput both ways.
- `hdd.c` error paths finish every IDE command with a status write (8.3).
- **[HS] `CardRemount()`** (8.4): CID compare, same-card keep / different-card
  eject-and-reopen, `booted` flag and the main-loop poll wired as in 8.6.
- **[HS] Hardware hot-swap tests:** pull during idle, during a Workbench
  directory listing, during a large HDF copy, during an ADF track read,
  during an HDF write; re-insert the same card and a different one; for each,
  record what the Amiga showed and whether Retry worked. These results decide
  how much of 8.5 can be promised.
- Error counters in the OSD.
- Long soak: `dd`-style read of the whole card from the firmware with a
  running CRC compared against the same computed on a PC -- the "hash
  checking data in and out" that motivated this.

### Stage 4 -- 4-bit and clock (2-4 days, only if Stage 0a passed)

- ACMD42/ACMD6, CTRL 4-bit, 4 parallel CRC16 already in Stage 1.
- Timing constraints done properly for 18.9 MHz; try `/4` (28.4 MHz) with CMD6
  high-speed switch and `SLEW FAST` only if the soak stays clean.
- Boot ROM stays 1-bit (it reads 80 KB once; not worth the bytes).
- **[HS]** Re-run the removal tests in 4-bit mode: DAT3 is now data, so the
  DAT3-sense path (if it was ever used) must be disabled after ACMD6.

### Stage 5 -- cleanup (1 day)

- Remove Stage 0 monitors, or keep 0c as a permanent counter on the `havesdbus
  = false` path for the other boards.
- Update `plan-v2-with-ddr3.md:2007-2027` and the reset review's
  recommendation 3 to point here; name the last tag that builds
  mist/de0/de10.
- Flash the bitstream only after Stages 2-3 have run for a while over JTAG.

## 10. Risks

| Risk | Consequence | Mitigation / recovery |
|------|-------------|-----------------------|
| Boot ROM cannot initialise the card in SD bus mode (pull-ups, a card quirk, a bug) | No firmware loads: black screen, `ErrorCode(0xf00)` loop (`boot.c:105-134`) | JTAG-loaded only until proven; reset button reloads the flash image, which is untouched. UART prints from the boot ROM are the first diagnostic. |
| Firmware/bitstream mode mismatch on a card | Firmware finds no card, error screen | Boot ROM always loads whatever `832OSDAD.BIN` is on the card, so swapping the file fixes it. Optional SPI-ownership fallback (5.1) makes old firmware work anyway. |
| Board lacks pull-ups and internal ones are too weak at speed | CRC errors at 18.9 MHz | Stage 0a finds out; divider steps down; 1-bit still works. |
| DAT1-3 not actually wired | No 4-bit | Plan still delivers the CRC goal; Stage 4 dropped. |
| No card-detect line on the board | Removal noticed only by polling / failed transfer (up to 500 ms + longest timeout) | Acceptable: 8.1c is the design of record; a CD pin is an improvement, not a dependency. |
| Replay serialiser off by a clock relative to `sck` | HDF sectors shifted by a bit -- immediately visible as a non-booting HDF | Caught by the Stage 1 mutant leg before hardware. |
| A timeout too short for a slow card's busy after write (up to 250 ms is legal for SDSC, more for some SDXC) | False "gone" during writes | 500 ms busy timeout is above spec; the firmware only declares GONE after CMD13 also fails. Measured in the Stage 3 write tests. |
| Card pulled mid-write | Lost block, possibly inconsistent FAT | Not recoverable by design; reported, counted, user checks the card on a PC. Same as any removable medium. |
| Amiga filesystem gives up on the first ERR rather than offering Retry | Same-card re-insertion needs a reboot of the Amiga after all (832 and OSD still fine) | Measured in Stage 0d before any RTL; if so, the honest promise shrinks to "no hang, clean error, floppies survive". |
| Boot ROM outgrows 8 KB | Link fails | Measured in Stage 2 before synthesis; last resort is `maxAddrBitBRAM => 13` plus `prg_start` 0x4000 in both Makefiles and `832_bridge.vhd:147`. |
| Other board ports break (`SD_MISO` etc. ports change) | mist/de0/de10 do not build | Accepted by project rule; name the last building tag. |
| Card wedged in a state CMD0 does not clear | A card stuck in data state ignores commands | CMD12 + CMD0 recovers everything the spec allows; beyond that the user pulls the card -- which with this plan is now a supported operation rather than a reboot. |
| A bug in the cfide ack path stalls the 832 (the `IOcpuena` mechanism is subtle, cf. the multicycle exceptions for i2c at `wizard.xdc:29-32`) | Host CPU hangs on a DATA read | Blocking reads only while a transfer is in flight; every transfer ends by completion or timeout (5.1, 8.2), so a read can never block forever. There is no watchdog to catch it otherwise. |

## 11. Effort summary

| Stage | Content | Estimate |
|-------|---------|----------|
| 0 | pin probe (incl. DAT3), software CRC16 on SPI reads, hardware CRC16 monitor on the direct path, counters, **removal probe + non-fatal card errors + IDE ERR completion, CD-pin check** | 2 days |
| 1 | SD card model (with removal/re-insertion), sd_host 1-bit **with bounded timeouts, reason bits, abort, line monitors**, replay serialiser, xsim bench with mutants | 5-7 days |
| 2 | boot ROM + firmware on SD bus mode, top/XDC (+ CD pin), hardware bring-up, first pull-the-card test | 3-5 days |
| 3 | verified direct-path replay, retry policy, hdd.c error completion, **CardRemount and the hot-swap test matrix**, OSD counters, soak | 4-5 days |
| 4 | 4-bit, clock, constraints, removal re-test in 4-bit | 2-4 days |
| 5 | cleanup, docs, flash | 1 day |

Total about three and a half working weeks; hot-swap adds roughly three days
spread over Stages 0, 1 and 3. Stage 0 remains worth doing on its own: it now
produces the CRC error rate *and* shows how the Amiga reacts to a clean IDE
error after a card pull, which sizes the hot-swap promise before the RTL is
written.

## 12. Not verified by reading the code

- Whether the AARS v5 I/O board has SD pull-ups or series resistors (no
  schematic in `doc/`).
- **Whether the micro-SD socket's card-detect contact is wired to any FPGA
  pin.** `sd_m_cdet` exists as a port name only; no XDC places it. Paul has to
  check the board. Until then the plan assumes polling (8.1c).
- Whether the board has an external pull-up on DAT3, which decides if DAT3
  sensing (8.1b) is possible at all.
- The Artix-7 internal pull-up strength at 3.3 V (DS181 has the range).
- That every card in use honours the SD-mode-to-SPI-mode fallback; the spec
  says so, Stage 2 checks.
- How the Amiga's filesystems (FFS, PFS3) react to an IDE command that ends
  with ERR and then succeeds on Retry after the same card is re-inserted --
  the basis of the "Retry succeeds" claim in 8.5. Stage 0d measures it on the
  current bitstream.
- Worst-case busy time of the cards in use after a write (sets the 500 ms
  timeout margin).
- The exact behaviour of an unplaced `sd_m_cdet` in the current build: either
  Vivado trims it as unused or a build warning has been ignored for years.
  Either way there is no card detect today.
- The SPI bit rate quoted in section 1 is computed from `cfide.vhd:405-475`,
  not measured.
