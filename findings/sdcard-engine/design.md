# SD card peripheral: one interrupt-driven SPI path for all card traffic

Status: design, approved by Paul 2026-10-24.  Branch `sdio`
(worktree `../MinimigAGA_TC64-sdio`, based on `retire-832` 410470a3).
Board: QMTech XC7A100T on the Open AARS I/O board v4.

## 1. Why

Paul copied a directory of many small files (~500 MB) from the SD card's FAT
side into an HDF on the same card.  It took about an hour (~140 KB/s) and the
OSD's about-screen animation crawled meanwhile.

Paul's brief (2026-10-24, verbatim): *"I want a unified way of handling SPI
bus traffic to and from the card, that doesn't involve the OSD CPU being in
busy waiting state, while being correct and ruling out corruption on the
SD-card."*  And: *"Make sure the hardware stays compatible with the Amiga
hardware."*

Target: the same copy in about **10 minutes** (~850 KB/s; source and
destination share the card, so ~1.7 MB/s on the card's bus).  The card stays
in **SPI mode** (section 9).

## 2. What is there today (verified 2026-10-24)

- **OSD CPU:** VexRiscv RV32IMC (`rtl/host/rv_hostcpu.v`), firmware `fw/ctrl`,
  boot loader `fw/ctrl_boot` (3.6 KB).  The 832 is retired.  The CPU's
  hardware window is **16 bits wide** (data in bits 15:0, acked on clk_28:
  `rv_hostcpu.v:15`, `host_bridge.vhd:34`).
- **One SPI shift register for everything** (`rtl/host/cfide.vhd`), one SCK,
  chip selects (`fw/ctrl/hardware.h:80-89`):

  | Select | Macro | Goes to | Traffic |
  | --- | --- | --- | --- |
  | `scs(1)` | `EnableCard` | the SD card | all card commands and data |
  | `scs(4)` | `EnableFpga` | SPI slave in `rtl/minimig/paula_floppy.v` | `HandleFpga` poll every main-loop pass, Gayle task file/status/xfer setup, IDENTIFY and packet data, today's HDD write data, floppy MFM tracks |
  | `scs(5)` | `EnableOsd` | `userio_osd_spi` | OSD text/graphics, config commands, keys |
  | `scs(6)` | `EnableDMode` | direct mode: `paula_floppy.v` snoops the card's data-out into the Gayle FIFO | HDD/CD reads |
  | `scs(7)` | `EnableRTC` | not connected on this board (PCF2123 has its own logic) | -- |

  Byte-at-a-time and polled: `SPI(x)` writes the data register and reads it
  back; the read stalls the CPU until the byte has shifted
  (`fw/ctrl/hardware.h:99`).  `SPI_fast()` = ~18.9 MHz SCK.
- **Interrupts today:** VBL, I2C and Akiko set `cfide`'s legacy flag
  (`cfide.vhd:376-378`); the handler (`main.c` `inthandler`) runs the Akiko
  and keyboard handlers.  A 16-source controller with spare `irq_src` bits
  exists (`cfide.vhd:384-408`) but no firmware uses it; using it means
  `IrqInstall()`, which turns the legacy flag off (`fw/ctrl/arch/irq.c`), so
  VBL/I2C/Akiko/keyboard handling moves over too.
- **Direct-mode reads are unchecked:** SPI-mode CRC is off and the read CRC
  bytes are thrown away; a bad or all-`$FF` block (card pulled) reaches the
  Amiga's filesystem.
- **Writes** (`fw/ctrl/hdd.c` `ATA_WriteSectors`): per sector, the CPU reads
  512 bytes from Gayle over the `scs(4)` link into RAM, sends them with CMD24
  (`fw/ctrl/mmc.c` `MMC_Write`) and spins on card busy.  No CMD25.  The
  Amiga gets its per-group IRQ and END only after the card has finished.
- **Gayle (`rtl/minimig/gayle.v`):** emulates the A600/A1200 IDE port and the
  drive controller; two ports (`gayle_port.v`), each with a task file, IRQ and
  an 8 KB sector FIFO (`gayle_fifo.v`).  Firmware-side port is parallel:
  `hdd_data_out[15:0]`, `hdd_data_in[15:0]`, `hdd_data_wr`, `hdd_data_rd`,
  `hdd_port`, `hdd_cmd_req`, `hdd_dat_req`, ...; `paula_floppy.v` drives it
  from its SPI slave.  The firmware sees only busy and data-request, not FIFO
  levels (`gayle.v:343-345`, `gayle_port.v:337,353`).  Reads:
  `drq = fifo_full & pio_in` and the Amiga's IRQ fires on a **rising DRQ
  edge** (`gayle_port.v:278-284,337`): a block put in before the Amiga drained
  the previous one would keep DRQ high, lose the IRQ and stall READ MULTIPLE,
  so today's "drain, then refill" order is Amiga-visible behaviour.  Any IDE
  command over `scs(4)` re-latches `hdd_port` (`paula_floppy.v:373-376`):
  that is why `CD_AudioPoll` must not run inside a transfer
  (`fw/ctrl/cdrom.h`).
- **Main loop (`fw/ctrl/main.c`):** one disk command runs to completion before
  the UI runs again; the about screen redraws stars and six logo lines on
  every pass, untimed (`menu.c` `MENU_ABOUT2`).
- **Boot RAM:** 8 KB shared by the boot code (bottom) and the main firmware's
  stack, which may grow down to `STACK_FLOOR` 0x1400 (`fw/ctrl/stackcheck.h:8`,
  `fw/ctrl/arch/firmware.ld:68`).
- **Board (schematic, Paul):** 10 k pull-ups to 3V3 on CMD, DAT0-3 and CLK;
  card detect `FPGA_SD_SW` on **pin F23, bank 15**, low = inserted, 10 k
  pull-up R25 + 100 nF C30 (no `PACKAGE_PIN` for `sd_m_cdet` in the XDC yet,
  unused in the RTL); card VDD hard-wired to 3V3; no 1.8 V.
- **Card model in `sim/`:** `sim/common/sd_spi_model.v` (SPI mode, no CRC
  checking).
- **Device fill (newest report, `stage_fast56_ld_move`):** LUTs 80 %, slices
  96.7 %, block RAM 119 / 135.  `retire-832` misses clk_114 by -0.144 ns
  (Paul's decision on that is pending).

## 3. Requirements

1. **Unified:** every card transfer -- FAT and directory sectors, config, ROM
   and ADF loading, ADF writes, HDF and ISO sectors, CD audio -- goes through
   one peripheral with one set of rules, the boot loader included.
2. **No busy waiting:** the OSD CPU starts a step and is told by interrupt
   when it is done, needs data, or failed.  It never spins on a byte, a token,
   card busy or a FIFO flag, and never stalls on the card.  The main loop
   (keys, OSD, CD audio, drive sounds) keeps running during disk work.
3. **Correct, and no corruption on the card** -- the overriding requirement:
   - no partial block is ever sent to the card;
   - no block whose CRC failed is ever handed to the Amiga or the firmware;
   - every wait ends in bounded time with a reason;
   - every error reaches the Amiga as an IDE error, never as good data, and is
     never silently dropped.
4. **Amiga-compatible:** what the Amiga sees -- Gayle's registers, IDE
   status/DRQ/IRQ behaviour and its timing rules, PIO through `$DA0000`, the
   floppy hardware -- stays exactly as it is.  No new Amiga-visible registers
   or autoconfig boards.  Drivers (scsi.device, atapi/CD drivers, trackdisk)
   cannot tell the difference except by speed.
5. **Fast:** the copy above in ~10 minutes (but see 9.1).
6. **Fits:** small enough for a nearly full device; no worse clk_114 than
   placement noise explains.

## 4. The peripheral (RTL)

A new **SPI peripheral** owns the card's pins.  It is **protocol-agnostic**:
it moves bytes and knows nothing about SD commands; the firmware runs the SD
protocol.  `cfide`'s shift register keeps the on-chip links (`scs(4)` Gayle /
floppy, `scs(5)` OSD) unchanged this round.  The card having its own SPI
master means card transfers and OSD / Gayle-link traffic run at the same time.

### 4.1 Parts

1. **TX and RX FIFOs** in one RAMB18 (2 KB; split is the builder's call, each
   side at least one 512-byte block plus its CRC).  **High/low watermark
   interrupts** per side.  For data blocks the FIFO works in block-sized
   slots: a block is either complete or not there.  The CPU reaches the FIFOs
   through a data-port register in its 16-bit hardware window.
2. **Byte shifter:** clocks bytes from TX to the pins and from the pins to RX;
   pauses SCK when TX is empty or RX is full (SPI mode tolerates any gap in
   SCK, so pausing is always safe).  A transfer length counter; CS control.
3. **CRC16 accumulator** (CCITT, as SD uses), switched on per transfer by the
   CPU: on TX it can append the two CRC bytes after the data; on RX it checks
   the two CRC bytes following the data and gives one **match / no match**
   bit.  CRC7 for the 6-byte commands: the builder decides between a small
   CRC7 option in the same unit or a table in firmware.
4. **Wait-for-byte mode:** clock `$FF` until the received byte equals / differs
   from a value the CPU set, with a timeout; nothing enters the RX FIFO while
   waiting; one interrupt when it ends (with the byte, or "timeout").  Covers
   waiting for a response, for the data start token and for card busy to end.
5. **Gayle block DMA** (between the RX/TX FIFO and Gayle's sector FIFO only,
   never the CPU's RAM), through a mux on Gayle's existing parallel firmware
   port (`hdd_data_out/in`, `hdd_data_wr/rd`, `hdd_port`):
   - *read:* after a whole block plus CRC is in RX **and the CRC matched**,
     one CPU command moves the block into the Gayle FIFO;
   - *write:* one CPU command moves a full sector (Gayle signals it with
     `dat_req`) from the Gayle FIFO into TX.  The block stays in TX until the
     card has accepted it, so a resend after a rejected write is the
     identical data.
   - Clock-domain crossing to Gayle's clock is part of this block.
   - While the DMA owns the Gayle data path, the mux keeps `paula_floppy.v`'s
     side off it and the firmware sends no IDE command over `scs(4)` that
     would re-latch `hdd_port`.
6. **Status, counters, interrupt:** state, last end reason (done, CRC
   mismatch, wait timeout, card gone, abort), bytes/blocks moved.  One
   interrupt line to the RISC-V via a spare `cfide` `irq_src` bit, with cause
   bits: TX low / RX high watermark, transfer done, wait done, DMA done,
   error, card detect change.
7. **Abort:** the CPU can stop any transfer, wait or DMA; the peripheral ends
   cleanly and reports where it stopped.
8. **Card detect:** `sd_m_cdet` on F23 (bank 15; check its VCCO for the
   IOSTANDARD), synchronised and debounced.  Pulling the card ends the current
   operation at once with "card gone" and raises an interrupt.
9. **Version/capability register** (for the lock-step check in 5.5).

### 4.2 Pins and clock

- SCK, CMD (MOSI), DAT3 (CS), DAT0 (MISO) from the new peripheral; DAT1/DAT2
  stay high as today.
- SCK from clk_114 with a divider: ~400 kHz for init, up to 25 MHz (the SPI
  mode limit) for data, duty cycle within the SD spec; the firmware can lower
  it (retry table).
- `sd_card.xdc`: constraints for the new pin registers; today's `spi_sck`
  generated clock stays for the on-chip slaves, the card gets its own.

### 4.3 Budget and style

Target **under ~600 LUTs plus one RAMB18** for the peripheral and the Gayle
mux.  If it goes over, stop and report before growing it.  Prove size and
timing in a small out-of-context project first ("iterate small"), not in full
builds.  Plain Verilog/VHDL, no vendor primitives (core stays vendor-neutral);
other board tops keep today's path and must still elaborate.

## 5. Firmware

### 5.1 Card driver

`fw/ctrl/mmc.c` keeps its API (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`
incl. the "to Gayle" form, `MMC_Write`), plus a multi-block write and
asynchronous start/complete calls.  It runs the whole SD SPI protocol:
commands, responses, tokens, CRC on (**CMD59** after init, so the card also
checks every command and written block), CMD25 multi-block writes, ACMD22.

- **Writes:** CMD25 per contiguous run (an HDF is contiguous within a
  cluster; split at cluster boundaries with the existing cluster index).
  ACMD23 pre-erase is the builder's call.
- **Write-done timing stays exactly as today (Paul):** the Amiga gets the
  per-group IRQ (`WriteStatus(IRQ)`) and END only after the card has finished
  programming those sectors -- for a CMD25 run, after the stop token's busy is
  over.  A CMD25 run never spans an IRQ group boundary.  No write-back.
- **Reads to Gayle keep today's order:** a block (or READ MULTIPLE group) goes
  into the Gayle FIFO only after the Amiga drained the previous one; the card
  side may read ahead into RX meanwhile.
- **Retry policy (Paul):**

  | Failure | Retries | Then |
  | --- | --- | --- |
  | Command response CRC wrong | 3 | CMD13; if that times out too, the card is gone |
  | Read block CRC wrong | 4, re-read from the failed block | 3rd retry also drops SCK one step |
  | Write block rejected, CRC (`0x0B`) | 4, resend the same block from TX | 3rd retry also drops SCK one step |
  | Write block rejected, write error (`0x0D`) | 0 (the card failed to program) | error at once |
  | Timeout (response, token, busy) | 3 | CMD13; if that times out too, the card is gone |

  A lowered SCK stays lowered until the next reboot.  After a failed
  multi-block write, ACMD22 says where to resume.  When retries run out the
  IDE command ends with ERR, the OSD shows the error, the counters record it;
  the Amiga's filesystem shows its normal Retry/Cancel requester.
  `FatalError` on a card error becomes an error return: a card error must not
  wedge the firmware.

### 5.2 Interrupt-driven disk commands

HDD and CD command handlers become state machines advanced by the
peripheral's interrupts (send command -> wait for R1 -> wait for token ->
receive block -> CRC ok -> DMA to Gayle -> ...).  The main loop runs between
steps.  The interrupt handler only records causes; the state machines run
from the main loop or the handler (builder's call, re-entrancy-safe).

- **One card operation at a time:** an operation is one command run on the
  card (one CMD17/18/24/25 up to its end), not a whole ATA command.  Long ATA
  transfers are split into bounded runs, so CD audio refill (which today runs
  between blocks) does not get worse.  Other card users (CD audio refill,
  file selector, config save, ADF access) queue and get the card between
  runs.
- The interrupt controller moves to `irq_src` / `IrqInstall()`, with VBL,
  I2C, Akiko and keyboard handling moved along.
- The about screen (stars, logo, scroller) redraws on a timer.

### 5.3 Instrumentation (first, on today's path)

Counters: disk commands per second; **sectors per command, as a histogram,
read and write separately**; time the card is busy; time waiting for the
Amiga (Gayle FIFO); CRC errors and retries per kind; main-loop pass time.
Shown in DebugMode and on the UART.

### 5.4 Boot loader

`fw/ctrl_boot` uses the same peripheral (it may simply wait on its status:
nothing else runs then), so there is one card path.  Its code must stay
**below 0x1400** (~1.4 KB more than today).  CRC in the boot loader is the
builder's call.

### 5.5 Bitstream and firmware in lock-step (Paul)

A firmware file built for the old card path cannot work with the new
bitstream.  The boot loader (inside the bitstream, so always matching) checks
the firmware file's version against the version register before jumping to
it; on a mismatch it **stops with a clear message on the OSD and hangs**.  No
fallback to the old path.

## 6. Verification

- **Peripheral bench (Verilator; xsim/iverilog as X-check):** extend
  `sim/common/sd_spi_model.v` with CRC checking, CMD59, CMD25/ACMD22, and
  error injection (bad response CRC, bad data CRC both ways, data rejected,
  long busy, no response, card pulled mid-block), so the RV L3 benches get it
  too.  ZipCPU's `sdspi` bench (GPLv3) is a reference.  Cases: watermarks,
  SCK pause on full/empty, wait-for-byte with timeout, CRC append/check,
  Gayle DMA both ways, abort in every state, card detect.
- **Mutant legs** (project practice): CRC check disabled, DMA allowed before
  the CRC result, a timeout removed -- the bench must catch each.
- **Gayle path:** extend `sim/gayle` so whole ATA READ/WRITE MULTIPLE runs go
  through the peripheral and the card model with the Amiga as PIO master,
  including the Amiga stopping mid-sector or abandoning a command; DRQ/IRQ
  timing as today.  The `scs(4)` link regressions stay green.
- **Firmware host tests** (`fw/ctrl/test`, mock_hw): the SD protocol layer,
  the retry table, cluster-run splitting, write-done timing, the
  one-operation-at-a-time rule, error reporting, the lock-step check.  The
  existing suite stays green.
- **Full system:** the RV L3 benches boot and run an HDF read/write through
  the peripheral.
- **Board:** write tests only on a scratch card or a copy of an HDF, never
  Paul's real disk; Claude never writes the card itself.  Each step: the
  small-files copy timed, file checksums against the source, a filesystem
  check of the HDF.

## 7. Order

1. **Baseline:** instrumentation + about-screen timer on today's path; Paul
   runs the copy (OSD closed / about screen open).
2. Peripheral + card model + bench (sim only).
3. Driver, interrupts and boot loader on the peripheral; reads (sim, then
   board).
4. Gayle DMA reads, then writes (sim, then board on a scratch card).
5. Interrupt-driven command state machines; UI during transfers.
6. Measure against the target.
7. **Later, optional:** a second instance of the same peripheral for the
   on-chip links (`scs(4)` Gayle/floppy, `scs(5)` OSD), so OSD drawing and
   floppy tracks stop stalling the CPU too and one SPI design serves
   everything.  Not this round: the card path is where the corruption risk
   and the speed problem are.

## 8. Goals, non-goals, anti-goals

**Goals:** requirements 1-6.

**Non-goals:** SD native mode; DMA into Amiga or CPU memory; any Amiga-side
change; the floppy MFM encoding; changing the on-chip links this round;
hot-swap beyond "a pulled card is an error, not a hang or bad data"; other
boards beyond "still elaborates".

**Anti-goals (failure even if fast):** any corrupted block on the card or
handed to the Amiga; data reported written before the card has it; a card
that worked before and now does not; a hang anywhere in the disk path (the
lock-step stop is a deliberate, messaged halt, not a hang); an Amiga-visible
change in Gayle/IDE behaviour; a worse clk_114.

## 9. Notes

### 9.1 Small files are bounded by per-command latency

The filesystem writes small files as many short, synchronous ATA commands
(headers, bitmap, directory blocks).  CMD25 helps only multi-sector commands;
each short write still pays the firmware's command handling plus one card
programming cycle (often a millisecond or more), and with write-done timing
unchanged the Amiga sees it.  So the baseline histogram (5.3) decides whether
10 minutes is reachable; cutting the firmware's per-command overhead matters
as much as the data path; and the card itself matters (A1/A2-rated cards are
specified for fast small random writes).  Accepted by Paul as long as the OSD
CPU never stalls on it.

### 9.2 Set aside: SD native 4-bit mode

Considered 2026-10-24, and earlier in
`findings/sdio/2026-09-19-sdio-implementation-plan.md` (832-era,
integrity-first).  A faster bus, but a card in SPI mode returns to native mode
only after a power cycle, which this board cannot do, and it does not touch
the per-command latency of 9.1.  Revisit only if the measurements after step 6
show the SPI bus itself is the limit.

### 9.3 Considered and dropped

- **SD-aware framing in hardware / a descriptor list:** more RTL; the
  protocol-agnostic FIFO plus three helpers does the same with the protocol
  in firmware (Paul, 2026-10-24).
- **Gayle's 8 KB FIFO as the verify buffer:** DRQ rises at `fifo_full`
  (`gayle_port.v:337`), before the block's CRC has arrived; would need a
  Gayle change to save ~10 us of copying per sector.
- **DMA into the RISC-V's RAM:** a bus master into host memory; the data port
  moves a sector in roughly 25 us (estimate), enough.
- **Yield points instead of interrupt-driven state machines:** with the
  interrupt-driven peripheral there is no busy waiting to replace (Paul).

## 10. Left to the builder

Register map and its place in the RISC-V hardware window; FIFO split and
slot handling; CRC7 in hardware or firmware; CDC method; exact SCK dividers;
timeout values and their hard limits; how the state machines are structured
within 5.2; ACMD23; CRC in the boot loader.  Each decision goes into this
document with a one-line reason.

## 11. Decisions

| Decision | By | Why |
| --- | --- | --- |
| Stay in SPI mode | Paul | native mode is a big change; SPI with gapless transfers may be enough |
| Unified path, no busy waiting, correctness first | Paul | his brief |
| Amiga-visible hardware unchanged | Paul | compatibility |
| Protocol-agnostic SPI peripheral: FIFOs + watermark IRQs + CRC16 accumulator + wait-for-byte + Gayle block DMA | Paul, Claude | firmware runs the protocol; hardware removes byte stalls, CPU copies and polling |
| Card on its own SPI master; on-chip links stay on `cfide` this round, second instance later | Claude, Paul agreed | parallel card and OSD traffic; limit what can break at once |
| CRC on (CMD59) + store-and-forward both ways | Claude | no partial or unverified block reaches the card or the Amiga |
| Write-done timing as today; no write-back | Paul | nothing reported written before the card has it |
| Retry table (3 / 4 / 4 / 0 / 3, SCK step-down on the 3rd data retry) | Paul | bounded, safe because of store-and-forward |
| Bitstream/firmware lock-step; mismatch = OSD message + hang | Paul | |
| Card detect on F23 (bank 15) | Paul | |
| Card shared per command run; long ATA transfers split into bounded runs | Claude | CD audio refill must not get worse |
| Boot loader below 0x1400 | forced | firmware stack floor in the shared boot RAM |
| Base on `retire-832`, branch `sdio`; timing measured against its build after Paul's timing fix | Claude | the 832 is retired |
| Baseline with a sectors-per-command histogram first | Claude, Paul agreed | 9.1: small files are latency-bound |
| TX keeps every sent byte until TX_COMMIT / TX_FLUSH; TXLVL counts kept bytes | plan, Claude (Task 6) | a block is resent from TX, never from a CPU copy |
| TX_REWIND goes back to the commit point (the oldest kept byte), not to the start of the last TX op | Claude (Task 6) | a retry needs a new command first; it is pushed behind the kept block and sent, then the rewind goes back to the token |
| Interlock: `verified` bytes at the RX head + sticky `poisoned`; RX_TO_GAYLE needs !poisoned and verified >= LEN; a good block counts only if RX held nothing unverified when it started; while poisoned even good bytes ahead wait for RX_FLUSH | controller ruling (Task 6) | read-ahead makes a single crc_ok bit unsafe (bad A + good B) |
| Gayle handshake, clk_114 side: g_req level for the op (may last 1 cycle); g_dir / g_port / g_words registers stable with it; dir 1: g_wdata + register g_wvalid (full word at the RX head), g_wnext only while g_wvalid (3 cycles per word at best), a g_wnext without g_wvalid is a Gayle error; dir 0: g_rvalid + g_rdata pulses >= 2 apart; g_ack ends (short count = error), g_err aborts; full text in the header of `rtl/host/sdcard_spi.v` | controller ruling, Claude (Task 6, fix round 1) | Task 7's bridge needs a fixed contract; a fixed word spacing was not self-checking, and the clk_28 CDC can make it 3 |
| CPU data port locked during a Gayle op: pushes dropped, pops read 0000, STATUS 8 | Claude (Task 6) | one TX writer for the rollback, a fixed dir 1 latency, no CPU pop can steal block bytes |
| GAYLE_TO_TX refused unless TX has room for LEN; any end but a full g_ack rolls TX back to its state at the start | ruling + Claude (Task 6) | no partial block in TX; a runtime overflow check would save 9 LUTs but start transfers that cannot finish |
| ABORT: XFER / waits stop at the next byte boundary (at once when paused, and Gayle ops); done IRQ only; idle ABORT a no-op with done IRQ; STATUS 8 kept | ruling, Claude (Task 6) | the card's byte framing stays intact; an abort is asked for, not a fault; a late ABORT must not wipe the result of the op that just finished |
| Card gone: the synchronised (not debounced) level ends any op at once, mid-byte too (SCK low, MOSI high) | controller ruling (Task 6) | 4.1 item 8 "at once"; with the card gone byte framing does not matter |
| Timeout bounds wait ops only, ends at the next byte boundary; counts units up and compares with TIMEOUT, so TIMEOUT writes are ignored while busy (like LEN / MATCH) | Claude (Task 6) | XFER pauses are the firmware's own FIFO handling, Gayle ops Amiga-paced (ABORT); byte framing; 32 LUTs less than a loaded down-counter |
| CRC16 byte-parallel; the RX check runs the 2 CRC bytes through it (zero = match); a mismatch is STATUS 1 = 0, not an error IRQ; bits 6 + 7 together refused | Claude (Task 6) | one accumulator, no compare register; a mismatch is a result the retry logic reads, not a fault of the peripheral |
| Size: `sdcard_spi` alone 469 LUT / 391 FF / 1 RAMB18, WNS +0.59 ns at 8.73 ns (OOC place + route) | measured (Task 6, fix round 1) | over the ~450 mark: about 130 LUTs of the ~600 budget left for Task 7's bridge and mux |
| Card gone: the firmware treats it as a card error and initialises the card again (CS high + >= 74 clocks, CMD0, ...) before any further use; after an aborted / cut TX-sourced XFER it does TX_REWIND or TX_FLUSH | controller ruling (Task 6 review) | the op stops mid-byte and the card may have seen part of a byte; the TX read point stands inside the block |
| CRC7 in firmware, a bitwise loop (`sdproto.c` `crc7`), no 256-byte table | Claude (Task 10, ruling T10-R1) | 5 bytes per command, a few hundred cycles next to a 512-byte block; no RAM for a table |
| Wait-op bounds (TIMEOUT units of 144.4 us): R1 and data response `T_NCR` 16 (2.3 ms), read token `T_TOKEN` 1732 (250 ms), write / CMD12 / stop-token busy `T_BUSY` 6926 (1.0 s); ACMD41 polling bounded by 345 TIMER counts (2.0 s) | Claude (Task 10, ruling T10-R4) | the spec's NCR <= 8 bytes (160 us at 400 kHz), read access <= 100 ms, write busy <= 250 ms SDSC / 500 ms SDHC/SDXC, init <= 1 s, each with 2-14x margin; a timeout is retried 3 times before the CMD13 probe, so a slow card gets 4 bounds |
| SCK step table: div 2, 3, 5, 8, 13, 27 (18.9, 14.2, 9.5, 6.3, 4.1, 2.0 MHz); "one step slower" = the next entry, the last one stays; `sd_sck_step` is BSS, never lowered back, not reset by a re-init | Claude (Task 10) | about 1.5x per step down to the init speed's order; "until the next reboot" = until the firmware restarts |
| No ACMD23 (pre-erase) before CMD25 | Claude (Task 10, ruling T10-R8) | a hint only, one more command (and failure mode) per run; runs are short (one IRQ group); revisit with Task 14's numbers |
| Every command is sent as FF + 6 bytes (one byte with CS low before it), CMD12 with a stuff byte after it; R1 = the first non-FF byte (WAIT_NE FF), bytes with bit 7 set (a stream still running) skipped up to 16, then a timeout; busy waits are WAIT_EQ FF (a whole released byte) | Claude (Task 10) | the usual SPI-mode framing (FatFs does the same); a partly released busy byte does not end the wait |
| A written block is [FF gap, token, 512 bytes] pushed into TX and kept until the card took it (05 + busy over), then TX_FLUSH; a retry pushes its commands behind the block and TX_REWINDs to it; stale bytes behind the block (an earlier retry's commands) are clocked out with CS off before the next command | Claude (Task 10) | TX can drop bytes ahead of the read point only with the block (TX_FLUSH / TX_COMMIT); with CS high the card ignores them |
| CMD25 retry: stop token, ACMD22, CMD25 from the first block not written; ACMD22 < blocks the card took: those again from buf; > : error | Claude (Task 10) | design 5.1 "ACMD22 says where to resume"; the card's own count wins |
| After `SD_E_GONE`, `SD_E_RETRIES`, `SD_E_ABORT`, `SD_E_INTERNAL` or a card-detect change the card is initialised again before the next op (`sd_sync`); an unanswered CMD13 probe counts as a timeout event | Claude (Task 10) | after retries ran out the card's state is unknown; re-init is cheap next to a wrong command on a confused card |
| `sd_op` has a `kind` field (read / write / CSD) beyond the plan's struct; `from_gayle` is refused (`SD_E_ARG`) until Task 11 | Claude (Task 10) | the plan's struct had no read / write field; Task 11 adds GAYLE_TO_TX |
| `MMC_*` card errors return 0 and set `ERROR_SDCARD` with `SetError` (not fatal); `MMCErr` holds the `SD_E_*` code; `SD_E_GAYLE` (the Amiga abandoned the read) sets nothing | Claude (Task 10, ruling T10-R7) | the OSD shows the error, the firmware goes on; an abandon is no error |
| HDD: a card error ends the ATA command with END \| IRQ \| ERR (no data block after it), an abandoned read with no status; a FAT seek that hit a card error fails the command too (its position would be wrong); CD: the same abandon rule (`CD_GONE`) | Claude (Task 10) | the old firmware stopped on `FatalError`; returning 0 must not turn into good-looking data or a status for a command the Amiga left; Task 11 adds the error register |
| To-Gayle reads: one `RX_TO_GAYLE` of 512 bytes per block after its CRC, the port from `ide_port` (`mmc.c` holds it now); no re-check of the flags before a dir-1 op | Claude (Task 10) | the bridge's `cmd_since` ends an op for an abandoned command in `g_err`; a `REGS_RD` re-check would clear that flag |
| The diskstat card-busy polls are no longer fed (the line shows 0); `sd_report()` prints `sd_err_count` and the SCK divider after each disk report | Claude (Task 10, ledger ruling) | COUNT is mod 2048, a 500 ms busy is 1.18 M bytes at div 2; card busy time is for Task 11 / 14 to measure if needed |
| SD v1 (CMD8 illegal: ACMD41 without HCS, CMD16 512) and MMC (CMD1) kept in `sd_init` | Claude (Task 10) | the old `MMC_Init` had them; not covered by the mock (its card is SDHC) |
| Card swap: the first `sd_init` after `sd_forget()` (`MMC_Init`, i.e. ColdBoot / the menu's Reboot) keeps the CID (CMD10, CRC16 checked); every later init (card gone, card-detect change, retries out, card reset) reads it again; another CID or an unreadable one: the card counts as changed, every op `SD_E_GONE`, nothing reaches the card, `ERROR_SDCARD` "SD card changed - reboot" until `MMC_Init`; the first init goes on without a CID if CMD10 fails | controller ruling (Task 10 fix round 1) | the mounted FAT, HDF chains and ADF index describe the old card: writes would land on the new card at the old LBAs; a CID that cannot be checked cannot be trusted |
| An R1 with the idle bit during an op (the card reset itself): `SD_E_RESET`, initialised again (same CID: goes on); CMD12's R1 error bits are the op's error (`SD_E_R1`) | controller ruling (Task 10 fix round 1) | a card in idle state takes no data command; an error of the stop command is not a good end |
| ACMD22 counting fewer blocks than the card took: each such loss is a write retry (row 2), at most 4 per op, then `SD_E_RETRIES` | controller ruling (Task 10 fix round 1) | the rewritten blocks' 05s reset the 0B budget: a card that keeps losing blocks would loop for ever |
| The CMD13 probe ending without an R1 (timeout or only stream bytes) gets a UART line and counts as a timeout; at the last SCK step a further step-down is no step (no line), and a step counts only when `sdc_set_div` took it | controller ruling (Task 10 fix round 1) | ruling T10-R6: every error visible; no line for a change that did not happen |
| `FileSeek` meeting the end of the chain keeps `file->cluster` (the last cluster; the pointer keeps its offset in it) and returns 0 (it stored the EOC mark, and the next seek inside that cluster read from a wrong address) | review (Task 10 fix round 1) | the EOC mark in the cluster would have read wrong data with valid CRCs |
| `FileReadEx` fails on a card error (also one in its last seek: the pointer would stay at the chunk just sent, and the CD path re-read it as good) or when blocks are left after the end of the chain (a read ending at the file's last sector is good); `BuildHardfileIndex` refuses a chain shorter than the file's size (every index target lies inside the file, so a 0 from `FileSeek` is a short chain or a card error: the unit is disabled); the HDD and CD paths treat a failed `HardFileSeek` (card error, or past the end) and a failed `FileReadEx` as errors; ATA reads and writes of a hardfile check lba + count against the file size before any sector is served or written; a write's `FileSeek(1)` meeting the end with sectors left fails before writing them | review (Task 10 fix rounds 1, 2 and 3) | a good read of the last cluster ended with ERR (round 1), and deciding on `MMCErr` alone then served and wrote LBAs past the file from its last cluster (round 2: silent corruption of the last sector); a card error in the last seek, and index entries past a short chain, served wrong sectors as good (round 3) |
| ROM loads: `SendFileV2` returns 0 on a failed read and sets `ERROR_ROM` ("ROM read error", the address, the block); `UploadKickstart` / `UploadExtROM` / `UploadActionReplay` return 0 then, also on a failed ROM key read or reopen | controller ruling (Task 10 fix round 1) | the Amiga must not run a part-loaded or wrongly decrypted ROM; ERROR_ROM is the error page's Reboot path |
| Other callers of failed card I/O: floppy read -> that sector sent with a wrong MFM data checksum (one data bit) + `ERROR_FDD`; a failed FAT step inside a track -> the rest of the track until it wraps the same (not read), the next read starts the track over; floppy write -> `ERROR_FDD` "Floppy write error", after a failed FAT step no further write on that track; config load read -> no config (the defaults, a boot message); config save write -> 0; RDB hunt -> stops (not RDB); hardfile index build -> the unit disabled (`ERROR_HDD`: wrong clusters in the index would read and write wrong places); `RARead` / `RASeek` / `RAReadLine` -> 0 also on a failed FAT step; ADF insert index -> not inserted + `ERROR_FDD`; drive sounds -> not loaded; boot logo -> stops; ball -> cleared; copper list -> the default list | controller ruling (Task 10 fix round 1) | never stale data that looks good (trackdisk sees a read error), never a write to a wrong place; the floppy has no write status for the Amiga, the OSD tells |
| Boot loader CRC: every read block's CRC16 checked by the peripheral (XFER bits 5 + 7, STATUS 1); a mismatch -> RX_FLUSH and the sector again; CMD59 on (all commands carry their CRC7 from a bitwise `crc7`, as `sdproto.c`) | Claude (Task 12, ruling T12-R1) | the hardware check costs no code; with CRC7 computed anyway CMD59 is one command (about 20 bytes); a corrupted firmware image must not run |
| Boot loader retries: 4 tries per command (no R1 in 2.3 ms, card gone, R1 CRC bit) and per sector (R1, no token in 250 ms / error token, CRC); from a sector's 3rd try the SCK is div 13 (4.1 MHz) for the rest of the boot; ACMD41 at most 5000 polls (>= 1.8 s); every failed try one UART line; out of tries -> the existing ErrorCode path (0xf00 / 0xff0 / 0x0f0) and the boot loop starts over | Claude (Task 12) | bounded like design 3.3's table at boot-ROM size; every op ends in hardware (LEN, TIMEOUT, card gone), so the STATUS polls cannot hang |
| Lock-step message channel: UART line `Firmware does not match this bitstream (need SDC %04x)` + `ErrorCode(0x0ff)` (BootDiag: cyan on the Amiga screen) + halt with interrupts off; no OSD text | ruling T12-R2 (deviation from 5.5 "message on the OSD") | the boot ROM has no OSD text code (an OSD write path would cost several hundred bytes of the 216 left below 0x1400); BootDiag shows the stop on the screen and the UART names the version |
| Lock-step trailer: the last 8 bytes of `RV32OSDA.BIN` = 'S','D','C','V', 0, 0, SDC_VERSION hi, lo; `fw/ctrl/sdctrailer.c` compiles them from `sdc.h` and `fw/ctrl/Makefile` appends them after objcopy (`_start` stays byte 0); the boot loader takes the last 8 bytes by the FAT directory entry's length and compares with the VERSION register; no trailer / short file = mismatch; `make check` (h) checks the built file | ruling T12-R3, Claude (Task 12) | one source of truth (`sdc.h`) for driver, trailer and boot loader; the register, not a constant in the ROM, is what the bitstream has; an old firmware (no trailer) must stop, not run |
| Boot loader: no SD_ENGINE = 0 path (VERSION != SDC_VERSION -> "SD init" fails, ErrorCode 0xf00); no MMC (CMD1); SD v1 kept (ACMD41 without HCS, CMD16 512) | Claude (Task 12) | QMTech-only rule: the other tops need only elaborate; MMC cards are not in use and the bytes are short |
| L2 boot runs (`sim/host_bridge` boot / boot_nofile / new boot_mismatch): the SD model on `sdcard_spi`'s pins; the bench takes TIME / DONE (0xFFFFFF00 / 04) only after the jump to 0x2000; boot_nofile ends at the retry's ErrorCode; boot_mismatch checks the halt (no hw access after 00FF). The fwboot legs keep the card on cfide's SPI and cannot pass on `sdio` (since Task 10 the firmware's card path is the peripheral too) until they move: Task 13's L3 `sdc_boot` covers boot + firmware | Claude (Task 12) | the ROM's TXW / TXB pushes are at the bench's TIME / DONE addresses; a cycle-limit end would cut a UART line now that the card init is fast |
| `from_gayle` writes (`sdproto.c`): always a CMD25 (one block too) ended by the stop token; per block [FF, FC] pushed by the CPU, then GAYLE_TO_TX 512 behind it, then the block is kept in TX as a buffer's block is (CRC retries resend it from TX) | Claude (Task 11a) | a Gayle error after the command (the Amiga abandoned it) can end a CMD25 cleanly with the stop token; a CMD24 waiting for its data token could only be given a block; the write-done point (the stop token's busy over) is then the same for every group |
| from_gayle block flow: the submit is the first block's go, `sd_gayle_go()` each next block's once `sd_gayle_need()` (the previous block left Gayle's FIFO); between a block's end and the next go the op is parked (no peripheral op); `sd_close()` ends the run at the next block boundary (stop token, SD_OK with done_blocks < count); `sd_sync()` / `sd_drain()` close a parked run themselves | Claude (Task 11a) | ruling T11-R1: a Gayle op only when its data is there, so it is short; a parked run must not hold a CPU-side card user: `sync_cur` would wait for a feeder (the main loop) that cannot run, a deadlock |
| The first block of a from_gayle op is staged: [FF + CMD25 frame, FF, FC] pushed, GAYLE_TO_TX 512 behind them (allowed: its hdd_dat_req was seen), then XFER TX 7 (the command), TX_COMMIT (the commit point at the block), R1, TX_REWIND + XFER 2 + XFER 512 + CRC; `sd_gayle_busy()` covers the staged GAYLE_TO_TX; later blocks of the run as before | controller ruling (Task 11a fix round 1) | an Amiga that abandons during the first block's DMA has then sent nothing to the card (no CMD25 to end, no stop token with no data block); 521 of TX's 1024 bytes; a command retry clocks the unsent kept block out with CS off and rewinds to it afterwards, as for any kept block |
| A Gayle error on GAYLE_TO_TX of a later block of a run: TX_FLUSH (the [FF, FC] in front of the rolled-back bytes), the stop token, SD_E_GAYLE; on an op's first block (staged, below) nothing has gone to the card: TX_FLUSH, SD_E_GAYLE; ACMD22 counting fewer blocks than were taken: SD_E_RETRIES, no resend | Claude (Task 11a, fix round 1: the first block) | no partial block reaches the card (Review Focus 2); the lost blocks' sectors left Gayle's FIFO, there is nothing to send again |
| A card-detect change while a from_gayle op is parked ends it with SD_E_GONE at once | Claude (Task 11a) | no peripheral op runs then, so no DONE would end it |
| HDD data path structure (`hdd.c`): one command context (`hc`) and states `H_*`; `HandleHDD` picks a command up only while none is in progress; READ / WRITE (MULTIPLE) start the state machine, the other ATA commands run to their end as before; `hdd_poll()` takes up to 8 immediate steps per main-loop pass and returns at the first that waits (an Amiga status poll that found nothing, a card op running) | Claude (Task 11a) | Gayle serves one command at a time; each step acts at once or waits for the next pass: no wait in the CPU |
| The main loop's disk pass is one function, `PollDisks(fpga)` in `main.c` (both loops, the error page's too): `sd_poll`, `hdd_poll`, `CD_AudioRefill` while an HDD command is in progress else `CD_AudioPoll`, `HandleFpga` unless a Gayle op may run (`sd_gayle_busy()`) | Claude (Task 11a) | one place for the two rules (no cs 0x10 command during a Gayle op; no CD port flags read inside an HDD command: the port latch); `hdd_test` runs the real one, cut out of `main.c` |
| The Amiga-wait counter (`diskstat_amiga_polls`) counts status polls, i.e. main-loop passes, per wait: the drain wait, each sector's hdd_dat_req wait (before a run and inside one) | Claude (Task 11a, the notes' "say which") | the old count's meaning (status polls per FIFO wait) carries over; passes need no TIMER read in the data path |
| Debug flags (ruling T11-R2): `volatile unsigned dbg_flags` in `diskstat.c` / `diskstat.h`, 0 by default; `DBG_ATA` (1) one UART line per ATA command at its end, `ATA <cmd> lba <first> n <count> port <p> ok/error/abandoned/done st <last status> t <TIMER counts>`; `DBG_DISKSTAT` (2) the 5.8 s disk report (off: the period starts over without it); `DebugMode` does not switch the trace on (its OSD debug lines stay as they are); documented in `fw/ctrl/README.md` | Claude (Task 11a) | `diskstat.c` is linked by every test of the disk path; quiet data path and no 26 ms report stall by default; the TIMER is read for the trace only with `DBG_ATA` |
| Write runs: a from_gayle CMD25 per run, started when the run's first sector shows hdd_dat_req (no op held open while the Amiga has not written), each next block's go after its own hdd_dat_req; a run parked longer than `HDD_PARK_COUNTS` (3: 17.4..23.2 ms) for the Amiga's next sector is closed (stop token) and the group goes on in a new run; runs of at most 16 sectors, inside a cluster and a group | Claude (Task 11a) | ruling T11-R1; the Amiga writes a sector in about 0.1 ms, so the bound only matters for an Amiga that stopped (Ctrl-Amiga-Amiga: Review Focus 3): no CMD25 left open, the card free for its other users |
| The Amiga leaving a command: a Gayle error on any op; hdd_cmd_req without hdd_dat_req while a write waits for a sector (normally drq is up then, so bsy is not); and the port's flags (`amiga_left`: `CMD_IDE_REGS_RD`, `IDEF_RST_SEEN` or `IDEF_DEV_WR`) before what the bridge's cmd_since does not guard: a write's END, every error status, a block the CPU writes into the FIFO (FakeRDB, the patched RDB) and a READ group's RDY after the first (fix round 1: a reset in a drain wait makes the new command's request look like "drained"); then no status for it, a write run ended on the card first (`sd_close`) | Claude (Task 11a, review fix round 1) | END, ERR, a CPU block or RDY would reach the Amiga's NEW command (a pio in on a new WRITE drops its data); the REGS_RD clears cmd_since, but what happened before it the flags report (RST_SEEN: a reset; DEV_WR: the host wrote drive/head, a new command's set-up: no host touches the task file during a command) and what happens after it sets cmd_since again; left open: a new command written without a reset and without a drive/head write before the look; an IRQ without END after a reset does nothing (pio out is cleared) |
| Error register: UNC (0x40) for a read the card failed, ABRT (0x04) for a write the card failed, an `hdd_cancel` and READ / WRITE MULTIPLE before SET MULTIPLE MODE (was an endless loop), IDNF (0x10) past the end of the hardfile; the other registers as written at the pickup | Claude (Task 11a) | ATA's codes for these cases; the Amiga's driver turns any ERR into an I/O error (Retry / Cancel) |
| Reads: the next group's RDY goes out as soon as the run that ends the group has delivered its last block to Gayle (its CMD12 may still run; `sd_op.done_blocks` is live for reads), else at the group's start | Claude (Task 11a) | the Amiga-visible order of the synchronous path (`rd_multi_order`'s golden); Gayle keeps the interrupt armed (block_mark) until the next rising DRQ, so RDY before the drain is safe |
| The HDD path's FAT walk is its own (`hdd.c` `seek`: HardFileSeek's index jump and FileSeek's walk), reading FAT sectors by async ops into `hdd_blk` (512 bytes of BSS, a one-sector cache); FakeRDB blocks and an HDF's own RDB block (patched) are built / read there too; `OpenHardfile` drops the cache | Claude (Task 11a) | no sd_sync in the data path; `fat_buffer` / `sector_buffer` would be overwritten by an sd_sync user (CD refill, menu, floppy) between two steps; an open HDF's chain links never change |
| The one wait left in the HDD path: a card to be initialised again after an error (`sd_card_type()` 0) is initialised synchronously (`sd_init`) before the path's next op; it can stall the main loop (OSD, CD refill, floppy) for up to about 2 s after a card error (the ACMD41 bound 2.0 s, the CMD0 / R1 retries at 400 kHz) | Claude (Task 11a), controller ruling (fix round 1: accepted as the one exception) | recovery after an error only, bounded, as `sd_sync` does it for every other user; an async init would be a second state machine |
| `hdd_cancel()` (from `OpenHardfile` and `ColdBoot`): the command's card op finished (a parked run closed, `sd_drain`), then END \| IRQ \| ERR with ABRT unless the Amiga left | Claude (Task 11a) | the OSD runs during HDD commands now: a hardfile reopened under a running write would get the rest of its sectors |
| `CD_Locked` reads no CD port flags while an HDD command is in progress (the lock is kept until the next look) | Claude (Task 11a) | the menu runs during HDD commands; the flags read's command word re-latches the Gayle's firmware port |
| `PollDisks` runs `sd_poll` + `hdd_poll` again while the card op makes a step (`sd_steps`), at most `DISK_STEPS` (8) rounds a pass; the loop stops at the first round in which no card step ran | Claude (Task 11a fix round 1, controller ruling) | a step whose next op is short (a 2-byte token, R1, a data response, a FLUSH) goes on in the same pass instead of waiting for the next one (in `hdd_test` with slow register accesses a WRITE MULTIPLE 64 takes 221 passes for 372 steps); no wait: the round ends when the peripheral is busy, and 8 rounds of a few register accesses keep the pass short for keys, OSD, CD refill and floppy |
