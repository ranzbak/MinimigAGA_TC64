# SD card SPI peripheral Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all SD card traffic onto a new interrupt-driven, protocol-agnostic SPI peripheral (FIFOs, CRC16, wait-for-byte, Gayle block DMA) so the OSD CPU never waits on the card, nothing unverified reaches the card or the Amiga, and the 500 MB small-files copy drops from ~1 h toward ~10 min.

**Architecture:** A Verilog block `sdcard_spi` (clk_114) owns the card pins and sits beside `cfide` in `minimig_virtual_top.v`; `cfide` only decodes three free register windows for it and keeps its own SPI master for the on-chip links. A clk_28 bridge `sdcard_gayle` moves 512-byte blocks between the peripheral's FIFOs and Gayle's sector FIFO through a mux in `minimig.v`. The firmware runs the SD protocol (`sdproto.c`) on a thin driver (`sdc.c`) and turns the HDD/CD data paths into interrupt-driven state machines.

**Tech Stack:** Verilog-2005 RTL (VHDL only where `cfide.vhd` is edited), Vivado 2023.2 (xc7a100tfgg676-2), Verilator + iverilog benches, `riscv-none-elf` gcc 15.2, host tests in `fw/ctrl/test` (gcc, ASan/UBSan).

**Spec:** `findings/sdcard-engine/design.md` (approved 2026-10-24). Read it first; this plan argues from it.

All paths are relative to the worktree `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-sdio`, branch `sdio`.

## Global Constraints

- The card stays in SPI mode. No SD native mode.
- Amiga-visible behaviour is unchanged: Gayle registers, IDE status/DRQ/IRQ and their order, PIO at `$DA0000`, floppy hardware. No new Amiga-visible registers.
- Write-done timing exactly as today: the per-group `WriteStatus(IDE_STATUS_IRQ)` and the final `END|IRQ` go out only after the card has finished programming those sectors (for CMD25: after the stop token's busy ends). No write-back.
- Reads into Gayle keep "drain, then refill": a group goes into Gayle's FIFO only after the Amiga drained the previous one (today's order in `hdd.c` `ATA_ReadSectors`).
- CRC on: CMD59 after init. A block reaches Gayle only after its CRC16 matched (enforced in hardware, Task 6). A write block stays in the TX FIFO until the card accepted it.
- Retry table (design 5.1): response CRC 3; read CRC 4 (SCK one step slower on the 3rd); write rejected CRC `0x0B` 4 (slower on the 3rd); write error `0x0D` 0; timeout 3; then CMD13, and if that times out the card is gone. A lowered SCK stays lowered until reboot.
- Bitstream/firmware lock-step: on a version mismatch the boot loader stops with a message and hangs. No fallback.
- Boot loader `_end` must stay `< 0x1400` (`fw/ctrl/Makefile` `check_g`).
- Budget: `sdcard_spi` + `sdcard_gayle` + mux under ~600 LUTs and one RAMB18; stop and report if over. clk_114 no worse than placement noise against the `retire-832` base build.
- Vendor-neutral RTL: no vendor primitives in the new blocks. Enabled by `parameter SD_ENGINE` in `minimig_virtual_top.v` (default 0); only `minimig_openaars_top.v` sets 1. Other tops must still elaborate.
- Every new `%` printf format needs a line in `fw/ctrl/test/gold/formats.txt` and a case in `fw/ctrl/test/fmt_cases.h`. No new discarded `TIMER` reads (`fw/ctrl/test/Makefile:215-222`).
- `TIMER` counts are 5.804 ms, not ms (`fw/ctrl/hardware.c:180-205`).
- Board rules: Claude may load bitstreams over JTAG; Claude never writes the SD card; write tests only on a scratch card or an HDF copy, never Paul's real disk; leave the board on the shipping image afterwards.
- Commits on `sdio` only; never stage `fw/ctrl/version.h`-style generated files, `.wcfg`, or `tools/vivado/ila_fastram_check.py`.

## Review Focus

