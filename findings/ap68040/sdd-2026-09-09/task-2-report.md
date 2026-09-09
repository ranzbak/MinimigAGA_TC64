# Task 2 report: Vivado build of the x3-core state, timing sign-off

HEAD at start: 4b033dc (branch v5.0). Not checked out, rebased, or touched
during this task; submodule left as pinned.

## Pre-build checks

**Baseline ILA state (finding).** `build/stage_ap040_ddr3only` (the bitstream
on the board today) was NOT built with ila=0. The only build log for it
(`/tmp/claude-1000/.../aff1ffcf.../scratchpad/build_ddr3only.log`, session
start 2026-09-08 19:55:15, matching the bit/ltx mtimes 20:17/20:18) shows the
command `-tclargs build/stage_ap040_ddr3only 1` -- i.e. **ila=1**. In
`build_ap040.tcl` a single `$ila` argument gates BOTH `DDR3_FASTRAM_ILA` and
`CPU040_DEBUG_ILA` (`set_property generic "... DDR3_FASTRAM_ILA=$ila
CPU040_DEBUG_ILA=$ila" ...`), and the baseline directory has a `.ltx` file,
confirming a debug build. So the "current board bitstream" the brief calls
the ila=0 shipping config is actually the ila=1 (both ILAs) config.
Consequence: baseline paid the ILA congestion cost the script's own comment
describes (~0.4 ns on the TG68K-ALU-to-cache path from `ila_cpu040`, plus
`ila_fastram`'s ~3.9k LUTs) -- with `PHYS_OPT_DESIGN`/`POST_ROUTE_PHYS_OPT_DESIGN`
forced on specifically to claw that back. That phys_opt force is
unconditional in `build_ap040.tcl` (outside the `if {$ila}` block), so it
applies the same way to every build this task makes; it is only the ILA
congestion itself that differs. Net effect: the task-2-x3 ila=0 build being
compared against this baseline is not a like-for-like congestion match --
the x3 ila=0 build should have MORE timing margin than the baseline for
reasons unrelated to the x3 core, because it carries no debug logic at all.
A pass against baseline is therefore a weaker signal than the brief assumed;
a fail would be unambiguous. Proceeding per the explicit addendum (build
`build/stage_ap040_x3` ila=0 first and sign off on it) since that instruction
is unambiguous about which two configurations to produce.

**`ap040_fill_cdc.v` / build.tcl vs build_ap040.tcl (finding).**
`tools/vivado/build_ap040.tcl` does NOT `source` `tools/vivado/build.tcl` (no
such call anywhere in its 341 lines), and it does NOT itself contain an
add_src loop for the AP68040 core files -- that loop (`ap040_tg68k_compat`,
`ap040_core`, ..., `ap040_fill_cdc`) exists only in the base
`tools/vivado/build.tcl`. `build_ap040.tcl` instead assumes those sources are
already members of the persistent Vivado project (`sources_1` fileset in
`project_1/project_1.xpr`). Checked `project_1/project_1.xpr` directly: it
lists 10 of the 11 AP68040 files (`ap040_tg68k_compat`, `ap040_core`,
`ap040_alu`, `ap040_muldiv`, `ap040_regfile`, `ap040_fpu`, `ap040_mmu`,
`ap040_cache`, `ap040_bus16_adapter`, `ap040_bus_timeout`,
`ap040_walker_cdc`) but NOT `ap040_fill_cdc.v`. So neither condition in the
brief's caveat holds: `build_ap040.tcl` will not add it, and it is not
already in the project. **`ap040_fill_cdc.v` will not enter the project by
running `build_ap040.tcl` alone.**
Checked whether this matters: `grep -rn ap040_fill_cdc` across the whole repo
finds only its own module declaration (`lib/AP68040/rtl/ap040_fill_cdc.v:18:
module ap040_fill_cdc`) -- nothing instantiates it anywhere, consistent with
the commit message "fill channel declared but not routed" (Task 1: the x3
overlay ties the fill port group off and leaves `ap040_fill_cdc` unused).
So its absence from the project is currently harmless for this build (no
missing-module elaboration error expected), but it is a real gap: Task 3
(routing the fill channel) will need `build.tcl`'s add_src loop to actually
run once, or `build_ap040.tcl` updated to add it itself, before that file can
be synthesized.

## Commands run

```
mkdir -p build/stage_ap040_x3
nohup env LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl \
  -tclargs build/stage_ap040_x3 0 \
  > .superpowers/sdd/plan-v2-with-ddr3/build_x3_ila0.log 2>&1 &
```
where `<shim>` =
`/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/8ce939b9-1808-4e35-b059-9f0f27302dc1/scratchpad/shim`
(holds `libtinfo.so.5`). No `-stack`. Vivado called by absolute path, not the
`vivado` shell alias.

Start: 2026-09-08 23:18:23 (local). End: 2026-09-08 23:38:51 (Vivado's own
"Exiting Vivado at" line). **Wall clock: 20 min 28 s.** `.bit` copied,
`.ltx` correctly NOT produced (no debug cores at ila=0; matches the
`build_ap040.tcl` "WARNING minimig_openaars_top.ltx not produced" line, which
is expected here, not an error).

A follow-up read-only query (`open_checkpoint` on the same build's
`minimig_openaars_top_postroute_physopt.dcp`, then `report_timing -from
clk_114 -to clk_114 -max_paths 10`) was run to name the second clk_114
endpoint that `report_timing_summary` does not enumerate on its own (it only
prints the single worst path per group). No re-implementation; same
checkpoint the bitstream came from.

## Sign-off table, ila = 0 (build/stage_ap040_x3) vs baseline (build/stage_ap040_ddr3only)

| clock / path | baseline (ila=1) | x3, ila = 0 | verdict |
|---|---|---|---|
| clk_114 WNS | −0.588 ns, 1 failing endpoint: `g_ap040.ap040/mmu/atc_ram/mem_reg_3 -> g_cache.cache/look_snooped_reg`, req 8.815 ns | **−0.347 ns, 2 failing endpoints** (both listed below) | **better WNS**; endpoint count +1, explained below -- see verdict note |
| clk_gen_sdram → clk_114 (SDRAM read path) | −0.602 ns, 16 failing endpoints (design-summary total of 17 = this 16 + the 1 clk_114-intra failure above -- brief's "17" is the design-wide figure, not this pair's) | **−0.510 ns, 16 failing endpoints** | **better WNS, same endpoint count** -- pass |
| clk_ddr100 | (not separately called out in baseline; intra-clock clk_ddr100 in baseline report: no WNS entry, i.e. all paths pass; inter clk_ddr100->clk_114 WNS +6.731 ns) | intra-clock clk_ddr100: no failing entries; inter clk_ddr100->clk_114 WNS **+7.592 ns**, 0 failing | pass, improved |
| DDR3 CDC `set_max_delay -datapath_only` exceptions (ddr3.xdc) | present, `ddr3_fastram_i/cdc/req_*_r_reg*` (max_dpo=10) and `cdc/rdata_r_reg*` (max_dpo=8.815) | **present, identical content**, same two lines (now at exceptions.rpt lines 135/138 -- line numbers shifted because the ila=1 baseline report carries extra ILA-related exception rows this build has none of) | unchanged -- pass |
| kernel multicycle sets (cpu.xdc) | populated, `-start 3`/`-hold 2` (`cycles=3(start)`/`cycles=2(start)` in report_exceptions) on `g_ap040.ap040/*`, `*_snooped_reg*` explicitly excluded from the filter | **populated, same filter text, same cycles=3(start)/cycles=2(start) pair, `g_ap040.ap040` referenced 16 times** in exceptions.rpt | unchanged -- pass |
| Design-wide (`Design Timing Summary`) | WNS −0.602 ns, 17 failing endpoints total | **WNS −0.510 ns, 18 failing endpoints total** (16 SDRAM + 2 clk_114-intra) | better WNS; +1 endpoint, same explanation as clk_114 row |

**The two clk_114 failing endpoints in the x3 build, named:**
1. `openaars_virtual_top/tg68k/g_ap040.ap040/mmu/atc_ram/mem_reg_0 -> g_ap040.ap040/g_cache.cache/look_snooped_reg/D`, slack **−0.347 ns** (period 8.815 ns). Same pair as baseline's sole failing endpoint (register index in the ATC RAM differs cosmetically -- `mem_reg_0` here vs `mem_reg_3` in baseline -- same source RAM, same destination register).
2. `openaars_virtual_top/tg68k/g_ap040.ap040/mmu/atc_ram/mem_reg_0 -> g_ap040.ap040/g_cache.cache/st_snooped_reg/D`, slack **−0.262 ns**. **New in this build.**

**Verdict on the new endpoint (`st_snooped_reg`).** Per the brief's rule, checked
whether it is free-running (not ce-qualified) in the x3 source before calling
this a constraint problem. `lib/AP68040/rtl/ap040_cache.v:345-397`: `st_snooped`
is set unconditionally (`if ((wr_accept_upd && snoop_st_row_acc) || (st_chk &&
...)) st_snooped <= 1;`, no `ce &&` guard on the set path) and only cleared
under `ce` -- the file's own comment at line ~334 says so explicitly: "Both
flags are set free-running -- the snoop is -- and consumed/cleared in the ce
domain" (same sentence covers `look_snooped`, "as for look_snooped" a few
lines down for `st_snooped`). It is the same violation class as the existing
`look_snooped_reg` endpoint, not a new one, and `cpu.xdc:86` already excludes
it: the kernel multicycle set's filter carries `NAME !~ *_snooped_reg*`, a
wildcard written before this commit that already matches `st_snooped_reg` by
name. Confirmed in `exceptions.rpt` line 65-66: the `-start 3 -hold 2` kernel
set's filter text includes `*_snooped_reg*` in its exclusion, so `st_snooped_reg`
was correctly left OUT of the kernel multicycle set and is timed at the plain
single-cycle 8.815 ns period, same as `look_snooped_reg` always was. This
matches the plan doc's own Task-1 ledger note ("`st_snooped` is the one new
free-running register and the existing `*_snooped_reg*` wildcard already
excludes it").

