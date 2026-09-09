# Final fix wave -- report

BASE: HEAD 2fb2570 (post final whole-branch review). No RTL changes made in
this wave; documentation, comments, tracked logs, and re-running existing
bench legs only. Two commits, by explicit path:

* `766b057` -- plan doc + comments (items 1-11)
* `0e27660` -- tracked xsim logs (item 13)

## Plan doc: `findings/ap68040/plan-v2-with-ddr3.md`

1. **Ship-build rows added.** Two new rows in the "Numbers to fill in"
   table for `build/stage_ap040_x3fill3` (727e4f4) and
   `build/stage_ap040_x3cad` (b7680d4, the bitstream on the board).
   Numbers confirmed by reading both builds' `timing_summary.rpt` and
   `utilization.rpt` before writing them (x3cad: clk_114 WNS -0.408ns / 2
   endpoints -- confirmed the worst path's destination is
   `g_cache.cache/st_snooped_reg/D`, one of the free-running snoop pair;
   clk_gen_sdram->clk_114 -0.481ns/16; clk_148 +0.024ns/0; LUT 40392
   (`utilization.rpt` "Slice LUTs | 40392"). x3fill3: clk_114 -0.343/3,
   clk_gen_sdram->clk_114 -0.314/16, clk_148 +0.026/0, LUT 40359 --
   confirmed the same way). File:line -- new rows inserted after the
   existing `stage_ap040_x3fill_ila` boot-check row.
2. **Hardware SysInfo line added**, same table location: 0.19x A4000/040-25
   (0e76761) -> 0.23x (x3 core, `stage_ap040_x3_ila`, 2026-09-09 00:25) ->
   still 0.23x with the fill channel (`stage_ap040_x3fill_ila`,
   `stage_ap040_x3cad`, verified 07:36). States plainly that D2 produced no
   SysInfo gain (cache-resident benchmark takes no line fills) and that
   this supersedes the "hardware number still owed" sentence for D2; the
   old row is edited in place to say so rather than left contradicting the
   new one.
3. **Task-3 log paragraph corrected** (the "keeps the CPU alive on
   fl_ack/fl_err" sentence, originally at the paragraph beginning "Two
   things measured on the way"): marked as now-false and superseded, with
   the reason (727e4f4 removed the ack terms because both FSMs release the
   bus before acking, so `bstate = "01"` already covers it) and the timing
   cost (seven new failing CE-net endpoints on `stage_ap040_x3fill2`,
   closed by the removal). Added the two fix rounds as an explicit list:
   (a) undecoded-fill hang, fix round 1, `5a20f8e`; (b) ack-term removal
   with the bench invariant, fix round 2, `727e4f4`.
4. **Task-4 phase-8 figures corrected** in the same log paragraph: the
   1933.2us / 2387.4us pair is now marked as absolute simulation time, with
   the from-release values (1868.8us at five phases, 2323.0us at four)
   given alongside, plus the reconciliation with task 3's 1867.70us + the
   1.128us undecoded-read cost = 1868.83us.
5. **Task-1 numbers annotated**: a new paragraph after the -2.97% / -3.58%
   / -11.07% figures states plainly that the bench's CACR write left the
   68040's internal caches off for that measurement (task 3 found and
   fixed it with `-DCACRVAL`), so those percentages measure the x3 core
   re-gate alone, not the x3 cache fix.
6. **"Five of the sixteen" corrected to four** (2, 6, 10, 14) with a
   pointer to `rtl/sdram/cpu_enable_cadence.v`, in both the task-1
   narrative paragraph (the `ce_core`/duty-cycle bug writeup) and the D1
   numbers-table row. **"82 of 87" fills**: left as-is where it is the
   literal count from that specific historical A/B run (task 3's original
   measurement, before fix round 1 added the undecoded fill), with a new
   parenthetical noting the shipped-state count is 83 channel / 1
   undecoded auto-completed / 5 adapter; the existing D2 log entry that
   already said "83 channel fills, 1 auto-completed, 5 adapter" (task 4's
   paragraph) was already correct and untouched.
7. **One line each added**, after the x3-overlay sentence: `lib/AP68040`
   is on local branch `x3-overlay` (`c5d5cc3`), not fetchable from the
   upstream remote until pushed to a fork; upstream AP68040 `a8a50ce`
   (cache-invalidation race + FPU frame fix) deliberately not merged, to
   keep one variable.

## Comments (no logic changes)

