#!/usr/bin/env bash
# DDR3 fast RAM (cache backend + CDC) simulation against a behavioural memory.
# Pure RTL, so iverilog is enough -- see findings/ddr3/implementation-plan.md
# section 0.  Usage: ./run.sh [seed]   (default seed is fixed, so the run is
# reproducible; pass a number to reshuffle the random stimulus).
set -e
cd "$(dirname "$0")"
mkdir -p build
R=../../rtl
iverilog -g2012 -DSOC_SIM -o build/ddr3_fastram_tb -s ddr3_fastram_tb \
  ddr3_fastram_tb.v mem_stub.v \
  $R/ddr3/ddr3_fastram.v $R/ddr3/ddr3_cdc.v \
  $R/sdram/cpu_cache_new.v $R/sdram/dpram_inf_256x32.v \
  $R/sdram/dpram_inf_be_1024x32.v $R/sdram/dpram_inf_generic.v
vvp -n build/ddr3_fastram_tb ${1:+"+seed=$1"} | grep -v "^VCD" | tee build/ddr3_fastram.log
grep -q "DDR3 FASTRAM TB: .* 0 failed" build/ddr3_fastram.log
