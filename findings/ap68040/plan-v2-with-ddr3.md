# AP68040 with MMU and FPU — implementation plan, second edition

Date 2026-09-06, updated 2026-09-07. Status: **stage 0 done, stage A's RTL
done and simulating; nothing on hardware yet.** The AP68040 runs the
`sim/ddr3_cpu` program through this project's wrapper and DDR3 chain. See
"Log" near the end for what was found on the way.
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

## Timing

### What the CPU island is today, and why the 040 fits in it unchanged

`clk_114` is 113.4375 MHz, 8.815 ns. The CPU does not run at that rate: the
kernel advances only on `clkena`, which the wrapper builds
(`TG68K.vhd:499`) from `enaWRreg` — pulsed by `sdram_ctrl.v:343-360` on
phases 2, 6, 10 and 14 of its 16-phase round, i.e. every 4th `clk_114`,
28.36 MHz — further gated on bus readiness (`mem_ready`, chipset
`ena7RD/WR`, `sel_undecoded_d`, `akiko_ack`). Every kernel register therefore
holds for at least 4 cycles, which `cpu.xdc` turns into:

| Path | Exception | Budget |
|---|---|---|
| kernel → kernel, kernel → wrapper | `-setup -start 4 / -hold -start 3` | 35.26 ns |
| kernel → memory side (`sdram`, `minimig`) | `-setup -start 3 / -hold -start 2` | 26.45 ns, because `sdram_ctrl` wants the address one cycle before chip-select |
| wrapper `addr*` registers → memory side | same 3-cycle rule | 26.45 ns |

The AP68040, placed and routed on its own at 45 % of the device with the
RAM fix: worst path **21.0 ns**, 39–40 logic levels, 66 % of it routing;
of the 5,000 worst endpoints, **0** exceed 26.45 ns and 1,148 exceed
17.63 ns ([performance.md](performance.md), [synth-reports/histogram.txt](synth-reports/histogram.txt)).
So under today's 4-cycle regime the core has 14 ns of margin; under a
3-cycle regime 5.4 ns standalone. The TG68K's in-system worst is 19.4 ns for
comparison — the 040 is the same class of path, not a harder one. Its
outputs to the bus are registered and change only on `clkena` edges
(`ap040_bus16_adapter.v` header), so the 3-cycle rule on kernel → memory is
satisfied for the same reason it is for the TG68K. The FPU is already inside
the 21.0 ns figure (full configuration was measured), and its 16 DSP48s sit
in the same multicycle island.

Conclusion: **stage A changes no clock and no exception values**; only the
three cell-set definitions in `cpu.xdc` move to the new instance.

### Where it can still go wrong, in order of likelihood

1. **The clock-enable net.** `clkena` is a *combinational* signal in the
   wrapper fanning out to the CE pin of every kernel flip-flop. The TG68K has
   roughly 2–3k of those; the AP68040 has **7,391**. That net is a genuine
   single-cycle path (enable source → CE, 8.815 ns) and no multicycle covers
   it. Vivado will replicate a high-fanout net, but a 7k-fanout CE driven by a
   LUT is the one path in this swap that is *new*, not just bigger. Watch it
   first in the A6 timing report. Mitigation ladder: let `phys_opt_design`
   replicate; then `MAX_FANOUT` on the wrapper's `clkena`; then register a
   duplicate enable tree in the wrapper — which shifts the kernel by one
   `clk_114` relative to the SDRAM round and must be re-benched in
   `sim/ddr3_cpu` before it is trusted, since the bus contract counts
   completions on that enable.
2. **Free-running logic inside the kernel set.** The compat top's stall
   watchdog counts on the raw clock by design (`ap040_tg68k_compat.v:14-28`),
   and `ap040_bus_timeout.v` may too. Their registers are single-cycle and
   must be *excluded* from the multicycle cell set, or Vivado relaxes them
   (TIMING-46 would flag some, not all). Step 0.3 finds them by reading for
   `always` blocks not qualified by `ce` and excludes them by instance name.
3. **Congestion at 64 %, then 71 %.** The 21.0 ns was measured at 45 %
   utilisation with nothing else on the die. Budget 10–20 % degradation
   in-system: 23–25 ns, still inside 35.26 with room, but *outside* the
   3-cycle 26.45 ns once the safety margin is counted. That is why the
   37.8 MHz option (D1) is a measured experiment after A6, never assumed.
4. **The SDRAM read path** (`clk_gen_sdram → clk_114`, 16 endpoints,
   −0.544 ns today, fix-12 reverted). It is I/O timing at the SDRAM bank, not
   CPU logic, but 28.7k extra LUTs change the placement around the
   `sdram_controller` pblock (`wizard.xdc:59-64`). Sign-off rule: no worse
   than today. If it degrades, add a pblock for the CPU island on the far
   side of the die from the SDRAM I/O before touching anything else.
