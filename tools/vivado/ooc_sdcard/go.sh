#!/bin/bash
# usage: go.sh [<name>] [<ooc|io>] [<t114 ns>] [<t28 ns>]
#   bash tools/vivado/ooc_sdcard/go.sh                # runs/ooc: the gate numbers
#   bash tools/vivado/ooc_sdcard/go.sh io io          # runs/io: card pin constraints
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
mkdir -p "$here/runs/$name"; cd "$here/runs/$name" || exit 1
rm -f summary.txt
# shellcheck disable=SC2086
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
	-source "$here/run.tcl" -tclargs "$here/runs/$name" "$mode" "$t114" $t28 > /dev/null 2>&1
if [ -f summary.txt ]; then echo "$name: $(cat summary.txt)"
else echo "$name: FAILED, see $here/runs/$name/vivado.log"; exit 1; fi
