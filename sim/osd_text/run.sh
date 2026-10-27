#!/bin/bash
# sim/osd_text: the OSD text layer rtl/openaars/adv7511/osd_text.v on the 720p
# generator (signal_generator.sv), against the Python model (model.py).
#
#   bash sim/osd_text/run.sh               # every leg + the mutant, Verilator
#   SIM=iverilog bash sim/osd_text/run.sh  # the same on Icarus (4-state, slower)
#   LEGS="edges off" bash sim/osd_text/run.sh
#   JOBS=4 NICE=0 bash sim/osd_text/run.sh # 4 legs at a time, no extra nice
#
# Each leg (model.py gen <leg>) loads cells, font and palette through the
# write ports, commits window A in frame 0, writes window B + commit in the
# middle of frame 1, and captures frames 1 (A) and 2 (B) at the layer's input
# and output.  Gate per leg: the bench's own checks (syncs and DE delayed
# exactly 2*LAT clocks, every pixel steady for its two clocks, the video
# untouched outside the picture; leg "off": every clock bit-identical to the
# input delayed 2*LAT) and model.py check (out_<f>.ppm byte-identical to the
# model's exp_<f>.ppm).  Legs:
#   s1full  scale 1 at x0 = 0, y0 = 0, 64 x 32 (all 32 rows); scale 2 64 x 20 centred
#   edges   scale 2 cut by the right / bottom edges; scale 1 ending exactly at them
#   clamp   cols 200 / rows 100 (clamped); 3 x 3 cells at the bottom right corner
#   small   one cell; 13 x 7 at scale 2
#   hz60    720p60 (generator i_hz60: other line length, same porches):
#           scale 2 64 x 20 centred; scale 2 cut by the right edge
#   off     layer disabled (window set); enabled with cols 0
#   vtop    the layer's frame pulse 10 lines before the generator's (bench
#           +vtop=10): the DE starts 25 lines after it; row 0 must still be
#           the first DE line.  (Not 15: with PAL_VT_TOP 15 the DE would then
#           end on the last clock before the next pulse, and the bench's
#           capture, which goes by the pulse, would cut its last pixel.)
#   oldrast the generator on the raster from before 2026-10-27 (active lines
#           0..719, DE right after the frame pulse; a build of its own)
# Every leg but oldrast runs pal_to_ddr.sv's hd_gen raster (PAL_VT_TOP 15,
# FP 0, SYNC 5, BP 25: the DE starts 15 lines after the frame pulse).
# Every palette has all four modes; the cells are random chars and attributes
# written in three lane passes, glyphs 0x80..0xff are rewritten through the
# font port, the rest come from osd_font.mem.
# Mutant (+define+OSD_TEXT_MUTANT: colours one pixel late, as without the
# cell prefetch): must FAIL at least one leg.  The legs (normal and mutant)
# run JOBS at a time (default 2), everything under nice -n NICE (default 19).
# Output: sim/osd_text/build/<sim>/<leg>/ (in/out/exp PPMs, logs).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
A=$ROOT/rtl/openaars/adv7511
SIM=${SIM:-verilator}
LAT=${LAT:-3}     # 0..5 (pal_to_ddr.sv uses 0)
LEGS=${LEGS:-$(python3 "$HERE/model.py" legs)}
B=$HERE/build/$SIM
SRC="$HERE/osd_text_tb.v $A/osd_text.v $A/signal_generator.sv"
mkdir -p "$B"
JOBS=${JOBS:-2}
NICE=${NICE:-19}
# the whole script (builds and every leg) under nice, increment NICE
[ -z "${OSD_TEXT_NICED:-}" ] && OSD_TEXT_NICED=1 exec nice -n "$NICE" bash "$0" "$@"
rm -f "$B"/*.result

build() {   # build <name> <defines...>
	local n=$1; shift
	if [ "$SIM" = verilator ]; then
		verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-MULTIDRIVEN -Wno-BLKANDNBLK \
			--top-module osd_text_tb -GLAT=$LAT "$@" -Mdir "$B/vl_$n" -o sim $SRC \
			> "$B/build_$n.log" 2>&1 || { echo "FAILED: verilator build $n, see $B/build_$n.log"; exit 1; }
	else
		iverilog -g2012 -Posd_text_tb.LAT=$LAT "${@/+define+/-D}" -o "$B/$n.vvp" $SRC \
			> "$B/build_$n.log" 2>&1 || { echo "FAILED: iverilog build $n, see $B/build_$n.log"; cat "$B/build_$n.log"; exit 1; }
	fi
}
simrun() {  # simrun <name> <dir> <plusargs...>
	local n=$1 d=$2; shift 2
	if [ "$SIM" = verilator ]; then (cd "$d" && "$B/vl_$n/sim" "$@")
	else (cd "$d" && vvp -n "$B/$n.vvp" "$@"); fi
}
leg() {     # leg <name> <leg>: exit 0 if the leg passes
	local n=$1 l=$2 d=$B/$1_$2 pa=
	rm -rf "$d"; python3 "$HERE/model.py" gen "$l" "$d" || return 1
	[ "$l" = off ] && pa=+off
	[ "$l" = hz60 ] && pa=+hz60
	[ "$l" = vtop ] && pa=+vtop=10
	[ "$l" = oldrast ] && n=${n}_old
	simrun "$n" "$d" $pa > "$d/tb.log" 2>&1
	grep -q "^=== PASS" "$d/tb.log" || return 1
	python3 "$HERE/model.py" check "$d" > "$d/model.log" 2>&1
}

# OLD: the generator's vertical raster before 2026-10-27 (leg oldrast)
if [ "$SIM" = verilator ]; then OLD="-GVT_TOP=0 -GVT_FP=5 -GVT_SYNC=5 -GVT_BP=20"
else OLD="-Posd_text_tb.VT_TOP=0 -Posd_text_tb.VT_FP=5 -Posd_text_tb.VT_SYNC=5 -Posd_text_tb.VT_BP=20"; fi
build ok
build mut +define+OSD_TEXT_MUTANT
if [[ " $LEGS " == *" oldrast "* ]]; then
	build ok_old $OLD
	build mut_old $OLD +define+OSD_TEXT_MUTANT
fi
echo "osd_text bench ($SIM, LAT $LAT, $JOBS jobs, nice $NICE)"
# at most JOBS simulations at a time; each writes <dir>/result (0 = pass)
for l in $LEGS; do
	for n in ok mut; do
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
		( leg "$n" "$l"; echo $? > "$B/${n}_$l.result" ) &
	done
done
wait
fail=0; caught=0
for l in $LEGS; do
	if [ "$(cat "$B/ok_$l.result" 2>/dev/null)" = 0 ]; then echo "  pass  $l"; sed 's/^/        /' "$B/ok_$l/model.log"
	else echo "  FAIL  $l"; grep -h -E "FAIL|differ|pixels" "$B/ok_$l/tb.log" "$B/ok_$l/model.log" 2>/dev/null | head -5 | sed 's/^/        /'; fail=1; fi
	if [ "$(cat "$B/mut_$l.result" 2>/dev/null)" = 0 ]; then echo "        mutant not caught by $l"
	else caught=$((caught + 1)); echo "        mutant caught by $l"; fi
done
if [ $caught -eq 0 ]; then echo "  FAIL  the mutant passes every leg"; fail=1
else echo "  pass  mutant caught by $caught leg(s)"; fi
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
