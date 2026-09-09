# Task 5a: build the fill-channel state (fb71459), sign off, verify boot over JTAG

Same shape as Task 2 (read task-2-brief.md and task-2-report.md for the commands, the report layout and the pitfalls found there). HEAD is fb71459.

## Builds
1. `build/stage_ap040_x3fill` -- ila = 0 (ship).
2. `build/stage_ap040_x3fill_ila` -- ila = 1 (probes for the boot check and the stall capture).
Command per Task 2: `LD_LIBRARY_PATH=<shim> /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl -tclargs <dir> <ila>`; shim = /tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/8ce939b9-1808-4e35-b059-9f0f27302dc1/scratchpad/shim; never -stack; nohup + `until` loop; ~30 min each.

## Sign-off (ila = 0) against the previous ship build, build/stage_ap040_x3
| | stage_ap040_x3 |
|---|---|
| clk_114 WNS / failing endpoints | -0.347 / 2 (atc_ram -> look_snooped, atc_ram -> st_snooped; free-running snoop compare, known) |
| clk_gen_sdram -> clk_114 | -0.510 / 16 |
| clk_ddr100 | +1.813 |
| LUT / BRAM / DSP | 40127 (63 %) / 59.5 / report |
| kernel multicycle sets populated on g_ap040.ap040; DDR3 CDC max_delay exceptions present | yes |
Rule: no path worse; no NEW failing endpoint unless it is the same snoop family; the fill FSM's address register in TG68K.vhd must be inside the wrapper `addr*` 3-cycle rule (task-3-report.md section 2.7 says how it was named) -- check exceptions.rpt shows it in that set and name the cell.

## Boot check (after the ila = 1 build)
Program `build/stage_ap040_x3fill_ila` and run `tools/vivado/ila_boot_probe.tcl` (read its header for arguments and the reference signature; wait at least three minutes after programming before the first probe -- this core reaches Workbench at ~110 s). Report booted / not booted with the signature evidence. If NOT booted after two probes five minutes apart: reprogram `build/stage_ap040_x3_ila` (known booting), confirm it boots by the same probe, and report BLOCKED with both probe outputs. If booted: leave `stage_ap040_x3fill_ila` on the board.

## Deliverables
Both build dirs; sign-off table; boot verdict; a Numbers row and a dated Log paragraph in findings/ap68040/plan-v2-with-ddr3.md; commit that file only (explicit path; plain prose; end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`). Report file: task-5a-report.md in this directory; short status contract back (Status, commit, sign-off line, boot verdict, which bitstream is on the board, concerns, report path).
