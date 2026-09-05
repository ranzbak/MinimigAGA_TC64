#!/bin/sh
# Run the autoconfig board-chain bench.
#
#   ./run.sh        compact table, every OSD combination
#   ./run.sh -v     add the full per-board AUTOCONFIG register dump
#
# Needs Icarus Verilog (iverilog -g2012 / vvp).
set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$here/autoconfig_tb.vvp

plus=
if [ "x$1" = "x-v" ] || [ "x$1" = "x--verbose" ]; then
    plus="+verbose"
    shift
fi

iverilog -g2012 -Wall -o "$out" \
    "$here/autoconfig_tb.sv" \
    "$root/rtl/minimig/minimig_autoconfig.v" \
    "$root/rtl/minimig/minimig_autoconfig_rom.v"

vvp "$out" $plus "$@"
