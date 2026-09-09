# Task 5a report: build the fill-channel state (fb71459), sign off, verify boot over JTAG

HEAD at start: fb71459 (branch v5.0). I did not check out, rebase, or touch
anything myself during this task; submodule left as pinned. **But HEAD did
move during this task, from someone else's commit landing in the shared
working tree while my ila = 1 build was mid-flight** -- see "Mid-task RTL
change" below; HEAD is `5a20f8e` as this report is written. No RTL change was
visible to me before I started (the parallel code review was not consulted;
no controller message had yet arrived reporting one at that point).

## Pre-build checks

**Fill FSM address register vs the brief's `addr*` premise (finding).** The
brief states the rule as "the fill FSM's address register in TG68K.vhd must
be inside the wrapper `addr*` 3-cycle rule ... check exceptions.rpt shows it
in that set and name the cell." Read `task-3-report.md` section 2.7 first, as
instructed, and it says the opposite of what the brief assumes: the register
is `fl_busaddr` (`rtl/soc/TG68K.vhd:342`), and the name was *deliberately*
chosen to sit next to `wk_busaddr` and NOT be matched by the `addr*` filter,
because `fl_busaddr`'s minimum stable window is exactly two cycles
(`FL_SEL -> FL_GAP -> FL_SEL`) and the `-start 2` setup relaxation that filter
grants would let the first capture -- the line-0 word, the only one that can
miss -- close on unsettled data. `cpu.xdc` was not touched in fb71459
(confirmed: `git show fb71459 --stat` lists no `.xdc` file), so there is
nothing to place fl_busaddr into.

Checked the built exceptions.rpt directly (`build/stage_ap040_x3fill/exceptions.rpt`):
`fl_busaddr`, `fl_addr`, `fl_req`, `fl_ack` do not appear anywhere in the file
(`grep` returns nothing), and the `addr*` filter's two lines are byte-identical
in content to the ones in the baseline `build/stage_ap040_x3/exceptions.rpt`
(`NAME =~ openaars_virtual_top/tg68k/addr* && ...`, `cycles=2(start)` /
`cycles=1(start)`, both flagged "Invalid endpoint" -- pre-existing, unrelated
to this build). **`fl_busaddr` is not in that set, by design, and cpu.xdc was
not asked to put it there.** The cell to name, per the brief's own instruction
to "name the cell": `openaars_virtual_top/tg68k/fl_busaddr_reg*` -- absent
from every exception filter in the file, timed at the plain single-cycle
8.815 ns period like `wk_busaddr` always has been. This is reported as a
finding, not treated as an error: the brief's premise does not match the
documented design decision, and I did not touch cpu.xdc or RTL to try to make
it match.

## Commands run

Build 1 (ila = 0, ship):
```
mkdir -p build/stage_ap040_x3fill
nohup env LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl \
  -tclargs build/stage_ap040_x3fill 0 \
  > .superpowers/sdd/plan-v2-with-ddr3/build_x3fill_ila0.log 2>&1 &
```
`<shim>` = `/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/8ce939b9-1808-4e35-b059-9f0f27302dc1/scratchpad/shim`
(holds `libtinfo.so.5`). No `-stack`. Vivado called by absolute path. Waited
with a background `until` loop polling for the `.bit` file or an `^ERROR`
line in the log, not repeated short sleeps.