8. `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc`:
   - The kernel-island comment (was ~139-141, now ~150-166): corrected
     "five of the sixteen" to four (2, 6, 10, 14), pointing at
     `rtl/sdram/cpu_enable_cadence.v`; explained that the -start 3/-hold 2
     values are tighter than four phases strictly need (they date from the
     reverted five-phase D1 attempt) and are kept deliberately since they
     cost only unused margin.
   - Two "meet single-cycle today" claims corrected (the `cpu_not_free`
     block comment, was ~82, and the snoop-flags paragraph, was ~106-107):
     both now state that `atc_ram -> {look,st}_snooped` does NOT meet
     single-cycle -- it fails setup by roughly -0.3 to -0.6ns in every
     AP040 build measured, including the pre-x3 baseline, and is named as
     the WNS-defining path on `clk_114`. Both keep the exclusion, now
     explained as correct regardless of whether the path currently meets
     timing.
   - Stale line citations re-derived by grepping `lib/AP68040/rtl` at the
     pinned `c5d5cc3`: `ap040_mmu.v:163` -> `ap040_mmu.v:165-167`
     (l_row/l_tag/l_ld declarations); `ap040_cache.v:253` ->
     `ap040_cache.v:345` (st_snooped) / `:376` (fill_snooped,
     look_snooped); `ap040_core.v:151` -> `ap040_core.v:150ff`
     (ipl_s1 is the first of that register group).
9. `rtl/soc/TG68K.vhd:320`: "five of sixteen phases" corrected to "four of
   sixteen phases (2, 6, 10, 14 -- rtl/sdram/cpu_enable_cadence.v is the
   single source)". `lib/AP68040/rtl/ap040_tg68k_compat.v:133` carries the
   same stale "5 of every 16" wording -- **left untouched**, as instructed:
   the submodule stays pinned at `c5d5cc3`. Recorded here as a known stale
   comment for whoever next touches that branch.
10. `sim/ddr3_cpu/ddr3_cpu_tb.sv:39-42`: the spelled-out phase list
    ("ph2/6/10/14 ... rtl/sdram/sdram_ctrl.v lines ~344-375") replaced with
    a pointer to `rtl/sdram/cpu_enable_cadence.v` as the single source
    shared by `sdram_ctrl.v` and the bench.
11. `sim/ddr3_cpu/run.sh`: added, immediately after the last flag
    (`--chipbus`) is shifted off (line ~125-131, before the region-size
    logic that follows it): `[ $# -gt 0 ] && { echo "run.sh: unknown
    flag(s): $*" >&2; exit 2; }`. Verified `bash -n` is clean and traced
    all six valid single/combination invocations
    (`--ap040 --chipbus`, `--lwmutant`, `--mmu`, `--mmumutant`,
    `--fillmutant`, `--nofill`) to confirm each fully shifts `$@` to empty
    before the guard, so no valid invocation is affected. Not edited while
    any leg was in flight -- edited and committed before item 12's runs
    started.

## Legs (run one at a time, HEAD 2fb2570, after the docs/comments commit)

| Leg | Result | Summary line |
|---|---|---|
| `./run.sh --ap040 --chipbus` | PASS | `DDR3 CPU TB: 2 passed, 0 failed` (9 over the channel, 1 undecoded auto-completed, 5 adapter, 0 bus errors) |
| `./run.sh --lwmutant` | **FAILED as required** | `DDR3 CPU TB: 1 checks failed` -- `FAIL 1895 32-bit-write protocol violations on the RAM port`; script printed `mutant failed as required` |
| `./run.sh --mmumutant` | **FAILED as required** | `DDR3 CPU TB: 1 checks failed` -- `FAIL the program stopped making progress (stall watchdog)`, last phase reached 2; `mutant failed as required` |
| `./run.sh --fillmutant` | **FAILED as required** | `DDR3 CPU TB: 3 checks failed` -- pattern read-back code 2 at phase 2, DDR3 backdoor mismatch in 271 places, and the new undecoded-hole check also failed (no line fill taken); `mutant failed as required` |

All four behaved as specified; nothing to fix, nothing stopped early.

## Tracked logs (item 13)

Commit `0e27660`. The eight logs in the AP040/TG68K test matrix (excludes
`xsim_run_mutant.log`, the TG68K-only mutant, untouched by tonight's AP040
work and not part of this set):

* `xsim_run_pass.log`, `xsim_run_pass_ap040.log` (already current, run
  earlier in the night against the same RTL as HEAD; `pass_ap040.log`
  needed no update at all),
* `xsim_run_pass_ap040_chipbus.log`, `xsim_run_lwmutant_ap040.log`,
  `xsim_run_mmumutant_ap040.log`, `xsim_run_fillmutant_ap040.log` --
  updated/added from the four legs run above,
* `xsim_run_mmu_ap040.log`, `xsim_run_nofill_ap040.log` -- already current
  from earlier in the night, `nofill_ap040.log` newly tracked.

All eight now describe HEAD's RTL (2fb2570, RTL-identical to b7680d4 --
the intervening commit only touched Vivado build-script source lists).

## Not staged / not touched (per instructions)

`fw/ctrl_832/version.h`, `sim/hostcpu-i2c-bridge/*.wcfg`,
`tools/vivado/ila_fastram_check.py`, and all untracked scratch files
remain exactly as they were; not staged, not committed. Vivado was not
run. No subagents were used.
