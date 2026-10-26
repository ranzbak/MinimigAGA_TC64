#!/bin/bash
# usage: go.sh [<name>] [<period_ns>] [GEN=VAL ...]
#   bash tools/vivado/ooc_osd/go.sh                 # runs/ooc at 6.734 ns (clk_148): the gate
#   bash tools/vivado/ooc_osd/go.sh lat4 6.734 LAT=4
# Out-of-context synthesis + implementation of the OSD text layer
# (rtl/openaars/adv7511/osd_text.v) behind the 720p generator, Vivado 2023.2,
# part xc7a100tfgg676-2: see run.tcl.  Results in runs/<name>/ (gitignored),
# one summary line plus the u_osd row of util_hier.rpt printed.  About 3
# minutes.  Phase 1 gate (findings/osd-redesign/plan.md): WNS > 0.3 ns,
# <= 550 LUT, 2 RAMB36, 0 DSP.
# Needs the libtinfo shim ~/lib/tinfo5/libtinfo.so.5 (a symlink to
# /lib/x86_64-linux-gnu/libtinfo.so.6, see tools/vivado/ooc_hostcpu/README.md);
# calls Vivado directly, never with -stack (it crashes the router).
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-ooc}; per=${2:-6.734}; if [ $# -ge 2 ]; then shift 2; else shift $#; fi
[ -e "$HOME/lib/tinfo5/libtinfo.so.5" ] || {
	echo "missing $HOME/lib/tinfo5/libtinfo.so.5:"
	echo "  mkdir -p ~/lib/tinfo5 && ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5"
	exit 1
}
export LD_LIBRARY_PATH=$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} LC_ALL=C
mkdir -p "$here/runs/$name"; cd "$here/runs/$name" || exit 1
rm -f summary.txt
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
	-source "$here/run.tcl" -tclargs "$here/runs/$name" "$per" "$@" > /dev/null 2>&1
if [ -f summary.txt ]; then
	echo "$name: $(cat summary.txt)"
	echo "| Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | DSP |"
	grep -E "^\| +(wosd|  u_osd|  u_gen) " util_hier.rpt
else echo "$name: FAILED, see $here/runs/$name/vivado.log"; exit 1; fi