Start: 2026-09-09 02:57:30. End: 2026-09-09 03:22:21 (Vivado's "Exiting
Vivado at" line). **Wall clock: 24 min 51 s.** `.bit` produced, `.ltx`
correctly NOT produced (ila = 0; matches the expected "WARNING
minimig_openaars_top.ltx not produced" line). No `^ERROR` lines in the log.

A follow-up read-only query (`open_checkpoint` on this build's own
`minimig_openaars_top_postroute_physopt.dcp`, then `report_timing -from
clk_114 -to clk_114 -max_paths 10 -sort_by group`) named the clk_114 failing
endpoints beyond the one `report_timing_summary` prints by default, same
technique task 2 used. No re-implementation; same checkpoint the bitstream
came from. Output: `.superpowers/sdd/plan-v2-with-ddr3/clk114_intra_paths_x3fill.rpt`.

## Sign-off table, ila = 0 (build/stage_ap040_x3fill) vs baseline (build/stage_ap040_x3)

| clock / path | baseline (stage_ap040_x3) | x3fill, ila = 0 | verdict |
|---|---|---|---|
| clk_114 WNS, failing endpoints | −0.347 ns, 2: `atc_ram/mem_reg_0 -> look_snooped_reg` (−0.347), `atc_ram/mem_reg_0 -> st_snooped_reg` (−0.262) | **−0.398 ns, 2: `atc_ram/mem_reg_0 -> look_snooped_reg` (−0.398), `atc_ram/mem_reg_0 -> st_snooped_reg` (−0.251)** | same 2 endpoints, same free-running snoop family, **no new endpoint** -- but WNS is 0.051 ns worse on the `look_snooped_reg` leg. Flagged below, not a new-endpoint violation. |
| clk_gen_sdram → clk_114 (SDRAM read path) | −0.510 ns, 16 failing | **−0.512 ns, 16 failing** | same endpoint count, WNS 0.002 ns worse (noise-level) -- pass |
| clk_ddr100 (intra) | +1.813 ns, 0 failing | **+1.440 ns, 0 failing** | still passing, margin down 0.373 ns |
| Design-wide WNS, total failing endpoints | −0.510 ns, 18 | **−0.512 ns, 18** | same count, 0.002 ns worse -- pass |
| DDR3 CDC `set_max_delay -datapath_only` exceptions (ddr3.xdc) | present, `ddr3_fastram_i/cdc/req_*_r_reg*` (max_dpo=10), `cdc/rdata_r_reg*` (max_dpo=8.815), lines 135/138 | **present, byte-identical content, same lines 135/138** | unchanged -- pass |
| kernel multicycle sets (cpu.xdc), `-start 3`/`-hold 2` | populated, `g_ap040.ap040` referenced 16 times, `*_snooped_reg*` excluded | **populated, identical filter text, `g_ap040.ap040` referenced 16 times, same exclusion** | unchanged -- pass |
| fill address register (`fl_busaddr`) vs `addr*` 3-cycle set | n/a (register did not exist in this build) | **not present in the `addr*` set or any other exception; not present at all in exceptions.rpt** -- see finding above | by design, not a defect; brief's premise did not hold |

**Rule check.** "No path worse; no NEW failing endpoint unless it is the same
snoop family": no new endpoint (both endpoints are the pre-existing
`look_snooped_reg`/`st_snooped_reg` pair, same as baseline and the same as
the plain x3 core before the fill channel). But clk_114 WNS itself is 0.051 ns
worse than the immediately-preceding baseline (`stage_ap040_x3`, itself
already better than the original `stage_ap040_ddr3only` baseline from task 2).
Read literally, "no path worse" is not fully met on this one leg. The
regression is small (0.051 ns), on the same known free-running, by-design
violation this whole family always has (never fixed by constraint, excluded
from the kernel multicycle set by name, timed at the plain 8.815 ns period
since before this stage existed) and consistent with the extra
`fl_active`/`fl_*` logic the fill FSM adds to the kernel island raising local
congestion a little. It is reported here rather than judged pass/fail by me,
per the brief's instruction to report a sign-off violation with the numbers
rather than fix RTL or constraints.

## Utilization

| | baseline (stage_ap040_x3) | x3fill, ila = 0 |
|---|---|---|
| Slice LUTs | 40127 / 63400 (63.29 %) | **40260 / 63400 (63.50 %)** |
| Slice Registers | 19316 / 126800 (15.23 %) | **19628 / 126800 (15.48 %)** |
| Block RAM Tile | 59.5 / 135 (44.07 %) | **59.5 / 135 (44.07 %)** |
| DSPs | 28 / 240 (11.67 %) | **28 / 240 (11.67 %)** |

Small increase in LUT (+133) and register (+312) count, consistent with the
fill FSM (a second bus master, per the fb71459 commit message, "in the same
file and the same shape" as the existing walker) added to `TG68K.vhd`. BRAM
and DSP counts unchanged, as expected (no new memory or arithmetic
structures).

## Mid-task RTL change (coordinator-reported fact, load-bearing for what follows)

**`build/stage_ap040_x3fill` (ila = 0) and `build/stage_ap040_x3fill_ila`
(ila = 1) are NOT built from the same RTL state.** I did not check out,
rebase, or touch anything myself, and the working tree was fb71459 for the
entire ila = 0 build (launched 02:57:30, `.bit`/checkpoint timestamps
03:20-03:22, all before the change below). But Paul's own fix round landed in
the live working tree while the ila = 1 build's synthesis was mid-flight:
`rtl/soc/TG68K.vhd` was modified on disk at 03:30:04 and committed as
**`5a20f8e`** ("A line fill of an address that decodes to nothing completes,
it does not fault") at 04:00:49 -- fb71459 plus a fix so an undecoded-fill
address auto-completes with `$FFFF` via `sel_undecoded` instead of raising
`fill_err` as a bus error. My ila = 1 build's `launch_runs` call started at
03:25:51, but per `project_1/project_1.runs/synth_1/runme.log` the actual
`synth_design` read of sources began at 03:36:50 -- after the 03:30:04 edit.
**So `build/stage_ap040_x3fill_ila` was synthesized from `5a20f8e`, not
fb71459**, even though nothing I did selected that commit; the project reads
sources off disk at synth time, and the disk changed under the running build.
HEAD is `5a20f8e` as I write this.

**Consequence for the numbers below.** The ila = 1 sign-off numbers in the
next section are for `5a20f8e`, not the fb71459 state this task was scoped
to. They are reported as measured, per the coordinator's instruction, but are
not a clean ila = 1 measurement of fb71459 alone -- they include whatever
extra logic the undecoded-fill-completes fix added to the kernel island. The
ila = 0 build is unaffected and is a clean fb71459 measurement. Per the
coordinator: no rebuild here; the controller schedules the ila = 0 rebuild
(and, presumably, an ila = 1 rebuild) against `5a20f8e` separately. The boot
probe below is run on the ila = 1 bitstream as briefed, understanding it is
actually testing `5a20f8e`.

## Build 2: ila = 1 (build/stage_ap040_x3fill_ila) -- reported, NOT signed off, and NOT fb71459 (see above)

Command (same shim, same absolute Vivado path):
```
mkdir -p build/stage_ap040_x3fill_ila
nohup env LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl \
  -tclargs build/stage_ap040_x3fill_ila 1 \
  > .superpowers/sdd/plan-v2-with-ddr3/build_x3fill_ila1.log 2>&1 &
```
Start: 2026-09-09 03:25:32. End: 2026-09-09 04:00:39. **Wall clock: 35 min
7 s.** Both `.bit` and `.ltx` produced (expected: `CPU040_DEBUG_ILA=1` and
`DDR3_FASTRAM_ILA=1`). No `^ERROR` lines in the log.

Same read-only `report_timing` query technique as build 1, against this
build's own `minimig_openaars_top_postroute_physopt.dcp` (checkpoint mtime
03:58, consistent with the 03:59 `.bit`/`.ltx`, i.e. the checkpoint the
bitstream actually came from). Output:
`.superpowers/sdd/plan-v2-with-ddr3/clk114_intra_paths_x3fill_ila.rpt`.

| | ila = 1 value (actually 5a20f8e) | for reference: ila = 0, fb71459 |
|---|---|---|
| `clk_114` WNS, failing endpoints | **−0.641 ns, 4 failing** | −0.398 ns, 2 |
| `clk_gen_sdram` → `clk_114` WNS, failing endpoints | **−0.319 ns, 16 failing** | −0.512 ns, 16 |
| `clk_ddr100` (intra) | **+0.436 ns, 0 failing** | +1.440 ns, 0 failing |
| Design-wide WNS, total failing endpoints | **−0.641 ns, 20** | −0.512 ns, 18 |
| Slice LUTs | **45,784 / 63400 (72.21 %)** | 40,260 (63.50 %) |
| Slice Registers | **29,562 / 126800 (23.31 %)** | 19,628 (15.48 %) |
| Block RAM Tile | **125.5 / 135 (92.96 %)** | 59.5 (44.07 %) |
| DSPs | **28 / 240 (11.67 %)** | 28 |

The LUT/FF/BRAM jump vs. the ila = 0 build is the ILA cores themselves
(`ila_cpu040` + `ila_fastram`), same mechanism task 2 documented -- not
attributable to the RTL delta between fb71459 and 5a20f8e, which is one small
combinational-completion fix, not new registers of that scale.

**The four clk_114 failing endpoints in the ila = 1 (5a20f8e) build, named:**
1. `.../mmu/atc_ram/mem_reg_2 -> g_cache.cache/look_snooped_reg/D`, slack
   **−0.641 ns** -- known free-running snoop family, same pair as every prior
   build in this task and task 2.
2. `.../mmu/atc_ram/mem_reg_3 -> g_cache.cache/st_snooped_reg/D`, slack
   **−0.241 ns** -- same family.
3. `openaars_virtual_top/tg68k/wk_busaddr_reg[22]/C -> g_ap040.ap040/core/bf_t40_reg[11]/CE`,
   slack **−0.008 ns**. **Not the snoop family.**
4. `openaars_virtual_top/tg68k/wk_busaddr_reg[22]/C -> g_ap040.ap040/core/bf_t40_reg[12]/CE`,
   slack **−0.008 ns**. **Not the snoop family.**

Endpoints 3 and 4 are new, small (−0.008 ns, essentially at the ILA-congestion
noise floor task 2 already documented for this build configuration), and sit
on `wk_busaddr` -> `bf_t40_reg[*]/CE` -- the walker's address register feeding
an AP68040 core barrel-shifter/field-extract register's clock enable, not
anything the fill channel touches directly and not the snoop family either.
Given the mid-build RTL substitution documented above, I cannot attribute
these two to fb71459's fill-channel routing, to the 5a20f8e fix, or to plain
ILA congestion (task 2's ila=1 build already showed clk_114 WNS degrading by
210 failing endpoints from ILA congestion alone, so a handful of near-zero
new endpoints here is well within that noise). Not signed off, consistent
with the brief -- flagged here rather than judged, per the same
report-don't-fix instruction as the ila = 0 finding above.

Kernel multicycle sets and DDR3 CDC exceptions checked the same way as the
ila = 0 build: `g_ap040.ap040` referenced 16 times in the kernel `cycles=3(start)`
set, `addr*` filter's two lines byte-identical in content, CDC `max_dpo`
exceptions present and unchanged (now at exceptions.rpt lines 347/350 --
shifted from the ila=0 build's 135/138 because the ila=1 report carries extra
ILA-related exception rows, same shift pattern task 2 documented for its own
ila=1 build).


## Boot check (build/stage_ap040_x3fill_ila, actually 5a20f8e -- see above)

Command:
```
LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal \
  -source .superpowers/sdd/plan-v2-with-ddr3/ila_boot_probe.tcl \
  -tclargs build/stage_ap040_x3fill_ila \
           .superpowers/sdd/plan-v2-with-ddr3/x3fill_ila_probe1 1 200
```
(`1` = program the device; `200` = wait 200 s after programming before the
first capture, i.e. more than the brief's three-minute floor and past this
core's ~110 s time-to-Workbench.) One JTAG/hw_manager session, opened and
closed by the script itself; confirmed no other hw session was open first
(no `hw_server` process running, and the concurrent Vivado build process --
`build/stage_ap040_x3fill2`, launched by the controller per the progress
ledger -- never opens one).

Log: `.superpowers/sdd/plan-v2-with-ddr3/x3fill_ila_probe1.log`. Programmed at
04:05:56; ILA identified as `hw_ila_1`; waited 200 s; three captures armed and
triggered back-to-back at 04:09:25-04:09:26 (all "captured ->" lines present,
no "NO TRIGGER" lines).

**"now" capture** (`x3fill_ila_probe1_now.csv`, `CAPTURE_MODE ALWAYS`,
trigger-on-anything, 4096 samples): every single sample --
`dbg_pc=00f815d2`, `dbg_ir=4e72` (STOP), `dbg_flags=0`, `bus_ctl=f` (no bus
cycle active). This is a byte-for-byte match to `ref_booted_now.csv` (the
reference signature the header cites, confirmed by Paul at Workbench on
2026-09-09 00:25): same PC, same STOP opcode, same idle flags, no bus
activity. `dat_out` differs cosmetically (0x00c0 here vs 0x0080 in the
reference -- stale bus-hold value from whatever the last real cycle wrote,
not part of the signature).

**"busy" capture** (`x3fill_ila_probe1_busy.csv`, triggers on
`cpustate != 7'bxxxxx01`): pre-trigger rows show the same idle STOP pattern;
at the trigger sample `dbg_flags` goes from `4` to `4`/`5` and `cpustate`
moves through `1f -> 0f -> 03 -> ...` -- the CPU leaving the idle wait state,
consistent with the documented reference behaviour ("wakes on the level-3
autovector ... walks the VERTB/BLIT server chain").

**"write" capture** (`x3fill_ila_probe1_write.csv`, triggers on the first
`as=0,rw=0` write): trigger row `dbg_pc=4018b6bc`, `tg68_adr=00dff1c8`
(a chip register address, $DFF1C8), `dbg_ir=316e` (a `MOVE` opcode),
`dbg_flags=1` (busy) -- a live CPU executing code outside the idle loop and
writing to the chipset, exactly the shape of interrupt-handler activity a
running AmigaOS produces.

**Verdict: BOOTED.** All three captures agree with each other and with the
reference signature on the first probe; the two-probes-five-minutes-apart
fallback was not needed. `build/stage_ap040_x3fill_ila` is left programmed on
the board.

## Deliverables

1. `build/stage_ap040_x3fill/` (ila = 0, fb71459 -- clean, unaffected by the
   mid-task edit) and `build/stage_ap040_x3fill_ila/` (ila = 1, actually
   5a20f8e). Both untracked build output, left in place, matching every other
   `build/stage_*` directory.
2. This report.
3. Plan-doc row + Log paragraph in `findings/ap68040/plan-v2-with-ddr3.md`
   (below), noting both the ila = 0/ila = 1 numbers and the mid-task RTL
   substitution.

## Files changed / commit

- `findings/ap68040/plan-v2-with-ddr3.md`: added the ila = 0 / ila = 1
  build rows under "Numbers to fill in as they are measured" and a dated Log
  paragraph, including the mid-task HEAD move from fb71459 to 5a20f8e and the
  boot verdict.
- No other tracked files touched. `build/stage_ap040_x3fill/`,
  `build/stage_ap040_x3fill_ila/`, and the query/probe scratch files under
  `.superpowers/sdd/plan-v2-with-ddr3/` are untracked, left in place.
- Did NOT stage or touch Paul's pre-existing uncommitted edits
  (`fw/ctrl_832/version.h`, `sim/hostcpu-i2c-bridge/*.wcfg`,
  `tools/vivado/ila_fastram_check.py`, `sim/ddr3_cpu/xsim_run_*.log`) or any
  untracked scratch files.
- Commit: only `findings/ap68040/plan-v2-with-ddr3.md`, by explicit path.

## Concerns

1. **`build/stage_ap040_x3fill_ila` is not the fb71459 state this task was
   scoped to build.** It is `5a20f8e` (fb71459 + the undecoded-fill-completes
   fix), because Paul's own commit landed in the shared working tree between
   the ila = 1 build's `launch_runs` call and the point its `synth_design`
   step actually read sources from disk. I did not cause this and could not
   have prevented it without a private worktree, which the brief did not
   provide for and which the coordinator's instruction (do not rebuild, this
   is a known/expected fact, continue as briefed) treats as already known.
   The boot verdict above is therefore evidence that **5a20f8e** boots, not
   direct evidence for fb71459 in isolation -- though fb71459's own ila = 0
   build's sign-off numbers (clean, unaffected) are still valid for fb71459.
2. **The ila = 0 (fb71459) build has two clk_114 failing endpoints, both the
   pre-existing free-running snoop family, but the WNS on that family is
   0.051 ns worse than the immediately-prior `stage_ap040_x3` baseline**
   (−0.398 ns vs −0.347 ns). Read literally, the brief's "no path worse" rule
   is not fully met on this one leg; reported with full numbers rather than
   judged, per the brief's own instruction not to fix RTL or constraints on a
   sign-off violation.
3. **The brief's premise about `fl_busaddr` and the `addr*` 3-cycle set does
   not hold**, per task-3-report.md section 2.7's own documented, deliberate
   design decision (confirmed against the actual `exceptions.rpt` and
   `cpu.xdc`): `fl_busaddr` is not in that set and was never meant to be.
   Reported as a finding, not treated as a defect to fix.
4. **A rebuild is already in flight, per the progress ledger** --
   `build/stage_ap040_x3fill2` (ila = 0, 5a20f8e state), launched by the
   controller around 04:1x, for a like-for-like ila = 0 sign-off of 5a20f8e
   against `stage_ap040_x3`. Not part of this task; noted so the plan-doc row
   below is not read as the final word on 5a20f8e's ila = 0 timing.
5. Per instructions, I did not look for or read the parallel code review of
   fb71459/5a20f8e; if it later surfaces an RTL finding affecting either
   build in this task, both bitstreams here would need to be revisited.