5. **The DDR3 side is untouched.** No new clock crossing: the 040 sits behind
   the same `cpu_cache_new`/`ddr3_fastram`/`ddr3_cdc` chain, and the
   `set_max_delay -datapath_only` bounds in `ddr3.xdc` do not change. The
   040's caches change the *traffic* (8-sub-cycle line fills, copy-back
   writes) but not any timing path. The island's own slack (2.27 ns intra
   `clk_ddr100`) is unaffected.
6. **Stage B walker requester.** Its address register drives the `cpuaddr`
   mux → `sel_*` decode → memory side. Name it to match the existing
   `addr*` filter in `cpu.xdc` (or extend the filter) so it gets the 3-cycle
   rule the kernel address gets; it holds its value until `walker_ack`, so the
   rule is honest. The mux itself is one LUT level on a 26.45 ns path.
7. **Stage E dual-core.** The kernel-output mux is one LUT level on 3-cycle
   paths — fine. The unselected core is held in reset with `clkena_in` low:
   its registers are static, so it costs routing resources but no timing
   paths that matter. Both kernel instances get their own cell set. The
   select is latched at reset (`cpu_config` bit 4 below) and is quasi-static;
   `set_false_path -from` that register keeps it out of the CE-path report.
   What decides E is not any of this but item 3 at 71 %.

### Sign-off per stage

| Stage | Must hold |
|---|---|
| A6 | kernel island WNS ≥ 0 under `-start 4`; CE net WNS ≥ 0 with no replication warnings left unresolved; SDRAM read path ≥ −0.544 ns (no worse than today); DDR3 CDC exceptions unchanged in `report_exceptions` |
| D1 | same under `-start 3 / -hold -start 2` on the kernel island; measured, two build iterations maximum |
| D3 | `report_exceptions` shows no multicycles on the core at all (sibling 37.8 MHz clock, slow→fast 1:3 rule as `dll_28 → clk_114` uses) |
| E | A6's rules at ≈ 71 %; two build iterations, then stop |

### Calendar

Critical path to a usable MMU + FPU 68040 at 28 MHz: stage 0 (S) → A (M,
one hardware session at A6) → B (S–M, one hardware session at B3) → C (S).
Roughly one to two weeks including bench time, with three hardware sessions
(A6, B3, C). D and E are afterwards and independent of each other.

## OSD and firmware

### How the CPU setting reaches the RTL today

