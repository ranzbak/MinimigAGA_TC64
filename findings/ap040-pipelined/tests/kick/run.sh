#!/bin/sh
# Run a Kickstart ROM on both cores (one after the other), then compare and analyse.
#   sh run.sh <rom> <tag> [extra plusargs...]      e.g.
# KICK_CORES="ref pipe pipe_fpu" runs the AP040_HAS_FPU=1 leg too (built by
# `sh build.sh pipefpu`); its trace is compared against the LC040 pipelined
# leg, which is the diff that shows what AmigaOS does once the FPU probe
# answers (PLAN.md Q17 condition 2).
#   sh run.sh /home/paul/work/amiga/Update3.1/ROMs/unsplit_unswapped/kick.a1200.46.143 a
# Output: runs/<tag>_{ref,pipe}.{txt,log}, runs/<tag>_compare.txt,
#         runs/<tag>_{ref,pipe}_checkpoints.txt
# The ROM is read by path (kick_sys.sv $fread); it is never copied.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROM=$1; TAG=$2; shift 2
mkdir -p "$HERE/runs"
# one at a time (the sim-leg rule): reference first, then pipelined
CORES=${KICK_CORES:-"ref pipe"}
for c in $CORES; do
	/usr/bin/time -f "%e s wall" "$HERE/obj_$c/Vtb_kick" +rom="$ROM" \
		+trace="$HERE/runs/${TAG}_$c.txt" "$@" > "$HERE/runs/${TAG}_$c.log" 2>&1
done
for c in $CORES; do cat "$HERE/runs/${TAG}_$c.log"; done
python3 "$HERE/compare.py" "$HERE/runs/${TAG}_ref.txt" "$HERE/runs/${TAG}_pipe.txt" --rom "$ROM" \
	> "$HERE/runs/${TAG}_compare.txt" 2>&1 || true
for c in $CORES; do
	python3 "$HERE/analyze.py" "$HERE/runs/${TAG}_$c.txt" --rom "$ROM" > "$HERE/runs/${TAG}_${c}_checkpoints.txt"
done
grep -v '^  \(ref \|pipe\) #' "$HERE/runs/${TAG}_compare.txt"
