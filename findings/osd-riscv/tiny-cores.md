# Tiny RISC-V cores as an EightThirtyTwo replacement — survey, gates, measurements

Date: 2026-10-16. Part: xc7a100tfgg676-2, host clock clk_114 = 8.815 ns (113.44 MHz).
Tool: Vivado 2026.1 (non-project, OOC, synth + opt + place + phys_opt + route). Not cross-checked with 2023.2.
Companion to `doc/osd-riscv-plan.md` §2. Not committed.

## TL;DR

* **Recommendation: VexRiscv, RV32IMC with a 4 KB I-cache (IBusCachedPlugin), the official-spec debug
  module (EmbeddedRiscvJtag), and standard M-mode IRQs.** Measured: 1742 LUT / 1639 FF / 1 RAMB36 +
  3 RAMB18 / 4 DSP, WNS +1.10 ns at 8.815 ns. That is +965 LUT over the 832. Dhrystone on a
  4-cycle-per-access bus: 0.563 DMIPS/MHz, about 64 DMIPS at 113 MHz, **7.1x the 832** on the same bus model.
* **NEORV32 is the runner-up**, and it wins only on maintenance and its plain VHDL source. It
  is never faster on our path: with a 4 KB I$ it gets 0.318 DMIPS/MHz (4.0x the 832, 56 % of VexRiscv)
  at 2198 LUT. Without caches it gets 0.227 (2.85x).
* **No tiny core passes both gates.** SERV/QERV pass (they are maintained and use the standard ISA), but
  they are slower than the 832 on our bus (0.32x / 0.88x), have no M and no debug module, and are not
  usable here. Every other sub-1k-LUT core fails a gate. The passing cores that are fast enough start
  at about 1.25 k LUT, which is +470 over the 832.
* **picorv32 fails gate 1** (GitHub repo archived, Sep 2026). It is listed only as a reference row.
* **Hazard3 is not tiny on Artix-7.** IMC is 2.25 k LUT and **misses 113 MHz** in every variant tried
  (best is -0.57 ns, ~107 MHz). IM alone just closes timing (+0.33 ns with the register file in LUTRAM).
  It has the fastest zero-wait IPC (1.13 DMIPS/MHz), but on our 4-cycle bus it gets 0.315, roughly the
  same as an uncached VexRiscv.

## 1. Hard gates (evaluated first)

Gate 1 is active maintenance: commits or releases in the last ~12 months (since 2025-10-16), and not
archived. Gate 2 is a standard ISA built by upstream GCC/LLVM with no patches (RV32I/E + M/C + Zicsr),
with standard M-mode traps (mtvec/mie/mip/mcause) preferred. Data comes from the GitHub REST API on
2026-10-16 and from the shallow clones listed in §6.

### 1.1 Passed both gates (measured)

