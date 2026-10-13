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
ALL="ring50 ring60 ringf60 ringlace ringdbl ringvm ringvp ring50_16 ring60_16 ringf60_16 ringlace_16 ringdbl_16 ringvm_16 ringvp_16"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
for l in "${legs[@]}"; do echo "$l ${ARGS[$l]}"; done | \
	xargs -P ${SCALER_JOBS:-8} -L 1 bash -c 'l=$0; build/tb_crt_frame/Vtb "$@" > '"$B"'/$l.log 2>&1 || echo "$l: simulation failed"'
fail=0
pass() { echo "  pass  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }
for l in "${legs[@]}"; do
	case $l in
	ring*)
		first=$(echo "${ARGS[$l]}" | sed 's/.*+first=\([0-9]*\).*/\1/')
		m=$(python3 scl_check.py ring $B/$l.log $first 3 4) && pass "$l: $m" || bad "$l: $m"
		;;
	esac
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