**Rule check (from the brief): no path worse than baseline, kernel sets
populated, CDC exceptions unchanged.** All three hold. clk_114 WNS improved
(−0.347 vs −0.588 ns) despite one more endpoint in the same pre-existing,
by-design free-running category; SDRAM path WNS improved (−0.510 vs −0.602 ns)
at the same endpoint count; kernel sets populated identically; CDC exceptions
byte-for-byte the same two lines. **Sign-off: PASS**, with the caveat recorded
above under "Pre-build checks" that baseline itself was an ila=1 build, so
this x3 ila=0 build had less congestion to begin with -- the comparison is
valid (both rules are about not regressing) but not perfectly like-for-like.

## Utilization

| | baseline (ddr3only, ila=1) | x3, ila = 0 |
|---|---|---|
| Slice LUTs | 45619 / 63400 (71.95 %) | **40127 / 63400 (63.29 %)** |
| Slice Registers | 29158 / 126800 (23.00 %) | **19316 / 126800 (15.23 %)** |
| Block RAM Tile | 125.5 / 135 (92.96 %) | **59.5 / 135 (44.07 %)** |
| DSPs | 28 / 240 (11.67 %) | **28 / 240 (11.67 %)** |

The large drop in LUT/FF/BRAM vs. baseline is expected and not attributable to
the x3 core: baseline carries `ila_cpu040` (8 probes, 4096 deep) and
`ila_fastram` (24 probes incl. two 128-bit ones, 4096 deep, two match units on
four probes) -- BRAM alone accounts for most of the 66-tile difference. DSP
count identical (unaffected by either core or ILA).

