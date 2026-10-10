#!/usr/bin/env bash
# sim/chip32 -- a 32-bit CPU access to chip RAM through the real minimig bus
# path and the real sdram_ctrl + SDRAM model (findings/chip32/plan.md, Task 2),
# and since findings/fastslot the wrapper's two chip-slot modes on it.
#
#   std        Standard master (TG68K.vhd fastchip = 0): must PASS, and T1-T7
#              must be bit-identical to the bench before fastslot (STD_REF_*)
#   fast       Fast master (+fast): must PASS, incl. the T8 rate gate (every
#              CPU chip cycle 2 CCK after the last, no DMA, CPU latency 0-24)
#   std_gated  Standard master under the T8 rate gate:            MUST FAIL
#   mut_word2  word 2 of a read taken from the wrong chip48 word:  MUST FAIL
#   mut_nowr2  word 2 of a write never enabled:                    MUST FAIL
#   mut_steal  (Fast) the bridge never sees dbr, so the CPU takes DMA CCKs: MUST FAIL
#   mut_early  (Fast) the cycle ends a round early, before its slot: MUST FAIL
#
# Every leg also checks, over the whole run, that the CPU never takes a CCK
# whose DMA half was used and never takes two CCKs in a row (the AGA chip bus
# gives the CPU at most every other one).  T9 runs 2048 CCKs of CPU-independent
# DMA under random CPU traffic (CPU latency +lat=12, where the two masters run
# at different speeds) and writes every DMA slot to a file; the std and fast
# files must be identical.  T10 has DMA read a word in the CCK after each CPU
# write of it, and checks the DMA sees the write.
#
# vvp is single-core: at most four runs at once.  Exit status 0 only when
# every leg did what it must.
set -e
cd "$(dirname "$0")"
mkdir -p build
R=../../rtl
# The Standard leg's T1-T7, from the bench as it was before fastslot (9f969de
# plus the checksum monitor alone): the slot histogram, the check count and the
# fold of every SDRAM pin and CPU strobe through T7.
STD_REF_T17="CHIP32 T1-T7 slots per CPU access: 0:0 1:1079 2:0 3+:0, 2083 checks, 0 errors"
STD_REF_SUM="CHIP32 trace checksum through T7: c140f8a19ea7e96d"
# Order matters for `timescale: the tb (1ps) first, the minimig files inherit
# it, sdram_ctrl.v sets 1ns for itself and what follows it.
SRC="chip32_tb.v \
  $R/minimig/minimig_m68k_bridge.v $R/minimig/gary.v $R/minimig/minimig_bankmapper.v \
  $R/minimig/minimig_sram_bridge.v \
  $R/sdram/sdram_ctrl.v $R/sdram/cpu_enable_cadence.v $R/sdram/cpu_cache_new.v \
  $R/sdram/dpram_inf_256x32.v $R/sdram/dpram_inf_be_1024x32.v $R/sdram/dpram_inf_generic.v \
  ../../lib/models/AS4C16M16SA.v"
for b in pass mut_word2 mut_nowr2 mut_steal mut_early; do
  case $b in
    pass)      D="" ;;
    mut_word2) D="-DMUT_WORD2" ;;
    mut_nowr2) D="-DMUT_NOWR2" ;;
    mut_steal) D="-DMUT_STEAL" ;;
    mut_early) D="-DMUT_EARLY" ;;
  esac
  iverilog -g2012 -gspecify -DSOC_SIM -Dsg7 -DFAST $D -o build/tb_$b -s chip32_tb $SRC
done
# leg  build  plusargs
LEGS="std:pass:+lat=12 +t9file=build/t9_std.txt
fast:pass:+fast +gate_fast +lat=12 +t9file=build/t9_fast.txt
std_gated:pass:+gate_fast +t9file=build/t9_std_gated.txt
mut_word2:mut_word2:+fast +stopfail +t9file=build/t9_mut_word2.txt
mut_nowr2:mut_nowr2:+stopfail +t9file=build/t9_mut_nowr2.txt
mut_steal:mut_steal:+fast +stopfail +t9file=build/t9_mut_steal.txt
mut_early:mut_early:+fast +stopfail +t9file=build/t9_mut_early.txt"
echo "$LEGS" | xargs -P 4 -I{} bash -c 'IFS=: read -r l b p <<< "{}"; vvp -n build/tb_$b $p '"$*"' > build/$l.log 2>&1'
rc=0
for l in std fast; do
  grep -h "^CHIP32" build/$l.log | grep -v progress | sed "s/^/$l: /"
  if grep -q "^CHIP32 TB: PASS" build/$l.log; then echo "$l: PASS"; else echo "$l: FAILED"; rc=1; fi
done
if grep -qxF "$STD_REF_T17" build/std.log && grep -qxF "$STD_REF_SUM" build/std.log; then
  echo "std: T1-T7 identical to the bench before fastslot"
else
  echo "std: T1-T7 DIFFER from the bench before fastslot"; rc=1
fi
if [ -s build/t9_std.txt ] && cmp -s build/t9_std.txt build/t9_fast.txt; then
  echo "T9: Standard and Fast DMA traces identical ($(wc -l < build/t9_std.txt) DMA slots)"
else
  echo "T9: Standard and Fast DMA traces DIFFER (or are empty)"; rc=1
fi
for l in std_gated mut_word2 mut_nowr2 mut_steal mut_early; do
  if grep -q "^CHIP32 TB: PASS" build/$l.log; then
    echo "$l: MUTANT DID NOT FAIL -- the bench has no teeth"; rc=1
  else
    echo "$l: failed as required ($(grep -c '^FAIL' build/$l.log) FAIL lines: $(grep '^FAIL' build/$l.log | awk '{print $2}' | sort | uniq -c | tr -s ' ' | tr '\n' ' '))"
  fi
done
exit $rc
