# OSD / host CPU: EightThirtyTwo -> RISC-V -- implementation plan

Status: plan only. Written 2026-10-16 around picorv32, revised the same day
after the core survey (`findings/osd-riscv/tiny-cores.md`) and Paul's
decisions (section 12): the core is **VexRiscv**. Branch `osd-riscv`, off
`5.0-040-pipelined` (the main branch for this board version; `osd-riscv`
merges back into it, never into superproject `main`; the AP68040 core
submodule is not touched by this work -- should it ever be, core changes land
on core `main` first, as usual). Baseline must be 49b1868 or later: it
contains the merged `spicdc` branch (SPI generated clock 7c33c98,
paula_floppy direct-mode race 202e077, `sim/spi_cdc`). No RTL, firmware or
build script has been changed yet. The executable task list for Phases 1-2 is
`doc/osd-riscv-exec-1.md`.

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
| Core | **VexRiscv** (SpinalHDL, MIT), **RV32IMC**, `IBusCachedPlugin` **4 KB I-cache** (direct-mapped, 32-byte lines), `DBusSimplePlugin` (uncached), standard M-mode CSRs (writable `mtvec`, `mepc`, `mcause`, `mtval`, `mie`/`mip`), `MulPlugin` (DSP) + iterative divider, `LightShifterPlugin`, full bypass. Debug builds add **`EmbeddedRiscvJtag`** (official RISC-V debug spec 0.13 DM + DTM, upstream OpenOCD). Pinned upstream commit `baf7dc8`; Scala config and the generated Verilog are committed. Fallback, only if VexRiscv becomes untenable: NEORV32 IMC + OCD, uncached. |
| Why | The only core that passes both hard gates (maintained; standard ISA and traps, decision 12.1) **and** is fast on our bus: Dhrystone at 3 wait states 0.563 DMIPS/MHz, ~64 DMIPS at 113.4 MHz, **7.1x the 832** on the same bus model (NEORV32 + 4 KB I$ 4.0x, Hazard3 IMC 4.0x but fails timing). Best timing margin of the fast candidates. Debuggable over the FPGA JTAG cable through a BSCANE2 tunnel. Costs: maintenance mode (no tagged releases; VexiiRiscv is the author's successor), JDK 17 + sbt to regenerate, two bus masters (I$ refill + dBus). `findings/osd-riscv/tiny-cores.md` sections 2-4. |
| LUT delta vs 832 | Measured (OOC, Vivado 2026.1): IMC + 4 KB I$ + DM **1,742 LUT / 1,639 FF / 1 RAMB36 + 3 RAMB18 / 4 DSP** vs the 832's 777 / 793 / 0 / 4 -> +965 LUT. The production build has no DM: IMC + 4 KB I$ est. ~1,270 LUT / ~800 FF (DM costs +309..473 LUT, +844 FF). Whole `hostcpu` est. ~1,500-1,650 LUT vs 912 today. Re-measured in Vivado 2023.2 in Phase 1. |
| Fmax at 113.4 MHz | WNS **+1.10 ns** at 8.815 ns OOC (IMC + 4 KB I$ + DM, registered I/O), est. 130 MHz. The risk is congestion at 98 % slices, not the core's own paths. |
| Endianness | **Byte-invariant memory, value-preserving I/O** (section 5): the CPU block swaps the four data lanes between the LE core and the BE ROM/SDRAM (byte selects stay address-indexed); the 16-bit hardware window is unswapped and every firmware I/O register moves to offset 0. FAT swaps become identity; Amiga/hardware-facing multi-byte structures get explicit BE helpers. VexRiscv has no misaligned access support: misaligned loads/stores **trap** (enabled at generation) so the port finds them. |
| Code size (measured) | Firmware RV32IMC ~85-95 KB vs 83,830 B. Boot ROM RV32IMC 3,636 B text + 650 B data/bss vs 4,333 B: **fits the 8 KB BRAM**. (gcc 14.2; re-measured with the pinned xPack 15.2 in Phase 2.) |
| Verification before any board test | Unchanged: L1 (iverilog, core + memory model), L2 (xsim, real bridge + cfide + hostcache), L3 co-simulation with the real minimig SPI slaves, the real boot ROM and firmware, an Amiga-side model, golden images, 832 reference traces, stress grid and margin monitors (section 7, Phase 4). Floppy, HDD and CD/ATAPI paths are gated by it. |
| Interrupts / peripherals | First port: the one existing cfide interrupt (vblank, I2C INT, Akiko request) on **machine external interrupt** (MEI); standard trap entry in the firmware's crt0 (`mtvec` writable, direct mode); `SetIntHandler()` ABI unchanged. Timer/software lines tied off. Phase 8: one pending/mask register block in cfide in front of MEI, `mtime` on MTI, individually benched offloads (section 6); their order is asked again after Phase 2 (decision 12.9). |
| Debug | Three generated core variants, chosen by the bridge generic `rv_debug`: **0 = none (default, production)**, 1 = DM + **BSCANE2 tunnel** over the Xilinx JTAG chain (Artix-only file, off by default), 2 = DM + **pin TAP** (vendor-neutral, four header pins). OpenOCD `riscv` target. Hardware bring-up after Phase 5, off the critical path. Upstream OpenOCD cannot drive the Platform Cable USB II on this machine (section 3.8). |
| Toolchain | **xPack `riscv-none-elf-gcc` 15.2.0-1** (GCC 15.2, binutils 2.45, newlib 4.5; multilibs `rv32imc/ilp32` and `rv32im/ilp32`), installed at `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`, `RV_GCC_DIR` override in every Makefile. Ubuntu `riscv64-unknown-elf-gcc` 13.2 is the fallback. |
| Firmware trees | New: `fw/ctrl_rv`, `fw/ctrl_boot_rv`, `fw/dhrystone_rv`. `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/dhrystone_832` stay untouched as the A/B reference until Phase 9. |
| Phases | 0 measure (**done**, tiny-cores.md) -> 1 VexRiscv vendoring + CPU block + bridge + L2 -> 2 toolchain + boot ROM + trap/IRQ + L1 + Dhrystone -> 3 firmware 1:1 + host tests -> 4 co-simulation (differential 832 vs RV, stress; I$ hit rate; 832 Dhrystone on the board) -> 5 build integration + A/B -> 6 board parity + stress -> 7 performance -> 8 peripherals/IRQ -> 9 retire the 832 |

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
- `rtl/soc/minimig_virtual_top.v` ~1329: `EightThirtyTwo_Bridge #(debug)
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
  `gen832.py`, `debug_bridge_stub.vhd`; needs `E832=` pointing at the main
  checkout's `EightThirtyTwo/RTL` because the worktree's submodule is not
  initialised); `sim/gayle` (two-port Gayle, `golden_a.txt` trace, mutant
  modes); `sim/osd_keyq` (OSD key queue, mutant mode); `sim/sdram_coherency`,
  `sim/cpu_cache_sdram` (SDRAM models); `sim/rom-hostcpu-test` (ROM entity
  only). No bench runs the host firmware. The SD model in `tb_spi_cdc.v`
  serves direct-mode data only (no command protocol).

### 1.2 Firmware (`fw/ctrl_832`, 14,407 lines after the cdrom merge)

- vbcc832 `-O=1343`, big-endian, linked at 0x2000, **stack in the boot BRAM**
  (top 0x2000, `setstack()`); 832OSDAD.bin 83,830 B, bss end 0x1DF48;
  `AUDIO_BUFFER` at host 0x70000 (2 x 32 KB) caps code+data+bss+heap at
  448 KB.
- Boot ROM: 4,333 B, bss end 0x1354, stack 0x240, `prg_start=0x2000`,
  `OSDNAME="832OSDADBIN"`; `romgen` -> VHDL table between
  `rom_prologue/epilogue.vhd` (file byte i in BE lane i). Its `putchar`
  does not wait for TX ready, and need not: cfide holds a UART write until
  the transmitter is free. There is no TX-ready bit, and cfide never acks a
  UART read (it would hang the CPU), so no firmware may read `0xFFFFFFF0`.
- Interrupts: lib832 `start.S` dispatches through `_InterruptVector` at byte
  13 of the ROM, patched by `SetIntHandler()`; `inthandler()` reads
  `GetInterrupts()` (which clears the cfide line), runs `akiko_inthandler()`
  and `c64keys_inthandler()`. Everything else polls from `main()`:
  `drivesounds_fill`, `HandleRTC`, `CD_AudioPoll`, `HandleFpga` (6-byte SPI
  status poll), `HandleUI`, the 250 ms ADV7511 INT edge check.
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

## 2. Core survey and selection (decided)

### 2.1 Survey

Done in `findings/osd-riscv/tiny-cores.md` (2026-10-16) against Paul's hard
gates (decision 12.1): (1) actively maintained, not archived; (2) standard
ISA built by upstream GCC/LLVM, standard M-mode traps. Gates first, then OOC
size/timing on `xc7a100tfgg676-2` at 8.815 ns and Dhrystone on a
cycle-accurate bus model with wait states.

- Passed both gates: VexRiscv, NEORV32, Hazard3, Ibex, SERV/QERV.
- Rejected by gate: **picorv32** (archived Sep 2026; custom IRQ scheme),
  FazyRV, DarkRISCV, Minimax, FemtoRV, rvx (RV32I only), Kronos, biriscv,
  tinyriscv, RudolV, NERV, e203, SCR1, Potato, uRV, CV32E40X. CV32E40P, VeeR
  EL2, VexiiRiscv pass but are multi-k LUT.
- Passed but unusable here: Hazard3 IMC misses 113 MHz in every variant
  (best -0.57 ns) and is fetch-bound on our bus; Ibex is SystemVerilog and
  -2.2 ns; SERV/QERV are slower than the 832 on our bus (0.32x / 0.88x).

The original survey of this plan (picorv32 primary, Hazard3 runner-up) is
superseded by gate 1.

### 2.2 Selection reasoning

Throughput on our path, not Fmax, separates the candidates. Firmware runs
from SDRAM through hostcache and a bridge that costs ~4-5 clk_114 per hit,
so an uncached core is fetch-bound: going from 0 to 3 wait states costs
2.5-4x (Hazard3 loses its whole IPC lead, 1.13 -> 0.315 DMIPS/MHz). A 4 KB
I-cache takes VexRiscv back to 0.563 DMIPS/MHz at 3 wait states, 1.9x its
uncached figure; NEORV32's multi-cycle core only gains 0.227 -> 0.318
because it is core-bound. A 1 KB I$ is worse than no cache (line thrash with
8-word refills), so **4 KB is the minimum** and the real-firmware hit rate
is checked in Phase 4 before the size is frozen.

VexRiscv IMC + 4 KB I$ + DM is the smallest gate-passing core that is fast
here (1,742 LUT vs NEORV32's 2,198 with the same cache, +1.10 vs +0.76 ns),
and its `EmbeddedRiscvJtag` can tunnel through BSCANE2 so the debugger needs
no extra pins. Its maintenance risk is bounded by vendoring: the Scala
configuration and the generated plain Verilog-2001 (no vendor primitives;
builds on Quartus) are committed with the upstream commit hash, so the
design never depends on upstream changing; regeneration (JDK 17 + sbt) is
needed only when the CPU configuration changes. VexiiRiscv (same author, same
bus and debug ideas) is the migration path if VexRiscv bit-rots. NEORV32
(plain VHDL, 13 releases in 12 months) remains the fallback if the JDK/sbt
toolchain becomes a problem or throughput stops mattering after the Phase 8
offloads; it needs 4 spare pins for JTAG.

Production configuration (`rtl/host/vexriscv/GenOsd.scala`, generated by
Phase 1): the measured `GenTiny` IC4K configuration plus three changes, each
re-measured OOC in Phase 1:

- `CsrPluginConfig.small(0x20)` with `mtvecAccess = READ_WRITE`: the
  firmware owns its trap vector in SDRAM (no ROM ABI, and the firmware stack
  may overwrite the boot ROM code, section 3.4).
- `DecoderSimplePlugin(catchIllegalInstruction = true)` and
  `DBusSimplePlugin(catchAddressMisaligned = true)`: illegal opcodes (a wrong
  `-march`, A-extension code in a library) and misaligned accesses (the 832
  tolerated them; at least one exists in the boot ROM, section 5.2) trap
  with `mepc`/`mtval` instead of silently misbehaving.
- Debug variants as in section 3.8.

If the Phase 1 OOC gate fails because of these additions, the catch flags go
first (recorded), `mtvec` stays writable.

### 2.3 Measurements (Phase 0, done)

From `findings/osd-riscv/tiny-cores.md` (OOC, Vivado 2026.1, core hierarchy
only, registered-I/O wrapper; Dhrystone 2.1, 100 runs, gcc 13.2 `-O2`, one
shared memory, each access 1 + WS cycles, no SDRAM misses modelled):

| Candidate | LUT | FF | RAMB36/18 | DSP | WNS @8.815 | DMIPS/MHz WS=0 | DMIPS/MHz WS=3 | DMIPS @113.4, WS=3 | x 832 (WS=3) |
|---|---|---|---|---|---|---|---|---|---|
| 832 (design config) | 777 | 793 | 0/0 | 4 | +2.368 | 0.113 | 0.080 | 9.0 | 1.00 |
| VexRiscv IMC (IBusSimple) | 1,243 | 757 | 0/2 | 4 | +1.306 | 0.760 | 0.298 | 33.8 | 3.7 |
| VexRiscv IMC + DM | 1,716 | 1,603 | 0/2 | 4 | +1.263 | 0.760 | 0.298 | 33.8 | 3.7 |
| **VexRiscv IMC + 4 KB I$ + DM** | **1,742** | **1,639** | **1/3** | 4 | **+1.104** | 0.786 | **0.563** | **63.9** | **7.1** |
| NEORV32 IMC + OCD (fallback) | 1,866 | 1,293 | 1/0 | 4 | +1.172 | 0.389 | 0.227 | 25.7 | 2.85 |
| NEORV32 IMC + OCD + 4 KB I$ | 2,198 | 1,468 | 1/5 | 4 | +0.755 | 0.391 | 0.318 | 36.1 | 4.0 |
| Hazard3 IMC (best) | 2,244 | 623 | 0/0 | 3 | -0.566 | 1.126 | 0.315 | 35.8 | 4.0 |

Still open from Phase 0, moved:

- The 832's absolute figure (0.113 DMIPS/MHz, vbcc `-O=1343`) passes
  Dhrystone's own checks but is low: **confirm once on the board** with
  `fw/dhrystone_832` before quoting absolute numbers (Phase 4.6). The
  ratios between the RISC-V rows do not depend on it.
- **I$ hit rate on the real firmware** (FAT, floppy/HDD, CD paths have a
  larger hot set than Dhrystone): from an L3 trace (Phase 4.5) before the
  4 KB size is frozen; 8 KB is a generation-time change (+1 RAMB36).
- Vivado 2023.2 cross-check of the chosen variants and the whole `hostcpu`
  OOC (Phase 1).
- SPI byte loop ns/byte and 32 KB ring-fill ms, both CPUs, end to end in L3
  (Phase 4.4); they decide whether P5 (SPI FIFO) is needed.

---

## 3. Architecture of the port

### 3.1 Memory map (unchanged)

| Host address | Device | Notes |
|---|---|---|
| 0x000000-0x001FFF | boot BRAM, 8 KB, R/W | reset vector 0x0, boot trap entry 0x20 (`mtvec` reset value); after boot: the firmware's stack (top 0x2000) |
| 0x002000-0x7FFFFF | SDRAM via hostcache | firmware at 0x2000 (`prg_start`, entry `_start`), `AUDIO_BUFFER` 0x70000, Amiga memory at `addr ^ 0x680000` |
| bit 23 set | cfide registers, 16-bit | value-preserving, offset 0 in each 16-byte window; the firmware uses 0xFFFFFFx0 addresses, reachable as `x0`-relative 12-bit offsets (`sb a0, -32(zero)` = SPI data) |

Every instruction fetch goes through the I-cache, including the boot ROM;
nothing executes from the hw window. Data accesses are never cached in the
CPU (only in hostcache, as today).

### 3.2 CPU block `rtl/host/rv_hostcpu.v` (new, Verilog)

One Verilog module puts the VexRiscv behind the 832's bus contract, so the
VHDL bridge's state machine serves either CPU unchanged:

- **Core instance** by parameter `DEBUG` (0/1/2) -> `VexOsd` / `VexOsd_DMT`
  (+ `rv_bscane2`, Artix only) / `VexOsd_DMJ` (section 3.8).
- **Bus contract** (identical to `eightthirtytwo_cpu`): `req` with
  `addr[31:2]`, `q`, `sel[3:0]` (bit i = byte at A+i), `wr`, all stable
  until the cycle in which `ack=1`; `d` is valid in the `ack` cycle; in the
  cycle after `ack`, `req` is 0 or a new request. One transaction in flight.
- **iBus** (`IBusCachedPlugin` cmd/rsp): one command per 32-byte line
  (`iBus_cmd_payload_size = 5`); the block issues the 8 word reads of the
  line in order and returns 8 `iBus_rsp_valid` beats. A line refill is
  atomic.
- **dBus** (`DBusSimplePlugin`): `dBus_cmd_ready` only when the block is
  idle; a write is complete when it is acked (posted from the core's view,
  but the next access waits); a read returns one `dBus_rsp_ready` beat.
- **Arbiter**: at transaction boundaries dBus wins over iBus (the pipeline
  is stalled on it). Arbitration happens only when idle, so ordering between
  the two masters is program order as seen by the memory.
- **Lanes**: for `addr[23]=0` (ROM, SDRAM) the four data bytes are swapped
  in both directions (`q = {w[7:0], w[15:8], w[23:16], w[31:24]}`, read data
  likewise), `sel` passes through; for `addr[23]=1` (hw) no swap. Zero LUTs
  beyond the mux on `addr[23]`. `DBusSimplePlugin` replicates byte and
  halfword store data across lanes.
- **Interrupts**: `irq_ext` (cfide `interrupt`) registered once ->
  `externalInterrupt`; `timerInterrupt`, `softwareInterrupt` <- 0 until
  Phase 8.
- **Resets**: `reset_n` (async, active low, synchronously released inside)
  resets the core and, as `debugReset`, the debug module; the DM's
  `ndmreset` additionally resets the core only.
- **`EXTRA_WS`** (bench-only parameter, default 0 = no logic): idle cycles
  inserted before every request -- the "slower CPU" knob of the stress mode
  (section 7.2), replacing the planned core clock enable (VexRiscv has none
  without regeneration).

### 3.3 Bridge (`rtl/host/832_bridge.vhd`, rewritten in place)

Entity name and existing ports of `EightThirtyTwo_Bridge` stay (top
instance, XDC cell names `hw_req_reg`/`wr_reg`, Quartus project untouched).

1. New generics `cpu_riscv : boolean := false`, `rv_debug : natural := 0`,
   `rv_extra_ws : natural := 0`; new ports with defaults `rv_jtag_tck`,
   `rv_jtag_tms`, `rv_jtag_tdi : in std_logic := '0'`, `rv_jtag_tdo : out
   std_logic` (used only with `rv_debug = 2`).
2. `gen832:` the 832, its debug bridge and `OSDBoot_832_ROM`; `genrv:`
   `rv_hostcpu` and `OSDBoot_rv_ROM`. Both instantiated through component
   declarations so a bench or build compiles only the CPU it elaborates.
3. One state machine for both CPUs (`waiting`, `rom`, `ram`, `hw`,
   `hw_release`): the CPU block already presents BE lanes, so the ROM,
   hostcache and hw paths are the 832's.
4. **Four-phase hw handshake.** cfide's `ack` is a clk_28 register that
   stays high until a clk_28 edge sees `req` low; today the bridge leaves the
   `hw` state the moment it sees `ack`, so a next hw access within ~4
   clk_114 cycles would be acknowledged by the stale `ack` and a write could
   be missed on the clk_28 side. New state `hw_release`: on `hw_ack='1'`
   latch the data, drop `hw_req`, ack the CPU and wait in `hw_release` until
   `hw_ack='0'`. Unconditional (both CPUs), so A/B compares like with like;
   it closes inventory item 1 (section 7.1).
5. **Arbiter hook:** a later DMA requester (Phase 8, P7) joins this state
   machine in front of hostcache (CPU > DMA). Not built now; the states are
   written so adding a requester does not restructure them.

### 3.4 I-cache coherency rules

- The I$ is flushed at reset and by `fence.i` (the `IBusCachedPlugin`
  decodes it; the flush walks the 128 lines).
- Any code written through dBus is followed by `fence.i` before it runs:
  the boot ROM's `_boot()` after `LoadFile()` (needed even though a cold
  boot starts with an empty I$, because a soft re-entry of the boot ROM after
  an `ndmreset` or a future firmware reload would not); the debugger does its
  own (OpenOCD issues `fence.i` on resume after memory writes).
- Refills go through hostcache, which is write-through with invalidate on
  write hit, so a refill after a code write sees the new data.
- The firmware sets `mtvec` to its own entry in SDRAM in crt0, before
  interrupts are enabled and before the stack (top 0x2000, in the boot BRAM)
  can overwrite boot ROM code; nothing executes from the boot BRAM after
  `_boot()`.
- DMA (Phase 8) never writes code; the I$ needs no snooping.

### 3.5 Boot ROM entity

`OSDBoot_rv_ROM.vhd` from `fw/ctrl_boot_rv` by the unchanged romgen flow
(file byte i in BE lane i; the CPU block's lane swap hands the core LE
instruction words). `maxAddrBitBRAM => 12` (8 KB) stays; 16 KB (`=> 13`,
`prg_start = 0x4000`, +1 RAMB36) is a one-line reserve, used only if the
RV32IM build needs it (decision 12.3).

### 3.6 Top level and A/B

`minimig_virtual_top.v` parameters `hostcpu_riscv = 0`, `hostcpu_rvdebug =
0` -> bridge generics (Phase 5). Stages `stage_rv*` and `stage_832ab` from
the same tree. Each boot ROM loads its own file: `OSDNAME="832OSDADBIN"` /
**`"RV32OSDABIN"`** (8.3 name `RV32OSDA.BIN`; the earlier `RV32OSDADBIN` had
12 characters), so one SD card serves both bitstreams and the A/B is a
reprogram. Config files are not shared (decision 12.4: LE layout + converter
tool).

### 3.7 Firmware trees and toolchain (decisions 12.7, 12.8)

- `fw/ctrl_boot_rv/`: copy of `fw/ctrl_boot_832` sources + `crt0.S`,
  `boot.ld`, `Makefile`; builds `OSDBoot_rv.bin` and `OSDBoot_rv_ROM.vhd`
  (committed with the sources).
- `fw/ctrl_rv/`: copy of `fw/ctrl_832` at a recorded commit (Phase 3) plus
  `arch/` (`crt0.S`, `trap.S`, `irq.c/.h`, `csr.h`, `firmware.ld`) created
  in Phase 2 so the trap/IRQ code is benched before the firmware exists.
  Builds `RV32OSDA.BIN`. Its host tests live in `fw/ctrl_rv/test`.
- `fw/dhrystone_rv/`: L1 and board builds.
- `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/dhrystone_832`: untouched until
  Phase 9 (read-only use by benches is fine). A bug fix that must land in
  both trees during the port is two commits that name each other.
- Toolchain: xPack `riscv-none-elf-gcc` 15.2.0-1 (released 2025-10-23,
  the newest xPack release on 2026-10-16), linux-x64 tarball sha256
  `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758`,
  unpacked to `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`; shared make
  fragment `tools/riscv/toolchain.mk` with `RV_GCC_DIR ?=` and
  `RV_PREFIX ?= riscv-none-elf-`; fallback `RV_GCC_DIR=/usr
  RV_PREFIX=riscv64-unknown-elf-` (Ubuntu 13.2 + picolibc). Flags
  `-march=rv32imc_zicsr_zifencei -mabi=ilp32 -Os -ffunction-sections
  -fdata-sections -fno-builtin -funsigned-char -ffreestanding -nostdlib
  -Wl,--gc-sections` + `-lgcc` for the firmware and boot ROM (they bring
  their own `small_printf.c`; lib832's `string.S` becomes plain C);
  test programs may link newlib-nano. Link check: no A-extension opcodes
  (`objdump -d | grep -E '\b(lr|sc|amo[a-z]+)\.w\b'` empty). Clang/LLVM
  building the tree is a Phase 3 check, not a requirement.

### 3.8 Debug (decision 12.6)

The debug transport is a **generation-time** choice in SpinalHDL, so three
Verilog variants are generated and committed; the bridge generic `rv_debug`
picks one:

| `rv_debug` | Module | Transport | Vendor | Cost |
|---|---|---|---|---|
| 0 (default) | `VexOsd` | none | neutral | -- |
| 1 | `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v` | DM, DTM tunnelled through `BSCANE2` USER4 on the FPGA's own JTAG chain (`withTunneling = true, withTap = false`; `jtagInstruction` port + a separate JTAG clock) | Artix-only file, listed only in the Vivado build scripts, never in `host.qip` | ~+470 LUT, +844 FF |
| 2 | `VexOsd_DMJ` | DM + its own TAP (IDCODE 0x10002FFF, IR 5 bits) on four spare header pins | neutral | same |

OpenOCD: upstream `riscv` target. Pins: `jtag newtap riscv cpu -irlen 5
-expected-id 0x10002FFF; target create riscv.cpu.0 riscv -chain-position
riscv.cpu`. Tunnel: `source [find cpld/xilinx-xc7.cfg]; target create cpu.0
riscv -chain-position xc7.tap; riscv use_bscan_tunnel 6 1` (VexRiscv README).
Configs in `tools/openocd/`. **Cable:** the board's programming cable is a
Xilinx Platform Cable USB II (03fd:0008); the installed OpenOCD 0.12.0 has no
driver for it (`adapter list`: ftdi, usb_blaster, jlink, cmsis-dap, ...). The
tunnel therefore needs an FTDI-based JTAG cable on the same header (e.g. a
Digilent HS2/HS3, which Vivado also drives) -- Paul's call before Phase 5.4.
The pin variant needs any OpenOCD adapter plus four free FPGA pins.
Production images use `rv_debug = 0`. Debug is not on the critical path:
variants generated and OOC-measured in Phase 1, a DM smoke test in L1
(pin TAP, JTAG BFM) in Phase 2, hardware bring-up in Phase 5.4.

### 3.9 Tests and harnesses

- **L1** `sim/rv_l1/` (iverilog, Verilog only): `rv_hostcpu` + a BE memory
  model with per-region latency (`+ROMWS`, `+WS`) + sim MMIO (char out,
  time stamp, done, a cfide-like interrupt register). Runs directed CPU-block
  tests, the trap/IRQ tests, the firmware-unit programs of
  `fw/ctrl_832/test/emu` (`cue_emu`, `cdaudio_emu`, `atapi_emu`, compiled by
  gcc against the 832 tree's sources until `fw/ctrl_rv` exists, then via
  `FWDIR=`), Dhrystone, the DM smoke test. Seconds per run; usable while
  Vivado holds the machine. Replaces the 832e harness for the RISC-V side.
- **L2** `sim/host_bridge/` (xsim 2023.2, mixed): the real bridge + cfide +
  hostcache + SDRAM model (+ SD card model from Phase 2) with test ROMs.
- `fw/ctrl_rv/test` (gcc, host-native) grows in Phase 3.

### 3.10 VexRiscv vendoring

`rtl/host/vexriscv/`: `GenOsd.scala` (the configuration), `regen.sh`
(clones upstream VexRiscv at the pinned commit into a cache outside the repo,
`VEX_SRC ?= ~/opt/vexriscv-src`, copies `GenOsd.scala` into
`src/main/scala/vexriscv/demo/`, runs `sbt -java-home
/usr/lib/jvm/java-17-openjdk-amd64 -batch "runMain vexriscv.demo.GenOsd"`,
copies the three `.v` files back), `VERSION` (upstream commit
`baf7dc82f855eddaf5b0a20a6802c526f127e38a`, SpinalHDL 1.13.0, sbt
1.6.0 per upstream `project/build.properties`), `README.md` (why the files
are generated, JDK 23 fails with "bad constant pool index", ~1.3 GB of
`~/.sbt`/`~/.cache/coursier`, ~2 min per run, port lists), and the generated
`VexOsd.v`, `VexOsd_DMT.v`, `VexOsd_DMJ.v` (~4.5 k / ~8 k / ~8 k lines).
Regeneration must be byte-reproducible apart from the generator header.

---

## 4. Sizing

Logic (measured OOC, core only, Vivado 2026.1): IMC + 4 KB I$ + DM 1,742
LUT / 22 LUTRAM / 1,639 FF / 1 RAMB36 + 3 RAMB18 / 4 DSP; IMC uncached
without DM 1,243 / 757; the 4 KB I$ costs +26 LUT and +1 RAMB36 (it replaces
`IBusSimple`); DM costs +309..473 LUT and +844 FF. Production (`rv_debug =
0`) est. ~1,270 LUT / ~800 FF / 1 RAMB36 + 2 RAMB18 / 4 DSP. Adding the CPU
block (~80-120 LUT: refill counter, arbiter, lane mux), the bridge and
hostcache: `hostcpu` est. **~1,500-1,650 LUT** vs 912 today, **+600-750
LUT** (+1.2 % of the device), FF roughly unchanged, BRAM +1.5 tiles
(88.5 -> ~90 of 135). Debug builds add ~470 LUT / 844 FF more and are not
expected to fit timing as easily at 98 % slices -- they are lab images.

Measured (2026-10-16, Task 8, Vivado 2023.2, whole `hostcpu` OOC at 8.815 ns, `findings/osd-riscv/ooc-2023.2.md`): the 832 reference row gives 871 LUT / 974 FF / 3 RAMB36 / 4 DSP, WNS +2.25 ns (stage figure 912 / 944, -4.5 %, so the flow is trusted); the RISC-V `hostcpu` (`rv_debug = 0`) gives **1,532 LUT / 1,252 FF / 4 RAMB36 + 3 RAMB18 (5.5 tiles) / 4 DSP, WNS +1.68 ns**, i.e. **+661 LUT, +278 FF, +2.5 BRAM tiles** vs the 832 (core 1,400 LUT, CPU block 50, hostcache 65, boot ROM glue 18); the debug build `rv_debug = 2` is 2,018 LUT / 1,977 FF, WNS +0.87 ns. Worst paths are the core's register-file BRAM address inputs; the `dBus_cmd_valid`-dependent paths in `rv_hostcpu` have +3.3 ns (output-register CE) and +3.9 ns slack and are not critical. The remaining risk is clk_114 congestion at 98 % slices, which an OOC run cannot show; Phase 5.2 is the recovery step.

Code size (measured 2026-10-16, riscv32 gcc 14.2 `-Os`): 26 of 31 firmware
units compile unchanged -- RV32IMC 48,105 B text + 2,921 B data, RV32IM
58,435 B text; the five that gcc rejects (`fat.c`, `hdd.c`, `menu.c`,
`drivesounds.c`, `small_printf.c`: prototype mismatches, `{` in a macro
argument, implicit `puts`) are ~45 % of the lines, so the whole image is
~85-95 KB RV32IMC / ~105-115 KB RV32IM against 83,830 B (832 incl. lib832);
bss ~33 KB. Boot ROM RV32IMC 3,636 B text + 22 + 628 (RV32IM 4,576) against
4,333 B. Re-measured with xPack 15.2 in Phase 2/3. Stack: the firmware's
stack shares the 8 KB boot BRAM with dead boot ROM code; gcc's RISC-V frames
differ from vbcc's, so Phase 3 measures the stack high-water mark (fill
pattern) in L3 and on the board.

---

## 5. Endianness -- analysis and strategy

### 5.1 Choice

The 832 is big-endian and shares SDRAM with a big-endian 68k: byte A+0 is
bits 31:24 (`bytesel(0)` -> `hostWR[31:24]` -> upper byte of the lower
16-bit SDRAM word). Options:

- **Byte-invariant (chosen):** swap data lanes in the CPU block. Every byte
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
279-280. Implement `le16/le32/be16/be32()` keyed on `__BYTE_ORDER__`;
rename call sites once.

Explicit big-endian handling to add:
1. `hdd.c` RDB/PartitionBlock synthesis (86-160): every long -> `be32()`;
   the longs checksum sums BE longs.
2. `hdd.c` `IdentifyDevice()` `unsigned short id[256]` sent byte-wise by
   `WriteIDEData` -> store with `be16()` so the byte stream is unchanged.
3. `boot.c:200` default copper list -> `be16()`.
4. `drivesounds.c:231-233` manual byte swap (BE CPU producing LE samples) ->
   delete on LE; keep `c*0x10001`.
5. `config.c`: the config file is `sizeof(configTYPE)` = 212 raw bytes with
   `unsigned long version` and other multi-byte members. **Decision 12.4:**
   the RISC-V firmware reads/writes its native LE layout; a host tool
   (`fw/ctrl_rv/tools/cfgconv`) converts 832 (BE) config files; a file with
   the wrong byte order is detected by its `version` field and rejected with
   an OSD message instead of being loaded.
6. `firmware.h` `UPGRADE`/`CheckFirmware/WriteFirmware`: verify dead; else as 5.
7. Struct overlays on disk data to re-check: `fat.c:137 MasterBootRecord`,
   `hdd.c:90/131/524 RigidDiskBlock/PartitionBlock`, `config.c:275`.
8. **Misaligned multi-byte accesses** (new with VexRiscv; they trap): e.g.
   `minfat.c:136-138` reads `pe->startlba` through a `struct PartitionEntry *`
   at MBR offset 454 (2 mod 4) -- read it byte-wise (`le32` from bytes); the
   same overlay in `fat.c`. The trap handler names the PC; L1/L3 runs find
   the rest.
9. Anything found by the differential bench (Phase 4) -- the golden SPI
   byte traces catch what the grep did not.

### 5.3 Hardware window

Value-preserving 16-bit registers at offset 0: `HW_SPI(x)` +3/+7/+11 ->
+0/+4/+8 (DATA 0xFFFFFFE0, CS 0xFFFFFFE4, SPEED 0xFFFFFFE8), `RS232`
0xFFFFFFF0, `AUDIO` 0x..B0, `TIMER` 0xFFFFFFD0, `PLATFORM` 0xFFFFFFC0,
`RTCBASE` 0x..70, `REG_AKIKO_ADDR/DATA` 0/4, `REG_KEYBOARD_WORD0..3`
0/4/8/0xC, `REG_KEYBOARD_OUT` 0; the 32-bit ones are already at 0.
`DBusSimplePlugin` replicates `SB/SH` data across lanes, which would hide a
forgotten write offset but not a read -- do not rely on it. Boot ROM
`spi.h`/`uart.h` get the same edit. cfide does not change in this phase.

---

## 6. Interrupts and peripherals

### 6.1 Today

One level line from cfide (vblank | I2C INT | Akiko request edge; enable bit
0 at 0x..A0; cleared by any access). `inthandler()` runs the Akiko and C64
keyboard state machines; everything else polls. cfide's enable bit is the
only mask.

### 6.2 First port (polling 1:1)

- cfide `interrupt` -> `rv_hostcpu.irq_ext` -> VexRiscv `externalInterrupt`
  (level; `mip.MEIP` follows it). `timerInterrupt`/`softwareInterrupt` = 0.
- `fw/ctrl_rv/arch/crt0.S` (entry at 0x2000): `sp = 0x2000`, set `gp`,
  clear `.bss`, `mtvec = trap_entry` (direct mode, 4-byte aligned, in
  SDRAM), run `.init_array` (gcc `__attribute__((constructor(prio)))` with
  the 832 `__constructor(n.name)` order), `mie.MEIE = 1`, `mstatus.MIE = 1`,
  `main()`.
- `trap.S` `trap_entry`: save the 16 caller-saved registers (`ra`, `t0-t6`,
  `a0-a7`) on the current stack (64 bytes, 16-byte aligned), call
  `rv_trap(mcause, mepc, mtval)`, restore, `mret`. No nesting (`mstatus.MIE`
  is cleared by hardware on entry).
- `rv_trap()`: `mcause = 0x8000000B` -> call `_InterruptVector` (a RAM
  function pointer; `SetIntHandler(h)` writes `HW_INTERRUPT = 0` then the
  pointer -- same meaning as the 832's byte-13 patch, no ROM ABI). The
  handler clears the cfide source itself (`inthandler()` reads
  `GetInterrupts()` first, as today); a still-pending level re-enters after
  `mret`, as today. Any other cause is an exception: print `mcause`/`mepc`/
  `mtval` over the UART (always, not only in DebugMode -- it is fatal),
  show an OSD error if possible, halt.
- `EnableInterrupts()/DisableInterrupts()/GetInterrupts()` keep cfide's
  semantics (the enable bit at 0x..A0), so the firmware's call sites are
  unchanged. `irq_save()/irq_restore()` (`csrrci mstatus, 8` / restore) are
  added for Phase 8 critical sections.
- The boot ROM has its own trap entry at 0x20 (exceptions only: print and
  `ErrorCode`), never enables interrupts.
- Nothing else changes: same SPI polling, same main loop. This is the
  reference point for every later offload.

### 6.3 Interrupt controller (Phase 8.0, implemented)

Done on branch `osd-riscv` (RTL `7f0a672`, `75af45c`; firmware API `59f3552`,
`d492f6e`; spec `doc/osd-riscv-exec-2.md`). VexRiscv has three standard
lines: MEI, MTI, MSI. The sources go through one small controller in
`rtl/host/cfide.vhd` on MEI (not through `ExternalInterruptArrayPlugin`:
custom CSRs, regeneration). It runs on `clk_28` like the rest of cfide and
sits beside the legacy INTERRUPT register at `0xFFFFFFA0`, which is
unchanged (bit 0 = enable on write, any access clears its flag), so the 832
firmware is unaffected. Four 16-bit registers in the cfide hw window
`0xFFFFFF30..3C` (`addr(23)='1'`, `addr(7 downto 4) = X"3"`, register
selected by `addr(3 downto 2)`):

```
0xFFFFFF30  IRQ_PENDING  R: PENDING and MASK; clears exactly the EDGE-mode bits it returns,
                            once per access. W: no effect
0xFFFFFF34  IRQ_MASK     R/W, reset 0
0xFFFFFF38  IRQ_RAW      R: synchronised source levels, no side effect. W: no effect
0xFFFFFF3C  IRQ_MODE     R/W, reset 0; per bit 0 = EDGE, 1 = LEVEL
```

| Bit | Source | Notes |
|---|---|---|
| 0 | `vbl_int` | vertical blank, pulse: EDGE |
| 1 | `i2c_int` | I2C master transfer event (`i2c_master_mmio` `r_interrupt`); cleared only by an access to `0xFFFFFFA0`: LEVEL, and the handler must access `0xFFFFFFA0` |
| 2 | `amiga_req` | Akiko request, pulse: EDGE |
| 3 | `i2c_ext_int` | the ADV7511's INT pin (also I2C status bit `0x400`): LEVEL |
| 4..15 | `irq_src(15 downto 4)` | spare cfide input port, defaulted to 0 (a top that has no source leaves it open); P1 (IDE, floppy) and later |

Every bit is the same logic (decision 12.9): a 2-FF synchroniser into
`clk_28`, then EDGE (MODE bit 0): a rising edge of the synchronised level
sets the bit, and an IRQ_PENDING read that returns it clears it; an edge in
the cycle of that clear wins ("set wins"); an event of a masked bit stays
pending until it is unmasked and read. LEVEL (MODE bit 1): the bit is the
synchronised level itself, a read does not clear it, it drops with the
source. Switching the mode: EDGE to LEVEL discards an unread event; LEVEL to
EDGE starts clear and needs a new rising edge. The CPU line is the legacy
flag OR `(PENDING and MASK) /= 0`; MASK and MODE reset to 0, so with MASK = 0
the behaviour is the pre-8.0 one. The timer (P2) drives MTI directly from an
`mtime >= mtimecmp` compare, not through this block. No PLIC: sixteen
sources in software bit order (bit 0 first) are enough.

Firmware rules (`fw/ctrl_rv/arch/irq.h`, API in its README):

- Level sources (ADV7511 INT bit 3, IDE requests, the I2C flag bit 1) go in
  LEVEL mode with `IrqSetMode(bit, 1)` before `IrqEnable(bit)`: the interrupt
  stays asserted until the device is serviced, so no `IrqRaw()` re-check is
  needed. Pulse sources (vblank, Akiko) stay EDGE, the reset mode.
- The synchroniser delays a LEVEL bit's fall by up to 3 `clk_28` cycles after
  the device drops its line: a handler that returns at once may be called one
  extra time and must tolerate that.
- A debugger reading IRQ_PENDING consumes pending EDGE bits.
- API: `IrqSetHandler(bit, h)`, `IrqSetMode(bit, level)`, `IrqEnable(bit)`
  (installs the dispatcher), `IrqDisable(bit)`, `IrqRaw()`, `IrqInstall()`
  (idempotent; switches the legacy register off through `SetIntHandler`). The
  dispatcher reads IRQ_PENDING, calls the handler of each set bit, bit 0
  first, and repeats until a read returns 0. A pending bit with no handler
  has its MASK bit cleared (no livelock); a spurious legacy flag is turned
  off. `SetIntHandler(h)` with a non-dispatcher handler clears MASK. After
  `IrqInstall()` do not use `EnableInterrupts()`.
- P1 sources connect to `irq_src` bits 4..15 and must be pulses of at least
  one `clk_28` cycle or levels.

Measured cost (OOC synthesis of cfide alone, XC7A100T): +61 LUT / +113 FF,
no BRAM or DSP (48 synchroniser/prev, 16 pend, 16 mask, 16 mode, 16 read
latch, 1 request-seen), against the ~30 LUT of the earlier sketch.

Open board items: the ADV7511 INT polarity is inferred active-high (the part
is set up without a polarity write, and `i2c_master_mmio` and the 832
firmware use it that way), not measured; the interrupt OR path is untimed in
a full build; the top leaves `irq_src` open (all 0).

Firmware structure from 8.0 on: ISRs only move bytes and set flags (timer
tick, UART RX into a ring, "request pending" flags, audio half flag); the
main loop does all SPI/SD/FAT work; critical sections = `irq_save()/
irq_restore()` around shared variables; fdd/hdd/atapi/cdrom code stays
non-reentrant and main-loop only; one SPI bus, one owner, **never SPI from
an ISR**. Clock domain for all new peripherals: `clk_114` behind the cfide
hw window (like the SPI master today); minimig-facing request lines cross
from clk_28/clk7_en with 2-FF synchronisers or the existing req/ack style.
Budget for the whole of Phase 8: <= 1.5 k LUT, <= 2 BRAM tiles, each step
measured against the previous stage.

### 6.4 Candidate peripherals (each a separate Phase 8 step)

| # | Peripheral | Removes from firmware / timing it fixes | IRQ source(s) | Register sketch (cfide window) | LUT / BRAM est. | Risk | Priority (proposal) |
|---|---|---|---|---|---|---|---|
| P1 | **Request IRQ + OSD reply ready flag** | The 6-byte `HandleFpga()` SPI status poll per loop (~100 us) and the `SPI_reply()` pause: `userio_osd` exposes "reply byte loaded" and "key queue non-empty"; `paula_floppy` exposes "track request pending" (CMD_RDTRK/WRTRK), `gayle_port` "command written" / "FIFO threshold"; cfide shows them on `irq_src` bits 4..15 (6.3) and in a `HOST_REQ` status word | request lines (4-5 bits) | `0x..B4 HOST_REQ` R: {osd_reply_rdy, keyq, fdd_req, ide0_cmd, ide1_cmd, ide_fifo_rdy} | ~120 LUT, 0 BRAM | low (status only; minimig-side changes are output ports) | **1** -- biggest latency win per LUT; also fixes inventory item 2 in hardware |
| P2 | Timer (`mtime`/`mtimecmp`, 64-bit at clk_114, on MTI, plus 100 Hz tick) | `GetTimer/CheckTimer` 16-bit wrap handling, RTC/drive-sound/HDMI 250 ms bookkeeping moves to the tick ISR | MTI, tick | `0x..D4 MTIME_LO/HI`, `0x..DC MTIMECMP_LO/HI` (TIMER at D0 stays) | ~100 LUT | low | **1** |
| P3 | UART RX + 16-byte TX/RX FIFOs | A debug console (today TX-only, blocking per byte) | RX non-empty, TX empty | `0x..F0 DATA`, `0x..F4 STATUS` | ~120 LUT (LUTRAM) | low | 2 |
| P4 | I2C INT routing | The 250 ms edge-poll of the ADV7511 INT | existing `i2c_int` as its own bit | none new | ~10 LUT | none | 1 (free with 8.0) |
| P5 | SPI master with 64-byte TX/RX FIFOs and byte counter | The two hw round trips per byte: the CPU queues "n bytes, CS pattern", reads the RX FIFO; SPI becomes wire-bound (~3.5 MB/s at 28 MHz) instead of CPU-bound; CS deassert timing becomes a hardware constant (inventory items 2-4) | FIFO half / done | `0x..E0` compatible byte register stays; `0x..EC CTRL/COUNT`, `0x..E8 FIFO` | ~300-400 LUT + LUTRAM (or 1 BRAM18) | medium: all five slaves share CS semantics; must keep the single-byte path for the 832 A/B | 2 -- only if Phase 4.4/7.1 show the byte loop matters |
| P6 | Sector DMA engine SD <-> minimig FIFO (generalised direct mode) | The CPU from the read data path SD -> paula/gayle; the engine owns CS, count and both directions, FPGA -> SD for HDF/ADF writes included. Removes the CS-timing race class structurally | done / error | `0x..C4 DMA_CMD` {dir, slave, blocks}, `0x..C8 DMA_STAT` | ~300-500 LUT | medium-high: touches `paula_floppy`/`gayle_port` FIFO ports; the SD write protocol (token, busy) must be in hardware | 3 -- after P5 is measured |
| P7 | CD-DA ring refill DMA + half-empty IRQ | The 32 KB copy per 186 ms and its SPI loop; firmware supplies an LBA run list per half | half flip, list empty | `0x..C0 CDA_LIST`, `CDA_CTL` | ~500-700 LUT + 1 BRAM; needs the bridge arbiter (3.3.5) | high: SDRAM host port is lowest priority; hostcache coherency (DMA writes must invalidate or bypass); `scale()` volume moves to hardware or is dropped | 4 -- only if P5+P1 still leave underruns |
| P8 | I2C engine | already exists (`i2c_master_mmio`) | -- | -- | 0 | -- | n/a |

Estimated total if P1-P5 are built: ~700 LUT, 0-1 BRAM; within budget.
P6/P7 are decided on Phase 7/8 measurements, not up front. The order is
asked again after Phase 2 with the dependency map at the end of
`doc/osd-riscv-exec-1.md` (decision 12.9).

---

## 7. Verification strategy (simulation before any board test)

Paul's requirement: floppy, hard-disk and CD/ATAPI paths are proven in
simulation + verification before a board test. The backlog's "SPI clock
constraints and a floppy direct-mode race" is the model case: `paula_floppy`
dropped the last direct-mode word if chip select went away within ~30
cycles; the 832 took ~45 -- correctness rested on firmware timing. 202e077
fixed it in RTL and `sim/spi_cdc` swept the host access gap 2..64 to prove
it. A different CPU changes every such margin, so each one is listed,
measured and guarded. VexRiscv is ~7x the 832 on our bus: every margin that
rests on instruction spacing shrinks.

### 7.1 Inventory of firmware-timing-dependent handshakes on the host side

| # | Handshake | Where | Dependency / margin today | Status | How it is checked |
|---|---|---|---|---|---|
| 1 | hw register write hold / stale `ack` between back-to-back hw accesses | bridge <-> cfide (clk_114 <-> clk_28) | an access needs >= 1 clk_28 period of `req`; a second access within ~4 clk_114 of the previous `ack` can be falsely acknowledged. 832 spacing happened to exceed it | fixed by the four-phase handshake (3.3.4) | `sim/host_bridge` back-to-back test + mutant; `tb_spi_cdc` GAP=2 rows |
| 2 | OSD reply byte load | `userio_osd` loads the reply per SPI transfer on the clk7_en grid | needs >= 40 clk_114 between host accesses; below that `OSD_CMD_VERSION` fails 3/3 in every skew corner; firmware 174322f adds a pause (`SPI_reply()`: 4 x `SPIN`) | **open**: firmware pause only; margin shrinks with a faster CPU | `tb_spi_cdc` `osd` test with the RV host (hostrv); margin monitor "cycles between accesses during OSD reads" >= 40; hardware fix = P1's reply-ready flag (poll it instead of counting) |
| 3 | Direct-mode SD -> paula/gayle, CS release after the 4096th bit | `mmc.c` `EnableDMode; SPI(0xFF); RDSPI; DisableDMode` | was >= ~30 cycles after the last bit, 832 ~45 | fixed in RTL (202e077: word latched on its last sck edge) | `tb_spi_cdc` `direct` GAP 2..64 and `host832`/`hostrv` real-CPU runs; monitor measures last-sck-to-CS-release; mutant (202e077 reverted) must fail |
| 4 | Command byte then CS release on the minimig slaves (`DisableFpga/DisableOsd` right after the last byte) | `userio_osd_spi` `rx`/`cmd` through clk7_en synchronisers; `paula_floppy`, `gayle` command decode | unknown; the GAP sweep covers it for `wr/rd/osd` | measured, not guaranteed by design | same bench; add a monitor "last sck edge to `_scs` rise" per slave with a per-slave minimum derived from the RTL (2 clk7_en = ~8 clk_28) |
| 5 | SPI data register write while the shifter is busy | cfide `SD_busy` | the write is held, not dropped (support state machine stalls the CPU) | by construction | assertion in `sim/host_bridge`: no SPI write accepted while `SD_busy` |
| 6 | Floppy track **read**: host feeds MFM words into the paula FIFO while Paula DMA drains | `fdd.c` `ReadTrack`/`SectorToFpga`, `CMD_RDTRK` status | FIFO must not run empty while `dsklen` DMA is active; drain rate ~1 word per 32 us (250 kbit/s MFM), fill rate = SPI; large slack, but a stalled host (CD refill, menu) can starve it | depends on main-loop latency | co-sim: ADF track reads with a monitor "FIFO empty && DMA active" = failure; stress mode with the CPU throttled finds the latency bound |
| 7 | Floppy track **write**: host drains the write FIFO while the Amiga writes | `fdd.c` `FindSync/GetHeader/GetData`, `CMD_WRTRK` | FIFO depth gives the slack; host must keep up for a whole track (~200 ms) | depends on main-loop latency | co-sim: ADF track write with "FIFO full && Amiga writing" monitor; written ADF compared with the golden image |
| 8 | IDE PIO flow control | `hdd.c` `while(!(GetFPGAStatus() & CMD_IDECMD))`, `CMD_IDEDAT`; gayle FIFOs | status-driven, no timing margin; latency only affects throughput | by construction | co-sim HDF multi-sector read/write, data compare; `sim/gayle` golden trace unchanged |
| 9 | ATAPI phases / CD READ | `cdrom.c` flags, `CD_TIMEOUT` 10 s | status-driven; 10 s host timeout (timer-based) | by construction | co-sim CD READ(10/12) of ISO sectors, data compare |
| 10 | SD card protocol waits | `mmc.c`: CMD41 1000 ms (timer), data-token wait `timeout++ >= 1000000` (count), write-busy loop | count-based waits expire ~7x sooner on VexRiscv (still well above the token time, but no longer a 1 s guarantee) | low | SD model with programmable token delay up to 250 ms; count loops converted to `CheckTimer` in Phase 3 (one-line changes) |
| 11 | `SPIN` / explicit delays | `hardware.c:236` (OSD reply, item 2); commented-out `SPIN`s in `fdd.c` (historic ADF-write workaround); `audio_clear` waits one TIMER tick | only item 2 is live | -- | grep gate in Phase 3: no new count-based delays |
| 12 | RTC (`pcf2123`) CS high time between transfers | `rtc.c`, `scs(7)` | the chip's minimum CS-inactive time is covered by the firmware's instruction spacing today | depends on CPU speed | add the datasheet minimum as a monitor in the co-sim (RTC model) or insert an explicit timer-based guard; low risk, listed for completeness |
| 13 | Akiko C2P service latency | `amiga_req` held until the host answers | the 68k bus waits; latency = ISR latency; correctness independent of speed | fine | co-sim: an Amiga-side Akiko write; measure latency both CPUs |
| 14 | Kickstart upload complete before CPU release | SDRAM write acks precede `OsdDoReset` | ordering by the bridge (one transaction in flight; dBus waits for the previous write's ack) | by construction | differential trace: last SDRAM write before the reset SPI command |
| 15 | OSD key queue | `osd_keyq` | queued since 174322f; no margin | fine | `sim/osd_keyq` unchanged |

Rule for the port: items 1-4 and 10 are closed by hardware or by replacing
counts with status/timer; 6 and 7 are bounded by measured main-loop latency
in the stress mode and later by P1; nothing new may depend on instruction
timing (reviewed in Phase 3's grep gate).

### 7.2 Bench levels

- **L1** `sim/rv_l1/` (iverilog): `rv_hostcpu` + BE memory model with
  per-region latency + sim MMIO (section 3.9). Directed CPU-block tests
  (lanes, refills, `fence.i`, bus-contract checker), trap/IRQ tests,
  firmware-unit programs, Dhrystone, DM smoke test. Abstract latency model;
  the real bridge/hostcache timing is L2's job.
- **L2** `sim/host_bridge/` (xsim, mixed): bridge + cfide + hostcache +
  SDRAM model (+ SD card model), directed tests (lanes, hw offsets,
  back-to-back hw, SPI busy, IRQ entry/return with the real cfide line),
  boot ROM end-to-end boot from a FAT16 card image, Dhrystone on the real
  memory path; the 832 regression is `sim/spi_cdc/host832/run.sh` with the
  rewritten bridge.
- **L3 co-simulation** `sim/spi_cdc/hostrv/` (sibling of `host832/`, xsim):
  the real `paula_floppy` + `paula_floppy_fifo`, `gayle` + `gayle_port` +
  `gayle_fifo`, `userio_osd` + `userio_osd_spi`, `cfide`, `hostcache`, the
  bridge, the **RISC-V core running the real boot ROM and firmware** (from
  the ROM VHDL and the L2 SD-card model serving a FAT16 image that holds
  `RV32OSDA.BIN`, `832OSDAD.BIN`, config slots, a kickstart, an ADF, an HDF
  with the synthesised-RDB case, an ISO and a CUE/BIN), plus an
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
  version string and inter-access timing. Reuse: `tb_spi_cdc.v`'s skew grid
  and `GAP` statistics, `host832/run.sh`'s file list and xsim flow,
  `sim/gayle`'s Gayle model and golden format, `sim/osd_keyq`'s key
  injector. An I$ miss counter in the trace gives the real-firmware hit rate
  (Phase 4.5).
- **Timing-stress mode** in L3: `rv_extra_ws` (0, 4, 16, 64 idle cycles per
  bus access -- slower CPU: the latency-bound items 6/7/10) and a
  `+FAST_HW` plusarg that shortens the SD model's token delay and the SDRAM
  model's latency to the minimum (faster CPU-visible timing: items 2/4) plus
  the `(SCKDLY, C28DLY)` skew grid; **margin monitors** print the minimum
  observed value of every item in 7.1 per run and compare it with the RTL
  requirement, so margins are measured, not just not-failing.
- **Teeth**: mutant runs that must fail -- 202e077 reverted (item 3), the
  four-phase handshake removed (item 1), a 1-byte-short MFM sector (data
  compare), `fence.i` removed from the L1 self-modifying test, `sim/gayle`'s
  existing mutants.

### 7.3 Host-native unit tests to add (`fw/ctrl_rv/test`)

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
- `config_test.c`: LE config round trip; `cfgconv` converts every BE config
  file in the repo/SD image and the result compares field by field
  (decision 12.4); `swap_test.c`: the le/be helpers on both byte orders.
All run under ASan/UBSan like the existing ones; `make -C fw/ctrl_rv/test`
is the single entry point.

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
5. Each run on the 832 and the RV bitstream from the same card; results in
   `findings/osd-riscv/stress.md` side by side.

---

## 8. Phases, tasks, models, gates

Model tags: **S** = Sonnet (mechanical / well specified), **O** = Opus (RTL,
timing, verification, debug, review). Every task ends with its gate; the
orchestrator commits (committed tree builds; `version.h` stays unstaged).
Branch rule: all of this on `osd-riscv`, merged into `5.0-040-pipelined` at
the end of Phase 5 (A/B-capable tree), again after Phase 6/7, and per step
in Phase 8; never into superproject `main`; core submodule untouched.
Phases 1 and 2 are broken down into executable tasks in
`doc/osd-riscv-exec-1.md` (task numbers there: T1..T15).

### Phase 0 -- measure (done)

`findings/osd-riscv/tiny-cores.md`: gates, OOC size/timing of 20+ core
configurations, Dhrystone on the bus model with 0 and 3 wait states,
VexRiscv vs NEORV32 head to head; decision recorded in 12.1. Moved out of
Phase 0: the 832 Dhrystone board confirmation (4.6), the real-firmware I$
hit rate (4.5), the Vivado 2023.2 cross-check (1.3), the SPI byte loop and
ring-fill columns (4.4).

### Phase 1 -- VexRiscv vendoring, CPU block, bridge, L2

- 1.1 **O** Vendoring `rtl/host/vexriscv/` per 3.10: `GenOsd.scala`,
  `regen.sh`, three generated variants, README, VERSION (exec T2). Gate:
  regeneration byte-reproducible; iverilog parses all three; no vendor
  primitive in the generated files.
- 1.2 **O** `rtl/host/rv_hostcpu.v` + L1 bench skeleton with directed tests
  (lanes, refill, `fence.i`, bus-contract checker) (exec T4). Gate: all
  pass, also with `EXTRA_WS=3`.
- 1.3 **S** OOC in Vivado 2023.2: core variants (exec T3) and the whole
  `hostcpu` (exec T8). Gate: VexOsd WNS >= +1.0 ns; `hostcpu` (`rv_debug=0`)
  <= 1,750 LUT and WNS >= +0.5 ns; XDC cells `hostcpu/hw_req_reg`,
  `hostcpu/wr_reg` exist.
- 1.4 **O** Bridge rewrite per 3.3 (exec T6). Gate: `host832/run.sh` all
  configurations PASS with the new bridge (832 regression including the
  handshake); `cpu_riscv=true` elaborates.
- 1.5 **O** L2 bench `sim/host_bridge/` (exec T7): lanes vs the BE SDRAM
  model, hw offsets, back-to-back hw, SPI-busy assertion. Gate: all pass;
  the handshake mutant fails.

### Phase 2 -- toolchain, boot ROM, trap/IRQ, L1, Dhrystone

- 2.1 **S** Toolchain pin `tools/riscv/` (exec T1, done first because L1/L2
  test programs need it). Gate: multilib check for rv32imc and rv32im on
  xPack 15.2 (and the Ubuntu fallback reported).
- 2.2 **S** L1 firmware-unit programs (exec T5). Gate: three `PASS`.
- 2.3 **S** SD card SPI model + FAT16 card image tool (exec T9). Gate: model
  unit bench reads a file's sectors byte-exact.
- 2.4 **S** Boot ROM port `fw/ctrl_boot_rv` (exec T10). Gate: host
  `minfat` test finds and loads a file from a card image; size <= 6 KB;
  no A-extension opcodes.
- 2.5 **O** Trap/IRQ entry `fw/ctrl_rv/arch` (exec T11). Gate: L1 register
  signature + exception tests; L2 IRQ via the real cfide line.
- 2.6 **O** End-to-end boot in L2 (exec T12). Gate: boot ROM loads
  `RV32OSDA.BIN` from the card image, `fence.i`, jumps; test firmware
  reports "FW OK" and its IRQ count.
- 2.7 **S** `fw/dhrystone_rv` (exec T13). Gate: L1 WS=3 Dhrystone >= 5x the
  832's bench figure; L2 number recorded.
- 2.8 **O** Debug: DM smoke test in L1, `rv_bscane2.v`, OpenOCD configs
  (exec T14). Gate: L1 halts/reads/resumes the hart through the pin TAP.
  Not blocking Phase 3.
- 2.9 Dependency map of phases 3-9 to Paul (exec T15); his phase-8 order
  goes into 12.9.

### Phase 3 -- firmware 1:1 and host tests (`fw/ctrl_rv`)

- 3.1 **S** Create `fw/ctrl_rv` as a copy of `fw/ctrl_832` at a recorded
  commit (+ `arch/` from Phase 2), `Makefile` (xPack, `RV_GCC_DIR`), entry
  via `arch/crt0.S`, `__constructor` -> `__attribute__((constructor(prio)))`
  with the same order, `MM_VERSTRING` `-RV` suffix. Gate: all units compile;
  map shows `_end` < 0x70000.
- 3.2 **S** gcc fixes (`ShowError`, `FindDirectoryByCluster`, `{` in macro
  args, implicit `puts`), I/O offsets (5.3), le/be helpers (5.2 "flips"),
  `mmc.c` count loops -> `CheckTimer` (7.1 item 10), `SPI()`/`EnableFpga()`
  overridable under `-DHOSTTEST`. Grep gate: no `SPIN`-style count delays
  added.
- 3.3 **O** Endianness items 1-8 of 5.2. Gate: host tests pass; golden-byte
  tests for RDB/identify/copper (goldens dumped from the 832 build via the
  UART hexdump or the 832e harness) pass.
- 3.4 **S** Config file LE + `fw/ctrl_rv/tools/cfgconv` (decision 12.4).
  Gate: round-trip test on every config file in the repo/SD image,
  field-by-field compare; wrong-order file rejected.
- 3.5 **S** Remove vbcc workarounds only where a comment names the compiler
  bug; **O** reviews the diff. Gate: host tests pass; no behaviour change.
- 3.6 **S/O** Host unit tests of 7.3; goldens recorded from the 832 build.
  Gate: `make -C fw/ctrl_rv/test` green; each test has a mutant check.
- 3.7 **S** Stack high-water mark: fill pattern below 0x2000, report in
  DebugMode; Clang build check. Gate: numbers recorded.

### Phase 4 -- co-simulation (the gate for floppy/HDD/CD)

- 4.1 **O** L3 bench `sim/spi_cdc/hostrv/` per 7.2: SD model with
  multi-block reads/writes (CMD17/18/24/25), Amiga-side bus-functional
  model, Paula DMA model, Gayle traffic from `sim/gayle`, trace logger,
  margin monitors (7.1), `rv_extra_ws` and `+FAST_HW` stress, skew grid.
  Gate: cold boot to the main loop; ADF read of 10 tracks and write of 10
  tracks compare equal; HDF 64-sector read and write compare equal; CD
  READ(10) of 32 sectors compares equal; CD-DA fill of both halves compares
  with the BIN; monitors report every 7.1 margin; teeth mutants fail.
- 4.2 **O** Differential: the same scenarios with `cpu_riscv=false` and the
  832 firmware produce the golden normalised SPI/host-bus traces; RV traces
  `diff` empty modulo version/timing. Gate: documented in
  `findings/osd-riscv/phase4.md` with the margin table for both CPUs across
  the stress grid.
- 4.3 **S** No misaligned-access or illegal-instruction trap in any L3
  scenario (trap log empty). Gate: log.
- 4.4 **S** Speed in L3, end to end, both CPUs: SPI byte loop ns/byte,
  32 KB ring fill ms, menu redraw. Gate: RV ring fill <= 832.
- 4.5 **S** I$ hit rate from the L3 trace per scenario (miss counter in
  `rv_hostcpu`, sim only). Gate: recorded; if the main-loop hot set misses
  > 5 %, evaluate 8 KB (regeneration + OOC) before Phase 5.
- 4.6 **S** 832 Dhrystone on the board (`fw/dhrystone_832`, current
  bitstream, UART). Gate: number recorded next to the bench's 0.113
  DMIPS/MHz.

### Phase 5 -- build integration and A/B

- 5.1 **S** `add_src` in all six `tools/vivado/build*.tcl`, `rebuild.tcl`,
  `host.qip` (VexOsd.v + rv_hostcpu.v, never `rv_bscane2.v`), top
  parameters; stages `stage_rv` and `stage_832ab`. Gate: both implement;
  hostcpu hierarchical utilisation recorded; clk_114 WNS of `stage_rv` not
  worse than `stage_832ab` by more than 0.1 ns; `report_clocks` still shows
  `spi_sck`.
- 5.2 **O** Timing/fit recovery if needed (placement directives, retiming,
  I$ `twoCycleRam`, a pipeline register in the CPU block). Gate: WNS within
  the current -0.2 ns, no new failing endpoints under hostcpu.
- 5.3 **S** Card image with both firmware files; build notes. The spicdc
  board check (decision 12.5) is part of the 832 leg's acceptance:
  `report_clocks` shows `spi_sck`, HDF copy + checksum, ADF read/write.
  Gate: both bitstreams boot from one card. Merge `osd-riscv` ->
  `5.0-040-pipelined`.
- 5.4 **O** Debug bring-up (not blocking): a lab stage with `rv_debug=1`
  (or 2), OpenOCD + GDB attach, halt, breakpoint in `main`, `load` +
  `fence.i`. Needs an OpenOCD-supported cable (3.8). Gate: session log in
  `findings/osd-riscv/debug.md`.

### Phase 6 -- board parity and stress

Checklist in section 9 and the stress protocol 7.4, both bitstreams,
recorded in `findings/osd-riscv/parity.md` and `stress.md`. Gate: every row
"same" or an explained, accepted difference; stress runs clean on RV and
no worse than the 832.

### Phase 7 -- performance

- 7.1 **S** Board numbers: Dhrystone over UART, `cda_underruns` under the
  7.4 loads, the Cure/stutter scenario, menu redraw latency. Gate: table.
- 7.2 **O** If needed, each a separate stage re-measured with 7.1 and re-run
  through L3: line refills as hostcache bursts (one 16-byte hostcache line
  per two I$ beats without a round trip each), 8 KB I$, hostcache to 2 K
  words (+1 BRAM). Gate: no parity regression; 7.1 improvement.

### Phase 8 -- peripherals and interrupts (each step: bench, build, board, merge)

Order to be confirmed by Paul (decision 12.9) with the dependency map in
`doc/osd-riscv-exec-1.md` T15. Proposal:

- 8.0 **done** on branch `osd-riscv` (RTL `7f0a672`, `75af45c`; firmware
  `59f3552`, `d492f6e`; design in 6.3): IRQ pending/mask/raw/mode block on
  MEI, legacy `0xFFFFFFA0` preserved; firmware `irq_save/restore`, dispatcher
  API. L2 tests `t_irqctl`, `t_irqapi`. P1 sources attach to `irq_src` bits
  4..15 as pulses >= 1 `clk_28` cycle or levels. Still to do: board test, and
  L3 differential / 832 A/B once those exist.
- 8.1 **O/S** P1 request IRQ + OSD reply ready flag. Gate: L3 shows zero
  idle SPI polls and the `osd` test passing at GAP=2; board stress clean.
- 8.2 **S** P2 timer on MTI + P4 I2C routing; tick ISR owns timers/RTC/
  drive-sound cursor/HDMI check. Gate: L3 + board.
- 8.3 **S** P3 UART RX FIFO + debug console. Gate: L3 + serial test per the
  CP210x notes.
- 8.4 **O** P5 SPI master FIFO (only if 4.4/7.1 say the byte loop matters).
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
  `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/dhrystone_832`, `test/emu`,
  `fw/testbed` 832 bits, `sim/spi_cdc/host832` (keep its results), the
  `debug` generic; rename `fw/ctrl_rv` -> `fw/ctrl`, `fw/ctrl_boot_rv` ->
  `fw/ctrl_boot`; update host.qip, build scripts, `rebuild.tcl`, docs,
  memory notes. Gate: clean clone builds; no `832` outside `doc/`; tag;
  merge to `5.0-040-pipelined`.

Dependencies: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8.x -> 9, with: 2.1
before 1.2 (test programs); 3.2/3.6 can start on the gcc errors and host
tests before Phase 2 finishes; 5.4 needs only 5.1 and a cable; 8.7 needs
only 6. Full map in `doc/osd-riscv-exec-1.md` T15.

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
load/save slots, defaults, **832-written config files load identically after
`cfgconv`** and an unconverted one is rejected cleanly.

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
| VexRiscv in maintenance mode (no releases; author's work moved to VexiiRiscv) | No upstream fixes; a bug we hit is ours to fix | Pinned commit, generated Verilog committed, configuration small and conventional (plugins used by LiteX/Efinix for years); L1/L2/L3 benches; VexiiRiscv as migration path; NEORV32 IMC + OCD as the drop-in fallback behind the same `rv_hostcpu` contract (single XBUS master, simpler) |
| Regeneration needs JDK 17 + sbt (JDK 23 fails; ~1.3 GB caches; network for the first run) | Cannot change the CPU config when the toolchain rots | Only needed for config changes; `regen.sh` pins JDK path, commit and SpinalHDL version; README records the failure modes; the generated `.v` files are the source of truth for builds |
| Real firmware's hot set larger than 4 KB | I$ thrash, throughput far below the Dhrystone 7.1x | Phase 4.5 hit rate from the L3 trace before freezing; 8 KB is a regeneration; Phase 7 line bursts from hostcache |
| I-cache coherency (code written through dBus) | Stale instructions after firmware load or a debugger write | Rules in 3.4; `fence.i` in `_boot()`; L1 self-modifying-code test with a mutant |
| Misaligned accesses the 832 tolerated | Wrong FAT/MBR fields | `catchAddressMisaligned` traps with PC; audit item 5.2.8; L3 trap log must be empty (4.3) |
| clk_114 timing worsens with ~+700 LUT at 98 % slices | Build fails timing | Phase 1 OOC in 2023.2 with the whole hostcpu; production without DM; 5.2 recovery (I$ two-cycle RAM, CPU block pipeline register) |
| Two bus masters behind a one-transaction bridge | Starvation or ordering bugs | Arbitration only at transaction boundaries, dBus first, atomic line refills; bus-contract checker in L1; L2 back-to-back tests |
| Endianness miss in a shared structure | HDF does not boot, config corrupt | 5.2 audit; golden-byte tests; differential traces (4.2); config converter + rejection of the wrong byte order |
| Firmware-timing margins change with the CPU (~7x faster) | Lost SPI writes, dropped words, OSD reply garbage | 7.1 inventory with monitors in L3; four-phase handshake; P1 ready flag; stress grid incl. `rv_extra_ws`; teeth mutants |
| Firmware stack in the boot BRAM overgrows (gcc frames differ) | Corrupted data/stack at 0x0-0x1FFF | `mtvec` in SDRAM so ROM code may be overwritten; high-water mark measured (3.7); 16 KB BRAM reserve |
| Debug cable: OpenOCD 0.12 has no driver for the Platform Cable USB II | No GDB on the board | Production does not need it; FTDI cable (Digilent HS2/HS3) for the tunnel, or the pin variant with any adapter; decided before 5.4 |
| Debug DM FF cost (+844 FF) at 98 % slices | Lab images fail timing | Debug only in lab stages; the pin/tunnel choice does not change the core |
| libgcc/newlib with A or C instructions in an IM build | Illegal-instruction trap | Multilib check (rv32im directory) in the toolchain task; objdump link check; `catchIllegalInstruction` handler prints PC |
| gcc exposes C bugs vbcc hid | Behaviour differences | Minimal fixes, host tests, differential bench |
| Mixed-language instantiation on Quartus Lite / iverilog | Build or bench breaks on Intel | VHDL bridge instantiates Verilog through component declarations; `host.qip` lists `VexOsd.v` + `rv_hostcpu.v`; L1 is Verilog-only, L2/L3 xsim |
| Peripheral phase grows beyond budget | Fit regression | Per-step LUT gate against the previous stage; P6/P7 only on evidence |
| DMA coherency with hostcache (P7) | Stale audio/data | Arbiter in the bridge with invalidate-on-DMA-write or ring bypass; L3 ring compare under load |
| SD model fidelity (write protocol, busy) | Bench passes, board fails | Model built from `mmc.c`'s expectations and the SD spec; token/busy delays swept; board stress 7.4 remains the last gate |

---

## 11. Open decisions for Paul (history)

*Answered 2026-10-16 -- see section 12, which overrides this list. The
original recommendations were: picorv32 now with Hazard3 as drop-in; RV32IMC
if cheap; 8 KB boot BRAM; keep the BE config format; spicdc check on the 832
build first; drop JTAG debug for RISC-V; single firmware tree with
`Makefile.rv32`; Ubuntu gcc 13.2; peripheral order 8.0, P1, P2, P4, P3, then
P5-P7 on evidence. Of these, only the 8 KB boot BRAM survives unchanged.*

## 12. Decisions (Paul, 2026-10-16)

1. **Core: VexRiscv RV32IMC + 4 KB I-cache + `EmbeddedRiscvJtag`** (standard
   RISC-V debug spec, upstream OpenOCD), standard M-mode IRQs. Chosen after
   the hard gates -- (a) actively maintained (not archived; commits or
   releases in ~12 months), (b) standard ISA + standard machine-mode
   trap/IRQ CSRs, supported by upstream GCC and LLVM without patches -- and
   the measurements in `findings/osd-riscv/tiny-cores.md`: 1,742 LUT, WNS
   +1.10 ns at 8.815 ns, 7.1x the 832's Dhrystone at 3 wait states.
   picorv32 fails (a). Fallback: NEORV32 IMC + OCD, uncached, only if
   VexRiscv becomes untenable.
2. **ISA: RV32IMC preferred, RV32IM acceptable.** Paul (revised the same
   day): memory is not the limit, but take compressed instructions if
   leaving them out means toolchain/library trouble. With VexRiscv, C costs
   nothing in LUTs (-25 LUT, within noise) and ~0.9 ns of timing, and it
   cuts fetch traffic (+12 % Dhrystone at 3 wait states). RV32IMC it is; an
   RV32IM core would be another generated variant.
3. **Boot ROM: 8 KB preferred**, 16 KB only if the RV32IM boot ROM needs it.
4. **Config file: drop the big-endian format.** The RISC-V firmware
   reads/writes a native little-endian layout; a host command-line tool
   converts old (832, big-endian) config files to the new format. Task in
   Phase 3 (3.4, Sonnet; gate: round-trip test on every config file in the
   repo/SD image, field-by-field compare).
5. **spicdc board check: Paul takes the risk.** No separate check before the
   port; it happens on the 832 leg of the A/B build (Phase 5.3):
   `report_clocks` shows `spi_sck`, HDF copy + checksum, ADF read/write,
   as part of the acceptance of the 832 A/B reference bitstream.
6. **Debug: needed** ("debugging firmware is likely in our future"):
   RISC-V External Debug spec (DM + JTAG DTM; OpenOCD + GDB). Resolved with
   the core: the transport is a generation-time choice, so three variants
   are committed (3.8): none (default), BSCANE2 tunnel through the Xilinx
   JTAG chain (Artix-only file, off by default per the vendor-neutral rule),
   dedicated pins (vendor-neutral). Production images leave the DM out.
7. **Firmware: new RISC-V dedicated trees** `fw/ctrl_rv`, `fw/ctrl_boot_rv`
   (and `fw/dhrystone_rv`), not a `Makefile.rv32` inside `fw/ctrl_832`. The
   832 trees stay untouched as the A/B reference until Phase 9.
8. **Toolchain: the most up-to-date one** with an rv32imc and rv32im
   multilib: **xPack `riscv-none-elf-gcc` 15.2.0-1** (GCC 15.2.0, binutils
   2.45, newlib 4.5.0; the newest xPack release on 2026-10-16), pinned by
   version and sha256, installed outside the repo at
   `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`, `RV_GCC_DIR` override in the
   Makefiles. `~/bin/riscv32-unknown-elf-gcc` 14.2 (CH32V badge build,
   rv32imac only) is not used; Ubuntu `riscv64-unknown-elf-gcc` 13.2
   (rv32im/rv32imac multilibs + picolibc 1.8.6) is the fallback. Clang/LLVM
   building the tree is checked in Phase 3 (gate 1b).
9. **Peripheral order:** deferred -- Paul wants it again once the
   dependencies between stages are worked out (re-ask after Phase 2, with
   the dependency map in `doc/osd-riscv-exec-1.md` T15).
   Paul 2026-10-17: implement 8.0 now; uniform edge-detected sources; read
   clears the returned bits; per-source EDGE/LEVEL MODE register. Done (6.3).
   The rest of the Phase 8 order (P1..P7) stays open for Paul.
