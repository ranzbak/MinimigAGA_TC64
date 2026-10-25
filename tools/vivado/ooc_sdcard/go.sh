#!/bin/bash
# usage: go.sh [<name>] [<ooc|io>] [<t114 ns>] [<t28 ns>]
#   bash tools/vivado/ooc_sdcard/go.sh                # runs/ooc: the gate numbers
#   bash tools/vivado/ooc_sdcard/go.sh io io          # runs/io: card pin constraints
#        go.sh <name> guard [<engine|noengine|rename_spi|rename_bridge|rename_spi_impl|all>]
#   bash tools/vivado/ooc_sdcard/go.sh guard guard    # runs/guard/<case>: sd_card_engine.tcl's
#                                                     # guard, the five cases in parallel
#                                                     # (guard.tcl; about 3 minutes)
# Size and timing of the SD card engine (sdcard_spi + sdcard_gayle + mux) on
# its own, Vivado 2023.2, part xc7a100tfgg676-2: see run.tcl.  Results in
# runs/<name>/ (gitignored), one summary line printed.  About 2-3 minutes.
# Needs the libtinfo shim ~/lib/tinfo5/libtinfo.so.5 (a symlink to
# /lib/x86_64-linux-gnu/libtinfo.so.6, see tools/vivado/ooc_hostcpu/README.md);
# calls Vivado directly, never with -stack (it crashes the router).
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-ooc}; mode=${2:-ooc}; t114=${3:-8.73}; t28=${4:-}
[ -e "$HOME/lib/tinfo5/libtinfo.so.5" ] || {
	echo "missing $HOME/lib/tinfo5/libtinfo.so.5:"
	echo "  mkdir -p ~/lib/tinfo5 && ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5"
	exit 1
}
export LD_LIBRARY_PATH=$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} LC_ALL=C
if [ "$mode" = guard ]; then
	cases=${3:-all}
	[ "$cases" = all ] && cases="engine noengine rename_spi rename_bridge rename_spi_impl"
	for c in $cases; do
		d="$here/runs/$name/$c"
		rm -rf "$d"; mkdir -p "$d"
		( cd "$d" && /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
			-source "$here/guard.tcl" -tclargs "$d" "$c" > /dev/null 2>&1 ) &
	done
	wait
	rc=0
	for c in $cases; do
		d="$here/runs/$name/$c"
		if [ -f "$d/result.txt" ]; then cat "$d/result.txt"
		else echo "=== GUARD $c FAIL: no result, see $d/vivado.log"; fi
		grep -q "PASS$" "$d/result.txt" 2>/dev/null || rc=1
	done
	exit $rc
fi
mkdir -p "$here/runs/$name"; cd "$here/runs/$name" || exit 1
rm -f summary.txt
# shellcheck disable=SC2086
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
	-source "$here/run.tcl" -tclargs "$here/runs/$name" "$mode" "$t114" $t28 > /dev/null 2>&1
if [ -f summary.txt ]; then echo "$name: $(cat summary.txt)"
else echo "$name: FAILED, see $here/runs/$name/vivado.log"; exit 1; fi
