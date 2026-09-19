# SD card: from SPI mode to SD bus mode -- implementation plan

Date 2026-09-19. Status: **plan only, nothing implemented.** Builds on the
backlog entry "The SD card is SPI, and should be SDIO" in
`findings/ap68040/plan-v2-with-ddr3.md:2007-2027`.

Naming: "SDIO" is strictly the I/O-card spec; what we want is the SD memory
card's native bus protocol (CMD/CLK/DAT0-3, CRC7 + CRC16). This document says
"SD bus mode" for that and keeps "SDIO" only where the backlog uses it.

## 1. Goal

**Integrity first.** Every command, response and data block on the SD bus
carries a CRC the card and host both check: CRC7 on CMD, CRC16 per DAT line.
A flipped bit on the wire becomes a detected error that can be retried instead
of a silently corrupt sector handed to a mounted filesystem (or written back to
the card). That is the reason to do this.

**Speed second.** 4-bit DAT at 25 MHz is roughly 10 MB/s raw against today's
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
- **Card detect.** `sd_m_cdet` has an IOSTANDARD (`sd_card.xdc:21`) but **no
  PACKAGE_PIN anywhere** and is unused in the RTL (declared
  `minimig_openaars_top.v:65`, never read). No hot-swap detection exists; card
  state after a swap must be inferred from CMD13 failures. Unchanged by this
  plan.
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
entry does not mention it.

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

## 4. The bootstrap problem

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
  clocks), busy detection on DAT0 for R1b.
- **Data unit.** 512-byte block buffer (one RAMB18, 256 x 16). Read: wait for
  start bit on DAT0 (timeout, 100 ms class), shift 1-bit or 4-bit, four
  parallel CRC16 (x^16+x^12+x^5+1) checkers, one per lane, compare with the
  16 CRC bits after the block, flag per-lane mismatch. Write: start bit, data,
  CRC16 per lane, end bit, then capture the 3-bit CRC status token on DAT0
  (010 accepted, 101 CRC error, 110 write error) and wait for busy release.
- **Replay serialiser** (the direct-path replacement, see 3.2). When armed, it
  substitutes for the card's MISO at cfide's `sd_dimm` input: on each falling
  edge of cfide's internal `sck` it presents the next bit of the verified
  block buffer, MSB first, so the existing `EnableDMode(); SPI(0xFF)` 4096-bit
  shift delivers a CRC-checked sector to `paula_floppy` **with paula_floppy,
  Gayle and hdd.c unchanged**. `sck` is a sysclk flop (`cfide.vhd:395,459`), so
  this is same-domain logic.
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
| 0x...20 +2  | CTRL: bit0 soft reset, bit1 4-bit mode, bit2 clock enable, bits 7:4 clock divider, bit8 arm replay, bit9 clear error counters | STATUS: bit0 busy, bit1 cmd done, bit2 cmd CRC7 err, bit3 resp timeout, bit4 data done, bit5 data CRC err, bit6 data timeout, bit7 write status != 010, bit8 DAT0 busy, bit9 buffer valid, bits 15:12 CRC-failing lane mask |
| 0x...24 +2  | ARG_HI (arg 31:16)                                                     | CRC error counter (data)                                                                            |
| 0x...28 +2  | ARG_LO (arg 15:0)                                                      | CRC error counter (cmd/resp)                                                                        |
| 0x...2C +2  | CMD: bits 5:0 index, bits 7:6 resp type (0 none, 1 48-bit, 2 48-bit busy, 3 136-bit), bit8 data read, bit9 data write, bit10 no-CRC response (R3). Writing starts the transaction. | RESP: each read pops the next 16 bits of the captured response, MSB first (3 reads for R1, 8 for R2), then wraps |
| 0x...30 +2  | DATA: push 16 bits into the block buffer (write pointer auto-increments) | DATA: pop 16 bits (read pointer auto-increments)                                                     |
| 0x...34 +2  | pointer reset (any write)                                              | buffer pointer / fill level (debug)                                                                 |
| 0x...38 +2  | -                                                                      | last CRC16 computed on lane 0 (debug, used by the Stage 0 SPI monitor too)                           |
| 0x...3C +2  | -                                                                      | CORE_SDBUS caps: bit0 sd_host present, bit1 4-bit supported, bits 7:4 RTL revision                  |

