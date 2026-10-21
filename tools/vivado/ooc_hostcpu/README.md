# ooc_hostcpu: out-of-context size and timing of the OSD RISC-V cores

Synthesises and implements one generated VexRiscv core from `rtl/host/vexriscv/`
on its own (registered-I/O wrapper `wvex.v`, part `xc7a100tfgg676-2`, Vivado
2023.2, no project, no IP). Use it to check LUT/FF/BRAM/DSP and setup slack at
the host clock after a change to `GenOsd.scala`. It does not touch
`project_1` and takes about 2 minutes and 2-4 GB per run.

## Prerequisites

* Vivado 2023.2 at `/opt/Xilinx/Vivado/2023.2/bin/vivado`. `go.sh` calls it
  directly (the shell alias adds `-stack`; do not use it).
* The libtinfo shim: `~/lib/tinfo5/libtinfo.so.5` must exist (a symlink to
  `/lib/x86_64-linux-gnu/libtinfo.so.6`). `go.sh` sets
  `LD_LIBRARY_PATH=$HOME/lib/tinfo5` and `LC_ALL=C` itself.
  Without the shim Vivado dies at start with a missing `libtinfo.so.5`:
  `mkdir -p ~/lib/tinfo5 && ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5`
* Python 3 for `parse.py`.

## Run

```sh
cd tools/vivado/ooc_hostcpu
./go.sh <name> <variant> <period_ns> [GEN=VAL ...]
# all three, in parallel, at the host clock (8.815 ns = 113.4375 MHz):
for v in VexOsd VexOsd_DMT VexOsd_DMJ; do ./go.sh $v $v 8.815 & done; wait
./parse.py
```

`<variant>` is the module name: `VexOsd` (no debug), `VexOsd_DMT` (debug
module, BSCANE2 tunnel ports `jtagInstruction_*` + `jtag_tck` as wrapper
ports), `VexOsd_DMJ` (debug module with its own TAP on `jtag_*`). `<name>`
is only the output directory. For a scratch copy of a core (for example a
variant with other catch flags) set `VEXSRC=/path/to/Core.v` and keep the
module name equal to `<variant>`; never edit the committed Verilog.

## Where the results land

`runs/<name>/` (gitignored):

| File | Content |
|---|---|
| `summary.txt` | one line: variant, source, period, `wns=` (setup WNS of the `clk` group), Vivado version |
| `util_hier.rpt` | utilisation per hierarchy level; the `u_core` row is the core without the wrapper's registers |
| `util.rpt`, `util_synth_hier.rpt` | whole-wrapper and post-synthesis utilisation |
| `timing.rpt`, `crit.rpt` | timing summary and the worst setup path |
| `vivado.log` | full log; `go.sh` prints `FAILED` if `summary.txt` is missing |

## How to read it

`./parse.py` prints one table row per run: LUT (total, includes LUTRAM and
SRL), LUTRAM, SRL, FF, RAMB36, RAMB18, DSP of `u_core`, the period and WNS,
and the estimated Fmax `1000/(period - WNS)`. Compare the numbers against the
`u_core` line of `util_hier.rpt` by eye if in doubt. The wrapper adds its own
~170 FF for the I/O registers; they are not in the `u_core` figures. For the
debug variants `tck` is a 50 ns clock in an asynchronous group with `clk`, so
the WNS reported is the `clk` group only; the `tck` slack is in `timing.rpt`.

Gates used for the OSD host CPU (8.815 ns): `VexOsd` <= 1450 LUT and
WNS >= +1.0 ns; `VexOsd_DMT` and `VexOsd_DMJ` <= 1950 LUT and WNS >= +0.9 ns.
Results: `findings/osd-riscv/ooc-2023.2.md`.

## Whole `hostcpu` (EightThirtyTwo_Bridge) -- `go_bridge.sh`

OOC synthesis + implementation of the complete `EightThirtyTwo_Bridge` (CPU, bridge,
hostcache, boot ROM) at 8.815 ns, four runs: `832` (reference, EightThirtyTwo),
`rv0` (VexOsd, no debug), `rv1` (VexOsd_DMT + `rtl/host/xilinx/rv_bscane2.v`, BSCANE2
tunnel; its TCK pin is a 50 ns clock asynchronous to `clk`), `rv2` (VexOsd_DMJ, pin TAP).
Results in `runs/bridge_<mode>/`
(`summary.txt`, `util.rpt`, `util_hier.rpt`, `crit.rpt` top-5 paths, `routed.dcp`);
the `summary.txt` line also lists how many `*hw_req_reg*` / `*wr_reg*` cells exist.

```
# once: the RV boot ROM image (any 8 KB image; default path used by run_bridge.tcl)
make -C sim/host_bridge TESTS=t_lanes
cd tools/vivado/ooc_hostcpu
./go_bridge.sh 832 && ./go_bridge.sh rv0 & ./go_bridge.sh rv2 & wait
./go_bridge.sh rv1
./go_bridge.sh rv0 8.5          # optional second argument: clock period in ns
RVROM=/path/OSDBoot_rv_ROM.vhd E832=/path/to/EightThirtyTwo/RTL ./go_bridge.sh rv0
```

Totals are in `util.rpt` (the top is the whole hostcpu, not just the core). Measured
numbers: `findings/osd-riscv/ooc-2023.2.md`.
