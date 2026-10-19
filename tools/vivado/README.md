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

## Host CPU

The board build (`minimig_openaars_top`, parameter `HOSTCPU_RISCV = 1`) is the
VexRiscv RV32IMC OSD host CPU (`rtl/host/rv_hostcpu.v`, `rtl/host/vexriscv/VexOsd.v`,
boot ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`). `project_1.xpr` predates those sources
and lists the EightThirtyTwo's, so `build_ap040.tcl` sources `hostcpu.tcl`: for the run
it adds and enables the RISC-V group and disables the 832 group (`EightThirtyTwo/RTL/*`,
`fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`), and afterwards puts the project back as it
found it. There is no 832 build mode; every other top keeps the 832 through the
`minimig_virtual_top` defaults (`hostcpu_riscv = 0`). The 832 board image is
`build/stage_spicdc_49b1868` (branch `5.0-040-pipelined`). The build extras the
script writes for the host CPU: `util_hier.rpt`, `util_hostcpu.rpt`, `clocks.rpt`,
`hostcpu_cells.txt` (which CPU is in the netlist), `handshake_timing.rpt`, `failing.rpt`,
`drc.rpt`.

Building the RISC-V image (`B`, `doc/osd-riscv-exec-5.md` Task 2; `$WB` a worktree of the
commit with its submodules and a copy of `project_1`, `$OUT` the output directory):

```
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C POST_CHIP=1 POST_CI=1 \
  /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log $OUT/vivado.log \
  -source $WB/tools/vivado/build_ap040.tcl -tclargs $OUT 0 $WB
```

The boot ROM is committed with its sources; to rebuild it, see `fw/ctrl_boot_rv/README.md`
(`make -C fw/ctrl_boot_rv`, xPack riscv-none-elf-gcc 15.2 via `tools/riscv/toolchain.mk`).

## AP68040 build, program and test runbook

Step-by-step procedures for the AP68040 core: environment, `build_ap040.tcl`
arguments and post-build checks, JTAG loading, flashing, the hardware test with
phase-histogram and RTG captures, and the simulation legs:
[`doc/build-program-test.md`](../../doc/build-program-test.md).