`ack` for these addresses: follow the SPI path, which asserts `IOcpuena` when
the engine is not busy (`cfide.vhd:351-355`, sysclk) and passes it out through
the `clk_28` ack process (`cfide.vhd:181-193`). Make DATA reads block while the
buffer is not valid the same way `SD_busy` blocks SPI, so the boot ROM's read
loop needs no polling. Do **not** copy the i2c_master_mmio arrangement
(`cfide.vhd:524-544`, on `clk_28`) -- it needed the multicycle exceptions at
`wizard.xdc:29-32` and the SPI engine's sysclk pattern is the simpler
precedent.

### 5.3 Top-level and constraints

- `minimig_virtual_top.v`: new ports for the six card lines as tristate pairs
  (`_i/_o/_t`), routed to cfide; `SD_MISO/SD_MOSI/SD_CLK/SD_CS` remain for
  boards without `havesdbus`. Other tops (`minimig_mist_top.v`,
  `minimig_de0_nano_top.vhd`, `minimig_de10lite_top.vhd`) are unmodified and
  get default values; per the project rule they may still break and the last
  tag that builds them should be named in the commit.
- `minimig_openaars_top.v:59-64,279-284`: ports become `inout`, driven with the
  PS/2-style `assign x = t ? 1'bZ : o` pattern.
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

1. Clock on at 18.9 MHz or slower, 74+ clocks with CMD high.
2. CMD0 (no response).
3. CMD8 arg 0x1AA, R7: echo check -> v2 card. No response -> v1 card.
4. ACMD41 (CMD55 + CMD41) arg HCS|voltage, R3 (no CRC), loop until bit31
   ready, up to 1 s; CCS bit -> `CARDTYPE_SDHC` else `CARDTYPE_SD`.
5. CMD2, R2 (136 bits): CID. Ignore contents.
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

### 6.2 Boot ROM (`fw/ctrl_boot_832`)

`spi.c` gains a `#ifdef SDBUS` body for `spi_init()` and `sd_read_sector()`
(`spi.c:225-268`, `280-334`) using the same register map; `boot.c` unchanged.
With CRC and framing in hardware the SD-bus body is *smaller* than the SPI one
(no `cmd_write` byte loop, no 0xFE token hunt). Budget: 2.5 KB free, target
under 1 KB added. Verify with `OSDBoot_832.map` before synthesis.

## 7. Error handling and retry -- the payoff

Concrete policy, same in boot ROM and firmware:

| Event                                  | Action                                                                                                                                   |
|----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| Response CRC7 error / response timeout | Re-issue the command up to 3 times. On CMD17/18/24 also send CMD12 first if the card may be in data state. Count in `cmd_crc_errors`.     |
| Read data CRC16 error (any lane)       | Discard buffer, re-issue CMD17 for that LBA up to 4 times with the clock divider stepped down one notch on the 3rd. Count in `data_crc_errors`, keep last bad LBA and lane mask. |
| Write CRC status 101                   | Re-send the block up to 4 times. 110 (write error): fail the write, `FatalError(ERROR_SDCARD, ...)` as today (`mmc.c:436`).               |
| Data timeout (no start bit)            | CMD12, CMD13 to learn the card state; if not `tran`, CMD7 reselect; retry once; then fail.                                                |
| 4 consecutive failures on one LBA      | Firmware: return 0 to the caller, existing `FatalError` path. Boot ROM: fall back to 1-bit (Stage 4) then to retrying the whole init, as `boot.c:103` already loops forever. |
| Error counters                         | Exposed in the OSD's system/about page and printed at boot on the UART, so a marginal card or socket shows as a number, not as a mystery crash. |

The counters are the thing to look at first after Stage 0: if they stay at
zero for weeks on real cards, the integrity gain of the remaining stages is
insurance rather than a fix, and Paul can decide whether the speed gain
justifies continuing.

## 8. Staged plan

Each stage is a separate branch off `e2-t4` (or wherever E2 has landed by
then), builds the openaars image, and can be reverted by not merging it.

### Stage 0 -- measure and de-risk (1-2 days)

Cheap experiments, no protocol change, no boot ROM change:

