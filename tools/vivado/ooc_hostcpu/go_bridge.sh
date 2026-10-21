#!/bin/bash
# usage: go_bridge.sh <832|rv0|rv1|rv2> [period_ns]   (default 8.815; rv1 = rv_debug 1, BSCANE2 tunnel)
# Out-of-context synthesis + implementation of the whole EightThirtyTwo_Bridge (Vivado 2023.2).
# Results: runs/bridge_<mode>/ (gitignored). Optional env: E832=<EightThirtyTwo RTL dir>, RVROM=<OSDBoot_rv_ROM.vhd>
# (rv runs default to sim/host_bridge/build/t_lanes: run `make -C sim/host_bridge TESTS=t_lanes` first).
here=$(cd "$(dirname "$0")" && pwd)
mode=$1; per=${2:-8.815}
export LD_LIBRARY_PATH=$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} LC_ALL=C
mkdir -p "$here/runs/bridge_$mode"; cd "$here/runs/bridge_$mode" || exit 1
rm -f summary.txt
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
  -source "$here/run_bridge.tcl" -tclargs "$here/runs/bridge_$mode" "$mode" "$per" > /dev/null 2>&1
echo "bridge_$mode done: $(cat summary.txt 2>/dev/null || echo FAILED, see runs/bridge_$mode/vivado.log)"
