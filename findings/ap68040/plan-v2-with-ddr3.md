# AP68040 with MMU and FPU — implementation plan, second edition

Date 2026-09-06. Status: **plan only; nothing implemented, nothing built.**
Supersedes the order of work in [README.md](README.md), which was written
before the DDR3 fast RAM landed and assumed it would arrive as an in-domain
DLL-off controller. It arrived differently (see "What changed since the first
plan"), so the memory side of that plan is out of date; its compatibility
assessment ([compatibility.md](compatibility.md)) and clock-rate measurements
([performance.md](performance.md)) still stand and are relied on below.

## The question asked

Put the 68040 into the Minimig configuration next to the TG68K if it fits,
otherwise make it the only core. MMU and FPU on.

## The answer, with the numbers

Both fit. Measured on the bitstream tagged `ddr3-fast-ram` (build/stage_z3ram3,
`report_utilization -hierarchical`) and the AP68040 out-of-context place and
route at commit 0e76761 with the RAM-primitive fix
([synth-reports/util_routed.rpt](synth-reports/util_routed.rpt)):

| | LUTs | of 63,400 | BRAM tiles | DSP |
|---|---|---|---|---|
| Design today (TG68K, DDR3 board 3, RTG, Toccata) | 15,909 | 25 % | 49.5 | 18 |
| of which the TG68K wrapper `tg68k` (kernel + decode + Akiko/C2P) | 5,043 | | | |
| AP68040, MMU + FPU + 4 KB/4 KB caches, placed and routed | 28,694 | 45 % | 10 | 20 |
| **Sole core**: today − TG68K kernel (≈ 4,000–4,500) + AP68040 | **≈ 40,400** | **≈ 64 %** | ≈ 60 | 38 |
| **Both cores**, OSD-selected: today + AP68040 + kernel mux (≈ 300) | **≈ 44,900** | **≈ 71 %** | ≈ 60 | 38 |

So the honest answer to "does it fit" is: on LUT count, yes, either way. What
the count does not say is whether two 40-logic-level cores plus the DDR3
island route and close timing at 71 %. The AP68040 alone at 45 % of the device
routes with its worst path at 21.0 ns ([performance.md](performance.md)), and
every path fits the 3-cycle `clkena` budget with 5 ns to spare; congestion at
71 % will eat some of that. That is a place-and-route question, and the only
way to answer it is to run it. The earlier "not an option on this device" in
compatibility.md was written when the core was 70.8k LUTs, before the
`dpram.v` fix; it no longer holds.

**Recommendation.** Build the sole-core version first, as a build-time choice
(`CPU_CORE = "TG68K" | "AP040"` on the top level, two bitstreams). Everything
it needs — wrapper, walker port, constraints, benches — is also needed for the
dual-core version, so nothing is wasted. Then try the dual-core bitstream as a
bounded experiment (stage E): if it closes timing with margin, ship it; if it
does not, the two bitstreams are the product. Do not start with the dual
build: a timing failure there cannot be told apart from an integration bug.

## What changed since the first plan

* **DDR3 fast RAM exists**, as Zorro-III board 3 on the 100 MHz island
  (`rtl/ddr3/*`, vendored `core_ddr3_controller`, `cpu_cache_new` in front,
  a 16-byte line CDC behind). Boards 1 and 2 stay on the SDRAM. The README's
  C-track (in-domain DLL-off controller at 56.7 MHz, RTG on DDR3, the
  watermark arbiter) is superseded and is **not** part of this plan; RTG
  stays on the SDRAM.
* **The DDR3 backend is already a line port.** `ddr3_fastram.v` talks to the
  island in 16-byte lines with 16 byte enables through `ddr3_cdc.v`. The 040's
  line fills and copy-back writes map onto that 1:1 once they bypass the
  16-bit bus — stage D here, formerly B1/B2.
* **The Zorro-III bases are latched now** (`z3ram3_base`), which is exactly
  what the 040's cacheable-window inputs want.
* **Constraint prerequisites landed**: fix-04 (multicycles off
  `[all_registers]`), fix-05 (clock groups), fix-06/07/09/10. The multicycle
  sets in `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` are by instance path
  and the file says so: "if the CPU core is replaced, only the three set
  definitions change". fix-12 (SDRAM read capture clock) was **reverted**
  (does not run on hardware); the SDRAM read path keeps its known −0.5 ns.
* The AP68040 tree at `~/work/fpga/Xilinx/artix7/minimig/AP68040`, commit
  0e76761, is unchanged since the assessment; `primitives/dpram.v` is still
  the single-process version that dissolves into 43k LUTs. Its self-test
  suite runs on this machine (iverilog + vasm); results in "Numbers" below.

## What the core offers and what the SoC has to give it

From `rtl/ap040_tg68k_compat.v` (the only top level to use) and its headers.

**Drop-in part.** `clk`, `nreset`, `clkena_in`, `data_in[15:0]`,
`data_write[15:0]`, `addr_out[31:0]`, `nwr`, `nuds`, `nlds`, `busstate[1:0]`
(00 fetch, 01 idle, 10 read, 11 write — same encoding), `longword`, `fc`,
`ipl`, `nresetout`, `vbr_out`. The bus contract in `ap040_bus16_adapter.v`
is the Minimig one this wrapper already speaks: outputs registered on
`clkena_in`, one request at a time, level acknowledge, an IDLE cycle between
split sub-cycles, long = two word cycles when even. `cpu[1:0]` does not
exist — the core is always a 68040 — so the wrapper's `cpu(1)` (32-bit
decode, AGA longword chip access) is fixed high in the AP040 branch.

