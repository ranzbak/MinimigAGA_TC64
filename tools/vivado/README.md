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

### Debug lab build

`RV_DEBUG=1` in the environment builds the LAB bitstream: the same image with the
RISC-V debug module in the host CPU (`rtl/host/vexriscv/VexOsd_DMT.v`), its debug
transport tunnelled through the FPGA's own JTAG chain by a `BSCANE2` on USER4
(`rtl/host/xilinx/rv_bscane2.v`), so OpenOCD/GDB reach the CPU over the Platform Cable
(`tools/openocd/minimig-rv-bscan.cfg`). For that run only, `build_ap040.tcl` appends
` HOSTCPU_RVDEBUG=1` to the generic (the board top's parameter; the bridge gets
`rv_debug = 1`) and prints `host CPU = RISC-V, DEBUG MODULE (rv_debug = 1, LAB BUILD)`;
`hostcpu.tcl` adds the two debug sources to `sources_1` and `tools/vivado/rv_debug.xdc`
(TCK as clock `rv_tck`, 50 ns, asynchronous to `clk_114`; the comments name the
synchronisers that make that safe) to `XC7A100T` with `PROCESSING_ORDER LATE`, and
restores the project afterwards like the RV group. The extra report `rv_debug.rpt` has the
`BSCANE2` cell(s) with `JTAG_CHAIN`, the `VexOsd_DMT` cell count, `rv_tck`, its timing
(from, to, within) and the CDC report of both crossings. The changed generic forces a
re-synthesis, both into and out of a lab build. `RV_DEBUG` unset or `0` is the shipping
image, call for call as before; any other value stops the build before the project is
touched. Never ship a lab bitstream: the debug module lets anyone with a JTAG cable halt
the host CPU and rewrite its memory.

```
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C POST_CHIP=1 POST_CI=1 RV_DEBUG=1 \
  /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log $OUT/vivado.log \
  -source $WB/tools/vivado/build_ap040.tcl -tclargs $OUT 0 $WB
```

The scripts' host CPU handling is tested without Vivado (Tcl 8.6, `apt install tcl8.6`):

```
tclsh tools/vivado/test/hostcpu_mock_test.tcl    # ends "=== HOSTCPU MOCK PASS (<n> checks)"
```

It runs `build_ap040.tcl` and `hostcpu.tcl` against a mocked Vivado (recorded calls, a
small project model, a throw-away fake repository root) and compares the default build's
call list and output with those of commit `547693f` (the scripts before `RV_DEBUG`;
`-base <rev>` picks another, `-keep <dir>` saves the call lists), then checks the
`RV_DEBUG=1` additions, the restore and the crash recovery from `.hostcpu_undo`.

## AP68040 build, program and test runbook

Step-by-step procedures for the AP68040 core: environment, `build_ap040.tcl`
arguments and post-build checks, JTAG loading, flashing, the hardware test with
phase-histogram and RTG captures, and the simulation legs:
[`doc/build-program-test.md`](../../doc/build-program-test.md).
