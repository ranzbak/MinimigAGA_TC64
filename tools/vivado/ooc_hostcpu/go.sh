#!/bin/bash
# usage: go.sh <name> <VexOsd|VexOsd_DMT|VexOsd_DMJ> <period_ns> [GEN=VAL ...]
# Out-of-context synthesis + implementation of one generated core (Vivado 2023.2).
# Results: runs/<name>/ (gitignored). Optional env: VEXSRC=<scratch core .v>.
here=$(cd "$(dirname "$0")" && pwd)
name=$1; variant=$2; per=$3; shift 3
export LD_LIBRARY_PATH=$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} LC_ALL=C
mkdir -p "$here/runs/$name"; cd "$here/runs/$name" || exit 1
rm -f summary.txt
/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log vivado.log \
  -source "$here/run.tcl" -tclargs "$here/runs/$name" "$variant" "$per" "$@" > /dev/null 2>&1
echo "$name done: $(cat summary.txt 2>/dev/null || echo FAILED, see runs/$name/vivado.log)"
