#!/bin/bash
# sim/hdmi_upsample: gates for the HDMI scaler (findings/scaler/plan.md).
#
#   ring*      the 16-line ring (step 3): tb_crt_frame's ring bookkeeping
#              (see "the line-buffer ring" there): the reader never reads a
#              line slot the writer is writing, no slot is overwritten while
#              an HD line reads it, the lag stays inside the ring -- over
#              whole frames (HD frames 3..6).  Line-rate mode: PAL, NTSC,
#              PAL on the 60 Hz path, interlace, 31 kHz, VPOS -30 / +40, on
#              the 8 buffers it uses (lag 3..4) and forced onto all 16
#              (+ring16, the same)
#   rat*       the exact-ratio stepping (step 4), Scaling sharp (cfg 1000)
#              unless named: the ring check as above with the lag 2..15
#              (in time: >= 2 at an HD line's first read, < 16 at its
#              last), over four whole frames once VPOS has glided to its
#              target, and the geometry (scl_check.py geom: y steps exactly
#              2/5 resp. 1/3 per HD line; HD row 0's centre at source line
#              24.2 PAL / 22.1667 NTSC, the window 24..311 / 22..261 at
#              2.5x / 3x).  rat50 rat60: PAL, NTSC (the study's frame,
#              scaler/mkframes.py); ratarea50: Scaling area; ratlace50,
#              ratlace60: interlace -- the long field's rows half a line
#              lower in the source (centre 24.7 / 22.6667: its lines land
#              half a line above, the fields interleave); ratf60: PAL on the
#              60 Hz path (3x, ring only); ratvp50/ratvm50/ratvp60/ratvm60:
#              VPOS +64 / -64 (the OSD's ends; the window moves by as many
#              source lines, the vsync lines inside it), ring and stepping
#   ratrows    the exact-ratio picture with crt_post's vertical effects off
#              (step 4: row = line floor(y)) against the line-rate picture
#              of the same frame: every row is a line-rate row of its
#              source line, the rows before the window black
#
# The golden frames (golden.sh check) are the other gate of every step.
# Usage: scaler_run.sh [leg ...] (default: all).  Logs: build/scaler/.
# SCALER_JOBS parallel simulations (default 8).
set -e
cd "$(dirname "$0")"
./crt_build.sh > /dev/null
B=build/scaler
mkdir -p $B
declare -A ARGS=(
	[ring50]="+first=3 +frames=4"
	[ring60]="+ntsc +first=3 +frames=4"
	[ringf60]="+force60 +first=3 +frames=4"
	[ringlace]="+lace +first=3 +frames=4"
	[ringdbl]="+dbl +first=3 +frames=4"
	[ringvm]="+voff=-30 +first=10 +frames=4"
	[ringvp]="+voff=40 +first=14 +frames=4"
)
for l in ring50 ring60 ringf60 ringlace ringdbl ringvm ringvp; do
	ARGS[${l}_16]="${ARGS[$l]} +ring16"
done
FP="+frame=build/scaler_pal.hex"
FN="+ntsc +frame=build/scaler_ntsc.hex"
ARGS[rat50]="$FP +cfg=1000 +first=8 +frames=4 +out=$B/rat50"
ARGS[rat60]="$FN +cfg=1000 +first=8 +frames=4 +out=$B/rat60"
ARGS[ratarea50]="$FP +cfg=2000 +first=8 +frames=4 +out=$B/ratarea50"
ARGS[ratlace50]="$FP +lace +cfg=1000 +first=8 +frames=4 +out=$B/ratlace50"
ARGS[ratlace60]="$FN +lace +cfg=1000 +first=8 +frames=4 +out=$B/ratlace60"
ARGS[ratf60]="$FP +force60 +cfg=1000 +first=8 +frames=4"
ARGS[ratvp50]="$FP +cfg=1000 +voff=64 +first=24 +frames=3 +out=$B/ratvp50"
ARGS[ratvm50]="$FP +cfg=1000 +voff=-64 +first=24 +frames=3 +out=$B/ratvm50"
ARGS[ratvp60]="$FN +cfg=1000 +voff=64 +first=24 +frames=3 +out=$B/ratvp60"
ARGS[ratvm60]="$FN +cfg=1000 +voff=-64 +first=24 +frames=3 +out=$B/ratvm60"
ARGS[lr50]="$FP +first=8 +frames=1 +out=$B/lr50"
ALL="ring50 ring60 ringf60 ringlace ringdbl ringvm ringvp ring50_16 ring60_16 ringf60_16 ringlace_16 ringdbl_16 ringvm_16 ringvp_16"
ALL="$ALL rat50 rat60 ratarea50 ratlace50 ratlace60 ratf60 ratvp50 ratvm50 ratvp60 ratvm60 ratrows"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
want() { local x; for x in "${legs[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
want ratrows && { want rat50 || legs+=(rat50); want lr50 || legs+=(lr50); }
for l in "${legs[@]}"; do [ -n "${ARGS[$l]}" ] && echo "$l ${ARGS[$l]}"; done | \
	xargs -P ${SCALER_JOBS:-8} -L 1 bash -c 'l=$0; build/tb_crt_frame/Vtb "$@" > '"$B"'/$l.log 2>&1 || echo "$l: simulation failed"'
fail=0
pass() { echo "  pass  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }
for l in "${legs[@]}"; do
	case $l in
	ring*)
		first=$(echo "${ARGS[$l]}" | sed 's/.*+first=\([0-9]*\).*/\1/')
		m=$(python3 scl_check.py ring $B/$l.log $first 3 4 notime) && pass "$l: $m" || bad "$l: $m"
		;;
	ratrows)
		m=$(python3 scl_check.py rows $B/lr50_8.hex $B/lr50_phase.txt $B/rat50_8.hex $B/rat50_phase.txt 8) && pass "$l: $m" || bad "$l: $m"
		;;
	rat*)
		first=$(echo "${ARGS[$l]}" | sed 's/.*+first=\([0-9]*\).*/\1/')
		m=$(python3 scl_check.py ring $B/$l.log $first 2 15) && pass "$l: ring $m" || bad "$l: ring $m"
		[ $l = ratf60 ] && continue
		hz=50; c=24.2; [ ${l: -2} = 60 ] && { hz=60; c=22.1667; }
		case $l in ratvp*) c=$(python3 -c "print($c - 64)");; ratvm*) c=$(python3 -c "print($c + 64)");; esac
		for f in $(seq $first $((first + 2))); do
			cf=$c
			# interlace: the long field's rows lie half a line lower in the source
			if [[ $l == ratlace* ]] && grep -q "^lf $f 1" $B/$l.log; then cf=$(python3 -c "print($c + 0.5)"); fi
			m=$(python3 scl_check.py geom $B/${l}_phase.txt $f $hz $cf) && pass "$l: $m" || bad "$l: $m"
		done
		;;
	esac
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