**Sideband the SoC must feed.**

| Port | Feed from | Notes |
|---|---|---|
| `cache_snoop_stb`, `cache_snoop_addr[31:0]` | `sdram_ctrl.v` `snoop_act` and `{chipAddr,1'b0}` (`:292-295`, already built for `cpu_cache_new`) | Needs a new output pair on `sdram_ctrl` and a new input pair on the wrapper; same clock domain. Without it chip RAM is uncacheable in the D-cache. The I-cache never caches the chip window by design (`ap040_tg68k_compat.v:227-242`). |
| `cache_z2_ena` | `z2ram_ena` | window is $200000–$9FFFFF, hard-wired in the core |
| `cache_z3_base0[4:0]`, `cache_z3_ena0` | `5'b01000`, `z3ram_ena` | window = `addr[31:27]`, 32 MB: $40000000–$41FFFFFF covers board 1 **and** board 3 where the OS puts it today |
| `cache_z3_base1[3:0]`, `cache_z3_ena1` | `z3ram3_base[7:4]`, `z3ram3_ena` | window = `addr[31:28]`, 256 MB: follows the DDR3 board wherever the OS places it |
| `cache_allow_all` | `0` | |
| `berr` | `0` for stage A | the SoC never raises bus errors today (undecoded space auto-completes with $FFFF); the core has its own watchdogs. Stage B may drive it from the walker router. |
| `ipl_autovector` | `1` | ignored by the core; always autovectored |
| `walker_req/we/addr/wdat` → `walker_ack/data/berr` | **stage B** | tied off in stage A: `ack = 0`, `berr = 0`. A walk that never acks becomes a bus error via the watchdog, so the MMU is unusable but the core does not hang. |
| `cacr_out[31:0]` | → `cpu_cache_ctrl[3:0]` for `cpu_cache_new` | **layout differs**: 040 CACR is DE = bit 31, IE = bit 15; `cpu_cache_new` wants the 020 nibble {clear, –, freeze, enable}. Proposal: `{cache_maint_req, 1'b0, 1'b0, 1'b1}` — external caches always on (they are coherent: snoop for chip RAM, single master for DDR3), cleared on CINV/CPUSH. Verify in the bench (stage A5). |
| `cache_maint_req/ic/dc`, `mmu_*`, `debug_*`, `nmi_ack_toggle` | open | observation |
| `cache_req/addr/data/ack/burst/burst_len/ramaddr` | leave open | **stubbed to zero inside the compat top** (`:434-438`): there is no line-fill port in this checkout; every fill is eight 16-bit sub-cycles through the adapter. Stage D adds one. |

**Two facts about the walker port** (from `ap040_mmu.v`):
`walk_ack = w_active && w_issued && walker_ack && !walker_berr` and the walk
FSM advances under `if (ce)`. So `walker_req` is a level held until the FSM
sees `walker_ack` on a `clkena` edge, and the ack must be a level, not a
one-cycle pulse on the free-running clock. `ap040_walker_cdc.v` is for hosts
whose MMU and memory run on different clocks; here everything is `clk_114`
with `clkena`, so it is not needed.

