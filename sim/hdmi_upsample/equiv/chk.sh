#!/bin/bash
# chk.sh [FILE [GOLD]]: verilator -Wall lint of FILE (default and pal_to_ddr
# parameters, -DSYNTHESIS), formal equivalence (eq.sh) against GOLD with the
# default, pal_to_ddr and tb_upsample_stale parameters, and the iverilog
# compile with tb_upsample_stale.  FILE defaults to the working tree's
# pal_to_hd_upsample.sv, GOLD to the same file at HEAD.
S=$(dirname "$(readlink -f "$0")")
W=$(readlink -f "$S/../../..")
A=$W/rtl/openaars/adv7511
O=${EQ_OUT:-$S/../build/equiv}
export EQ_OUT=$O
mkdir -p "$O/lint"
F=$(readlink -f "${1:-$A/pal_to_hd_upsample.sv}")
if [ -n "$2" ]; then
	G=$(readlink -f "$2")
else
	G=$O/head.sv
	git -C "$W" show HEAD:rtl/openaars/adv7511/pal_to_hd_upsample.sv > "$G" || exit 1
fi
rm -f "$O"/lint/*
L=$O/lint/pal_to_hd_upsample.${F##*.}
cp "$F" "$L"
cd "$O/lint" || exit 1
echo "== lint default"
nice -n 19 verilator --lint-only -Wall --top-module pal_to_hd_upsample "$L" $A/bram_tdp.v 2>&1 | grep "%" | cut -c1-170
echo "== lint pal_to_ddr parameters"
nice -n 19 verilator --lint-only -Wall -GPAL_HD_H_RES=1685 -GPAL_HD_H_RES60=1980 -GPAL_OFFSET_HZ=199 \
	-GPAL_OFFSET_HZ60=119 -GRATIO_RDX=3 --top-module pal_to_hd_upsample "$L" $A/bram_tdp.v 2>&1 | grep "%" | cut -c1-170
echo "== lint -DSYNTHESIS"
nice -n 19 verilator --lint-only -Wall -DSYNTHESIS --top-module pal_to_hd_upsample "$L" $A/bram_tdp.v 2>&1 | grep "%" | cut -c1-170
echo "== formal default"
CHP= "$S/eq.sh" "$G" "$F" | grep -E "Of those|proven!|exit"
echo "== formal pal_to_ddr parameters"
CHP="-set PAL_HD_H_RES 1685 -set PAL_HD_H_RES60 1980 -set PAL_OFFSET_HZ 199 -set PAL_OFFSET_HZ60 119 -set RATIO_RDX 3" \
	"$S/eq.sh" "$G" "$F" | grep -E "Of those|proven!|exit"
echo "== formal tb_upsample_stale parameters, CRT 0"
CHP="-set PAL_HD_H_RES 1980 -set PAL_HD_H_RES60 1685 -set CRT 0" "$S/eq.sh" "$G" "$F" | grep -E "Of those|proven!|exit"
echo "== iverilog"
cd "$W/sim/hdmi_upsample" || exit 1
iverilog -g2012 -o "$O/stale_chk.vvp" tb_upsample_stale.v "$F" $A/bram_tdp.v $A/signal_generator.sv
echo "iverilog rc=$?"