| Core | Maintainer / health | Last activity (12-month commits; last release) | ISA options | IRQ model | Debug (RISC-V External Debug) | HDL / licence |
|---|---|---|---|---|---|---|
| **VexRiscv** | Charles Papon (SpinalHDL); used by LiteX and Efinix (Sapphire SoC); 3.3 k stars | 18 commits (last 2026-09-24), all community PRs merged by the author; **no tagged releases**; README points new users to VexiiRiscv (100+ commits/12m) → **maintenance mode** | RV32I/E, M (DSP mul + iterative div), C, optional I$/D$/MMU, all as plugins | standard mtvec/mie/mip/mcause; 3 lines (external/timer/software); `ExternalInterruptArrayPlugin` adds 32 lines through custom CSRs | **EmbeddedRiscvJtag** = official spec 0.13 DM + JTAG DTM (used in my `_dm` runs). Pin TAP (`withTap`) or **BSCANE2 tunnel** (`withTunneling`), so it can use the FPGA config cable. README example uses the stock `target create … riscv` OpenOCD flow; not hardware-verified here. The classic `DebugPlugin` (needs the SpinalHDL OpenOCD fork) was **not** used | SpinalHDL → generated Verilog-2001, MIT |
| **NEORV32** | Stephan Nolting + contributors; very active; 2.3 k stars | 100+ commits/12m; **13 releases in 12 months** (v1.12.9 … v1.13.6, last 2026-09-20) | RV32I/E, M, C, Zb*, Zicond, Zfinx, U, PMP, caches, many peripherals | standard MEI/MTI/MSI at the top level; CPU has 16 fast IRQs (standard mcause 16-31), but `neorv32_top` routes them to internal peripherals. Our lines arrive through MEI, the CFS slot (own FIRQ) or GPIO (up to 32 interrupt-capable inputs, one FIRQ) | OCD = spec 1.0 DM + JTAG DTM, docs state "compatible with upstream OpenOCD and GDB". **Pin JTAG only** (no BSCANE2 tunnel in rtl) | VHDL (minimal 2008), BSD-3 |
| **Hazard3** | Luke Wren (individual; in RP2350 silicon); 1.1 k stars | 70 commits/12m (develop branch, pushed 2026-08-29); release v1.1.1 2026-03-12 | RV32I/E, M, A, C, Zba/b/s/kb, Zcb/Zcmp, U, PMP | standard + optional Xh3irq (priorities, NUM_IRQS up to 512) | standard DM + JTAG DTM, includes a **Xilinx-7 BSCANE2 DTM**; riscv-openocd/upstream | Verilog-2005, Apache-2.0 |
| **Ibex** | lowRISC CIC; OpenTitan silicon; very active (commit 2026-10-16) | yes | RV32I/E, M (slow/fast/1-cycle), **C always on**, B, PMP; main now carries CHERIoT | standard + 15 fast IRQs | standard (needs pulp riscv-dbg, not vendored in the ibex repo) | **SystemVerilog** (+ lowRISC prims), Apache-2.0. Quartus Lite/Standard SV support is weak |
| **SERV / QERV** | Olof Kindgren / FOSSi; 1.9 k stars | 13 commits/12m; release 1.4.0 2025-10-15. QERV is the `W=4` parameter of SERV (the standalone qerv repo was last pushed 2025-05) | RV32I/E, Zicsr, C; M only through an external MDU | standard CSRs, **timer IRQ only** | **none** | Verilog, ISC |

### 1.2 Rejected by gate

