#!/bin/bash
# Elaborate EightThirtyTwo_Bridge with cpu_riscv => true from the RISC-V
# sources only: no EightThirtyTwo, no OSDBoot_832_ROM, no debug_bridge_jtag.
# Proves the component-declaration split.  xsim tools, one run at a time;
# output in run_${RUNTAG:-wt}.
#
#   elab.sh          rv_debug 0 and 2 (vendor-neutral sources only)
#   elab.sh dmt      rv_debug 1: VexOsd_DMT + rtl/host/xilinx/rv_bscane2.v,
#                    BSCANE2/BUFG from unisims_ver (+ glbl); proves the
#                    DEBUG = 1 wiring connects (the tunnel is not simulated)
#   elab.sh all      all three
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mode=${1:-neutral}
case "$mode" in
	neutral) dbgs="0 2" ;;
	dmt)     dbgs="1" ;;
	all)     dbgs="0 2 1" ;;
	*) echo "usage: elab.sh [dmt|all]"; exit 2 ;;
esac

run="$HERE/run_${RUNTAG:-wt}"
rm -rf "$run"; mkdir -p "$run"
cd "$run"
X() { "$VIVADO_PATH/bin/$@" >> compile.log 2>&1 || { echo "FAILED: $*"; tail -20 compile.log; exit 1; }; }
: > compile.log
X xvlog "$ROOT/rtl/host/rv_hostcpu.v" "$ROOT/rtl/host/vexriscv/VexOsd.v" "$ROOT/rtl/host/vexriscv/VexOsd_DMJ.v" \
	"$ROOT/rtl/host/hostcache.v" "$ROOT/rtl/sdram/dpram_inf_generic.v"
case " $dbgs " in *" 1 "*)
	X xvlog "$ROOT/rtl/host/vexriscv/VexOsd_DMT.v" "$ROOT/rtl/host/xilinx/rv_bscane2.v" \
		"$VIVADO_PATH/data/verilog/src/glbl.v" ;;
esac
X xvhdl "$HERE/OSDBoot_rv_ROM_stub.vhd" "$ROOT/rtl/host/832_bridge.vhd" "$HERE/tb_elab_rv.vhd"
for dbg in $dbgs; do
	if [ "$dbg" = 1 ]; then
		# tb_elab_rv1 = tb_elab_rv with RV_DEBUG => 1 (no -generic_top: glbl would get it too)
		X xelab -debug off -L unisims_ver tb_elab_rv1 work.glbl -s tb_rv1
		# the primitives must come from unisims_ver, the core must be the DMT one
		for m in unisims_ver.BSCANE2 unisims_ver.BUFG work.rv_bscane2 work.VexOsd_DMT 'work.rv_hostcpu(DEBUG=1'; do
			grep -qF "Compiling module $m" compile.log || { echo "FAILED: $m not in the elaborated design"; exit 1; }
		done
		echo "rv_debug=1: elaborated (VexOsd_DMT + rv_bscane2, BSCANE2/BUFG from unisims_ver)"
	else
		X xelab -debug off -generic_top "RV_DEBUG=$dbg" tb_elab_rv -s "tb_rv$dbg"
		echo "rv_debug=$dbg: elaborated"
	fi
done