## Build 2: ila = 1 (build/stage_ap040_x3_ila) -- reported, NOT signed off

Command (same shim, same absolute Vivado path):
```
nohup env LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl \
  -tclargs build/stage_ap040_x3_ila 1 \
  > .superpowers/sdd/plan-v2-with-ddr3/build_x3_ila1.log 2>&1 &
```
Start: 2026-09-08 23:43:06. End: 2026-09-09 00:09:52. **Wall clock: 26 min 46 s.**
Both `.bit` and `.ltx` produced (expected: `CPU040_DEBUG_ILA=1` and
`DDR3_FASTRAM_ILA=1`, so both `ila_cpu040` and `ila_fastram` are present).

| | ila = 1 value | for reference: ila = 0 | for reference: baseline (ila=1) |
|---|---|---|---|
| `clk_114` WNS, failing endpoints | **−0.753 ns, 210 failing endpoints** | −0.347 ns, 2 | −0.588 ns, 1 |
| `clk_gen_sdram` → `clk_114` WNS, failing endpoints | **−0.508 ns, 16 failing** | −0.510 ns, 16 | −0.602 ns, 16 |
| Design-wide WNS, total failing endpoints | −0.753 ns, 226 | −0.510 ns, 18 | −0.602 ns, 17 |
| Slice LUTs | 45,635 / 63400 (71.98 %) | 40,127 (63.29 %) | 45,619 (71.95 %) |
| Slice Registers | 29,266 / 126800 (23.08 %) | 19,316 (15.23 %) | 29,158 (23.00 %) |
| Block RAM Tile | 125.5 / 135 (92.96 %) | 59.5 (44.07 %) | 125.5 (92.96 %) |
| DSPs | 28 / 240 (11.67 %) | 28 | 28 |

