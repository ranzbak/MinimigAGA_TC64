# Vivado helpers

Run from the repository root as
`LD_LIBRARY_PATH=<libtinfo5 shim dir> /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal -source tools/vivado/<script> -tclargs ...`.
Vivado 2023.2 needs `libtinfo.so.5`; a directory containing a symlink of that name to
`libtinfo.so.6` on `LD_LIBRARY_PATH` is enough.

| Script | Purpose | Args |
|---|---|---|
| `build.tcl` | Open `project_1`, make sure `cpu.xdc` is in fileset `XC7A100T`, reset synthesis, run to bitstream, write timing and utilisation reports | `<report dir>` |
| `program.tcl` | Program a bitstream over JTAG and print the DONE pin | `<bitstream>` |
| `phase_sweep.tcl` | Step an MMCM/PLL fine phase shift through a VIO named `vio_ps` (probes `vio_trig`, `vio_incdec`, `vio_nsteps`, `vio_rst`, `ps_count_1`, `busy`) to the given step counts, 15.74 ps per step at a 1134.375 MHz VCO; optional VIO reset. Do **not** use the VIO reset to judge boots: it does not restart the host properly | `<bitstream> <steps>... [reset]` |
| `ila_capture.tcl` | Arm an ILA with a trigger, pulse the VIO reset, wait, upload, write a CSV; probe names and trigger are set inside the script | `<steps> <output dir>` |

Written during the September 2026 constraint work. The VIO/ILA scripts expect the
instrumented builds described in `findings/constraints/fix-12-*.md` and the hierarchy
prefix `openaars_virtual_top/amiga_clk/amiga_clk_i/`; adapt the prefix for a new design.

## AP68040 build, program and test runbook

Step-by-step procedures for the AP68040 core: environment, `build_ap040.tcl`
arguments and post-build checks, JTAG loading, flashing, the hardware test with
phase-histogram and RTG captures, and the simulation legs:
[`doc/build-program-test.md`](../../doc/build-program-test.md).
