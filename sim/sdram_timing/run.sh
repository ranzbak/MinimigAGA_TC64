#!/usr/bin/env bash
# SDRAM read-path timing simulation. Usage: ./run.sh [slow|fast] [sg6|sg7]
set -e
cd "$(dirname "$0")"
CORNER=${1:-slow}; GRADE=${2:-sg7}
R=../../rtl/sdram
DEF="-DSOC_SIM -D$GRADE"; [ "$CORNER" = fast ] && DEF="$DEF -DFAST"
iverilog -g2012 -gspecify $DEF -o build/tb_${CORNER}_${GRADE} -s sdram_timing_tb \
  sdram_timing_tb.v ../../lib/models/AS4C16M16SA.v \
  $R/sdram_ctrl.v $R/cpu_cache_new.v $R/dpram_inf_256x32.v $R/dpram_inf_be_1024x32.v $R/dpram_inf_generic.v
vvp -n build/tb_${CORNER}_${GRADE} | grep -v "^VCD" | tee build/${CORNER}_${GRADE}.log
