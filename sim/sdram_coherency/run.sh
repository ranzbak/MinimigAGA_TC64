#!/usr/bin/env bash
# Chip-RAM coherency simulation: CPU and chipset both hitting chip RAM through
# the real rtl/sdram/sdram_ctrl.v.
#
#   ./run.sh                      fast corner, sg7, background load ON
#   ./run.sh fast sg7 +nobg       BENCH VALIDATION: no contention, must pass
#   ./run.sh fast sg7 +rounds=50  shorter run
#
# Use the FAST corner for coherency work: at the slow corner the read path is
# one word late all by itself (findings/constraints/sdram-sim-results.md) and
# every chipset read fails for a reason that is not coherency.
set -e
cd "$(dirname "$0")"
mkdir -p build
CORNER=${1:-fast}; GRADE=${2:-sg7}; shift 2 2>/dev/null || true
DEF="-DSOC_SIM -D$GRADE${CLS:+ -DCL_SNOOP}"; [ "$CORNER" = fast ] && DEF="$DEF -DFAST"
R=../../rtl/sdram
iverilog -g2012 -gspecify $DEF -o build/tb_${CORNER}_${GRADE} -s sdram_coherency_tb \
  sdram_coherency_tb.v ../../lib/models/AS4C16M16SA.v \
  $R/sdram_ctrl.v $R/cpu_enable_cadence.v $R/cpu_cache_new.v \
  $R/dpram_inf_256x32.v $R/dpram_inf_be_1024x32.v $R/dpram_inf_generic.v
vvp -n build/tb_${CORNER}_${GRADE} "$@" | grep -v "^VCD" | tee build/${CORNER}_${GRADE}.log