a. **Pin probe.** Make `sd_m_d1/d2` inputs (they are driven 1 today and the
   card leaves them high-Z in SPI mode, so this is electrically safe), read
   them back in cfide's `platformdata` (`cfide.vhd:178`, 12 free bits). Build
   once without and once with `PULLTYPE PULLUP`. Without pull-ups reading 1
   means the board has them; 0/random means it does not and the FPGA's must be
   used. This settles the pull-up question in 5.3 and confirms DAT1/DAT2 reach
   the FPGA at all.
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

Riskiest assumption at this stage: that the board's DAT1-3 traces are
actually connected to the socket. If (a) shows them floating with no pull-up
and still floating *with* the internal pull-up enabled, something is wrong on
the board and only 1-bit mode is possible. **The plan still delivers the CRC
benefit in 1-bit mode; only Stage 4 evaporates.**

### Stage 1 -- sd_host in simulation, 1-bit (4-6 days)

- Write `sim/sdbus/sd_card_model.sv`: behavioural SD memory card, SD bus mode
  only. CMD0/8/55/ACMD41/2/3/7/9/13/16/17/18/24/12, ACMD6/42, CRC7/CRC16
  generation and checking, 1-bit and 4-bit data, sparse sector store,
  plusargs for error injection: flip a bit in block N, corrupt the CRC of
  block N, drop response to command K, hold busy for T. **No SD model exists
  in the repo** (`sim/minimig/nc/run/spi_memory.sv` is an SPI memory for the
  retired NC flow; `sim/rtc_spi_clock/rtc_spi_slave.sv` is an SPI slave), so
  this is new work and is most of the stage.
- Write `sim/sdbus/sd_host_tb.sv` driving cfide's host bus the way
  `sim/hostcpu-i2c-bridge/i2c_bridge_tb.sv:30-38,200-230` does
  (`addr/d/q/req/wr/ack`), with an xsim `run.sh` copied from `sim/ddr3_cpu/run.sh`
  (prj file, `xvhdl`/`xvlog`/`xelab`/`xsim`, `run_<variant>/` directories,
  PASS/FAIL grep). Include mutant legs that MUST fail, per the project habit:
  CRC checker disabled, replay serialiser off by one bit.
- Implement `sd_host` (5.1), the register map (5.2), the replay serialiser,
  the `havesdbus` generic. Bench asserts: init ladder completes, single/multi
  block reads match the model's store, injected bit flip -> STATUS bit5 with
  the right lane, retry reads clean, write with injected CRC error -> bit7,
  replay delivers the exact 4096 bits into a paula_floppy-style slave stub.

### Stage 2 -- boot ROM and firmware on SD bus mode, 1-bit, hardware (3-5 days)

- Boot ROM `spi.c` SDBUS body (6.2); firmware `sdbus.c` + `mmc.c` SD-bus body
  (6.1) with retries (7). Card-state reset between boot ROM and firmware (4.3).
- Top-level inout ports, XDC changes (5.3).
- Bring-up over JTAG with the UART (`debugTxD`) showing the boot ROM's
  progress and an ILA on the six card lines if it does not talk. Vivado lab
  gotchas apply (memory note).
- Acceptance: boots Workbench from an HDF on three different cards (old SDSC,
  SDHC, SDXC) ten times each; error counters read zero or the retries are
  visible and the machine keeps going; OSD file browser, ADF and HDF writes
  work; the SPI-mode fallback in 4.2 verified once by putting an old
  `832OSDAD.BIN` on the card (only if the optional pin-ownership fallback in
  5.1 is built).

Riskiest assumption: the spec's promise that CMD0 after the boot ROM's CMD7
resets the card cleanly and that the SD-mode-to-SPI-mode fallback works on real
cards. Both are tested here, before anything is flashed.

### Stage 3 -- direct path replay and retry policy on hardware (2-3 days)

- Switch `MMC_ReadMultiple(lba, NULL, n)` to buffer-verify-replay (6.1).
- CMD17-per-block vs CMD18 decision by measuring HDF throughput both ways.
- Error counters in the OSD.
- Long soak: `dd`-style read of the whole card from the firmware with a
  running CRC compared against the same computed on a PC -- the "hash
  checking data in and out" that motivated this.

### Stage 4 -- 4-bit and clock (2-4 days, only if Stage 0a passed)