| Core | Gate | Reason (evidence) |
|---|---|---|
| picorv32 | 1 | GitHub repo **archived** (Sep 2026); no release since v1.0 (2019). Also gate 2 minus: custom IRQ scheme (q-regs, `retirq/maskirq`), no Zicsr traps |
| FazyRV (meiniKi) | 2 | Active (59 commits), but `INT`/`CSR` configs are "work in progress… deviations from the specification", mtvec is fixed at synthesis, no M, no DM; README: "still needs to become production-ready" |
| DarkRISCV | 2 | Active (19 commits), but README says "partial M-extension, MUL only, no DIV (use -mno-div)", no C, incomplete CSR/trap set, no DM |
| Minimax | 1/2 | 3 commits/12m; RVC-native with no CSRs or interrupts |
| FemtoRV (learn-fpga) | 2 | Educational; Gracilis IRQ is a partial custom CSR subset; no DM |
| Steel → **rvx** (rafaelcalcada) | ISA | Active (pushed 2026-10-15) and standard Zicsr IRQs, but **RV32I only** (no M, no C, no DM): below the "IM acceptable" floor |
| Kronos | 1 | last push 2023-05 |
| ultraembedded riscv / biriscv | 1 | last push 2021-09 |
| tinyriscv | 1 | last push 2023-11 |
| RudolV | 1 | last push 2022-05 |
| NERV (YosysHQ) | 1/2 | 0 commits/12m; no CSRs/IRQ |
| e203 hbirdv2 | 1 | 0 commits on the default branch in 12 m |
| SCR1 (Syntacore) | 1 | last push 2024-11 (and SystemVerilog) |
| Potato | 1 | last push 2024-08 |
| uRV (CERN OHWR) | 1 | OHWR wiki: "not yet ready to be offered as a block"; JTAG debug and C are listed as planned |
| CV32E40X | 1 | last push 2024-11 |
| CV32E40P, VeeR EL2, VexiiRiscv | size | Pass both gates but are far larger (multi-k LUT; VexiiRiscv's minimal config was not generated here). Not measured |

## 2. Measured size and timing (OOC, registered-I/O wrapper, core hierarchy only)

The wrapper registers every core input and output, so all paths are reg→reg. The numbers are the
`u_core` line of `report_utilization -hierarchical` after route, so wrapper FFs are excluded. "DM" means
DM plus pin JTAG-DTM (tck clocked at 50 ns, async to clk). Est. Fmax = 1/(period − WNS). Rows marked
`@6.5`, `@7.0` etc. are tighter re-runs, and their Fmax is a lower bound for that configuration.

| Run | Config | LUT | LUTRAM | FF | RAMB36/18 | DSP | WNS @8.815 | est. Fmax |
|---|---|---|---|---|---|---|---|---|
| **832 (baseline)** | BE, IRQ, no dualthread/fwd/prefetch | **777** | 0 | **793** | 0/0 | 4 | +2.368 | ≥160 (@6.5: +0.245) |
| **VexRiscv IM** | IBusSimple, LightShifter, MulPlugin + iterative div, CSR small | 1268 | 0 | 727 | 0/2 | 4 | +2.238 | 152 |
| VexRiscv IMC | same + C | 1243 | 0 | 757 | 0/2 | 4 | +1.306 | ≥155 (@7.0: +0.531) |
| VexRiscv IM + DM | EmbeddedRiscvJtag | 1577 | 22 | 1571 | 0/2 | 4 | +1.492 | 137 |
| VexRiscv IMC + DM | | 1716 | 22 | 1603 | 0/2 | 4 | +1.263 | ≥149 (@7.0: +0.267) |
| VexRiscv IMC + 1 KB I$ + DM | IBusCached 32 B lines | 1756 | 38 | 1660 | 0/3 | 4 | +1.465 | 136 |
| **VexRiscv IMC + 4 KB I$ + DM** | IBusCached 32 B lines | **1742** | 22 | **1639** | **1/3** | 4 | **+1.104** | 130 |
| **NEORV32 IM** | neorv32_top, XBUS only, fast mul, no Zicntr | 1310 | 24 | 852 | 1/0 | 4 | +0.962 | 127 |
| NEORV32 IMC | | 1485 | 24 | 871 | 1/0 | 4 | +0.901 | ≥144 (@7.5: +0.562) |
| NEORV32 IM + OCD | | 1706 | 24 | 1275 | 1/0 | 4 | +1.239 | 132 |
| NEORV32 IMC + OCD | | 1866 | 24 | 1293 | 1/0 | 4 | +1.172 | ≥147 (@7.5: +0.681) |
| NEORV32 IMC + OCD + 1 KB I$ | 16×64 B / 32×32 B, no bursts | 2070 / 2093 | 46 | 1379 / 1394 | 1/4 | 4 | +1.013 / +0.937 | 128 |
| **NEORV32 IMC + OCD + 4 KB I$** | 128×32 B, no bursts | **2198** | 24 | **1468** | **1/5** | 4 | **+0.755** | 124 |
| Hazard3 IM | A=0, MUL_FAST, no counters, regfile BRAM | 1784 | 0 | 505 | 0/2 | 3 | +0.114 | 115 |
| Hazard3 IM, RB+LUTRAM RF | REDUCED_BYPASS, `-max_bram 0` | 1690 | 44 | 562 | 0/0 | 3 | +0.333 | 118 |
| Hazard3 IM + DM (LUTRAM RF) | | 2349 | 44 | 983 | 0/0 | 3 | +0.284 | 117 |
| Hazard3 IMC (BRAM RF) | | 2251 | 0 | 559 | 0/2 | 3 | **−1.845** | 94 |
| Hazard3 IMC (LUTRAM RF) | best IMC variant | 2244 | 44 | 623 | 0/0 | 3 | **−0.566** | 107 |
| Hazard3 IMC + RB (LUTRAM RF) | | 2278 | 44 | 619 | 0/0 | 3 | −1.231 | 100 |
| Hazard3 IMC, FAST_BRANCHCMP=0 | | 2266 | 44 | 625 | 0/0 | 3 | −2.983 | 85 |
| Hazard3 IMC + DM (LUTRAM RF) | | 2700 | 44 | 1038 | 0/0 | 3 | −1.210 | 100 |
| Ibex IMC (RV32MFast, FPGA RF) | no DM | 2519 | 44 | 904 | 0/0 | 1 | **−2.235** | 90 |
| SERV (W=1) RV32I | serv_rf_top, RF in BRAM | 168 | 0 | 182 | 0/1 | 0 | +2.697 | 163 |
| SERV RV32IC | | 315 | 0 | 200 | 0/1 | 0 | +3.276 | 181 |
| QERV (W=4) RV32I | | 257 | 0 | 218 | 0/1 | 0 | +1.737 | 141 |
| QERV RV32IC | | 395 | 0 | 236 | 0/1 | 0 | +2.622 | ≥180 (@6.0: +0.451) |
| *picorv32 IM (ref, gate 1 fail)* | plan defaults: barrel shift, counters64, IRQ+qregs+timer, fast mul, div | 1847 | 88 | 938 | 0/0 | 4 | +2.345 | 155 |
| *picorv32 IMC (ref)* | | 2152 | 88 | 966 | 0/0 | 4 | +1.065 | 129 |

**Cost of C**: VexRiscv −25 LUT/+30 FF (it is within noise, and C mostly costs timing: −0.93 ns),
NEORV32 +175 LUT/+19 FF, Hazard3 +467 LUT/+54 FF and −1.96 ns (it breaks timing), SERV +147,
QERV +138, picorv32 +305.
**Cost of DM**: VexRiscv +309..473 LUT / +844 FF (the FF cost is large), NEORV32 +381..396 LUT /
+423 FF, Hazard3 +580..660 LUT / +420 FF.
**Cost of a 4 KB I$**: VexRiscv +26 LUT and +1 RAMB36 (IBusCached replaces IBusSimple), NEORV32
+332 LUT and +5 RAMB18.

Hazard3's critical path is register-file read (BRAM clk→out 2.1 ns) → bypass → branch compare →
frontend → next-PC/bypass select, 13-18 levels. It is an ASIC-oriented 3-stage design. Ibex fails by
2.2 ns. Neither is a candidate at 113 MHz without pipeline changes.

## 3. Throughput on our path (Dhrystone 2.1, cycle-accurate RTL sim)

Each core runs the same Dhrystone (100 runs, picorv32's `dhry_1/2.c` + `stdlib.c`, gcc 13.2
`-O2 -march=rv32im[c]`, timer = MMIO store). The 832 runs `fw/dhrystone_832` built with vbcc832
`-O=1343` (fw flags), 100 runs, with timer and UART changed to the same MMIO stores; it passes the
built-in result checks. Memory is one shared single-port memory, one access in flight. Each access
takes **1 + WS cycles** (WS = 0 is single-cycle BRAM-like, WS = 3 is ~ a hostcache hit through the
bridge, per plan §2.2 "4-5 clk_114 per hit"). SDRAM misses are not modelled. Bus adapters: 832 req/ack
(ack after 1+WS), Hazard3 AHB-Lite (hready low WS cycles, pipelined address phase), VexRiscv simple
cmd/rsp (rsp 1+WS after accept; I$ refill = 8 single-word beats, first beat 2+WS, then 1+WS each),
NEORV32 XBUS (ack 1+WS after stb; cache bursts disabled, single-word refill like our bridge), SERV
Wishbone (ack 1+WS).

DMIPS/MHz = 10^8 / (cycles × 1757). DMIPS at 113.44 MHz. "× 832" uses the same WS.

| Core / config | WS=0 cycles | DMIPS/MHz | DMIPS | × 832 | **WS=3 cycles** | **DMIPS/MHz** | **DMIPS** | **× 832** |
|---|---|---|---|---|---|---|---|---|
| 832 (design config) | 505,400 | 0.113 | 12.8 | 1.00 | 714,342 | 0.080 | 9.0 | 1.00 |
| Hazard3 IM | 54,537 | 1.044 | 118 | 9.3 | 207,348 | 0.274 | 31.1 | 3.4 |
| Hazard3 IMC | 50,533 | 1.126 | 128 | 10.0 | 180,516 | 0.315 | 35.8 | 4.0 |
| VexRiscv IM (IBusSimple) | 74,841 | 0.760 | 86 | 6.8 | 214,740 | 0.265 | 30.1 | 3.3 |
| VexRiscv IMC (IBusSimple) | 74,841 | 0.760 | 86 | 6.8 | 190,917 | 0.298 | 33.8 | 3.7 |
| VexRiscv IMC + 1 KB I$ | 111,224 | 0.512 | 58 | 4.5 | 216,174 | 0.263 | 29.9 | 3.3 |
| **VexRiscv IMC + 4 KB I$** | 72,457 | 0.786 | 89 | 7.0 | **101,087** | **0.563** | **63.9** | **7.1** |
| NEORV32 IM | 144,790 | 0.393 | 45 | 3.5 | 271,188 | 0.210 | 23.8 | 2.6 |
| NEORV32 IMC | 146,290 | 0.389 | 44 | 3.5 | 250,954 | 0.227 | 25.7 | 2.85 |
| NEORV32 IMC + 1 KB I$ (16×64 B) | 231,149 | 0.246 | 28 | 2.2 | 388,619 | 0.146 | 16.6 | 1.8 |
| NEORV32 IMC + 1 KB I$ (32×32 B) | – | – | – | – | 300,640 | 0.189 | 21.5 | 2.4 |
| **NEORV32 IMC + 4 KB I$ (128×32 B)** | 145,486 | 0.391 | 44 | 3.5 | **178,804** | **0.318** | **36.1** | **4.0** |
| SERV RV32I | 2,104,634 | 0.027 | 3.1 | 0.24 | 2,254,127 | 0.025 | 2.9 | 0.32 |
| QERV RV32I | 659,194 | 0.086 | 9.8 | 0.77 | 808,687 | 0.070 | 8.0 | 0.88 |
| QERV RV32IC | 695,020 | 0.082 | 9.3 | 0.73 | 898,252 | 0.063 | 7.2 | 0.80 |

Observations:
* The 832 figure (0.113 DMIPS/MHz, 12.8 DMIPS) is low, but the run passes Dhrystone's own checks.
  It is the design's configuration (no prefetch, no forwarding) with vbcc code. **Confirm it once on
  the board** (`fw/dhrystone_832`) before quoting absolute numbers. The ratios between the RISC-V rows
  do not depend on it.
* An uncached core loses 2.5-4x going from WS=0 to WS=3. Hazard3 loses its whole IPC lead (1.13 → 0.315).
  This is the plan's "fetch-bound" concern, now measured.
* A 4 KB I$ (Dhrystone's ~4 KB loop fits) takes VexRiscv back to 0.563 at WS=3, 1.9x its uncached figure.
  NEORV32's multi-cycle core only gets 0.227 → 0.318, because it is core-bound, not fetch-bound.
* A 1 KB I$ is **worse than no cache** for both cores: lines thrash and each miss refills 8-16 words.
  Real firmware (FAT, floppy/HDD, CD paths) has a larger hot set than Dhrystone, so 4 KB is the
  minimum worth building. The bigger win would come from burst/line refills in the bridge from the
  existing hostcache.
* C helps NEORV32 and VexRiscv a little at WS=3 (+8 % / +12 %, less fetch traffic). It hurts QERV.

## 4. VexRiscv vs NEORV32, head to head

| Question | VexRiscv | NEORV32 | Edge |
|---|---|---|---|
| 1. Maintenance | 18 merged PRs in 12 m, no releases. The author's active work is VexiiRiscv (README: "you may be interested in VexiiRiscv"). Mature and widely deployed (LiteX, Efinix), effectively **maintenance mode** | 100+ commits, **13 tagged releases in 12 m**, responsive single lead + contributors | **NEORV32** |
| 2. Debug | EmbeddedRiscvJtag: official spec DM + DTM (measured), pin TAP **or BSCANE2 tunnel** over the existing FPGA JTAG cable. Stock OpenOCD `riscv` target per README (untested here). The classic DebugPlugin (fork-only) was not used | spec DM + DTM, docs: upstream OpenOCD + GDB; pin JTAG only (needs 4 spare FPGA pins + adapter, or a home-made BSCANE2 bridge) | **VexRiscv** (no extra pins) |
| 3. Regeneration | Needs JDK 17 + sbt + SpinalHDL 1.13. Here: JDK 23 (default) **fails** with sbt 1.6.0, JDK 17 works (`sbt -java-home /usr/lib/jvm/java-17-openjdk-amd64`). About 1.3 GB of caches (`~/.sbt`, `~/.cache/coursier`), ~2 min per generation. Output is plain Verilog-2001 (8 k lines per CPU), no vendor primitives (one harmless `ram_style` attribute), so it builds on Quartus. Practice: **commit the generated .v plus the Scala config** | plain VHDL, generics only, no generator | **NEORV32** |
| 4. Throughput on our path (WS=3) | 0.298 uncached, **0.563 with 4 KB I$** (64 DMIPS) | 0.227 uncached, 0.318 with 4 KB I$ (36 DMIPS) | **VexRiscv, 1.3x uncached / 1.8x cached** |
| Size (IMC + DM) | 1716 LUT uncached, **1742 with 4 KB I$** (+1 RAMB36) | 1866 uncached, 2198 with 4 KB I$ | **VexRiscv** (−150 / −456 LUT) |
| Timing at 8.815 ns | +1.26 / +1.10 ns (≥149 MHz uncached) | +1.17 / +0.76 ns (≥147 MHz uncached) | about equal uncached; VexRiscv with I$ |
| 5. IRQ | standard mtvec/mie/mip/mcause; 3 lines (MEI/MTI/MSI). More lines need an external pending/mask register on MEI (~30 LUT, cleanest), or `ExternalInterruptArrayPlugin` (32 lines, custom CSRs) | standard; MEI/MTI/MSI at top, plus GPIO with up to 32 interrupt-capable inputs (per-pin enable/type/pending, standard FIRQ) and the CFS slot. Using `neorv32_cpu` directly exposes 16 FIRQs | NEORV32 (more lines in the box), but both are fine for ~8 sources behind one MEI |
| Bus fit | IBus/DBus simple cmd/rsp (2 masters → small arbiter in the bridge) | single XBUS (Wishbone-style stb/ack), maps directly to req/ack | NEORV32 |
| Vendor neutrality / Intel | generated Verilog: yes | VHDL: yes | equal |

**Decision: VexRiscv IMC + 4 KB I$ + EmbeddedRiscvJtag (BSCANE2 tunnel), 3 standard IRQ lines plus a
small pending/mask register on MEI.** It is the smallest gate-passing core that is fast on our path,
it has the best timing margin of the fast candidates, and it is debuggable over the JTAG cable already
on the board. The maintenance risk is real but bounded: the configuration is frozen in a committed
Scala file and generated Verilog, so the design never depends on upstream changing. VexiiRiscv (same
author, same bus and debug ideas) is the migration path if VexRiscv bit-rots.

**NEORV32 wins if** (a) the team will not keep a JDK 17 + sbt toolchain alive (it is only needed when
the CPU configuration changes), or (b) throughput is not the constraint. For example, if Phase 8 moves
the SPI/CD-DA work to FIFO/DMA so the CPU only orchestrates, 2.6-4x the 832 is already enough. Or
(c) release cadence and a single readable VHDL source matter more than ~450 LUT and 1.8x speed. In
those cases use NEORV32 IMC + OCD (1866 LUT, uncached). Its 4 KB I$ buys only +40 % on our path for
+332 LUT. NEORV32 also needs 4 spare pins for JTAG, or a custom BSCANE2 DTM.

Hazard3 would only win if the bridge became near-zero-wait (for example a CPU-side TCM/I$ in front)
**and** the C extension were dropped or Hazard3 were re-pipelined for timing. Neither is cheap here.

Caveats: the bus model has no SDRAM misses (real misses favour the I$ configurations even more), and
Dhrystone fits in 4 KB while real firmware may not. Re-check the I$ hit rate with a firmware trace in
the Phase 4 co-sim before freezing the size. One cache detail: the Vex I$ refill model charges one
extra cycle per line, which is slightly pessimistic for Vex.

## 5. Reproduction

Scratch root (ephemeral): `T=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores`
(`$T/src` = clones, `$T/wrap` = wrappers + Vivado scripts, `$T/runs/<name>` = reports, `$T/perf` = benches).

Clones (shallow, measured commits): picorv32 ef203c2, Hazard3 8af9929 (stable), neorv32 b262045,
VexRiscv baf7dc8, serv f200eb2, ibex 7a4697f; 832 = the `EightThirtyTwo` submodule (d1cd671).

### 5.1 Vivado OOC flow

`$T/wrap/run.tcl` (all runs):
```tcl
# vivado -mode batch -source run.tcl -tclargs <outdir> <srcs.tcl> <period_ns> [GEN=VAL ...]
set outdir [lindex $argv 0]; set srcs [lindex $argv 1]; set period [lindex $argv 2]
set gens [lrange $argv 3 end]; file mkdir $outdir; set_part xc7a100tfgg676-2; source $srcs
set gargs {}; foreach g $gens { lappend gargs -generic $g }
set extra {}; if {[info exists ::env(EXTRA_SYNTH)]} { set extra $::env(EXTRA_SYNTH) }
synth_design -top wtop -part xc7a100tfgg676-2 -mode out_of_context -flatten_hierarchy rebuilt {*}$gargs {*}$extra
create_clock -name clk -period $period [get_ports clk]
if {[llength [get_ports -quiet tck]]} { create_clock -name tck -period 50.0 [get_ports tck]
  set_clock_groups -asynchronous -group clk -group tck }
opt_design; place_design; phys_opt_design; route_design
report_utilization -hierarchical -hierarchical_depth 2 -file $outdir/util_hier.rpt
report_timing_summary -max_paths 5 -file $outdir/timing.rpt
```
Driver: `$T/wrap/go.sh [-lutram] <name> <srcs.tcl> <period> [GEN=VAL...]` (sources
`/opt/Xilinx/2026.1/settings64.sh`; `-lutram` sets `EXTRA_SYNTH="-max_bram 0"`). Queues:
`cd $T/wrap && xargs -P 4 -L 1 ./go.sh < queue1.txt` (also queue2-4.txt). Table: `python3 -I $T/wrap/parse.py $T`.

Wrappers (each registers every I/O; the core instance is `u_core`):
`w832.vhd` (generics as `rtl/host/832_bridge.vhd`), `wvex.v` (`VEXMOD`/`DM`/`ICACHE` defines),
`wneo.vhd` (`C`, `OCD`, `IC`, `ICB`, `BS`; `BOOT_MODE_SELECT=1`, XBUS, `XBUS_TIMEOUT=0`,
`CPU_FAST_MUL_EN`, no Zicntr), `whz3.v` (`C`, `DBG`, `RB`, `FBC`; DM + `hazard3_jtag_dtm`),
`wserv.v` (`W`, `COMPRESSED`, `WITH_CSR=1`, `MDU=0`), `wibex.sv` (`ibex_top`, RV32MFast,
RegFileFPGA, Zca), `wpico.v` (plan §2.2 defaults).

### 5.2 VexRiscv generation

`$T/src/VexRiscv/src/main/scala/vexriscv/demo/GenTiny.scala` (written for this study):
IBusSimple (or IBusCached 1/4 KB, 32 B lines, `injectorStage = rvc`), DBusSimple,
`CsrPluginConfig.small(0x20).copy(withPrivilegedDebug = dm)`, DecoderSimple, RegFile SYNC,
IntAlu, Src, LightShifter, HazardSimple (full bypass), MulPlugin,
`MulDivIterativePlugin(genMul=false, genDiv=true)`, Branch (late), optional
`EmbeddedRiscvJtag(DebugTransportModuleParameter(7,1,7), withTunneling=false, withTap=true)`.
```
cd $T/src/VexRiscv
sbt -java-home /usr/lib/jvm/java-17-openjdk-amd64 -batch "runMain vexriscv.demo.GenTiny"      # 4 uncached variants
sbt -java-home /usr/lib/jvm/java-17-openjdk-amd64 -batch "runMain vexriscv.demo.GenTiny ic"   # I$ variants
# -> gen_tiny/VexTiny_IM[C][_IC1K|_IC4K][_DM].v
```
(Default JDK 23 fails: "bad constant pool index" in sbt 1.6.0.) For the production BSCANE2 build,
switch to `withTunneling = true, withTap = false` with a `BSCANE2(userId = 4)` per the VexRiscv README.

### 5.3 Dhrystone benches

* RISC-V image: `$T/perf/sw` (picorv32 dhrystone sources, `stdlib.c` `time()` → store to
  0x20000000, `start.S`, `link.ld` at 0):
  `riscv64-unknown-elf-gcc -march=rv32imc -mabi=ilp32 -O2 -ffreestanding -nostdlib -fno-builtin -DTIME -DRISCV -DUSE_MYSTDLIB -T link.ld -o dhry_rv32imc.elf start.S dhry_1.c dhry_2.c stdlib.c -lgcc`,
  then objcopy to a binary and a little-endian 32-bit hex.
* 832 image: `$T/perf/sw832` = `fw/dhrystone_832` with `Number_Of_Runs = 100`, `_readMilliseconds()` →
  store to 0x20000000, `RS232` → int store to 0x10000000, a store to 0x20000004 at the end of `main`. Build with
  `vbcc832 -+ -c99 -O=1343 -unsigned-char …`, `832a -eb`, and
  `832l -eb -s_STACKSIZE=0x0 -s_STACKTOP=0x10000 -b 0 crt0.a dhry_1.o dhry_2.o uart.o setstack.o lib832.a`, big-endian hex.
  **Trap:** 832 `bytesel(0)` is the q(31:24) lane (big-endian). The first run had the lanes reversed and
  corrupted the strings.
* Benches in `$T/perf/tb` (`mem_common.vh` = shared memory + MMIO; `WS` define):
  `iverilog -g2012 -DWS=3 -DC=1 -DHEX='"…/dhry_rv32imc.hex"' -I$H -I$H/arith tb_hz3.v <hazard3.f files>`;
  `tb_serv.v` (`-DW=1|4`), `tb_vex.v` / `tb_vexc.v` (`-DVEXMOD=VexTiny_IMC[_IC4K]`), then `vvp -N`.
  NEORV32 and 832 run in xsim 2026.1: `./runneo.sh <WS> <C> [IC ICB BS]`, `./run832.sh <WS>`.
  **Trap:** xsim 2026.1 on this host needs `export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu`, otherwise the link step fails with
  "cannot find crt1.o".
* Result line: `DHRY_CYCLES <n> WS <ws>` (cycles between the two `time()` stores).

## 6. Sources

* GitHub REST API, 2026-10-16: repo `archived`/`pushed_at`, commits since 2025-10-16, releases for each repo above.
* VexRiscv README §EmbeddedRiscvJtag / Tunneled JTAG; `src/main/scala/vexriscv/demo/GenFullWithOfficialRiscvDebug.scala`.
* NEORV32 `docs/datasheet/on_chip_debugger.adoc` ("compatible with upstream OpenOCD and GDB"), `overview.adoc` (minimal VHDL-2008).
* Hazard3 `hdl/hazard3_config.vh`, `example_soc/soc/example_soc.v`, `hdl/debug/dtm/hazard3_xilinx7_jtag_dtm.v`.
* FazyRV README (CONF MIN/INT/CSR, "not production-ready"); DarkRISCV README ("MUL only, no DIV"); uRV: https://www.ohwr.org/project/urv-core/wiki