**One fact about the constraints.** The compat top has a core-side stall
watchdog that counts on the **free-running** clock ("a clkena wedge cannot
stop the count", `ap040_tg68k_compat.v:14-28`). It is a single-cycle path
inside what `cpu.xdc` will call the kernel island. The kernel multicycle set
must exclude it (`NAME !~ *watchdog*` or whatever the instance is called), or
Vivado will relax a genuine single-cycle path — harmless for a 21-bit counter,
wrong as a constraint, and exactly the class of thing fix-04 was about.

**Restart model.** On a write fault the faulting instruction re-executes; the
core never advertises a valid WB3. NetBSD's `trap.c` would double-apply RMW
stores if it completed writebacks itself. AmigaOS's `68040.library` does not,
so this matters only for stage F.

## Order of work

Effort: S = hours, M = days, L = a week or more including bench time. Each
stage ends in a commit and a bench or hardware result; nothing is synthesised
before its bench passes, which is the rule that saved a bring-up cycle on the
DDR3 (`findings/ddr3/z3ram3-on-ddr3-plan.md`).

### Stage 0 — bring the core in, keep it verifiable (S)

| # | Step | Exit criterion |
|---|---|---|
| 0.1 | Vendor AP68040 as a git submodule at `lib/AP68040`, pinned at 0e76761 (same arrangement as `rtl/tg68k`). Add its eleven `rtl/*.v` to the Vivado project as SystemVerilog, `ap040_defs.svh` on the include path. | project opens, `read_verilog -sv` clean |
| 0.2 | RAM primitive: a project-local `rtl/cpu040/dpram.v` from [synth-reports/dpram_xilinx.v](synth-reports/dpram_xilinx.v) compiled **instead of** the submodule's, so the submodule stays pristine. Run `lib/AP68040/tb/run_tests.sh` with the override on the path. The replacement returns *old* data on a cross-port collision where the original returns *new*; `tb_ap040_cache_snoop.v` is the test for exactly that. | all tests pass with the override; `bench_loop` cycles recorded below |
| 0.3 | Constraints: make `cpu.xdc`'s three set definitions take the kernel instance path from one variable; add the watchdog exclusion. No behaviour change for the TG68K build. | `report_exceptions` identical before/after on the TG68K build |
| 0.4 | The 4 September OOC numbers were taken at 0e76761 with this same replacement; re-run only if 0.2 changes anything. | — |

### Stage A — sole core: AP040 in the wrapper, 16-bit bus, no MMU walk (M)

| # | Step | Exit criterion |
|---|---|---|
| A1 | `rtl/soc/TG68K.vhd`: generic `cpu_core : string` ("TG68K" default, "AP040"). The kernel instantiation (`pf68K_Kernel_inst`, ~line 430) becomes a `generate` with two branches; **all decode, Zorro-III, DDR3, Akiko, chipset state machine and NMI logic stay as they are**. AP040 branch: component declaration for `ap040_tg68k_compat`; `cpu(1)` forced '1'; `skipFetch` '0'; ports per the table above. New wrapper inputs `snoop_stb`, `snoop_addr[31:0]`. Top levels pass `CPU_CORE` down; `AP040_HAS_FPU`/`HAS_MMU`/`ENABLE_CACHE` exposed as top-level parameters, **all 1 by default**. | TG68K build bit-identical in behaviour (sim/ddr3_cpu, sim/autoconfig unchanged) |
| A2 | `sdram_ctrl.v`: bring out `snoop_act` and the chip address as outputs; `minimig_virtual_top.v` wires them to the wrapper. | lint clean |
| A3 | `cpu.xdc`: kernel set = the AP040 instance minus the watchdog; wrapper and memory sets unchanged. `-setup -start 4 / -hold -start 3` as today (28.36 MHz, 35.3 ns budget; core worst path 21 ns). | `report_exceptions` shows the sets populated for both builds |
| A4 | Firmware: `fw/ctrl_832/menu.c:85` `config_cpu_msg[3]` "020 alpha" → "68040" for the AP040 bitstream; the wrapper ignores `cpu` in the AP040 branch, so the OSD choice is cosmetic there. (Becomes real in stage E.) | — |
| A5 | **Bench**: `sim/ddr3_cpu` gets `CPU_CORE` as a plusarg/define and compiles the AP040 sources under xsim; the same 68k program runs (assembled `-m68020`, valid 040 code). Add: chip-RAM access through the AGA longword path (the `longword` contract, `TG68K.vhd:589/630`), a 32-bit fast-RAM write (`longword_en` in `ddr3_fastram.v`), `movec` to a 040-layout CACR and the `cpu_cache_ctrl` mapping, and an interrupt (IPL) with autovector. Mutant run stays. Run the variants **one at a time** (`sim/ddr3_cpu/run.sh` header). | PASS + backdoor PASS with CPU_CORE=AP040; TG68K variant unchanged |
| A6 | **Hardware**: build `CPU_CORE=AP040`, program by reprogramming (never soft reset). Boot **without startup-sequence** so SetPatch never runs and the MMU stays off — no `NOMMU` mechanism to get right on the first try. Then `ShowConfig` (CPU line must say 68040), `avail` (42 MB as today), ATK on the SDRAM board and the DDR3 board. Then a normal boot: SetPatch loads `68040.library`, which **will** enable the MMU and hit the tied-off walker → watchdog → access error. Expected; it is the exit condition for stage B. | Workbench up with MMU off; ATK clean on both boards; the MMU-on boot fails in the documented way |
| A7 | Baseline numbers: `bench_loop` cycles per instruction TG68K vs AP040 (from 0.2 and the TG68K equivalent), and a fast-RAM memory benchmark on hardware for both bitstreams. | table below filled |

### Stage B — MMU walker port (S–M)

Required for AmigaOS, not only for NetBSD: `68040.library` builds page tables
and enables translation at boot to control cache modes; MuFastROM/MMULib remap
Kickstart into fast RAM through it.

Design: **the walker rides the CPU's own memory path.** A page-table walk
happens during address translation, before the core's bus request exists, so
the wrapper's bus is idle (`busstate = 01`) whenever `walker_req` is high.
The wrapper adds a small requester that, while `walker_req` is up and the
kernel is idle, drives `cpuaddr`/`state`/`uds`/`lds`/`data` in the kernel's
place as two 16-bit sub-cycles (read or write), through the **existing**
`sel_*` decode, `ramcs`/`ddrcs`, `mem_ready` and `clkena` logic, and returns
`walker_data` with a level `walker_ack` held until `walker_req` drops. No
new SDRAM or DDR3 port, no arbiter, no CDC. Tables in chip RAM go to the SDRAM
port, tables in fast RAM to board 1 (SDRAM) or board 3 (DDR3) by address,
exactly as CPU data does. The walker's U/M-bit update is a read then a write,
two requests. `walker_berr` from an access into undecoded space (`sel_undecoded`).

| # | Step | Exit criterion |
|---|---|---|
| B1 | Requester in the wrapper as above; multiplexed into the kernel-side bus signals; `berr` optionally driven from `sel_undecoded_d` for walker accesses. | lint clean |
| B2 | **Bench**: `sim/ddr3_cpu` program builds a two-level table in DDR3 fast RAM (root in chip RAM to exercise both paths), loads URP/SRP/TC via `movec`, enables translation, touches a mapped page and a page with the M bit clear, checks the descriptor's U/M bits through the backdoor, then an unmapped page and checks the access-error frame. `lib/AP68040/tb` `t_mmu` already proves the MMU; this proves the router. | PASS |
| B3 | Hardware: normal boot with SetPatch; `68040.library` enables the MMU. Then MuFastROM (`MuFastROM ON` from MMULib) and confirm Kickstart runs from fast RAM (`MuScan`). | Workbench with MMU on; MuScan shows ROM in fast RAM |

### Stage C — FPU on hardware (S)

FPU is compiled in from stage A (fits: ≈ 40 k). This stage is verification
only: a program that uses FMOVE/FADD/FMUL/FDIV directly and one that hits an
unimplemented instruction (FSIN) so the FPSP trap path through
`68040.library` is exercised. `lib/AP68040/tb` `t_fpu` covers the core; this
covers the library. Record whether `AP040_HAS_FPU=0` is ever wanted as a
smaller build; if not, drop the parameter from the top level.

### Stage D — performance (M each, independent, in this order)

| # | Step | Depends on | Exit criterion |
|---|---|---|---|
| D1 | `clkena` every 3 (`enaWRreg` on 5 of 16 phases) + `-setup -start 3 / -hold -start 2` on the kernel island — [performance.md](performance.md) option 1a; every core path fits 26.45 ns with 5 ns to spare standalone. | A6 | timing closes in the full design; A7 benchmark ≈ +25–30 % |
| D2 | Line port to the DDR3: expose the 040 cache's fill/write-back request from the compat top (it is stubbed at `:434`; this is core-side work, upstream has no line port in this checkout) and connect it to `ddr3_fastram`'s existing 16-byte line CDC, bypassing `cpu_cache_new` and the 16-bit adapter for board 3. Chip RAM and board 1 stay on the 16-bit path. | A6 | a line fill = one CDC round trip instead of eight sub-cycles |
| D3 | Sibling 37.8 MHz clock for the CPU island, `clkena_in` = handshake only, multicycles removed — option 1b. | D1 | `report_exceptions` shows none on the core |

### Stage E — both cores in one bitstream, OSD-selected (M, bounded experiment)

Both kernels under the wrapper's `generate`, selected by `cpu_config[1:0]`
latched at reset ("11" = AP040, else TG68K in its 68000/010/020 mode); the
unselected core held in reset with `clkena` low; the kernel-side outputs
muxed (one LUT level on paths that have a 3-cycle budget); two kernel
multicycle sets in `cpu.xdc`. Then the real question: place and route at
≈ 71 %.

Accept if WNS ≥ 0 on the CPU island with the SDRAM read path no worse than
today's −0.544 ns. Otherwise stop, keep the two bitstreams, and record the
numbers. Time-box: two build iterations, no re-architecting to make it fit.

### Stage F — NetBSD/amiga (optional, M)

Walker port from B, the restart-model caveat above. Not on the AmigaOS path.

## Verification, collected

* `lib/AP68040/tb/run_tests.sh` — core alone, with the RAM override (0.2).
* `sim/ddr3_cpu` with `CPU_CORE=AP040` — wrapper + DDR3 chain + chipset model;
  extended in A5 and B2. Sequential runs only.
* `sim/autoconfig` — unchanged, guards the Zorro side.
* Hardware, per stage, always by reprogramming; `ShowConfig`, `avail`, ATK on
  both boards, then the stage's own test. The WinUAE `cputest` corpus is a
  native Amiga program; running it on the board after B3 is the strongest
  integration check available and costs nothing to set up.

## Risks

| Risk | Shows as | Mitigation |
|---|---|---|
| Timing at 64 % (sole) / 71 % (dual) with 40-level paths and the DDR3 island | negative WNS on the kernel island | stage order: sole core first at 28 MHz; D1/D3 only after A6; E time-boxed |
| `dpram` read-during-write semantics changed by the Xilinx-inferable form | cache/ATC stale for one cycle on a same-row collision | `tb_ap040_cache_snoop.v` in 0.2 |
| Free-running watchdog inside the multicycle set | wrong constraint, TIMING-46 | exclusion in 0.3 |
| 040 CACR → `cpu_cache_ctrl` mapping | external cache never enabled, or never cleared | A5 checks the mapping explicitly |
| `longword` / split-cycle contract differs from TG68K's in a corner | AGA longword chip access or `longword_en` DDR3 write corrupts | A5 covers both paths |
| The SoC never raises `berr`; the 040 expects bus errors on empty space | software that probes memory by trapping sees $FFFF instead | same as today with the TG68K; B1 can add it for walker accesses |
| The open intermittent DDR3 Guru (`findings/ddr3`) | the 040's internal caches change the access pattern on board 3 — may hide it, may expose it | keep the `ddr_ready`-triggered capture on the list; ATK on board 3 in A6 |
| `68040.library` enables the MMU before stage B | boot dies at SetPatch | A6 boots without startup-sequence first, and the failure is the documented exit condition |

## Numbers to fill in as they are measured

| | Value | Where |
|---|---|---|
| AP68040 self-tests at 0e76761 with the RAM override | — | 0.2 |
| `bench_loop` cycles per instruction, AP040 / TG68K | — | 0.2 / A7 |
| Post-route WNS, sole-core build, kernel island | — | A6 |
| Fast-RAM benchmark, TG68K vs AP040, 28 MHz | — | A7 |
| Same after D1 (37.8 MHz) and D2 (line port) | — | D1 / D2 |
| Post-route LUTs and WNS, dual-core build | — | E |
