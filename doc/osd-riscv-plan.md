# OSD / host CPU: EightThirtyTwo -> RISC-V -- implementation plan

Status: plan only, 2026-10-16. Branch `osd-riscv`, off `5.0-040-pipelined`
(the main branch for this board version; `osd-riscv` merges back into it,
never into superproject `main`; the AP68040 core submodule is not touched by
this work -- should it ever be, core changes land on core `main` first, as
usual). Baseline must be 49b1868 or later: it contains the merged `spicdc`
branch (SPI generated clock 7c33c98, paula_floppy direct-mode race 202e077,
`sim/spi_cdc`). No RTL, firmware or build script has been changed yet.

Target: QMTech XC7A100T (`xc7a100tfgg676-2`, fpga/openaars project_1). The
core must still build on Intel FPGAs: plain VHDL/Verilog only, Artix-specific
tricks behind a switch that defaults off.

"1:1" means functional parity for the user (same features, same behaviour),
not the same implementation. The first port is nevertheless a straight
polling port on today's hardware interface, with the 832 selectable as the
reference; hardware offloads come afterwards, one bisectable step at a time.

---

## 0. Summary

| Item | Decision / estimate |
|---|---|
| Core | **picorv32** (YosysHQ), native-bus variant, RV32IM(+C), IRQ, barrel shifter, look-ahead interface; behind a thin CPU wrapper so **Hazard3** (runner-up) is a drop-in. Final confirmation after the Phase 0 measurements (OOC area/timing **and** simulated throughput on the real memory path, table in 2.3). |
| Why | Smallest fit/timing risk on a 84 % LUT / 98 % slice design whose host clock has -0.2 ns WNS: ~917 LUT / 583 FF, 250+ MHz on 7-series; native `mem_valid/ready/wstrb` bus maps 1:1 on the existing req/ack bridge and makes memory-mapped peripherals trivial; gcc; formally verified; ISC. Cost: archived on GitHub (Sep 2026), non-standard IRQ scheme (~60 lines of asm), and CPI ~4 with no I-cache -- throughput on our bridge is the open question, hence 2.3. |
| LUT delta vs 832 | 832 cpu 761 LUT / 772 FF / 4 DSP. picorv32 regular ~917 / 583 / 4 -> **+150..+250 LUT, -190 FF**, BRAM unchanged. `COMPRESSED_ISA` est. +100 LUT. Hazard3 est. +1,000..1,700 LUT. Measured in Phase 0. |
| Fmax at 113.4 MHz | Not the discriminator for picorv32 (Artix -2 is ~25-35 % below the README's Kintex -2 416 MHz, still far above 114 with IRQ/MUL/C). Medium risk for Hazard3 (no 7-series figure published). NEORV32 marginal. |
| Endianness | **Byte-invariant memory, value-preserving I/O**: the bridge swaps the four data lanes between the LE CPU and the BE ROM/SDRAM (`bytesel` stays address-indexed); the 16-bit hardware window is unswapped and every firmware I/O register moves to offset 0. FAT swaps become identity; Amiga/hardware-facing multi-byte structures get explicit BE helpers (8 audited items, section 5). |
| Code size (measured) | Firmware RV32IMC ~85-95 KB vs 83,830 B (RV32IM ~105-115 KB). Boot ROM RV32IMC 3,636 B text + 650 B data/bss vs 4,333 B: **fits the 8 KB BRAM**. |
| Verification before any board test | A co-simulation bench with the real paula_floppy / gayle / userio_osd / cfide / hostcache and the RISC-V core running the real firmware against an Amiga-side model, golden images, 832 reference traces, timing-stress sweeps and margin monitors -- built on `sim/spi_cdc` (section 7, Phase 4). Floppy, HDD and CD/ATAPI paths are gated by it. |
| Interrupts / peripherals | First port: the one existing cfide interrupt (vblank, I2C INT, Akiko request) on `irq[3]`, firmware unchanged. Then Phase 8: a per-source IRQ controller in cfide and individually benched offloads (request IRQ + OSD reply ready flag, timer, UART, SPI master FIFO, sector DMA, CD-DA ring DMA) -- section 6. |
| Phases | 0 measure -> 1 bridge RTL -> 2 boot ROM + toolchain -> 3 firmware 1:1 + host unit tests -> 4 co-simulation (differential 832 vs RV32, stress) -> 5 build integration + A/B -> 6 board parity + stress protocol -> 7 performance -> 8 peripherals/IRQ -> 9 retire the 832 |

---

## 1. What exists today (facts from the tree)

### 1.1 RTL

- `rtl/host/832_bridge.vhd` (`EightThirtyTwo_Bridge`): `eightthirtytwo_cpu`
  with `littleendian => false`, `interrupts => true`. Decode on the CPU's
  32-bit address: `rom_select = addr(23 downto 13) = 0` -> 8 KB boot BRAM
  (`OSDBoot_832_ROM`, `maxAddrBitBRAM => 12`, writable); `hw_select =
  addr(23)` -> cfide, 16-bit (`cpu_d = x"0000" & hw_d`); else -> `hostcache`
  (direct-mapped 512 x 32 bit, 16-byte lines, write-through, invalidate on
  write hit) -> SDRAM host port. One transaction at a time; `addr/q/sel/wr`
  registered a cycle after the CPU request. `debug` generic (default 0 at the
  top) instantiates the Altera-virtual-JTAG `debug_bridge_jtag`.
- `rtl/host/cfide.vhd`: 16-bit registers decoded on `addr(7 downto 4)` with
  `addr(23)=1`: SPI (E), UART TX (F), timer (D), platform (C), audio (B),
  interrupt (A), C64 keyboard (9), Amiga/Akiko (8), RTC (7), I2C (6), video
  position (5), XADC (4). Registers on `clk_28`, SPI shifter and `sck_pin` on
  `clk_114`; `ack` is generated on clk_28 (SPI/UART via the clk_114
  `support_state` machine). `interrupt` = (`vbl_int` | `i2c_int` | rising
  `amiga_req`) gated by `interrupt_ena`; **any access to 0x..A0 clears it**.
  SPI writes are accepted only when `SD_busy='0'`; the support machine
  stalls the CPU until then.
- `rtl/sdram/sdram_ctrl.v` host port: `hostbytesel[0]` masks `hostWR[31:24]`
  on the lower-address 16-bit SDRAM word, `[3]` -> `[7:0]`: byte-select
  index i is the byte at A+i, lane order big-endian. Host space maps to
  physical `addr ^ 0x680000` (`HOSTMAP_ADDR`).
- `fw/ctrl_boot_832/rom_prologue.vhd`: `wea <= bytesel(0)&bytesel(1)&
  bytesel(2)&bytesel(3)` -> `bytesel(0)` writes bits 31:24, same convention.
- `rtl/soc/minimig_virtual_top.v` ~1323: `EightThirtyTwo_Bridge #(debug)
  hostcpu` on `CLK_114`, `host_interrupt` from cfide. `RTC_INT_N`, `CTRL_RX`
  exist as inputs and are unused by the host CPU. SPI chip selects:
  `SPI_CS[1]` SD card, `[4..6]` `SPI_SS2..4` to minimig (fpga/osd/direct
  mode), `[7]` RTC.
- Minimig SPI slaves: `rtl/minimig/userio_osd.v` + `userio_osd_spi.v` (OSD
  commands, replies loaded per transfer on the clk7_en grid, key queue),
  `paula_floppy.v` + `paula_floppy_fifo.v` (track read/write FIFOs, direct
  mode from the SD card, race fixed in 202e077), `gayle.v` + `gayle_port.v`
  + `gayle_fifo.v` (two-port IDE/ATAPI with sector FIFOs).
- XDC that names host registers: `wizard.xdc` 29-32 (multicycle
  `hostcpu/hw_req_reg`, `hostcpu/wr_reg` -> i2c_master_mmio); `sd_card.xdc`
  (generated clock `spi_sck` on `mycfide/sck_pin_reg`, bounded crossings).
- Build: Vivado 2023.2 (`tools/vivado/README.md`, libtinfo5 shim) through
  `tools/vivado/build_ap040.tcl` and five siblings, each with its own
  `add_src` list (convention in `build.tcl` lines 80-100); the 832 sources
  are only in `project_1.xpr` and in `rebuild.tcl`'s commented list
  (111-125). Quartus: `rtl/host/host.qip`.
- Benches that matter here (all iverilog unless noted, `RUNTAG` convention):
  `sim/spi_cdc/tb_spi_cdc.v` (xsim: cfide + paula_floppy + userio_osd + SD
  card model, an 832 **bus model** with `+GAP` = clk_114 cycles between
  accesses swept 2..64, `(SCKDLY, C28DLY)` skew grid; checks `wr`, `rd`,
  `direct`, `osd`); `sim/spi_cdc/host832/` (the same direct-mode transfer
  with the **real 832** + bridge + hostcache, program hand-assembled by
  `gen832.py`, `debug_bridge_stub.vhd`); `sim/gayle` (two-port Gayle,
  `golden_a.txt` trace, mutant modes); `sim/osd_keyq` (OSD key queue, mutant
  mode); `sim/sdram_coherency`, `sim/cpu_cache_sdram` (SDRAM models);
  `sim/rom-hostcpu-test` (ROM entity only). No bench runs the host firmware.

### 1.2 Firmware (`fw/ctrl_832`, 14,407 lines after the cdrom merge)

- vbcc832 `-O=1343`, big-endian, linked at 0x2000, **stack in the boot BRAM**
  (top 0x2000, `setstack()`); 832OSDAD.bin 83,830 B, bss end 0x1DF48;
  `AUDIO_BUFFER` at host 0x70000 (2 x 32 KB) caps code+data+bss+heap at
  448 KB.
- Boot ROM: 4,333 B, bss end 0x1354, stack 0x240, `prg_start=0x2000`,
  `OSDNAME="832OSDADBIN"`; `romgen` -> VHDL table between
  `rom_prologue/epilogue.vhd` (file byte i in BE lane i).
- Interrupts: lib832 `start.S` dispatches through `_InterruptVector` at byte
  13 of the ROM, patched by `SetIntHandler()`; `inthandler()` runs
  `akiko_inthandler()` and `c64keys_inthandler()`. Everything else polls from
  `main()`: `drivesounds_fill`, `HandleRTC`, `CD_AudioPoll`, `HandleFpga`
  (6-byte SPI status poll), `HandleUI`, the 250 ms ADV7511 INT edge check.
- 68k code inside the firmware (`bootcustominit.s`, `bootdiag.s`) is
  assembled by vasm into byte arrays and uploaded byte-wise (endian-neutral).
  `start68k.s`, `startup_*.s`, `osd_*-elf.ld`, `Makefile.68k` are leftovers of
  the 68k/ZPU ports; `#ifdef __GNUC__ void c_entry(void)` already exists.
- I/O access widths/offsets: 8-bit at offset 3 (`HW_SPI` +3/+7/+11, `RS232`
  0x..F3, `AUDIO` 0x..B3); 16-bit at offset 2 (`TIMER` 0x..D2, `PLATFORM`
  0x..C2, `HW_RTC` base 0x..72, `HW_AKIKO` +2/+6, `HW_KEYBOARD` +2/+6/+A/+E);
  32-bit at 0 (`HW_INTERRUPT`, `HW_I2C`, `VIDEOSCALE`, `HW_UART`);
  `FPGA_TEMP_RAW` 16-bit at 0.
- Tests: `fw/ctrl_832/test` (gcc, ASan/UBSan, `-DHOSTTEST`: cue, cdaudio,
  atapi, cdrom, openhf; "hdd.c as a whole does not build with gcc");
  `fw/ctrl_832/test/emu` (vbcc832 + patched `832e`, catches compiler bugs).
- CD audio: 2 x 32 KB ring, 186 ms per half, `CD_AudioPoll()` once per main
  loop, `cda_underruns()` is a live metric; a refill is ~64 SD sectors over
  the SPI byte loop plus 8 K word writes through the write-through cache.
  Underruns come from foreground jobs blocking the loop >150 ms (256-sector
  IDE transfers, floppy track writes).

### 1.3 Measured fit (cited, not re-measured)

`build/stage_cdscaler2/utilization.rpt`: 53,303 / 63,400 LUT (84 %), slices
98.2 %, 26,047 FF, 88.5 / 135 BRAM, 50 / 240 DSP; clk_114 WNS -0.202 ns.
832 share: hostcpu 912 LUT / 944 FF / 3 BRAM / 4 DSP; cpu 761 / 772 / 4 DSP;
hostcache 74 LUT / 1 BRAM.

---

## 2. Core survey and selection

### 2.1 Survey (web, 2026-10-16)

| Core | Language / licence | Status | Size on 7-series | Fmax | Interrupts | Bus / peripheral fit | Verdict |
|---|---|---|---|---|---|---|---|
| **picorv32** [1] | Verilog, ISC | Archived Sep 2026, formally verified | small 761 LUT / 442 FF; regular 917 / 583; large 2019 / 1085 | 250-450 MHz 7-series (Kintex -2 416 MHz, picorv32_axi); CPI ~4, 0.516 DMIPS/MHz zero-wait | 32 level/latched lines, non-standard (`getq/setq/retirq/maskirq/waitirq/timer`), built-in timer | native valid/ready + look-ahead; AXI4-Lite and Wishbone wrappers. One master: DMA needs a 2-way arbiter in the bridge (cheap). | **Primary** |
| **Hazard3** [2] | Verilog, Apache-2.0 | Active, in RP2350 silicon | not published; est. 1.5-2.5 k LUT | not published for Artix | standard Zicsr + Xh3irq (priorities), debug module (BSCANE2 DTM on Xilinx, optional) | AHB5-Lite, ~50-line adapter; single master, same arbiter story | **Runner-up / drop-in**, measured in Phase 0 |
| VexRiscv [3] | SpinalHDL -> Verilog, MIT | Active | RV32I 504 LUT (no IRQ); RV32IM 1418 / 949; +4 KB I$/D$ 1840 / 1158 | 243 / 216 / 199 MHz | standard | simple/AXI/Avalon/Wishbone; caches make DMA coherency harder | Measured in 2.3 as the "has an I-cache" reference; not chosen (JDK/sbt regeneration, unreleased SpinalHDL) |
| NEORV32 [4] | VHDL, BSD-3 | Very active (v1.13.6) | ~2300-2500 LUT / 1000-1800 FF / 7 BRAM | 130-150 MHz unconstrained | standard + 16 FIRQ, CLINT, OCD | XBUS/Wishbone, AXI | Too big and too little Fmax margin here |
| SERV [5] | Verilog, ISC | Active | 125 LUT / 164 FF | high | timer | Wishbone | Bit-serial, ~3 MIPS at 113 MHz: starves the SPI loops. Rejected |
| FemtoRV [6] | Verilog, BSD-3 | educational | ~1 k LUT (iCE40) | 80 MHz iCE40 | gracilis has IRQ | native | Less verified than picorv32 in the same niche. Rejected |
| ibex / CV32E40x | SystemVerilog + prim libs | Active | 2-6 k LUT | OK | standard | OBI | Breaks the plain-Verilog / Quartus / iverilog rule. Rejected |
| DarkRISCV | Verilog, BSD | hobby | small | high | non-standard | native | Compliance quirks, no formal proofs. Rejected |

Sources: [1] https://github.com/YosysHQ/picorv32 [2] https://github.com/Wren6991/Hazard3
[3] https://github.com/SpinalHDL/VexRiscv [4] https://stnolting.github.io/neorv32/
[5] https://github.com/olofk/serv [6] https://github.com/BrunoLevy/learn-fpga/blob/master/FemtoRV/README.md

### 2.2 Selection reasoning

Fmax at 113.4 MHz is not what separates picorv32 from the 832; throughput
is. picorv32's 0.516 DMIPS/MHz (~59 DMIPS at 114 MHz) assumes zero-wait
memory. Our firmware executes from SDRAM through hostcache and a bridge that
costs about 4-5 clk_114 cycles per hit and a burst fill per miss; picorv32
fetches one 32-bit word per instruction (per ~1.4 with C) through that path,
so its real CPI is roughly 4 + 4.5 = 8-9 without help -- ~13 MIPS,
~0.25 DMIPS/MHz, ~28 DMIPS. The 832 amortises one word fetch over ~4
one-byte opcodes, so its memory CPI is low and its figure is unknown until
measured. A core with its own I-cache and a pipeline (VexRiscv, Hazard3 +
cache wrapper, NEORV32 + i-cache) would run at CPI ~1.5-2 (50-75 MIPS) but
costs 1-1.5 k LUT more plus a cache, on a die with 98 % of slices packed.

Both knobs exist for picorv32 too: the look-ahead port lets the hostcache
tag lookup start a cycle early, a 1-line (16-byte) prefetch buffer in the
bridge serves sequential fetches without a round trip, and C halves fetch
traffic. The decision rule is therefore data-driven (2.3): pick the smallest
core that gives >= 1.5x the 832 on Dhrystone **and** fills a 32 KB CD-audio
half no slower than the 832, after the bridge-side improvements are counted.
If picorv32 cannot get there, Hazard3 with a 4 KB I-cache in the wrapper is
the next step, not a redesign, because everything sits behind the same
bridge interface. Peripheral friendliness (2.1 last column) is equal across
candidates for the same reason; picorv32's native bus is the simplest to put
MMIO on.

Default picorv32 parameters: `ENABLE_COUNTERS=1, ENABLE_REGS_16_31=1,
ENABLE_REGS_DUALPORT=1, LATCHED_MEM_RDATA=0, TWO_STAGE_SHIFT=0, BARREL_SHIFTER=1,
TWO_CYCLE_COMPARE=0, TWO_CYCLE_ALU=0, COMPRESSED_ISA=<Phase 0>, CATCH_MISALIGN=1,
CATCH_ILLINSN=1, ENABLE_PCPI=0, ENABLE_MUL=0, ENABLE_FAST_MUL=1, ENABLE_DIV=1,
ENABLE_IRQ=1, ENABLE_IRQ_QREGS=1, ENABLE_IRQ_TIMER=1, MASKED_IRQ=0,
LATCHED_IRQ=~0, PROGADDR_RESET=0x0, PROGADDR_IRQ=0x10, STACKADDR=0x2000`.

### 2.3 Phase 0 measurement table (to be filled; procedure in Phase 0)

All at 113.4 MHz on `xc7a100tfgg676-2`, memory path = real `hostcache.v` +
real bridge + an SDRAM host-port model with the measured ack latencies
(taken from `sim/spi_cdc/host832` waveforms) + the 8 KB BRAM boot ROM.
Dhrystone = `fw/dhrystone_*` 2.1 with the firmware's compiler flags.

| Candidate | LUT | FF | DSP | BRAM | WNS OOC @113.4 | DMIPS (sim, real path) | SPI byte loop ns/byte | 32 KB ring fill ms | notes |
|---|---|---|---|---|---|---|---|---|---|
| 832 (reference) | 761 (known) | 772 | 4 | 2+1 | from stage | board or 832e | | | the baseline every other row is compared with |
| picorv32 IM | ~917 | ~583 | 4 | 2+1 | | expect ~25-30 | | | |
| picorv32 IMC | ~1,020 | ~600 | 4 | 2+1 | | expect ~30-35 | | | |
| picorv32 IMC + look-ahead + 1-line prefetch | ~1,100 | ~650 | 4 | 2+1 | | expect ~40-45 | | | bridge option `rv_prefetch` |
| Hazard3 IMC (no debug) | est. 1.8-2.5 k | | | 2+1 | | expect ~35-45 (no I$) | | | AHB-Lite adapter |
| Hazard3 IMC + 4 KB I$ (wrapper) | +~150 LUT, +1 BRAM | | | | | expect ~70 | | | measurement only unless picorv32 fails the rule |
| VexRiscv IM + 4 KB I$ (pre-generated demo Verilog) | 1,840 (README) | 1,158 | | +cache | | expect ~70 | | | reference row only |

Gate: the row chosen satisfies DMIPS >= 1.5 x 832 and ring fill <= 832, with
WNS >= +1.0 ns OOC and the LUT delta <= +500 (picorv32 rows) or <= +1,800
(Hazard3 rows). The SPI byte loop is expected to be bound by the two clk_28
round trips per byte (~12-16 clk_114 each), i.e. roughly equal for all rows;
that column tells whether Phase 8's SPI FIFO is needed at all.

---

## 3. Architecture of the port

### 3.1 Memory map (unchanged)

| Host address | Device | Notes |
|---|---|---|
| 0x000000-0x001FFF | boot BRAM, 8 KB, R/W | reset vector 0x0, IRQ trampoline at 0x10 + RAM vector word; after boot: the firmware's stack |
| 0x002000-0x7FFFFF | SDRAM via hostcache | firmware at 0x2000, `AUDIO_BUFFER` 0x70000, Amiga memory at `addr ^ 0x680000` |
| bit 23 set | cfide registers, 16-bit | offset 0 in each 16-byte window from now on |

### 3.2 Bridge (`rtl/host/832_bridge.vhd`, rewritten in place)

Entity name and ports of `EightThirtyTwo_Bridge` stay (top instance, XDC cell
names `hw_req_reg`/`wr_reg`, Quartus project untouched); new generics
`cpu_riscv : boolean := false`, `rv_compressed : boolean := false`,
`rv_prefetch : boolean := false`.

1. `gen832:` existing 832, debug bridge and `OSDBoot_832_ROM`, unchanged.
2. `genrv:` `picorv32` (Verilog component from VHDL; mixed language works in
   Vivado and Quartus, `host.qip` lists the .v) behind `rv32_cpu_wrap.v`
   (`mem_valid/instr/ready/addr/wdata/wstrb/rdata` -> `req/ack/addr/q/sel/wr`,
   `irq[31:0]`), plus `OSDBoot_rv32_ROM`. The wrapper presents the generic
   interface that a Hazard3 (AHB-Lite adapter) wrapper would also present.
3. **Lanes** (section 5): ROM and hostcache paths swap the four data bytes
   in both directions, `sel` passes through; the hw path passes
   `q(15 downto 0) <= cpu_q(15 downto 0)` and `cpu_d <= x"0000" & hw_d`.
   Zero LUTs (wiring).
4. **Four-phase hw handshake.** cfide's `ack` is a clk_28 register that stays
   high until a clk_28 edge sees `req` low; the bridge today leaves the `hw`
   state the moment it sees `ack`, so a next hw access within ~4 clk_114
   cycles would be acknowledged by the stale `ack` and a write could be
   missed on the clk_28 side. New state `hw_release`: after `hw_ack='1'`
   drop `hw_req`, complete the CPU cycle, and accept the next hw transaction
   only after `hw_ack='0'` was seen. Unconditional (both CPUs), so A/B
   compares like with like; it is also what makes the timing-dependency
   inventory (section 7.1 item 1) a non-issue.
5. **Interrupts:** `interrupt` -> `irq[3]`; `irq[0]` picorv32 timer,
   `irq[1]` ebreak/ecall/illegal, `irq[2]` bus error (diagnostic handler
   prints PC in DebugMode and halts). Phase 8 sources on `irq[4..]`.
6. **Arbiter hook:** the bridge's single state machine is the natural place
   for a second requester (Phase 8 DMA): a `dma_req/ack/addr/q/sel/wr` port
   with fixed priority CPU > DMA (or round-robin) in front of hostcache.
   Not built in Phase 1, but the state machine is written so that adding a
   requester does not restructure it.
7. `rv_prefetch`: a 1-line (16-byte) instruction buffer filled on a fetch
   miss, serving sequential `mem_instr` hits in 1 cycle; invalidated by any
   write to the bridge control address 0x..A8 (picorv32 has no `fence.i`)
   -- the boot ROM writes it before `_boot()`.

### 3.3 Boot ROM entity

`OSDBoot_rv32_ROM.vhd` from the unchanged romgen flow (file byte i in lane i;
the lane swap hands the CPU LE instruction words). `maxAddrBitBRAM => 12`
stays (measured need ~5.3 KB of 8 KB incl. 0x240 stack and the trampoline);
16 KB (`=> 13`, `prg_start = 0x4000`, +2 BRAM tiles) is a one-line reserve.

### 3.4 Top level and A/B

`minimig_virtual_top.v` parameters `hostcpu_riscv = 0`, `hostcpu_rvc = 0`,
`hostcpu_rvpf = 0` -> bridge generics. Stages `stage_rv32*` and `stage_832ab`
from the same tree. Each boot ROM loads its own file (`832OSDADBIN` /
`RV32OSDADBIN`), so one SD card serves both bitstreams and the A/B is a
reprogram.

### 3.5 Firmware layout and toolchain

Single tree `fw/ctrl_832` (renamed `fw/ctrl` in Phase 9): `Makefile` (832,
untouched until Phase 9) and `Makefile.rv32`; same for `fw/ctrl_boot_832`.
Architecture code in `arch/` (`crt0_rv32.S`, `irq_rv32.S`, `rv32.ld`,
`arch_rv32.h` with the byte-order helpers) and `#if __riscv` /
`__BYTE_ORDER__` where unavoidable. A copied tree would diverge in days.

Toolchain (open decision 6): Ubuntu `/usr/bin/riscv64-unknown-elf-gcc` 13.2
+ `picolibc-riscv64-unknown-elf` headers, `-march=rv32im[c] -mabi=ilp32 -Os
-ffunction-sections -fdata-sections -fno-builtin -funsigned-char -nostdlib
-Wl,--gc-sections`, libgcc only (the firmware has `small_printf.c`, the
testbed has `malloc.c`; lib832's `string.S` becomes plain C). The multilib
set has `rv32im` and `rv32imac` (no `rv32imc`); rv32imc objects link against
the rv32im libgcc. Second choice `/home/paul/bin/riscv32-unknown-elf-gcc`
14.2 (single multilib `rv32imac`, newlib): then every object gets
`-march=rv32imc` and the link is checked for A-extension opcodes
(`objdump -d | grep -E 'lr\.w|sc\.w|amo'` empty), since picorv32 has no A.

### 3.6 Debug bridge

Dropped for the RISC-V path (production builds already have `debug=0`;
picorv32 has no debug module; the transports are vendor-specific on both
vendors). Replacements: UART `DebugMode`, the benches, and -- if ever --
Hazard3's debug module with a BSCANE2 DTM behind an Artix-only switch.

### 3.7 Tests and the emulator harness

- `fw/ctrl_832/test` (gcc) stays host-native and grows (Phase 3.5).
- `fw/ctrl_832/test/emu` (compiler-bug harness) is replaced by
  `fw/ctrl_832/test/rv32/`: the same `*_emu.c` programs compiled with the
  firmware's exact gcc flags, a 30-line crt0 and a `putchar` MMIO, run on the
  **real picorv32 RTL** under Verilator (picorv32's `testbench.v` pattern).
  No qemu/spike is installed; running on the RTL is more faithful anyway and
  is the L1 bench of Phase 4.
- `fw/dhrystone_832` -> `fw/dhrystone_rv32` for the L1 bench and the board.

---

## 4. Sizing

Logic: picorv32 regular 917 LUT / 583 FF / 4 DSP (README) vs 832 cpu
761 / 772 / 4 -> +150..250 LUT, -190 FF; `COMPRESSED_ISA` est. +100;
`rv_prefetch` est. +80 LUT + 128 FF; bridge otherwise unchanged. Expected
hostcpu ~1,100-1,300 LUT vs 912. Hazard3 est. +1,000-1,700.

Timing: picorv32's internal paths have >2x margin at 8.815 ns on -2; the
risk is clk_114 congestion itself (+200 LUT on 98 % slices; -190 FF helps).
Bridge stays registered both sides; Phase 0 runs OOC with the real
`clocks.xdc` constraint.

Code size (measured 2026-10-16, riscv32 gcc 14.2 `-Os`): 26 of 31 firmware
units compile unchanged -- RV32IMC 48,105 B text + 2,921 B data, RV32IM
58,435 B text; the five that gcc rejects (`fat.c`, `hdd.c`, `menu.c`,
`drivesounds.c`, `small_printf.c`: prototype mismatches, `{` in a macro
argument, implicit `puts`) are ~45 % of the lines, so the whole image is
~85-95 KB RV32IMC / ~105-115 KB RV32IM against 83,830 B (832 incl. lib832);
bss ~33 KB. Boot ROM RV32IMC 3,636 B text + 22 + 628 (RV32IM 4,576) against
4,333 B. RV32IMC is code-size neutral, so the 2 KB hostcache's hit rate
should be similar; RV32IM costs ~25 % more fetch bandwidth.

---

## 5. Endianness -- analysis and strategy

### 5.1 Choice

The 832 is big-endian and shares SDRAM with a big-endian 68k: byte A+0 is
bits 31:24 (`bytesel(0)` -> `hostWR[31:24]` -> upper byte of the lower
16-bit SDRAM word). Options:

- **Byte-invariant (chosen):** swap data lanes in the bridge. Every byte
  address means the same physical byte for CPU and 68k; byte streams
  (sector buffers, kickstart images, strings, `bootcustominit`, ADF/HDF/ISO
  data) copy with no code change; multi-byte values the CPU writes natively
  are LE in memory and the 68k sees them swapped -- the standard LE-host /
  BE-guest situation.
- Word-invariant (rejected): no swap; 32-bit values shared correctly but
  every byte copy lands at `A ^ 3`, i.e. every copy loop and the SD sector
  path change.
- Software-only or hardware-only variants (rejected): unreviewable in 14 k
  lines, or a register map that differs per CPU.

### 5.2 Firmware audit (what changes)

Endian-neutral already (no change): `fpga.c` kickstart upload, `boot.c`
logo/BootDiag/ErrorCode (bytes), `config.c` Clear* (zeros), `atapi.c`
(`put16/put32/get16/get32`), `cdaudio.c` (byte stores; the ring format is LE
16-bit), `hdd.c` `WriteIDEData/ReadIDEData` (bytes over SPI), `minfat.c` BPB
(byte arithmetic), `spi.c`, `osd.c` text, `cue.c`/`cdrom.c` (text + helpers).

Swap direction flips (today's "for 68000" swaps of LE on-disk FAT fields
become identity): `fat.c` `SwapBB/SwapBBBB` on FileSize/StartCluster/
HighCluster/FAT links/dates, `SwapPartitionBytes` (the MBR signature test
`fat.c:39,137-153` stays and takes the other branch), `minfat.c` 138/239/
279-280. Implement `le16/le32/be16/be32()` in `arch_rv32.h` keyed on
`__BYTE_ORDER__`; rename call sites once.

Explicit big-endian handling to add:
1. `hdd.c` RDB/PartitionBlock synthesis (86-160): every long -> `be32()`;
   the longs checksum sums BE longs.
2. `hdd.c` `IdentifyDevice()` `unsigned short id[256]` sent byte-wise by
   `WriteIDEData` -> store with `be16()` so the byte stream is unchanged.
3. `boot.c:200` default copper list -> `be16()`.
4. `drivesounds.c:231-233` manual byte swap (BE CPU producing LE samples) ->
   delete on LE; keep `c*0x10001`.
5. `config.c`: the config file is `sizeof(configTYPE)` = 212 raw bytes with
   `unsigned long version` (and any other multi-byte member) -> keep the
   **on-disk format big-endian**, swap on load/save, so 832-written slots
   load unchanged (needed for the A/B card).
6. `firmware.h` `UPGRADE`/`CheckFirmware/WriteFirmware`: verify dead; else as 5.
7. Struct overlays on disk data to re-check: `fat.c:137 MasterBootRecord`,
   `hdd.c:90/131/524 RigidDiskBlock/PartitionBlock`, `config.c:275`.
8. Anything found by the differential bench (Phase 4) -- the golden SPI
   byte traces catch what the grep did not.

### 5.3 Hardware window

Value-preserving 16-bit registers at offset 0: `HW_SPI(x)` +3/+7/+11 ->
+0/+4/+8, `RS232` 0x..F0, `AUDIO` 0x..B0, `TIMER` 0x..D0, `PLATFORM` 0x..C0,
`RTCBASE` 0x..70, `REG_AKIKO_ADDR/DATA` 0/4, `REG_KEYBOARD_WORD0..3`
0/4/8/0xC, `REG_KEYBOARD_OUT` 0; the 32-bit ones are already at 0. picorv32
replicates `SB/SH` data across lanes, which would hide a forgotten write
offset but not a read -- do not rely on it (Hazard3 does not replicate). Boot
ROM `spi.h`/`uart.h` get the same edit. cfide does not change in this phase.

---

## 6. Interrupts and peripherals

### 6.1 Today

One level line from cfide (vblank | I2C INT | Akiko request edge; enable bit
0 at 0x..A0; cleared by any access). `inthandler()` runs the Akiko and C64
keyboard state machines; everything else polls. cfide's enable bit is the
only mask.

### 6.2 First port (polling 1:1)

- `irq[3]` <- `interrupt`. Boot BRAM: reset stub at 0x0, IRQ trampoline at
  0x10 (`PROGADDR_IRQ`) saving the caller-saved set and `q0/q1`, calling
  through a RAM vector word (`_InterruptVector`, the counterpart of the
  832's byte 13), `retirq`. `SetIntHandler()`, `Enable/Disable/GetInterrupts()`
  unchanged in meaning. The handler clears the cfide source before `retirq`;
  with `LATCHED_IRQ` a still-pending level re-enters, as today. Linker
  script reserves 0x0-0xFF; the stack (top 0x2000) grows toward it.
- Nothing else changes: same SPI polling, same main loop. This is the
  reference point for every later offload.

### 6.3 Interrupt controller (Phase 8.0)

picorv32's 32 `irq` lines **are** the core-side controller (`maskirq` =
mask, `q1` = pending bitmap, latched or level per bit); Hazard3 would use
`mip/mie` + Xh3irq. Either way the platform needs one register block in
cfide at 0x..A0 so sources can be acknowledged and masked uniformly and so
the 832 keeps working during A/B:

```
0x..A0  IRQ_STATUS  R: pending bits, W1C      bit0 = legacy aggregate (vblank|i2c|akiko), kept
0x..A4  IRQ_ENABLE  R/W                        bit0 = legacy enable (today's semantics)
0x..A8  BRIDGE_CTL  W: bit0 = invalidate prefetch (3.2.7)
```

One cfide line per enabled source goes to `irq[4+n]` as well, so the
firmware can take a per-source vector or just read `IRQ_STATUS`. No
PLIC-lite: eight sources, fixed priority in software is enough.

Firmware structure from 8.0 on: ISRs only move bytes and set flags (timer
tick, UART RX into a ring, "request pending" flags, audio half flag); the
main loop does all SPI/SD/FAT work; critical sections = `irq_save()/
irq_restore()` around shared variables (picorv32 `maskirq`); fdd/hdd/atapi/
cdrom code stays non-reentrant and main-loop only; one SPI bus, one owner,
**never SPI from an ISR**. Clock domain for all new peripherals: `clk_114`
behind the cfide hw window (like the SPI master today); minimig-facing
request lines cross from clk_28/clk7_en with 2-FF synchronisers or the
existing req/ack style. Budget for the whole of Phase 8: <= 1.5 k LUT,
<= 2 BRAM tiles, each step measured against the previous stage.

### 6.4 Candidate peripherals (each a separate Phase 8 step)

| # | Peripheral | Removes from firmware / timing it fixes | IRQ source(s) | Register sketch (cfide window) | LUT / BRAM est. | Risk | Priority |
|---|---|---|---|---|---|---|---|
| P1 | **Request IRQ + OSD reply ready flag** | The 6-byte `HandleFpga()` SPI status poll per loop (~100 us) and the `SPI_reply()` pause: `userio_osd` exposes "reply byte loaded" and "key queue non-empty"; `paula_floppy` exposes "track request pending" (CMD_RDTRK/WRTRK), `gayle_port` "command written" / "FIFO threshold"; cfide shows them in IRQ_STATUS and a `HOST_REQ` status word | request lines (4-5 bits) | `0x..B4 HOST_REQ` R: {osd_reply_rdy, keyq, fdd_req, ide0_cmd, ide1_cmd, ide_fifo_rdy} | ~120 LUT, 0 BRAM | low (status only; minimig-side changes are output ports) | **1** -- biggest latency win per LUT; also fixes inventory item 2 in hardware |
| P2 | Timer (`mtime`/`mtimecmp`, 64-bit at clk_114, plus 100 Hz tick) | `GetTimer/CheckTimer` 16-bit wrap handling, RTC/drive-sound/HDMI 250 ms bookkeeping moves to the tick ISR | compare match, tick | `0x..D4 MTIME_LO/HI`, `0x..DC MTIMECMP_LO/HI` (TIMER at D0 stays) | ~100 LUT | low | **1** |
| P3 | UART RX + 16-byte TX/RX FIFOs | A debug console (today TX-only, blocking per byte) | RX non-empty, TX empty | `0x..F0 DATA`, `0x..F4 STATUS` | ~120 LUT (LUTRAM) | low | 2 |
| P4 | I2C INT routing | The 250 ms edge-poll of the ADV7511 INT | existing `i2c_int` as its own bit | none new | ~10 LUT | none | 1 (free with 8.0) |
| P5 | SPI master with 64-byte TX/RX FIFOs and byte counter | The two hw round trips per byte: the CPU queues "n bytes, CS pattern", reads the RX FIFO; SPI becomes wire-bound (~3.5 MB/s at 28 MHz) instead of CPU-bound; CS deassert timing becomes a hardware constant (inventory items 2-4) | FIFO half / done | `0x..E0` compatible byte register stays; `0x..EC CTRL/COUNT`, `0x..E8 FIFO` | ~300-400 LUT + LUTRAM (or 1 BRAM18) | medium: all five slaves share CS semantics; must keep the single-byte path for the 832 A/B | 2 -- only if 2.3 shows the byte loop matters (expected yes for 32 KB fills) |
| P6 | Sector DMA engine SD <-> minimig FIFO (generalised direct mode) | The CPU from the read data path SD -> paula/gayle (today's direct mode does this for reads with the CS timing in firmware; the engine owns CS, count and both directions, FPGA -> SD for HDF/ADF writes included). Removes the CS-timing race class structurally | done / error | `0x..C4 DMA_CMD` {dir, slave, blocks}, `0x..C8 DMA_STAT` | ~300-500 LUT | medium-high: touches `paula_floppy`/`gayle_port` FIFO ports; the SD write protocol (token, busy) must be in hardware | 3 -- after P5 is measured |
| P7 | CD-DA ring refill DMA + half-empty IRQ | The 32 KB copy per 186 ms and its SPI loop; firmware supplies an LBA run list (from the CUE/FAT chain) per half | half flip, list empty | `0x..C0 CDA_LIST` (base of run list in SDRAM), `CDA_CTL` | ~500-700 LUT + 1 BRAM; needs the bridge arbiter (3.2.6) | high: SDRAM host port is lowest priority; hostcache coherency (DMA writes must invalidate or bypass); `scale()` volume moves to hardware or is dropped | 4 -- only if P5+P1 still leave underruns |
| P8 | I2C engine | already exists (`i2c_master_mmio`) | -- | -- | 0 | -- | n/a |

Estimated total if P1-P5 are built: ~700 LUT, 0-1 BRAM; within budget.
P6/P7 are decided on Phase 7/8 measurements, not up front.

---

## 7. Verification strategy (simulation before any board test)

Paul's requirement: floppy, hard-disk and CD/ATAPI paths are proven in
simulation + verification before a board test. The backlog's "SPI clock
constraints and a floppy direct-mode race" is the model case: `paula_floppy`
dropped the last direct-mode word if chip select went away within ~30
cycles; the 832 took ~45 -- correctness rested on firmware timing. 202e077
fixed it in RTL and `sim/spi_cdc` swept the host access gap 2..64 to prove
it. A different CPU changes every such margin, so each one is listed,
measured and guarded.

### 7.1 Inventory of firmware-timing-dependent handshakes on the host side

| # | Handshake | Where | Dependency / margin today | Status | How it is checked |
|---|---|---|---|---|---|
| 1 | hw register write hold / stale `ack` between back-to-back hw accesses | bridge <-> cfide (clk_114 <-> clk_28) | an access needs >= 1 clk_28 period of `req`; a second access within ~4 clk_114 of the previous `ack` can be falsely acknowledged. 832 spacing happened to exceed it | fixed by the four-phase handshake (3.2.4) | `sim/host_bridge` directed back-to-back test; `tb_spi_cdc` GAP=2 rows |
| 2 | OSD reply byte load | `userio_osd` loads the reply per SPI transfer on the clk7_en grid | needs >= 40 clk_114 between host accesses; below that `OSD_CMD_VERSION` fails 3/3 in every skew corner; firmware 174322f adds a pause (`SPI_reply()`: 4 x `SPIN`) | **open**: firmware pause only; margin shrinks with a faster CPU | `tb_spi_cdc` `osd` test with the RV32 host (hostrv); margin monitor "cycles between accesses during OSD reads" >= 40; hardware fix = P1's reply-ready flag (poll it instead of counting) |
| 3 | Direct-mode SD -> paula/gayle, CS release after the 4096th bit | `mmc.c` `EnableDMode; SPI(0xFF); RDSPI; DisableDMode` | was >= ~30 cycles after the last bit, 832 ~45 | fixed in RTL (202e077: word latched on its last sck edge) | `tb_spi_cdc` `direct` GAP 2..64 and `host832`/`hostrv` real-CPU runs; monitor measures last-sck-to-CS-release; mutant (202e077 reverted) must fail |
| 4 | Command byte then CS release on the minimig slaves (`DisableFpga/DisableOsd` right after the last byte) | `userio_osd_spi` `rx`/`cmd` through clk7_en synchronisers; `paula_floppy`, `gayle` command decode | unknown; the GAP sweep covers it for `wr/rd/osd` | measured, not guaranteed by design | same bench; add a monitor "last sck edge to `_scs` rise" per slave with a per-slave minimum derived from the RTL (2 clk7_en = ~8 clk_28) |
| 5 | SPI data register write while the shifter is busy | cfide `SD_busy` | the write is held, not dropped (support state machine stalls the CPU) | by construction | assertion in `sim/host_bridge`: no SPI write accepted while `SD_busy` |
| 6 | Floppy track **read**: host feeds MFM words into the paula FIFO while Paula DMA drains | `fdd.c` `ReadTrack`/`SectorToFpga`, `CMD_RDTRK` status | FIFO must not run empty while `dsklen` DMA is active; drain rate ~1 word per 32 us (250 kbit/s MFM), fill rate = SPI; large slack, but a stalled host (CD refill, menu) can starve it | depends on main-loop latency | co-sim: ADF track reads with a monitor "FIFO empty && DMA active" = failure; stress mode with the CPU throttled finds the latency bound |
| 7 | Floppy track **write**: host drains the write FIFO while the Amiga writes | `fdd.c` `FindSync/GetHeader/GetData`, `CMD_WRTRK` | FIFO depth gives the slack; host must keep up for a whole track (~200 ms) | depends on main-loop latency | co-sim: ADF track write with "FIFO full && Amiga writing" monitor; written ADF compared with the golden image |
| 8 | IDE PIO flow control | `hdd.c` `while(!(GetFPGAStatus() & CMD_IDECMD))`, `CMD_IDEDAT`; gayle FIFOs | status-driven, no timing margin; latency only affects throughput | by construction | co-sim HDF multi-sector read/write, data compare; `sim/gayle` golden trace unchanged |
| 9 | ATAPI phases / CD READ | `cdrom.c` flags, `CD_TIMEOUT` 10 s | status-driven; 10 s host timeout (timer-based) | by construction | co-sim CD READ(10/12) of ISO sectors, data compare |
| 10 | SD card protocol waits | `mmc.c`: CMD41 1000 ms (timer), data-token wait `timeout++ >= 1000000` (count), write-busy loop | count-based waits expire sooner on a faster CPU (still >= 1 s); token wait normally 300 us | low | SD model with programmable token delay up to 250 ms; count loops converted to `CheckTimer` in Phase 3 (one-line changes) |
| 11 | `SPIN` / explicit delays | `hardware.c:236` (OSD reply, item 2); commented-out `SPIN`s in `fdd.c` (historic ADF-write workaround); `audio_clear` waits one TIMER tick | only item 2 is live | -- | grep gate in Phase 3: no new count-based delays |
| 12 | RTC (`pcf2123`) CS high time between transfers | `rtc.c`, `scs(7)` | the chip's minimum CS-inactive time is covered by the firmware's instruction spacing today | depends on CPU speed | add the datasheet minimum as a monitor in the co-sim (RTC model) or insert an explicit `WaitTimer`-free guard (read TIMER); low risk, listed for completeness |
| 13 | Akiko C2P service latency | `amiga_req` held until the host answers | the 68k bus waits; latency = ISR latency; correctness independent of speed | fine | co-sim: an Amiga-side Akiko write; measure latency both CPUs |
| 14 | Kickstart upload complete before CPU release | SDRAM write acks precede `OsdDoReset` | ordering by the bridge (write acked after SDRAM ack) | by construction | differential trace: last SDRAM write before the reset SPI command |
| 15 | OSD key queue | `osd_keyq` | queued since 174322f; no margin | fine | `sim/osd_keyq` unchanged |

Rule for the port: items 1-4 and 10 are closed by hardware or by replacing
counts with status/timer; 6 and 7 are bounded by measured main-loop latency
in the stress mode and later by P1; nothing new may depend on instruction
timing (reviewed in 3.2's grep gate).

### 7.2 Bench levels

- **L1** `fw/ctrl_832/test/rv32/` (Verilator, Verilog only): picorv32 + RAM +
  putchar. Unit programs, Dhrystone, the 2.3 micro-benchmarks with a
  cycle-accurate model of bridge + hostcache (real `hostcache.v`) + SDRAM
  port latency. Seconds per run; usable while Vivado holds the machine.
- **L2** `sim/host_bridge/` (xsim, mixed): bridge + cfide + hostcache + SDRAM
  model, directed tests (lanes, hw offsets, back-to-back, IRQ entry/return
  register signature), both CPU generics.
- **L3 co-simulation** `sim/spi_cdc/hostrv/` (sibling of `host832/`, xsim):
  the real `paula_floppy` + `paula_floppy_fifo`, `gayle` + `gayle_port` +
  `gayle_fifo`, `userio_osd` + `userio_osd_spi`, `cfide`, `hostcache`, the
  bridge, the **RISC-V core running the real boot ROM and firmware** (from
  the ROM VHDL and an SD-card SPI slave model serving a FAT16 image that
  holds `RV32OSDAD.bin`, `832OSDAD.bin`, the config slot, a kickstart, an
  ADF, an HDF with the synthesised-RDB case, an ISO and a CUE/BIN), plus an
  **Amiga-side model**: a bus-functional 68k issuing the register writes the
  firmware reacts to (floppy DMA reads and writes of whole ADF tracks via
  `dsklen`/`dskpt` + Paula DMA model consuming/producing MFM at the real
  rate, IDE task-file commands for HDF multi-sector reads and writes through
  the gayle ports, ATAPI PACKET READ(10)/READ TOC/PLAY AUDIO on port 2, an
  Akiko C2P write, OSD key events through the keyboard path). Data checks:
  MFM-decoded track data vs the golden ADF; written tracks decoded and
  compared; HDF sectors vs the golden HDF; CD sectors vs the ISO; CD-DA ring
  content vs the BIN; the RDB bytes vs the golden dump. Trace checks: every
  SPI transaction (CS, bytes, gaps) and every host-bus access is logged in a
  normalised form; the `cpu_riscv=false` run of the same scenario (the 832
  with the same card image) is the golden trace, compared with `diff` modulo
  version string and inter-access timing. Reuse: `tb_spi_cdc.v`'s SD model,
  skew grid and `GAP` statistics, `host832/run.sh`'s file list and xsim
  flow, `sim/gayle`'s Gayle model and golden format, `sim/osd_keyq`'s key
  injector.
- **Timing-stress mode** in L3: generic `rv_throttle` in the CPU wrapper
  (clock enable 1/1, 1/2, 1/4, 1/8 -- slower CPU: the latency-bound items
  6/7/10) and a `+FAST_HW` plusarg that shortens the SD model's token delay
  and the SDRAM model's latency to the minimum (faster CPU-visible timing:
  items 2/4) plus the `(SCKDLY, C28DLY)` skew grid; **margin monitors** print
  the minimum observed value of every item in 7.1 per run and compare it
  with the RTL requirement, so margins are measured, not just not-failing.
- **Teeth**: mutant runs that must fail -- 202e077 reverted (item 3), the
  four-phase handshake removed (item 1), a 1-byte-short MFM sector (data
  compare), `sim/gayle`'s existing mutants.

### 7.3 Host-native unit tests to add (`fw/ctrl_832/test`)

Feasible once Phase 3.2 makes `hdd.c`/`fdd.c` compile with gcc and
`hardware.h`'s `SPI()`/`EnableFpga()` macros become overridable under
`-DHOSTTEST` (a scripted SPI mock that records the byte stream and replays
canned replies):

- `fdd_test.c`: `SectorToFpga`/`SectorGapToFpga` MFM encoding of a known
  sector vs a golden byte stream recorded from the 832 build; `FindSync`/
  `GetHeader`/`GetData` fed with a recorded write-track stream; checksum and
  header/label handling; track/side arithmetic.
- `hdd_test.c`: `IdentifyDevice` byte stream; RDB + partition block bytes
  (golden from the 832); `ATA_ReadSectors` LBA/CHS math and sector_count
  wrap; multiple-mode chunking; `OpenHardfile` already covered.
- `mmc_test.c`: CMD sequences and token handling against the SPI mock,
  including the direct-mode call sequence (`EnableDMode` ... `DisableDMode`)
  recorded as a trace.
- `config_test.c`: 212-byte config round trip (BE on disk) with a file from
  a real card; `swap_test.c`: the le/be helpers on both byte orders.
All run under ASan/UBSan like the existing ones; `make -C fw/ctrl_832/test`
stays the single entry point.

### 7.4 Board stress protocol (part of the Phase 6 gate, both bitstreams)

1. ADF: from AmigaOS write a generated 880 KB pattern disk (e.g. a small
   test program filling all 160 tracks with LBA-tagged sectors), read it
   back and checksum on the Amiga; 20 iterations, normal and turbo floppy
   speed; `DebugMode` log clean (no retries).
2. HDF: copy a 50 MB file within the HDF and compare (Amiga `md5`/`cmp`);
   10 iterations; then the same with CD audio playing.
3. CD: read a 100 MB file from the ISO with checksum; CD-DA plays for 30 min
   while 2 loops; `cda_underruns` must stay 0 (0 is the current 832 figure
   in a quiet system -- record the 832's number under the same load).
4. Combined: ADF write/read loop + HDF copy loop + CD-DA for 1 hour.
5. Each run on the 832 and the RV32 bitstream from the same card; results in
   `findings/osd-riscv/stress.md` side by side.

---

## 8. Phases, tasks, models, gates

Model tags: **S** = Sonnet (mechanical / well specified), **O** = Opus (RTL,
timing, verification, debug, review). Every task ends with its gate; the
orchestrator commits (committed tree builds; `version.h` stays unstaged).
Branch rule: all of this on `osd-riscv`, merged into `5.0-040-pipelined` at
the end of Phase 5 (A/B-capable tree), again after Phase 6/7, and per step
in Phase 8; never into superproject `main`; core submodule untouched.

### Phase 0 -- measure (no change to the design)

- 0.1 **S** `tools/vivado/ooc_hostcpu/`: OOC project (`xc7a100tfgg676-2`,
  Vivado 2023.2 as production; 2026.1 for comparison only) implementing
  CPU wrapper + bridge skeleton at 113.4 MHz; variants per table 2.3 (incl.
  the 832 as reference). Gate: LUT/FF/DSP/BRAM/WNS columns of 2.3 filled;
  832 row within +/-10 % of 761 LUT.
- 0.2 **O** L1 throughput bench (7.2): real `hostcache.v`, bridge timing
  model, SDRAM port latency from `host832` waveforms; `fw/dhrystone_rv32`,
  SPI byte loop and 32 KB ring fill micro-benchmarks; run picorv32 IM/IMC/
  IMC+prefetch, Hazard3 IMC (+I$ wrapper), VexRiscv demo; the 832 reference
  from `fw/dhrystone_832` on the board (UART) or in 832e. Gate: DMIPS and
  ms columns of 2.3 filled; the selection rule applied in writing in
  `findings/osd-riscv/phase0.md`.
- 0.3 **O** Decision memo for open decisions 1-2; Paul signs off.

### Phase 1 -- bridge RTL

- 1.1 **O** Bridge rewrite per 3.2 (generics, lanes, four-phase hw
  handshake, IRQ map, arbiter-ready state machine, `rv_prefetch` option,
  `rv_throttle` bench generic), `rv32_cpu_wrap.v`, vendored
  `lib/picorv32/picorv32.v` with pinned hash and README. Gate: both
  generate branches elaborate in Vivado and lint in GHDL/iverilog; XDC
  cells `hostcpu/hw_req_reg`, `hostcpu/wr_reg` still exist.
- 1.2 **O** L2 bench `sim/host_bridge/`: lanes at every alignment against a
  BE memory model, hw offsets, back-to-back hw (must stall), SPI-busy
  assertion, IRQ register signature, prefetch invalidate. Gate: all pass
  for RV32; the 832 subset still passes; the handshake mutant fails.

### Phase 2 -- boot ROM and toolchain

- 2.1 **S** `fw/ctrl_boot_832/Makefile.rv32`, `arch/crt0_rv32.S`,
  `arch/rv32_boot.ld`, romgen flow -> `OSDBoot_rv32.bin/_ROM.vhd`,
  `OSDNAME="RV32OSDADBIN"`; fix `uart.c` `puts` prototype and `boot.c`
  `prg_start` cast; I/O offsets (5.3); `minfat.c` helpers (5.2); prefetch
  invalidate before `_boot()`. Gate: builds rv32im and rv32imc, `size`
  <= 6 KB; ROM VHDL passes the L2 bench boot test.
- 2.2 **O** `arch/irq_rv32.S` (picorv32 trampoline at 0x10, RAM vector,
  `SetIntHandler` ABI unchanged). Gate: L2 IRQ test with a C handler
  installed through the vector; all registers intact.
- 2.3 **S** L1 harness `fw/ctrl_832/test/rv32/` running `cue_emu`,
  `cdaudio_emu`, `atapi_emu`. Gate: three `PASS`.
- 2.4 **S** `fw/dhrystone_rv32` (also used by 0.2). Gate: runs in L1 and
  prints a number.

### Phase 3 -- firmware 1:1 and host tests

- 3.1 **S** `fw/ctrl_832/Makefile.rv32`, `arch/`, crt0 sets sp = 0x2000,
  `__constructor` -> `__attribute__((constructor(prio)))` with the same
  order, `MM_VERSTRING` `-RV32` suffix, entry via `c_entry()`. Gate: all 31
  units compile; map shows `_end` < 0x70000.
- 3.2 **S** gcc fixes (`ShowError`, `FindDirectoryByCluster`, `{` in macro
  args, implicit `puts`), I/O offsets (5.3), le/be helpers (5.2 "flips"),
  `mmc.c` count loops -> `CheckTimer` (7.1 item 10), `SPI()`/`EnableFpga()`
  overridable under `-DHOSTTEST`. Grep gate: no `SPIN`-style count delays
  added; 832 build still produces a byte-identical `832OSDAD.bin` apart
  from `version.h`.
- 3.3 **O** Endianness items 1-7 of 5.2. Gate: host tests pass; golden-byte
  tests for RDB/identify/copper (goldens dumped from the 832 build via the
  UART hexdump or the 832e harness) pass; config round-trip passes.
- 3.4 **S** Remove vbcc workarounds only where a comment names the compiler
  bug; **O** reviews the diff. Gate: host tests pass; no behaviour change.
- 3.5 **S/O** Host unit tests of 7.3 (`fdd_test`, `hdd_test`, `mmc_test`,
  `config_test`, `swap_test`); goldens recorded from the 832 build. Gate:
  `make -C fw/ctrl_832/test` green; each test has a mutant check (a
  deliberately wrong byte fails it).

### Phase 4 -- co-simulation (the gate for floppy/HDD/CD)

- 4.1 **O** L3 bench `sim/spi_cdc/hostrv/` per 7.2: SD-card SPI slave model
  extended to a FAT16 image with multi-block reads/writes (CMD17/18/24/25),
  Amiga-side bus-functional model, Paula DMA model, Gayle traffic from
  `sim/gayle`, trace logger, margin monitors (7.1), `rv_throttle` and
  `+FAST_HW` stress, skew grid. Gate: cold boot to the main loop; ADF read
  of 10 tracks and write of 10 tracks compare equal; HDF 64-sector read and
  write compare equal; CD READ(10) of 32 sectors compares equal; CD-DA fill
  of both halves compares with the BIN; monitors report every 7.1 margin;
  teeth mutants fail.
- 4.2 **O** Differential: the same scenarios with `cpu_riscv=false` and the
  832 firmware produce the golden normalised SPI/host-bus traces; RV32
  traces `diff` empty modulo version/timing. Gate: documented in
  `findings/osd-riscv/phase4.md` with the margin table for both CPUs across
  the stress grid.
- 4.3 **S** Speed columns of 2.3 re-measured in L3 (end-to-end, both CPUs).
  Gate: RV32 ring fill <= 832; Dhrystone >= 1.5x; else back to 3.2.7/2.2.

### Phase 5 -- build integration and A/B

- 5.1 **S** `add_src` in all six `tools/vivado/build*.tcl`, `rebuild.tcl`,
  `host.qip`, top parameters; stages `stage_rv32a` and `stage_832ab`.
  Gate: both implement; hostcpu hierarchical utilisation recorded; clk_114
  WNS of `stage_rv32a` not worse than `stage_832ab` by more than 0.1 ns;
  `report_clocks` still shows `spi_sck`.
- 5.2 **O** Timing/fit recovery if needed (`rv_compressed` off, placement
  directives, retiming). Gate: WNS within the current -0.2 ns, no new
  failing endpoints under hostcpu.
- 5.3 **S** Card image with both firmware files; build notes. Gate: both
  bitstreams boot from one card. Merge `osd-riscv` -> `5.0-040-pipelined`.

### Phase 6 -- board parity and stress

Checklist in section 9 and the stress protocol 7.4, both bitstreams,
recorded in `findings/osd-riscv/parity.md` and `stress.md`. Gate: every row
"same" or an explained, accepted difference; stress runs clean on RV32 and
no worse than the 832.

### Phase 7 -- performance

- 7.1 **S** Board numbers: Dhrystone over UART, `cda_underruns` under the
  7.4 loads, the Cure/stutter scenario, menu redraw latency. Gate: table.
- 7.2 **O** If needed: `rv_prefetch` on, `rv_compressed` on, hostcache to
  2 K words (+1 BRAM); each a separate stage re-measured with 7.1 and
  re-run through L3. Gate: no parity regression; 7.1 improvement.

### Phase 8 -- peripherals and interrupts (each step: bench, build, board, merge)

- 8.0 **O** IRQ controller block (6.3), legacy bit 0 preserved; **S**
  firmware `irq_save/restore`, ISR skeleton. Gate: L2 tests per source;
  832 A/B unaffected; L3 differential still empty.
- 8.1 **O/S** P1 request IRQ + OSD reply ready flag (minimig output ports,
  cfide status, `HandleFpga`/`SPI_reply` on flags). Gate: L3 shows zero
  idle SPI polls and the `osd` test passing at GAP=2; board stress clean.
- 8.2 **S** P2 timer + P4 I2C routing; tick ISR owns timers/RTC/drive-sound
  cursor/HDMI check. Gate: L3 + board.
- 8.3 **S** P3 UART RX FIFO + debug console. Gate: L3 + serial test per the
  CP210x notes.
- 8.4 **O** P5 SPI master FIFO (only if 2.3/7.1 say the byte loop matters).
  Gate: L3 data compares + margin monitors with the new CS timing; ring
  fill time; board stress.
- 8.5 **O** P6 sector DMA (only after 8.4 measurements). Gate: as 8.4 plus
  the 202e077 class of race provably removed (the engine owns CS).
- 8.6 **O** P7 CD-DA ring DMA (only if underruns remain). Gate: L3 ring
  compare with the arbiter under HDF load; `cda_underruns` = 0 on the board
  under 7.4 item 4.
- 8.7 **S** Firmware yield points in long IDE/floppy transfers (independent
  of hardware; can be done any time after 6). Gate: L3 monitor for items
  6/7 improves; board stress.

### Phase 9 -- retire the 832

- 9.1 **S** Remove `cpu_riscv=false` branches, the EightThirtyTwo submodule,
  832 Makefiles, `test/emu`, `fw/dhrystone_832`, `fw/testbed` 832 bits,
  `sim/spi_cdc/host832` (keep its results), the `debug` generic; rename
  `fw/ctrl_832` -> `fw/ctrl`, `fw/ctrl_boot_832` -> `fw/ctrl_boot`; update
  host.qip, build scripts, `rebuild.tcl`, docs, memory notes. Gate: clean
  clone builds; no `832` outside `doc/`; tag; merge to `5.0-040-pipelined`.

Dependencies: 0 -> 1 -> (2, 3) -> 4 -> 5 -> 6 -> 7 -> 8.x -> 9. 2.3/2.4 need
only 1.1's wrapper; 3.2/3.5 can start on the gcc errors and host tests before
Phase 1 finishes; 8.7 needs only 6.

---

## 9. Hardware parity checklist (functional, both bitstreams, one card)

Boot and platform: cold boot (SD init, partition, firmware load), UART
banner and platform line, splash (logo, copper list, bootcustominit,
bootdiag); F1-F4 overrides; kickstart load incl. `kick13patch`, E0 mirror and
vector clear, CPU released only on success; failed-ROM path keeps the OSD;
reset/reboot from OSD and keyboard, CD music stops on reset; version strings
(About, `$VER`, build), CORE_CAPS decoding (IDE2, TEMP).

OSD and input: menu button and keyboard open/close; all pages (Welcome,
Minimig 1/2, Floppy, Settings, Chipset, Memory, Video 1-4, HDMI, Audio,
Drives, Harddisks, IDE port 2, Misc, About, Thanks to, Load/Save, Confirm/
Warning/Error, Debug with the `A` temperature marker, Synth RDB, Firmware
pages -- verify dead or working); file selector (scroll, long names, dirs,
filters); keyboard (and C64 path if fitted), joystick/autofire, mouse incl.
wheel, key queue and overflow, key level at boot.

Storage: floppy insert/eject df0-3, read, write (survives reload), drive
count/speed, drive sounds on/off/volume; HDD HDF/whole card/partitions 1-4,
synthesised RDB boots, read/write multiple, identify in HDToolBox, large
transfers during CD audio, `OpenHardfile` leaves the CD slot alone; CD-ROM
ISO on port 2 (identify, TOC, reads, AmigaOS 3.9 CD boots/installs), CUE+BIN
with audio tracks, CD-DA play/pause/resume/stop, track/position reporting,
volume, underrun counter, `AUDIOF_AMIGA` ownership, stop on reset; config
load/save slots, defaults, **832-written config files load identically**.

Video / audio / peripherals: ADV7511 init, re-init on HPD (INT edge), manual
re-init, scaler modes, video position, scanlines/CRT mask, 15 kHz flag,
PAL/NTSC; audio volume, drive sounds + CD audio sharing the ring, Amiga
passthrough; RTC read/write, time visible in AmigaOS; UART DebugMode at
115200 without overruns; temperature and platform bits; Akiko C2P demo, I2C
INT serviced once per edge.

Plus the stress protocol 7.4.

---

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| picorv32 throughput on the uncached fetch path below the 832's | CD underruns, slow menus | Measured before commitment (2.3); look-ahead + 1-line prefetch + C; Hazard3 + I$ as the wrapper-level fallback |
| Endianness miss in a shared structure | HDF does not boot, config corrupt | 5.2 audit; golden-byte tests; differential traces (4.2); BE on-disk config |
| Firmware-timing margins change with the CPU | Lost SPI writes, dropped words, OSD reply garbage | 7.1 inventory with monitors in L3; four-phase handshake; P1 ready flag; stress grid; teeth mutants |
| clk_114 timing worsens with +200 LUT at 98 % slices | Build fails timing | Phase 0 OOC first; FF-lighter core; `rv_compressed` as first knob; 5.2 |
| IRQ trampoline register clobber (non-standard picorv32 scheme) | Rare crashes in Akiko/keyboard handlers | 2.2 register-signature bench; tiny handler |
| libgcc with A-extension / wrong ABI | Illegal-instruction trap | objdump link check; `CATCH_ILLINSN` handler prints PC |
| gcc exposes C bugs vbcc hid | Behaviour differences | Minimal fixes, 832 binary byte-identical check, host tests, differential bench |
| Mixed-language instantiation on Quartus Lite / iverilog | Build or bench breaks on Intel | VHDL bridge instantiates a Verilog component; `host.qip` lists it; L1 is Verilog-only, L2/L3 xsim |
| Peripheral phase grows beyond budget | Fit regression | Per-step LUT gate against the previous stage; P6/P7 only on evidence |
| DMA coherency with hostcache (P7) | Stale audio/data | Arbiter in the bridge with invalidate-on-DMA-write or ring bypass; L3 ring compare under load |
| picorv32 archived | No upstream fixes | Vendored, pinned, formally verified; wrapper keeps Hazard3 a drop-in |
| SD model fidelity (write protocol, busy) | Bench passes, board fails | Model built from `mmc.c`'s expectations and the SD spec; token/busy delays swept; board stress 7.4 remains the last gate |

---

## 11. Open decisions for Paul (recommendation in bold)

1. Core: **picorv32 now, Hazard3 measured in Phase 0 and kept as a drop-in**;
   switch only if 2.3's rule is not met with the bridge-side improvements.
2. ISA: **RV32IMC if Phase 0 shows <= +150 LUT and no WNS loss**, else RV32IM.
3. Boot BRAM: **8 KB** (5.3 KB used); 16 KB reserve.
4. Config on-disk format: **keep big-endian (832 layout)** for shared cards.
5. `spicdc`: **already merged (49b1868) -- nothing to merge.** The port's
   baseline is that tree; the backlog's "board check before merging"
   (`report_clocks` shows `spi_sck`, HDF copy + checksum, ADF read/write)
   should be done on the 832 build **before** it becomes the A/B reference
   (fold it into stage `stage_832ab`'s acceptance), so a pre-existing
   problem is not attributed to the RISC-V port.
6. JTAG debug bridge: **drop for RISC-V**, keep the 832's until Phase 9.
7. Firmware tree: **single tree with `Makefile.rv32`, rename in Phase 9**.
8. Toolchain: **Ubuntu riscv64-unknown-elf-gcc 13.2 + picolibc headers,
   `-nostdlib` + libgcc**; alternative the `~/bin` rv32imac 14.2 with the
   no-atomics link check.
9. Peripheral order: **8.0 controller, then P1 (request IRQ + OSD reply
   flag), P2 timer, P4 I2C, P3 UART; P5 SPI FIFO only on 2.3/7.1 evidence;
   P6/P7 only on Phase 7/8 measurements.** Alternative: P5 first if the ring
   fill number in 2.3 is already poor on the 832.