Worst clk_114 path in the ila=1 build: same pair as the new x3 ila=0
endpoint -- `g_ap040.ap040/mmu/atc_ram/mem_reg_2 -> g_cache.cache/st_snooped_reg`,
slack −0.753 ns, 11 logic levels (`CARRY4=2 LUT6=9`). Utilization is close to
the ila=1 baseline (both carry both debug cores; the small LUT/FF deltas are
from the x3 cache logic itself, same as the ila=0 vs ila=0-baseline
comparison would show if baseline had one).

**Not signed off, per the addendum -- but flagged here because the number is
larger than the addendum's own expectation.** The addendum says "ILA
congestion is known to cost ~0.1 ns"; the actual cost measured here is
−0.753 − (−0.588) = **0.165 ns worse WNS than the ila=1 baseline**, and,
more strikingly, the failing-endpoint count on clk_114 jumped from 1 (baseline)
/ 2 (x3 ila=0) to **210**. That is not one or two extra free-running snoop
registers -- it is congestion from `ila_cpu040`'s few-thousand LUTs/FFs
(per `build_ap040.tcl`'s own comment) pulling a much larger set of kernel-path
registers into violation, exactly the mechanism the script's comment warns
about ("a debug bitstream that violates setup on the very path being
investigated is worthless"). This build is for Paul's stall capture, not
final sign-off, so per the addendum this is not a blocking finding for this
task -- but it is worth Paul knowing before he reads a stall-capture number
that this bitstream's kernel timing is well outside spec, in case the timing
degradation itself perturbs the capture. Did not enumerate all 210 endpoints
(out of scope for a build that is explicitly not being signed off); the worst
one is named above and is the same register pair as the ila=0 build's new
(explained, benign) endpoint.

## Files changed / commit

- `findings/ap68040/plan-v2-with-ddr3.md`: added the "Post-route, x3-core
  build, ila = 0" and "... ila = 1" rows under "Numbers to fill in as they are
  measured", and a dated Log paragraph ("2026-09-08, stage D task 2").
- No other tracked files touched. `build/stage_ap040_x3/` and
  `build/stage_ap040_x3_ila/` are untracked build output, left in place,
  matching the existing pattern of every other `build/stage_*` directory.
- Did NOT stage or touch Paul's pre-existing uncommitted edits
  (`fw/ctrl_832/version.h`, `sim/hostcpu-i2c-bridge/*.wcfg`,
  `tools/vivado/ila_fastram_check.py`, `sim/ddr3_cpu/xsim_run_*.log`) or any
  untracked scratch files (`bad.txt`, `build/`, etc.).
- Commit: only `findings/ap68040/plan-v2-with-ddr3.md`, by explicit path.

## Concerns

1. **Baseline was built with ila=1, not ila=0.** The brief's "the same
   configuration as the current board bitstream" premise for the ila=0 build
   does not hold; see "Pre-build checks" above. Sign-off is still valid (both
   rules are "no regression"), but Paul should know the margin comparison
   flatters the x3 ila=0 build somewhat -- it is not carrying the ILA tax the
   baseline paid.
2. **`ap040_fill_cdc.v` is not in the Vivado project.** Harmless today
   (nothing instantiates it), but blocks Task 3 until `build.tcl`'s add_src
   loop is run once against this project, or `build_ap040.tcl` is given its
   own add_src for the AP68040 file list.
3. **ila=1 build's clk_114 timing is far outside the addendum's "~0.1 ns"
   expectation** (210 failing endpoints, WNS −0.753 ns). Not a sign-off
   requirement for this build, but worth a heads-up before using it for the
   stall capture.
4. A parallel, read-only code review of commit 4b033dc was running alongside
   this build per the controller's instructions; if it surfaces an RTL
   finding, both bitstreams in this task would need to be rebuilt. Not
   actioned here per instructions ("the controller will tell you").
