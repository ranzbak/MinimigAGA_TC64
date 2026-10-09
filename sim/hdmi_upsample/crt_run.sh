#!/bin/bash
# sim/hdmi_upsample: gates for the HDMI CRT emulation (pal_to_ddr.sv,
# pal_to_hd_upsample.v, crt_post.v; study 2026-10-08, design 2026-10-09).
#
#   unit       crt_post alone: all controls 0 = input unchanged (8-pixel
#              latency, all 256 values), also with both tables all zero (a
#              build that lost the .mem files keeps today's picture);
#              [1 6 1]/8 and [1 2 1]/4 on a step
#   ripple     two-line beam profiles in crt_wrom.mem: light per input line
#              max/min <= 1.1 (flat field, 2.4 HD lines per input line)
#   bypass15   OSD config 0, 15 kHz input: HDMI picture bit-identical to the
#              committed path (ref/, 662cd10), 2 frames
#   bypass31   same at 31 kHz (the scandoubler on, the firmware default)
#   gate31     every CRT item selected but 31 kHz input: still bit-identical
#   bypass60   OSD config 0 on the 60 Hz upsampler: bit-identical
#   rtg        every CRT item selected with RTG on: bit-identical
#   dim        Scanlines dim (beam profile 2 + LUT page 2): flat-field beat
#              <= 2 %, light within 2 % of the source
#   dim_hv     dim + H and V filters (two-line beam, blur): same limits
#   lace       interlaced, dim: the two fields' line phases 0.5 +- 0.02
#              input line apart (their scanlines interleave)
#   split      lowres/hires split screen with mid-line BPLCON0 switches,
#              H filters on: each HD row gets the kernel of its own line only
#   osd        OSD config 0 -> dim during HD frame 3: frame 3 bit-identical,
#              frame 4 changed, the latch moves once, at a frame end
#
# Usage: crt_run.sh [leg ...] (default: all).  Needs iverilog, verilator,
# python3 with numpy.  Pictures and logs: build/img/.  ~2 min on 3 cores.
set -e
cd "$(dirname "$0")"
./crt_build.sh > /dev/null
mkdir -p build/img
V=build/tb_crt_frame/Vtb
I=build/img
declare -A ARGS=(
	[bypass15]="+frames=2"
	[bypass31]="+dbl +frames=2"
	[gate31]="+dbl +cfg=3d"
	[bypass60]="+force60 +frames=2"
	[rtg]="+rtg +cfg=3d"
	[dim]="+cfg=01 +out=$I/dim"
	[dim_hv]="+cfg=3d +out=$I/dim_hv"
	[lace]="+cfg=01 +lace +frames=2 +out=$I/lace"
	[split]="+cfg=14 +split +out=$I/split"
	[osd]="+cfg=00 +cfg2=01 +cfgframe=3 +cfgline=300 +frames=2"
)
ALL="unit ripple bypass15 bypass31 gate31 bypass60 rtg dim dim_hv lace split osd"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
# the Verilator legs, at most 3 at a time (one core each)
sims=(); for l in "${legs[@]}"; do [ -n "${ARGS[$l]}" ] && sims+=("$l"); done
for l in "${sims[@]}"; do echo "$l ${ARGS[$l]}"; done | \
	xargs -P 3 -L 1 bash -c 'l=$0; '"$V"' "$@" > '"$I"'/$l.log 2>&1 || echo "$l: simulation failed"'

fail=0
pass() { echo "  pass  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }
diffs() { grep -E '^frame [0-9]+: [0-9]+ pixels differ' $I/$1.log; }
allzero() {  # every compared frame 0 pixels differ, and as many as asked
	local n; n=$(diffs $1 | wc -l)
	[ "$n" -ge "$2" ] && ! diffs $1 | grep -qv ': 0 pixels differ'
}
for l in "${legs[@]}"; do
	case $l in
	unit)
		u=$(vvp -n build/tb_crt_post_unit.vvp)
		echo "$u" | grep -q "bypass identity: 0 mismatches" && pass "unit bypass identity" || bad "unit bypass identity"
		echo "$u" | grep -q "hblur=1 step: 0 0 0 31 223 255" && pass "unit [1 6 1]/8 step" || bad "unit [1 6 1]/8 step"
		echo "$u" | grep -q "hblur=2 step: 0 0 0 63 191 255" && pass "unit [1 2 1]/4 step" || bad "unit [1 2 1]/4 step"
		u=$(vvp -n build/tb_crt_post_unit_zero.vvp)
		echo "$u" | grep -q "bypass identity: 0 mismatches" && pass "unit bypass identity with both tables zero" || bad "unit bypass identity with both tables zero"
		;;
	ripple)
		r=$(python3 crt_check.py ripple ../../rtl/openaars/adv7511/crt_wrom.mem)
		echo "$r" | sed 's/^/        /'
		echo "$r" | awk '/scan [23]:/ { if ($7 + 0 > 1.1) b = 1 } END { exit b }' \
			&& pass "ripple <= 1.1 (two-line beam, scan 2 and 3, 50 and 60 Hz)" || bad "ripple"
		;;
	bypass15|bypass31|gate31|bypass60|rtg)
		n=1; [[ "${ARGS[$l]}" == *frames=2* ]] && n=2
		if allzero $l $n; then pass "$l: $(diffs $l | sed 's/ (.*//' | paste -sd, -)"
		else bad "$l"; diffs $l; tail -3 $I/$l.log; fi
		grep -q "non-black" $I/$l.log && ! grep -q " 0 non-black" $I/$l.log || bad "$l: empty picture"
		;;
	dim|dim_hv)
		m=$(python3 crt_check.py flat $I/${l}_3.hex)
		echo "        $m"
		echo "$m" | awk '{ L = $3 + 0; B = $5 + 0; exit !(L >= 0.98 && L <= 1.02 && B <= 2.0) }' \
			&& pass "$l: light within 2 %, beat <= 2 %" || bad "$l"
		;;
	lace)
		m=$(python3 crt_check.py lace $I/lace_phase.txt 3 4)
		echo "        $m"
		echo "$m" | awk '{ v = $(NF-6) + 0; exit !(v >= 0.48 && v <= 0.52) }' \
			&& pass "lace: phase 0.5 +- 0.02" || bad "lace"
		;;
	split)
		m=$(python3 crt_check.py split $I/split_3.hex) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "split: each row its own kernel" || bad "split"
		;;
	osd)
		f3=$(grep -E '^frame 3: ' $I/osd.log | awk '{ print $3 }')
		f4=$(grep -E '^frame 4: ' $I/osd.log | awk '{ print $3 }')
		nl=$(grep -c '^cfg latched' $I/osd.log || true)
		grep '^cfg' $I/osd.log | sed 's/^/        /'
		if [ "$f3" = "0" ] && [ -n "$f4" ] && [ "$f4" != "0" ] && [ "$nl" = "1" ] && grep -q '^cfg latched.*at frame end: 1' $I/osd.log
		then pass "osd: frame 3 unchanged, frame 4 changed ($f4 px), latched once at the frame end"
		else bad "osd (frame 3: $f3, frame 4: $f4, latches: $nl)"; fi
		;;
	esac
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
