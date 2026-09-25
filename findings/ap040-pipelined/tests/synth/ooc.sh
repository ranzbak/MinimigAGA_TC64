#!/bin/sh
# ooc.sh [<pipe-tree>] [<top>] [<outdir>] [generics...] -- runs ooc.tcl in Vivado 2023.2
# (libtinfo.so.5 shim on LD_LIBRARY_PATH; no -stack, it crashes the router).
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=${1:-$HERE/../../../../../AP68040-pipelined}; [ $# -gt 0 ] && shift
TOP=${1:-ap040_pipe_core}; [ $# -gt 0 ] && shift
OUT=${1:-$HERE/out_$TOP}; [ $# -gt 0 ] && shift
SHIM=$HERE/.tinfo; mkdir -p "$SHIM"
[ -e "$SHIM/libtinfo.so.5" ] || ln -s /opt/Xilinx/Vivado/2023.2/lib/lnx64.o/Rhel/9/libtinfo.so.5 "$SHIM/libtinfo.so.5"
cd "$HERE"
LD_LIBRARY_PATH=$SHIM${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
	/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal -source "$HERE/ooc.tcl" \
	-tclargs "$(cd "$TREE" && pwd)" "$TOP" "$OUT" "$@" > "$OUT.log" 2>&1
grep '^=== ' "$OUT.log" || { echo "ooc synth failed, see $OUT.log"; tail -20 "$OUT.log"; exit 1; }