`fw/ctrl_832/osd.c:880` `ConfigCPU()` sends `OSD_CMD_CPU` (0x14) followed by
one byte, `cpu & 0x0f`. `rtl/minimig/userio_osd.v:416` takes `wrdat[3:0]`
into `t_cpu_config`; bits 1:0 (CPU type, the TG68K's `cpu(1:0)`) are copied
to `cpu_config` **only while reset is active** (`:83-89`), bits 3:2 (turbo
chip / kick) immediately. `cpu_config[3:0]` runs `userio.v` → `minimig.v` →
`minimig_virtual_top.v:214` → `.cpu(cpu_config[1:0])` on the wrapper. The
menu (`menu.c:85`) shows `config_cpu_msg[] = {"68000", "68010", "-",
"020 alpha"}` indexed by `config.cpu & 3` and cycles 0 → 1 → 3, skipping 2
(`:1323-1326`). `config.cpu` is saved to the SD-card config file as is.

The firmware already reads something back from the core:
`fpga.c:205-209` sends `OSD_CMD_VERSION` (0x88) and clocks four bytes,
`rtl_ver` in `userio_osd.v:588-596`, selected by `dat_cnt[2:0]` — a 3-bit
index of which only 0–3 are used; 4–7 fall to `default` and return
`MINION_VER`. That is the hook.

### Changes, by build

**Sole-core AP040 build.** The wrapper ignores `cpu(1:0)` (its 68040 branch
fixes 32-bit decode on). The OSD must say so rather than offer a choice that
does nothing:

| Where | Change |
|---|---|
| `userio_osd.v` | `rtl_ver` case gains `3'd4: 8'hA4` (a magic byte) and `3'd5: CORE_CAPS`. Old cores return `MINION_VER` for both, so a firmware that sees anything but 0xA4 in byte 4 knows there is nothing to read. `CORE_CAPS` is a parameter plumbed down from the top: bit 0 AP040 fitted, bit 1 AP040 *selectable* (dual build), bit 2 FPU, bit 3 MMU. Bytes 0–3 unchanged, so old firmware keeps working. |
| `minimig.v`, `userio.v` | pass `CORE_CAPS` through |
| `minimig_openaars_top.v` | `CORE_CAPS` derived from `CPU_CORE` and the AP040 parameters |
| `fpga.c:205` | clock two more bytes after the four; keep `core_caps` in a global (0 unless byte 4 == 0xA4); append " 68040" (and "/FPU", "/MMU") to the boot banner |
| `menu.c` | if `core_caps & 1` and not `& 2`: CPU line reads "68040", not selectable (skip `menusub == 0` in the select handler) |

Turbo chip / Kick stay as they are. (With the MMU on and MuFastROM in use,
turbo Kick is redundant for 040 users, but it is harmless and the menu does
not need to know.)

**Dual-core build (stage E).** The select must survive the same rules as
the CPU type: applied at reset only, and the RTL — not the firmware — is the
authority on whether it exists.

| Where | Change |
|---|---|
| `osd.c` `ConfigCPU` | send `cpu & 0x1f` |
| `userio_osd.v` | `t_cpu_config` and `cpu_config` become `[4:0]`; bit 4 is copied under reset next to bits 1:0, so a core switch takes effect at the next reset exactly as a CPU-type change does today |
| `userio.v`, `minimig.v`, `minimig_virtual_top.v` | widen to 5 bits; the wrapper gets `.cpu(cpu_config[1:0])` and `.core_sel(cpu_config[4])` |
| `TG68K.vhd` | in the dual build, `core_sel` picks the kernel; the unselected one is held in reset with `clkena_in` low. In a sole build the port is unused. |
| `menu.c` | when `core_caps & 2`: cycle 68000 → 68010 → 020 → **68040**; 68040 encodes as `config.cpu` bit 4 set with bits 1:0 = 11 (so an old core that only looks at bits 1:0 gets the TG68K in 020 mode — the closest thing). Leaving 68040 clears bit 4. |
| `config.c` | nothing: bit 4 lives inside the `unsigned char` that is already saved, and the load path does not mask it (checked: `config.c:337` only sets the default 0, `:428` passes the byte to `ConfigCPU` as is). |

Compatibility both ways: old firmware + new core sends bit 4 = 0 → TG68K
selected in a dual build, ignored in a sole build. New firmware + old core
reads byte 4 ≠ 0xA4 → `core_caps` = 0 → menu exactly as today.

One behaviour to keep: the firmware does not reset the machine when the CPU
type changes; the user does. Same for the core select. If that is felt to
be a trap, `menu.c` can call `OsdDoReset` when bit 4 changes — a one-line
addition, but a change in behaviour, so it is a decision, not a default.

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
| A4 | OSD: the capability bytes on `OSD_CMD_VERSION` and the firmware side of "OSD and firmware" above, sole-core rows. The wrapper ignores `cpu(1:0)` in the AP040 branch; the menu says "68040" because the core told it so, not because it was built that way. | firmware built; boot banner shows 68040/FPU/MMU on the AP040 bitstream and is unchanged on the TG68K one |
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

Both kernels under the wrapper's `generate`, selected by `cpu_config[4]`
latched at reset (the dual-build rows of "OSD and firmware": bit 4 = AP040,
else TG68K in the 68000/010/020 mode bits 1:0 select); the unselected core
held in reset with `clkena` low; the kernel-side outputs muxed (one LUT
level on paths that have a 3-cycle budget); two kernel multicycle sets in
`cpu.xdc`; `CORE_CAPS` bit 1 set so the menu offers the choice. Then the
real question: place and route at ≈ 71 %.

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

## Log

**2026-09-07, stages 0 and A (RTL).** Core vendored and pinned; RAM primitive
replaced and the core's own suite run against it; wrapper generate, snoop
path and constraints written; the AP68040 ran the full `sim/ddr3_cpu` program
through this project's wrapper and DDR3 chain on the first attempt.

Two bugs, both mine, both the same shape -- something moved and a downstream
reference still named the old place, and neither is visible to any bench:

* `z3ram3_base` was declared and consumed but never driven between `minimig`
  and `TG68K`; an undriven wire synthesises to zero, the board-3 decode then
  matched `$00`, and the machine black-screened as soon as the OS configured
  that board.  Synthesis warned about nothing.  (That one is the DDR3 work,
  fixed under `findings/ddr3/`, but it is the same lesson.)
* Making the kernel a generate renamed it: Vivado calls a VHDL if-generate
  instance `<label>.<instance>`, so every cell moved from
  `tg68k/pf68K_Kernel_inst/...` to `tg68k/g_tg68k.pf68K_Kernel_inst/...`.
  `cpu.xdc` and `wizard.xdc` both still named the old path, so twelve
  multicycle exceptions were dropped and a bitstream was written with no CPU
  timing exceptions at all.

Also: an XDC file is not general Tcl.  `foreach` is rejected outright
(Designutils 20-1281), which silently produced empty filter strings and cost
a build before the log said so.

**Rule for the rest of this work:** after moving or renaming anything in the
hierarchy, query the netlist for the new path and check the cell counts
before trusting a constraint or spending a build on it.  `read_xdc` against an
open run takes a minute and would have caught both.

**2026-09-07, first AP040 bitstream.** It fits and the CPU island closes:
43,750 LUTs (69 %, ILA included) and `clk_114` at +0.290 ns with no failing
endpoint.  Getting there took one more fix of the same family.

The first build failed `clk_114` at −0.436 ns on 18 endpoints -- all of them
from a *single* register, and all wrapper-to-kernel while kernel-to-kernel was
clean, so the multicycle island was working and the path was simply new.  It
was new because of the snoop: taking `cache_snoop_addr` as a raw tap on
`sdram_ctrl`'s `chipAddr` closed a loop from the CPU wrapper's address
register, out through `minimig`, through `sdram_ctrl` combinationally, and
back into the 040's cache tag RAM across the die -- 14 logic levels.
Registering the exported pair fixed it outright.

Worth recording why that fix and not a constraint: a wrapper-to-kernel
multicycle would have been the easy answer and would also have covered
`datatg68_c`, which is registered every cycle and feeds the core's `data_in`.
Relaxing that would have been wrong in the way `findings/constraints/fix-04`
is about.

**Two numbers to carry forward.**  Block RAM is at 82 %, not LUTs, and that is
what will decide stage E: the 040's caches and ATC are BRAM-hungry and a
second core cannot have 82 % again.  And the SDRAM read path is −0.643 ns
against −0.544 in the TG68K build, so the sign-off rule stated above ("no
worse than today") is **not met** -- about 0.1 ns of congestion.  It is the
same known path that fails in every build of this design and works on
hardware, but if the AP040 bitstream shows SDRAM flakiness where the TG68K one
does not, this is the first suspect, and a pblock keeping the CPU island away
from the SDRAM bank is the lever.

## Risks

| Risk | Shows as | Mitigation |
|---|---|---|
| Timing at 64 % (sole) / 71 % (dual) with 40-level paths and the DDR3 island | negative WNS on the kernel island | stage order: sole core first at 28 MHz; D1/D3 only after A6; E time-boxed |
| The `clkena` net: combinational, fanning out to 7,391 CE pins, single-cycle | negative WNS on enable → CE paths, or a replication storm | "Timing" item 1: watch it first at A6; `MAX_FANOUT`, then a registered enable tree re-benched in `sim/ddr3_cpu` |
| SDRAM read path degrades with the placement change | `clk_gen_sdram → clk_114` worse than −0.544 ns | CPU-island pblock away from the SDRAM bank; sign-off rule "no worse than today" |
| Firmware and core disagree about which CPUs exist | menu offers a choice the RTL ignores, or hides one it has | capability bytes behind a magic value on `OSD_CMD_VERSION`; old/new compatibility both ways in "OSD and firmware" |
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
| AP68040 self-tests at 0e76761 with the RAM override | **all 11 pass**, cache_snoop included | 0.2, 2026-09-07 |
| `sim/ddr3_cpu` with CPU_CORE=AP040, smoke (PATBYTES=64) | **PASS + backdoor PASS**, first run | A5, 2026-09-07 |
| Program phase 6 reached, AP040 vs TG68K, same program | 287 us vs 141 us | A5 smoke; 16-bit split transfers, 040 internal caches off |
| `bench_loop` cycles per instruction, AP040 / TG68K | — | 0.2 / A7 |
| **Post-route, sole-core AP040 build with ILA** (2026-09-07) | | |
|   LUTs / FF / BRAM / DSP | **43,750 (69 %)** / 26,335 (21 %) / **111 (82 %)** / 28 | A6 |
|   `clk_114` (the CPU island) | **+0.290 ns, 0 failing endpoints** | A6 |
|   `clk_ddr100` | +1.774 ns, 0 failing | A6 |
|   `clk_gen_sdram` → `clk_114` (the known SDRAM read path) | **−0.643 ns, 16 failing** (TG68K build: −0.544) | A6 |
| Post-route WNS on the `clkena` → CE paths | not the limit; no CE path in the top 40 violators | A6 |
| Fast-RAM benchmark, TG68K vs AP040, 28 MHz | — | A7 |
| Same after D1 (37.8 MHz) and D2 (line port) | — | D1 / D2 |
| Post-route LUTs and WNS, dual-core build | — | E |