- ACMD42/ACMD6, CTRL 4-bit, 4 parallel CRC16 already in Stage 1.
- Timing constraints done properly for 18.9 MHz; try `/4` (28.4 MHz) with CMD6
  high-speed switch and `SLEW FAST` only if the soak stays clean.
- Boot ROM stays 1-bit (it reads 80 KB once; not worth the bytes).

### Stage 5 -- cleanup (1 day)

- Remove Stage 0 monitors, or keep 0c as a permanent counter on the `havesdbus
  = false` path for the other boards.
- Update `plan-v2-with-ddr3.md:2007-2027` to point here; name the last tag
  that builds mist/de0/de10.
- Flash the bitstream only after Stages 2-3 have run for a while over JTAG.

## 9. Risks

| Risk | Consequence | Mitigation / recovery |
|------|-------------|-----------------------|
| Boot ROM cannot initialise the card in SD bus mode (pull-ups, a card quirk, a bug) | No firmware loads: black screen, `ErrorCode(0xf00)` loop (`boot.c:105-134`) | JTAG-loaded only until proven; reset button reloads the flash image, which is untouched. UART prints from the boot ROM are the first diagnostic. |
| Firmware/bitstream mode mismatch on a card | Firmware finds no card, `FatalError` screen | Boot ROM always loads whatever `832OSDAD.BIN` is on the card, so swapping the file fixes it. Optional SPI-ownership fallback (5.1) makes old firmware work anyway. |
| Board lacks pull-ups and internal ones are too weak at speed | CRC errors at 18.9 MHz | Stage 0a finds out; divider steps down; 1-bit still works. |
| DAT1-3 not actually wired | No 4-bit | Plan still delivers the CRC goal; Stage 4 dropped. |
| Replay serialiser off by a clock relative to `sck` | HDF sectors shifted by a bit -- immediately visible as a non-booting HDF | Caught by the Stage 1 mutant leg before hardware. |
| Boot ROM outgrows 8 KB | Link fails | Measured in Stage 2 before synthesis; last resort is `maxAddrBitBRAM => 13` plus `prg_start` 0x4000 in both Makefiles and `832_bridge.vhd:147`. |
| Other board ports break (`SD_MISO` etc. ports change) | mist/de0/de10 do not build | Accepted by project rule; name the last building tag. |
| Card power-cycle impossible after a wedged state | A card stuck in data state ignores commands | CMD12 + CMD0 recovers everything the spec allows; beyond that the user pulls the card, as today. |
| Bugs in the cfide ack path stall the 832 (the `IOcpuena` mechanism is subtle, cf. the multicycle exceptions for i2c at `wizard.xdc:29-32`) | Host CPU hangs on a DATA read | Blocking reads only while a transfer is in flight; timeouts in the controller always complete the transfer with an error flag so a read can never block forever. |

## 10. Effort summary

| Stage | Content | Estimate |
|-------|---------|----------|
| 0 | pin probe, software CRC16 on SPI reads, hardware CRC16 monitor on the direct path, counters | 1-2 days |
| 1 | SD card model, sd_host 1-bit, replay serialiser, xsim bench with mutants | 4-6 days |
| 2 | boot ROM + firmware on SD bus mode, top/XDC, hardware bring-up | 3-5 days |
| 3 | verified direct-path replay, retry policy, OSD counters, soak | 2-3 days |
| 4 | 4-bit, clock, constraints | 2-4 days |
| 5 | cleanup, docs, flash | 1 day |

Total about three working weeks, of which the first two days (Stage 0) are
worth doing on their own and produce the number that decides the rest.

## 11. Not verified by reading the code

- Whether the AARS v5 I/O board has SD pull-ups or series resistors (no
  schematic in `doc/`).
- The Artix-7 internal pull-up strength at 3.3 V (DS181 has the range).
- That every card in use honours the SD-mode-to-SPI-mode fallback; the spec
  says so, Stage 2 checks.
- The exact behaviour of `sd_m_cdet`: the port exists in the top but has no
  placement, so either Vivado trims it as unused or a build warning has been
  ignored for years. Either way there is no card detect.
- The SPI bit rate quoted in section 1 is computed from `cfide.vhd:405-475`,
  not measured.
