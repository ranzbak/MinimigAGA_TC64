# Task 2: Vivado build of the x3-core state, timing sign-off

Plan: findings/ap68040/plan-v2-with-ddr3.md, "Stage D — REVISED", item 1 ends with "Build, then re-measure with SysInfo and the ILA stall capture." The measurement is Paul's (hardware). This task is the build and the sign-off.

## Build
Script: tools/vivado/build_ap040.tcl (read its header: `-tclargs <report-dir> [<ila>] [<repo-root>]`). Output directory: `build/stage_ap040_x3`. Build the shipping configuration (ila = 0) -- the same configuration as the current board bitstream `build/stage_ap040_ddr3only`; check that directory's reports and the build.tcl generics to confirm which ILA generic(s) it was built with and match them, so the comparison is like for like. Run Vivado as:

    LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl -tclargs build/stage_ap040_x3 0

with `<shim>` = /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/8ce939b9-1808-4e35-b059-9f0f27302dc1/scratchpad/shim. Never pass -stack. Run it with nohup in the background to a log file inside the report dir and poll the log; a full build is long (expect the better part of an hour). Record wall-clock start and end.

## Sign-off (plan "Sign-off per stage", A6 row, against the current baseline)
Baseline = build/stage_ap040_ddr3only (on the board today):
| clock / path | baseline |
|---|---|
| clk_114 WNS | -0.588 ns, 1 failing endpoint: g_ap040.ap040/mmu/atc_ram -> g_cache.cache/look_snooped_reg (free-running snoop path, 8.815 ns) |
| clk_gen_sdram -> clk_114 (SDRAM read path) | -0.602 ns, 17 endpoints |
| clk_ddr100 | report it |
| DDR3 CDC set_max_delay -datapath_only exceptions (ddr3.xdc) | present in exceptions.rpt lines ~190-191 (ddr3_fastram_i/cdc/req_*_r_reg, rdata_r_reg) |
| kernel multicycle sets (cpu.xdc) | populated: check exceptions.rpt shows the -start 3/-hold 2 kernel sets with non-empty cell lists on the g_ap040.ap040 instance |

Fill the same table for the new build from build/stage_ap040_x3/timing_summary.rpt, exceptions.rpt and utilization.rpt (LUTs, BRAM, DSP). Name every failing endpoint on clk_114 (there should be at most the one above, unless the x3 cache adds a new free-running path -- name it if so). Rule: no path worse than baseline, kernel sets populated, CDC exceptions unchanged. If a NEW failing path appears inside the kernel island, check whether its endpoint register is free-running (not ce-qualified) in the x3 source before calling it a constraint problem.

## Deliverables
1. build/stage_ap040_x3/ with the .bit, .ltx (if any) and the reports (untracked, like every other build dir).
2. A "Numbers" row and a dated Log paragraph in the plan: LUT/BRAM/DSP, clk_114 WNS and endpoint, SDRAM path WNS, build time.
3. Commit the plan-doc change only (no build outputs). Do not stage Paul's pre-existing edits or untracked scratch.

## Exit criterion
Bitstream exists; sign-off table filled and compared; plan updated and committed. Hardware programming is NOT part of this task -- Paul programs and measures.

## Addendum (Paul, 21:45)
Build TWO configurations, ship first: `build/stage_ap040_x3` (ila = 0) and then `build/stage_ap040_x3_ila` (ila = 1, the CPU ILA for the stall capture). Sign-off on the ila = 0 build; report the ila = 1 build's clk_114 and SDRAM numbers too but do not sign it off (ILA congestion is known to cost ~0.1 ns). Programming the board is the controller's step, not yours.
