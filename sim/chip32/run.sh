#!/usr/bin/env bash
# sim/chip32 -- a 32-bit CPU access to chip RAM through the real minimig bus
# path and the real sdram_ctrl + SDRAM model (findings/chip32/plan.md, Task 2).
#
#   pass       must print "CHIP32 TB: PASS"
#   mut_word2  word 2 of a read taken from the wrong chip48 word: MUST FAIL
#   mut_nowr2  word 2 of a write never enabled:                 MUST FAIL
#
# The three builds run in parallel (vvp is single-core).  Exit status 0 only
# when the pass build passes and both mutants fail.
set -e
cd "$(dirname "$0")"
mkdir -p build
R=../../rtl
# Order matters for `timescale: the tb (1ps) first, the minimig files inherit
# it, sdram_ctrl.v sets 1ns for itself and what follows it.
SRC="chip32_tb.v \
  $R/minimig/minimig_m68k_bridge.v $R/minimig/gary.v $R/minimig/minimig_bankmapper.v \
  $R/minimig/minimig_sram_bridge.v \
  $R/sdram/sdram_ctrl.v $R/sdram/cpu_enable_cadence.v $R/sdram/cpu_cache_new.v \
  $R/sdram/dpram_inf_256x32.v $R/sdram/dpram_inf_be_1024x32.v $R/sdram/dpram_inf_generic.v \
  ../../lib/models/AS4C16M16SA.v"
for v in pass mut_word2 mut_nowr2; do
  case $v in
    pass)      D="" ;;
    mut_word2) D="-DMUT_WORD2" ;;
    mut_nowr2) D="-DMUT_NOWR2" ;;
  esac
  iverilog -g2012 -gspecify -DSOC_SIM -Dsg7 -DFAST $D -o build/tb_$v -s chip32_tb $SRC
done
for v in pass mut_word2 mut_nowr2; do
  vvp -n build/tb_$v "$@" > build/$v.log 2>&1 &
done
wait
rc=0
grep -h "^CHIP32" build/pass.log
if grep -q "^CHIP32 TB: PASS" build/pass.log; then echo "pass: PASS"; else echo "pass: FAILED"; rc=1; fi
for v in mut_word2 mut_nowr2; do
  if grep -q "^CHIP32 TB: PASS" build/$v.log; then
    echo "$v: MUTANT DID NOT FAIL -- the bench has no teeth"; rc=1
  else
    echo "$v: failed as required ($(grep -c '^FAIL' build/$v.log) FAIL lines)"
  fi
done
exit $rc