1. **Card pulled during a CMD25 write**: no hang anywhere, the ATA command ends with ERR, Gayle's port is released, the OSD shows the error, a reboot with the card back works. Tests: Task 6 `t_cardgone_midblock`, Task 11 `wr_card_gone`.
2. **Amiga abandons a command mid-sector** (a new command resets Gayle's FIFO while the bridge moves words): the DMA stops, no partial block reaches the card, the engine is idle again. Tests: Task 7 `t_fifo_reset_mid_dma`, Task 11 `wr_abandon`.
3. **Ctrl-Amiga-Amiga during a multi-block write**: the firmware ends the CMD25 cleanly (stop token / CMD12) before the next command; the card answers CMD13 afterwards. Test: Task 11 `wr_reset_mid_run`.
4. **Slow card** (500 ms busy after a block, 100 ms to the start token): no timeout inside the spec limits, the main loop keeps running. Tests: Task 10 `busy_500ms`, `token_100ms`.
5. **CD audio playing during HDD reads and writes**: no more CD underruns than today, and no `hdd_port` re-latch (no IDE command on cs `0x10`) during a Gayle DMA. Test: Task 11 `cd_audio_during_write`.

---

## Phase A: Baseline on today's path (no RTL change)

### Task 1: Disk statistics counters

**Files:**
- Create: `fw/ctrl/diskstat.c`, `fw/ctrl/diskstat.h`
- Modify: `fw/ctrl/hdd.c` (`ATA_ReadSectors`, `ATA_WriteSectors`), `fw/ctrl/mmc.c` (`MMC_Write` busy loop), `fw/ctrl/main.c` (main loop), `fw/ctrl/Makefile`
- Test: `fw/ctrl/test/diskstat_test.c`, `fw/ctrl/test/Makefile`, `fw/ctrl/test/gold/formats.txt`, `fw/ctrl/test/fmt_cases.h`, `fw/ctrl/test/mutants.sh`

**Interfaces:**
- Produces:
  - `void diskstat_cmd(int write, unsigned sectors);` — one call per ATA READ/WRITE (MULTIPLE) command.
  - `void diskstat_busy_polls(unsigned n);` — card-busy polls of one written block (each poll = one SPI byte).
  - `void diskstat_amiga_polls(unsigned n);` — `GetFPGAStatus()` polls waiting for Gayle's FIFO.
  - `void diskstat_loop_pass(void);` — once per main-loop pass.
  - `void diskstat_report(void);` — prints the summary on the UART.
  - `extern unsigned diskstat_hist[2][7];` — sectors per command, `[write][bucket]`, buckets `1, 2, 3-4, 5-8, 9-16, 17-64, 65-256`.

- [ ] **Step 1: Write the failing test** `diskstat_test.c`: `diskstat_cmd(1,1)` x3, `diskstat_cmd(1,16)`, `diskstat_cmd(0,256)`; assert `diskstat_hist[1][0]==3`, `diskstat_hist[1][4]==1`, `diskstat_hist[0][6]==1`; `diskstat_busy_polls(100)` twice, then `diskstat_report()` output on the mock UART contains `busy polls 200` and `cmds w 4 r 1`.
- [ ] **Step 2: Run** `make -C fw/ctrl/test run-diskstat_test` — Expected: FAIL (no `diskstat.c`).
- [ ] **Step 3: Implement** `diskstat.c`; hook `diskstat_cmd` at the top of `ATA_ReadSectors`/`ATA_WriteSectors`; count polls in the `MMC_Write` busy loop and in the two `GetFPGAStatus` wait loops in `hdd.c`; `diskstat_loop_pass()` at the top of the main loop; `diskstat_report()` every 1000 `TIMER` counts (~5.8 s) while `DebugMode` is on. Add the formats to `gold/formats.txt` and `fmt_cases.h`.
- [ ] **Step 4: Run** `make -C fw/ctrl/test run` and `make -C fw/ctrl` — Expected: all PASS, firmware links.
- [ ] **Step 5: Mutant** in `mutants.sh` (bucket bound off by one) — `bash fw/ctrl/test/mutants.sh` kills it.
- [ ] **Step 6: Commit** `fw/ctrl: disk statistics counters for the SD baseline`.

### Task 2: About screen on a timer

**Files:**
- Modify: `fw/ctrl/menu.c` (`MENU_ABOUT1`, `MENU_ABOUT2`, ~:1071-1111), `fw/ctrl/osd.h`

**Interfaces:**
- Produces: `#define ABOUT_FRAME_DELAY 3` (counts = 17.4 ms) in `osd.h`.

- [ ] **Step 1: Implement**: `MENU_ABOUT1` arms `about_timer = GetTimer(ABOUT_FRAME_DELAY)`; `MENU_ABOUT2` runs `StarsUpdate()` and the six `OsdDrawLogo` calls only when `CheckTimer(about_timer)` (then re-arms); `ScrollText` and the exit check stay on every pass.
- [ ] **Step 2: Run** `make -C fw/ctrl` and `make -C fw/ctrl/test run` — Expected: link and PASS.
- [ ] **Step 3: Commit** `fw/ctrl: about screen redraws on a 17 ms timer`.

### Task 3: Baseline measurement (Paul runs it)

**Files:**
- Create: `findings/sdcard-engine/baseline.md`

- [ ] **Step 1:** Build `fw/ctrl`; hand `build/RV32OSDA.BIN` to Paul with the current bitstream. Paul puts it on his card himself.
- [ ] **Step 2:** Paul runs the small-files copy three ways (OSD closed, menu open, about screen open), DebugMode on, UART captured (`ttyUSB1`). Record wall time, histograms, busy polls, Amiga polls, loop passes per second.
- [ ] **Step 3:** Write `baseline.md`: the numbers, busy time estimated as polls x one SPI byte at 18.9 MHz, and whether the histogram makes 10 minutes plausible (design 9.1). Commit `findings/sdcard-engine: baseline measurements`.
- [ ] **Step 4: Gate:** show Paul the numbers before Phase B; if single-sector commands dominate, say what speed-up is realistic.

## Phase B: RTL

### Task 4: SD card model with CRC and error injection

**Files:**
- Modify: `sim/common/sd_spi_model.v`, `sim/common/run_sd_model.sh`
- Create: `sim/common/tb_sd_model_crc.v`

**Interfaces:**
- Produces (model behaviour later benches rely on):
  - Real CRC16 (CCITT, poly 0x1021, init 0) on every read block; CMD59 arg bit 0 = 1 turns on checking of CRC7 on commands (bad → R1 `0x08`) and CRC16 on written blocks (bad → data response `0x0B`). CRC checking off by default (existing benches unchanged).
  - ACMD22: the count of well-written blocks of the last CMD25 (4 bytes + CRC).
  - Plusargs: `SD_ERR_RDCRC=<n>` (flip one bit in the n-th read block), `SD_ERR_WRREJ=<n>` (`0x0B` for the n-th written block), `SD_ERR_WRFAIL=<n>` (`0x0D`), `SD_ERR_NORESP=<n>`; existing `SD_BUSY`, `SD_TOKEN_DLY`.
  - Task `remove_card()`: MISO stays 1 and nothing is written from then on.

- [ ] **Step 1: Write the failing bench** `tb_sd_model_crc.v` (iverilog, bit-banged host): CMD0/8/ACMD41/58/CMD59(1); read block 0 and check its CRC16; write block 5 with a wrong CRC → `0x0B`, correctly → `0x05`; CMD25 of 3 blocks with `SD_ERR_WRREJ=2` → ACMD22 returns 1.
- [ ] **Step 2: Run** `bash sim/common/run_sd_model.sh crc` — Expected: FAIL.
- [ ] **Step 3: Implement** in `sd_spi_model.v` (CRC16 in `push_block`, CRC7 check, CMD59, ACMD22, plusargs, `remove_card`).
- [ ] **Step 4: Run** `bash sim/common/run_sd_model.sh` and `... crc` — Expected: both PASS.
- [ ] **Step 5: Commit** `sim/common: SD model with CRC7/CRC16, CMD59, ACMD22 and error injection`.

### Task 5: Peripheral core — registers, FIFOs, shifter, interrupt

**Files:**
- Create: `rtl/host/sdcard_spi.v`, `sim/sdcard_spi/tb_sdcard_spi.v`, `sim/sdcard_spi/run.sh` (Verilator via the `sim/common/hostsim.sh` `hs_verilate` pattern; iverilog leg as X-check)

**Interfaces:**
- Produces module `sdcard_spi` (clk = clk_114):

```verilog
module sdcard_spi #(parameter VERSION = 16'h5D01) (
  input  wire clk, input wire reset,
  input  wire        reg_wstb, input wire reg_rstb,   // one-cycle strobes, first cycle of an access
  input  wire [5:2]  reg_addr,                        // {window[1:0], sub[1:0]}, windows 0..2
  input  wire [15:0] reg_d,  output wire [15:0] reg_q,
  output wire        irq,                             // level, to cfide irq_src(4)
  output wire sd_sck, output wire sd_cs_n, output wire sd_mosi, input wire sd_miso,
  input  wire sd_cd_n,                                // card detect, low = inserted, unsynchronised
  output wire        g_req, output wire g_dir,        // dir 1: RX FIFO -> Gayle; 0: Gayle -> TX FIFO
  output wire        g_port, output wire [9:0] g_words,
  input  wire        g_ack, input wire g_err,
  output wire [15:0] g_wdata, input wire g_wnext,
  input  wire [15:0] g_rdata, input wire g_rvalid
);
```

- Register map (16-bit):

| Addr | Write | Read |
| --- | --- | --- |
| `0xFFFFFF00` | `TXW` push 2 bytes (15:8 first) | `RXW` pop 2 bytes (first in 15:8) |
| `0xFFFFFF04` | `TXB` push 1 byte (7:0) | `RXB` pop 1 byte (7:0) |
| `0xFFFFFF08` | — | `RXLVL` bytes in RX (10:0) |
| `0xFFFFFF0C` | — | `TXLVL` bytes in TX incl. kept (10:0) |
| `0xFFFFFF10` | `CMD` start an op | `STATUS` |
| `0xFFFFFF14` | `LEN` byte count (10:0) | `LAST` last received byte (7:0) |
| `0xFFFFFF18` | `MATCH` byte for wait ops (7:0) | `COUNT` bytes moved by the last op (10:0) |
| `0xFFFFFF1C` | `IRQACK` write 1 to clear | `IRQPEND` |
| `0xFFFFFF20` | `CFG`: 7:0 divider (SCK = clk_114 / (2*(div+1))), 8 CS asserted | `CFG` |
| `0xFFFFFF24` | `TIMEOUT`, units of 16384 clk_114 (144.4 us), 0 = 1 unit | `TIMEOUT` |
| `0xFFFFFF28` | `IRQEN` | `IRQEN` |
| `0xFFFFFF2C` | `WMARK`: 15:8 RX high, 7:0 TX low, units of 16 bytes | `VERSION` |

- `CMD` 3:0 op: `1` XFER, `2` WAIT_EQ, `3` WAIT_NE, `4` GAYLE_TO_TX, `5` RX_TO_GAYLE, `6` TX_REWIND, `7` TX_COMMIT, `8` RX_FLUSH, `9` TX_FLUSH, `15` ABORT. Bit 4 TX from FIFO (else `$FF`); bit 5 RX into FIFO (else discard); bit 6 append CRC16 after LEN TX bytes; bit 7 receive 2 more bytes after LEN and check them as CRC16 (not stored); bit 8 Gayle port.
- `STATUS`: 0 busy, 1 crc_ok (last op with bit 7), 2 timeout, 3 card present, 4 aborted, 5 card gone during the op, 6 refused, 7 Gayle error.
- `IRQPEND/IRQEN/IRQACK`: 0 op done, 1 RX >= high watermark, 2 TX <= low watermark, 3 error, 4 card-detect change. `irq = |(IRQPEND & IRQEN)`.
- FIFOs: one inferred 2048-byte RAM (RX 0-1023, TX 1024-2047). TX keeps sent bytes until `TX_COMMIT`; `TX_REWIND` re-sends from the start of the last TX-sourced op.

- [ ] **Step 1: Write the failing bench** with `sd_spi_model` (CRC off): `t_version` (`0xFFFFFF2C` = `16'h5D01`), `t_xfer_tx` (6 bytes, XFER LEN 6 bit 4 → model logs CMD0), `t_xfer_rx` (after CMD58, XFER LEN 8 bit 5 → RXW pops equal the OCR), `t_sck_pause` (XFER LEN 1500 bit 5 with RX not drained: SCK stops at 1024 bytes, resumes when drained, no byte lost), `t_watermark_irq` (WMARK RX 32: IRQPEND bit 1 at 512 bytes, `irq` follows IRQEN), `t_divider` (div `0x8A` → SCK period `2*(0x8A+1)` clk ±1).
- [ ] **Step 2: Run** `bash sim/sdcard_spi/run.sh` — Expected: FAIL.
- [ ] **Step 3: Implement** registers, FIFOs, shifter (SPI mode 0, MSB first, SCK idles low, pauses when TX empty for a TX-sourced op or RX full for an RX-sinking op), XFER, FLUSH, IRQ, card detect (2-FF sync, 2^20-clock debounce).
- [ ] **Step 4: Run** both legs — Expected: PASS, no X on `reg_q` or pins after reset.
- [ ] **Step 5: Commit** `rtl/host: sdcard_spi core - FIFOs, shifter, registers, interrupt`.

### Task 6: Peripheral core — CRC16, wait-for-byte, timeout, abort, TX keep

**Files:**
- Modify: `rtl/host/sdcard_spi.v`, `sim/sdcard_spi/tb_sdcard_spi.v`, `sim/sdcard_spi/run.sh`

**Interfaces:**
- Consumes: Task 5 module and map.
- Produces: ops 2, 3, 6, 7, 15; CMD bits 6, 7; the interlock: `RX_TO_GAYLE` is refused (STATUS bit 6, error IRQ, no `g_req`) unless `crc_ok` and `RXLVL >= LEN`.

- [ ] **Step 1: Write the failing cases** (model CRC on): `t_crc_read_ok` (CMD17, WAIT_NE `$FF` → LAST `$FE`, XFER 512 bits 5+7 → crc_ok 1), `t_crc_read_bad` (`SD_ERR_RDCRC=1` → crc_ok 0), `t_crc_write` (XFER 512 bits 4+6 after `$FE`: model answers `0x05`; with `SD_ERR_WRREJ=1` WAIT_NE returns `0x0B`), `t_wait_timeout` (WAIT_EQ `$00`, TIMEOUT 2 → timeout bit, error IRQ), `t_busy_wait` (WAIT_NE `$00` after a write with long `SD_BUSY` ends when MISO is `$FF`), `t_abort` (ABORT mid-XFER: aborted bit, SCK stops within one byte, CS untouched), `t_tx_rewind` (XFER bits 4+6, TX_REWIND, XFER: model receives identical 514 bytes; TX_COMMIT frees TXLVL), `t_refuse`, `t_cardgone_midblock` (`remove_card()` + `sd_cd_n` high mid-XFER → card-gone, error IRQ).
- [ ] **Step 2: Run** — Expected: new cases FAIL.
- [ ] **Step 3: Implement** CRC16 (CCITT, init 0, byte-parallel), WAIT_EQ/WAIT_NE (clock `$FF`, nothing into RX), timeout counter, ABORT, TX keep/rewind/commit, the interlock.
- [ ] **Step 4: Mutant legs** in `run.sh`: `-DSDC_MUT_NOCRC` (crc_ok forced 1), `-DSDC_MUT_NOINTERLOCK`, `-DSDC_MUT_NOTIMEOUT` — each fails at least one case (NOTIMEOUT via the bench watchdog, not a hang).
- [ ] **Step 5: Run** all legs — Expected: normal PASS, every mutant caught.
- [ ] **Step 6: Commit** `rtl/host: sdcard_spi CRC16, wait-for-byte, timeout, abort, TX keep`.

### Task 7: Gayle bridge and mux

**Files:**
- Create: `rtl/minimig/sdcard_gayle.v`
- Modify: `rtl/minimig/minimig.v` (new ports, mux on the `hdd_*` wires between `PAULA1` and `GAYLE1`), `sim/gayle/gayle_tb.v`, `sim/gayle/run.sh`

**Interfaces:**
- Consumes: Task 5 `g_*` ports.
- Produces module `sdcard_gayle` (clk = clk_28 with `clk7_en`):

```verilog
module sdcard_gayle (
  input  wire clk, input wire clk7_en, input wire reset,
  input  wire g_req, input wire g_dir, input wire g_port, input wire [9:0] g_words,
  output wire g_ack, output wire g_err,
  input  wire [15:0] g_wdata, output wire g_wnext,
  output wire [15:0] g_rdata, output wire g_rvalid,
  output wire        active, output wire port,
  output wire        data_wr, output wire data_rd,      // high for exactly one clk7_en sample
  output wire [15:0] data_out, input wire [15:0] data_in,
  input  wire        dat_req, input wire fifo_reset_seen
);
```

- `minimig.v`: `hdd_data_wr = pf_data_wr | (sg_active & sg_data_wr)`, `hdd_data_rd = pf_data_rd | (sg_active & sg_data_rd)`, `hdd_data_out = sg_active ? sg_data_out : pf_data_out`, `hdd_port = sg_active ? sg_port : pf_port`.
- Word = {first byte, second byte}, as `paula_floppy.v:366` builds it; `data_in` capture follows `hdd_data_rd`'s prefetch semantics (`paula_floppy.v:453-454`) — prove it in the bench. `fifo_reset_seen` comes from Gayle's `fifo_reset` (new command / `hdd_xfer_wr`) of the active port.

- [ ] **Step 1: Write the failing cases** in `gayle_tb.v` (`-DSDC_BRIDGE` leg): `t_bridge_read` (READ MULTIPLE 4: per group the firmware task does `WriteStatus(RDY)`, the bench drives the bridge with 256 words; the Amiga PIO master reads them; DRQ/IRQ trace equals `golden_a.txt` for the same command), `t_bridge_write` (bridge waits for `dat_req`, streams 256 words out, equal to what the Amiga wrote), `t_fifo_reset_mid_dma` (new ATA command mid-group → `g_err`, `active` drops, no more strobes), `t_two_ports`.
- [ ] **Step 2: Run** `sim/gayle/run.sh all` — Expected: new leg FAIL, old legs PASS.
- [ ] **Step 3: Implement** `sdcard_gayle.v` (toggle synchronisers across clk_114/clk_28, one strobe per clk7_en, abort on `fifo_reset_seen`) and the `minimig.v` mux and ports.
- [ ] **Step 4: Run** `sim/gayle/run.sh all` — Expected: all PASS, existing goldens unchanged.
- [ ] **Step 5: Commit** `rtl/minimig: sdcard_gayle bridge and hdd_* mux`.

### Task 8: Integration, pins, card detect, builds, size and timing

**Files:**
- Modify: `rtl/host/cfide.vhd` (decode windows 0-2 to `ext_*` ports, read-mux input, `ack <= '1'` as for the other blocks, first-cycle strobes), `rtl/soc/minimig_virtual_top.v` (`parameter SD_ENGINE = 0`; instantiate `sdcard_spi`; when 1: card pins from it, `irq_src(4)` = its `irq`, pass `g_*` to `minimig`), `rtl/soc/minimig_openaars_top.v` (`SD_ENGINE(1)`, `sd_m_cdet` wired), `fpga/openaars/aars_v5.0/xc7a100t/sd_card.xdc` (`PACKAGE_PIN F23` for `sd_m_cdet`, IOSTANDARD per bank 15's VCCO; generated clock on the `sdcard_spi` SCK register and the card pins' delays; `spi_sck` stays for the on-chip slaves), `tools/vivado/build_ap040.tcl` + `tools/vivado/rebuild.tcl` (`add_src` both new files), `rtl/host/host.qip`, `rtl/minimig/minimig.qip`, `sim/l3/tb_l3.v` + `sim/l3/run.sh` (same wiring, `SD_ENGINE` define), `sim/common/hostsim.sh` (`HS_RTL_FILES`)
- Create: `tools/vivado/ooc_sdcard/run.tcl`, `tools/vivado/ooc_sdcard/go.sh` (pattern of `findings/ap040-pipelined/tests/synth/ooc.sh`: libtinfo shim, no `-stack`)

**Interfaces:**
- Produces in `cfide.vhd`: `ext_wstb, ext_rstb : out std_logic` (one sysclk pulse, first cycle of `req`), `ext_addr : out std_logic_vector(5 downto 2)`, `ext_d : out std_logic_vector(15 downto 0)`, `ext_q : in std_logic_vector(15 downto 0)`.
- Firmware sees Task 5's map at `0xFFFFFF00-0x2C` and IRQ bit 4.

- [ ] **Step 1: Write the failing check**: `sim/host_bridge` case `t_sdc_regs` (Verilator, GHDL-converted cfide) reads `0xFFFFFF2C` = `16'h5D01` and writes/reads `CFG`.
- [ ] **Step 2: Run** `make -C sim/host_bridge TESTS=t_sdc_regs` — Expected: FAIL.
- [ ] **Step 3: Implement** the cfide decode, top wiring, XDC, build lists, L3 wiring.
- [ ] **Step 4: Run** `t_sdc_regs` and the existing `sim/host_bridge` suite — Expected: PASS.
- [ ] **Step 5: OOC**: `bash tools/vivado/ooc_sdcard/go.sh` — Expected: LUTs < 600, one RAMB18, WNS >= 0 at clk_114/clk_28. Over budget → stop and report to Paul.
- [ ] **Step 6: Elaboration**: `verilator --lint-only` (or `iverilog -E`) on the MiST and DE tops' file lists with `SD_ENGINE=0` — Expected: no new errors.
- [ ] **Step 7: Commit** `rtl: wire sdcard_spi into cfide, the virtual top and the openaars pins`.

## Phase C: Firmware

### Task 9: Driver, interrupt migration, mock peripheral

**Files:**
- Create: `fw/ctrl/sdc.h`, `fw/ctrl/sdc.c`
- Modify: `fw/ctrl/main.c` (`inthandler` → `IrqSetHandler`; `ColdBoot` interrupt setup), `fw/ctrl/akiko.c`, `fw/ctrl/c64keys.c` (`c64keyboard_checkreset` → `irq_save/irq_restore`), `fw/ctrl/arch/irq.h` (`#define IRQ_SDCARD 4`), `fw/ctrl/Makefile`
- Test: `fw/ctrl/test/mock_hw.c`, `fw/ctrl/test/mock_hw.h` (emulate Task 5's registers on the existing card emulator, with CRC per Task 4, error knobs, an IRQ pending word), `fw/ctrl/test/sdc_test.c`, `fw/ctrl/test/Makefile`

**Interfaces:**
- Produces (`sdc.h`):
  - `SDC(x)` = `*(volatile unsigned short *)(0xFFFFFF00+(x))`, offsets `SDC_TXW 0x00` … `SDC_WMARK 0x2C`, op/bit names as Task 5, `#define SDC_VERSION 0x5D01`.
  - `void sdc_init(void);` — handler on `IRQ_SDCARD` (LEVEL), CFG slow, IRQEN set.
  - `int sdc_start(unsigned cmd, unsigned len);` — 0, or -1 if busy.
  - `extern volatile unsigned sdc_events;` — IRQPEND bits latched by the handler (which acks the hardware).
  - `int sdc_wait(unsigned mask);` — sleeps with `wfi` until `sdc_events & mask`; only for boot-time and CPU-side sync wrappers, never in the HDD/CD data path. Under `HOSTTEST` it steps the mock.
  - `void sdc_push(const unsigned char *p, unsigned n);`, `void sdc_pop(unsigned char *p, unsigned n);`, `void sdc_set_div(unsigned div);`, `unsigned sdc_status(void);`

- [ ] **Step 1: Write the failing test** `sdc_test.c`: push 6 bytes + XFER → mock card logs CMD0; `sdc_wait(SDC_IRQ_DONE)` returns with `sdc_events` bit 0; RX XFER of 8 bytes pops the OCR; IRQEN off → no event.
- [ ] **Step 2: Run** `make -C fw/ctrl/test run-sdc_test` — Expected: FAIL.
- [ ] **Step 3: Implement** `sdc.c`, the mock registers, the interrupt migration (VBL → `c64keys_inthandler`, Akiko → `akiko_inthandler` via `IrqSetHandler` + `IrqEnable`).
- [ ] **Step 4: Run** `make -C fw/ctrl/test run` and `make -C fw/ctrl` — Expected: PASS.
- [ ] **Step 5: Commit** `fw/ctrl: sdc driver for the SD peripheral; interrupts on the irq controller`.

### Task 10: SD protocol on the driver; mmc.c on top

**Files:**
- Create: `fw/ctrl/sdproto.h`, `fw/ctrl/sdproto.c`
- Modify: `fw/ctrl/mmc.c`, `fw/ctrl/mmc.h` (same API on `sdproto`; SPI code removed; card errors return 0 instead of `FatalError`)
- Test: `fw/ctrl/test/sdproto_test.c`, `fw/ctrl/test/mmc_test.c`, `fw/ctrl/test/Makefile`

**Interfaces:**
- Consumes: Task 9 `sdc.h`.
- Produces (`sdproto.h`):
  - `int sd_init(void);` — CMD0, CMD8, ACMD41 (HCS), CMD58, CMD59(1), CMD9; SCK ~400 kHz, then data rate ≤ 25 MHz (start at div 2 = 18.9 MHz); returns CardType or 0.
  - `typedef struct sd_op { unsigned lba, count; unsigned char *buf; int to_gayle, from_gayle, port; int state, err, done_blocks; } sd_op;`
  - `int sd_submit(sd_op *op);` — 0, or -1 if another op is active.
  - `int sd_poll(void);` — advances the active op on `sdc_events`; 1 while active, 0 when idle; non-reentrant guard.
  - `int sd_sync(sd_op *op);` — finishes any active op first, then runs `op` to completion with `sdc_wait`; for CPU-side callers (FAT, config, ADF).
  - `extern unsigned sd_err_count[5];` — one per retry-table row.
- `mmc.c`: `MMC_Read`, `MMC_ReadMultiple` (buf 0 → `to_gayle`), `MMC_Write`, new `MMC_WriteMultiple(unsigned long lba, unsigned char *buf, unsigned long n)`, `MMC_GetCSD`, `MMC_GetCapacity` become `sd_sync` wrappers.

- [ ] **Step 1: Write the failing tests** `sdproto_test.c`: `init_crc_on`, `read_ok`, `read_crc_retry` (one bad → 1 retry, data right), `read_crc_exhaust` (4 retries, err, SCK slower after the 3rd and stays), `write_reject_retry` (`0x0B` once → identical resend), `write_fail_0D` (no retry), `cmd25_acmd22` (reject 3rd of 5 → ACMD22 2, resume at 3, card content right), `timeout_cmd13_gone`, `busy_500ms`, `token_100ms` (no error; `sd_poll` returns 1 throughout; the test's loop counter keeps rising), `one_op_at_a_time`.
- [ ] **Step 2: Run** `make -C fw/ctrl/test run-sdproto_test` — Expected: FAIL.
- [ ] **Step 3: Implement** `sdproto.c` (per op: command → wait R1 → token → data + CRC → next block; writes: token, data + CRC from TX, wait data response, wait busy, then TX_COMMIT, or TX_REWIND for a retry) and the `mmc.c` wrappers.
- [ ] **Step 4: Run** `make -C fw/ctrl/test run` — Expected: all PASS incl. the `fat_test`, `config_test`, `mmc_test`, `hdd_test`, `fdd_test` goldens (card contents byte-identical).
- [ ] **Step 5: Mutants**: retry count off by one, CRC result ignored — both killed by `mutants.sh`.
- [ ] **Step 6: Commit** `fw/ctrl: SD protocol on the SD peripheral, CRC on, retries`.

### Task 11: HDD and CD data paths as interrupt-driven state machines

**Files:**
- Modify: `fw/ctrl/hdd.c` (`ATA_ReadSectors`, `ATA_WriteSectors`, `HandleHDD`), `fw/ctrl/hdd.h`, `fw/ctrl/cdrom.c` (`cd_send_sectors`), `fw/ctrl/main.c` (main loop calls `hdd_poll()` and `sd_poll()`), `fw/ctrl/cdrom.h` (rule: no IDE command on cs `0x10` while a Gayle DMA is active)
- Test: `fw/ctrl/test/hdd_test.c` (+ goldens), `fw/ctrl/test/cdrom_test.c`

**Interfaces:**
- Consumes: Task 10 `sd_submit` / `sd_poll`, ops with `to_gayle` / `from_gayle`.
- Produces: `void hdd_poll(void);`, `int hdd_busy(void);`.
- Rules: reads — per group `WriteStatus(IDE_STATUS_RDY)`, wait (main-loop state, not a spin) until `CMD_IDECMD` shows the FIFO drained, then submit the group `to_gayle`. Writes — per group submit `from_gayle` CMD25 runs split at cluster boundaries (`HardFileSeek` index); only when the run is done (stop-token busy over) send `WriteStatus(IDE_STATUS_IRQ)` / `END|IRQ`. Runs of at most 16 sectors; between runs `CD_AudioRefill()` and queued card users run. Errors → `WriteStatus(END|IRQ|ERR)` with the error register set, `SetError` for the OSD.

- [ ] **Step 1: Write the failing tests** in `hdd_test.c`: `rd_multi_order` (mock Gayle trace equals today's golden for READ MULTIPLE 32), `wr_irq_after_program` (each group's IRQ only after the mock card logged the stop-token busy end), `wr_cluster_split`, `wr_card_gone`, `wr_abandon`, `wr_reset_mid_run`, `main_loop_runs` (the test's loop counter advances during a 64-sector write); in `cdrom_test.c`: `cd_audio_during_write`.
- [ ] **Step 2: Run** `make -C fw/ctrl/test run-hdd_test run-cdrom_test` — Expected: FAIL.
- [ ] **Step 3: Implement** the state machines and the main-loop calls.
- [ ] **Step 4: Run** `make -C fw/ctrl/test run` and `make -C fw/ctrl` — Expected: PASS.
- [ ] **Step 5: Commit** `fw/ctrl: HDD and CD data paths interrupt-driven on the SD peripheral`.

### Task 12: Boot loader on the peripheral; lock-step check

**Files:**
- Modify: `fw/ctrl_boot/spi.c` (card init + `sd_read_sector` on the peripheral; polling allowed here), `fw/ctrl_boot/boot.c` (version check before `_boot()`), `fw/ctrl_boot/README.md`, `fw/ctrl/Makefile` (append the trailer to `RV32OSDA.BIN`)
- Test: `fw/ctrl_boot/test` (existing boot test) + new case

**Interfaces:**
- Trailer: last 8 bytes of `RV32OSDA.BIN` = `'S','D','C','V',0,0,hi(SDC_VERSION),lo(SDC_VERSION)`, appended after `objcopy` (`_start` stays byte 0).
- Check: after `LoadFile`, compare the trailer with the `VERSION` register; mismatch → UART `Firmware does not match this bitstream (need SDC %04x)`, `ErrorCode(0x0ff)` (new code; BootDiag shows it on the Amiga screen), then hang with interrupts off.

- [ ] **Step 1: Write the failing test**: image with trailer `5D00` vs mock `VERSION` `5D01` → message + `ErrorCode(0x0ff)`; `5D01` → jumps.
- [ ] **Step 2: Run** the boot test — Expected: FAIL.
- [ ] **Step 3: Implement**; keep `_end < 0x1400`.
- [ ] **Step 4: Run** boot tests, `make -C fw/ctrl_boot`, `make -C fw/ctrl` (incl. `check_g`) — Expected: PASS.
- [ ] **Step 5: Commit** `fw/ctrl_boot: card through the SD peripheral; bitstream/firmware lock-step`.

### Task 13: Full-system simulation

**Files:**
- Modify: `sim/l3/run.sh` (scenarios `sdc_boot`, `sdc_hdd`), `sim/l3/README.md`

- [ ] **Step 1:** Add `SD_ENGINE=1` scenarios on the CRC model with CMD59.
- [ ] **Step 2: Run** `SIM=verilator RUNTAG=sdcb bash sim/l3/run.sh sdc_boot`, then `RUNTAG=sdch ... sdc_hdd` (serial, unique RUNTAGs) — Expected: boots through the peripheral; HDD sectors equal `SYNTH.HDF`.
- [ ] **Step 3: Run** `sdc_hdd` with `+SD_ERR_RDCRC=3` — Expected: one retry logged, data still right.
- [ ] **Step 4: Commit** `sim/l3: boot and HDD through the SD peripheral`.

### Task 14: Board bring-up and the measurement (with Paul)

**Files:**
- Create: `findings/sdcard-engine/results.md`

- [ ] **Step 1:** Full build with `tools/vivado/build_ap040.tcl` (stage `stage_sdc_<sha>`); timing against the `retire-832` base build; LUT/RAMB use.
- [ ] **Step 2:** Claude loads the bitstream over JTAG; Paul puts the matching `RV32OSDA.BIN` on a scratch card. Check boot, OSD, ADF read, HDF read (checksum a large file), CD ISO read.
- [ ] **Step 3:** Writes on the scratch card / an HDF copy only: copy files, checksums, HDF filesystem check; pull the card during a write once.
- [ ] **Step 4:** Paul runs the small-files copy as in Task 3; record time, histograms, `sd_err_count`, loop passes per second in `results.md`; compare with `baseline.md` and the target.
- [ ] **Step 5:** Leave the board on the shipping image. Commit `findings/sdcard-engine: board results`.
