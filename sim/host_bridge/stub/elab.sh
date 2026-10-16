#!/bin/bash
# Elaborate EightThirtyTwo_Bridge with cpu_riscv => true (rv_debug 0 and 2)
# from the RISC-V sources only: no EightThirtyTwo, no OSDBoot_832_ROM, no
# debug_bridge_jtag.  Proves the component-declaration split.  xsim tools,
# one run at a time; output in run_${RUNTAG:-wt}.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

run="$HERE/run_${RUNTAG:-wt}"
rm -rf "$run"; mkdir -p "$run"
cd "$run"
X() { "$VIVADO_PATH/bin/$@" >> compile.log 2>&1 || { echo "FAILED: $*"; tail -20 compile.log; exit 1; }; }
: > compile.log
X xvlog "$ROOT/rtl/host/rv_hostcpu.v" "$ROOT/rtl/host/vexriscv/VexOsd.v" "$ROOT/rtl/host/vexriscv/VexOsd_DMJ.v" \
	"$ROOT/rtl/host/hostcache.v" "$ROOT/rtl/sdram/dpram_inf_generic.v"
X xvhdl "$HERE/OSDBoot_rv_ROM_stub.vhd" "$ROOT/rtl/host/832_bridge.vhd" "$HERE/tb_elab_rv.vhd"
for dbg in 0 2; do
	X xelab -debug off -generic_top "RV_DEBUG=$dbg" tb_elab_rv -s "tb_rv$dbg"
	echo "rv_debug=$dbg: elaborated"
done
