#!/bin/bash
# sim/hdmi_upsample: gates for the HDMI CRT emulation (pal_to_ddr.sv,
# pal_to_hd_upsample.v, crt_post.v; study 2026-10-08, design 2026-10-09).
#
#   unit       crt_post alone: all controls 0 = input unchanged (9-pixel
#              latency, all 256 values), also with all tables zero (a
#              build that lost the .mem files keeps today's picture);
#              bloom alone (no vertical effect) unchanged too; [1 6 1]/8
#              and [1 2 1]/4 on a step; each mask mode's column pattern;
#              bloom fills the scanline gap of white (more on high), not
#              of a dark grey
#   ripple     two-line beam profiles in crt_wrom.mem: light per input line
#              max/min <= 1.1 (flat field, 2.4 HD lines per input line)
#   bypass15   OSD config 0, 15 kHz input: HDMI picture bit-identical to the
#              committed path (ref/, 662cd10), 2 frames; the beam filter's
#              output = its input every clk_114 (beam bypass)
#   bypass31   same at 31 kHz (the scandoubler on, the firmware default)
#   gate31     every CRT item selected (mask, bloom, beam too) but 31 kHz
#              input: still bit-identical, the beam filter never on
#   bypass60   OSD config 0 on the 60 Hz upsampler: bit-identical
#   rtg        every CRT item selected (mask, bloom, beam too) with RTG on:
#              bit-identical, the beam filter never on
#   beamfx15   every other CRT effect on, beam off: the beam filter's output
#              = its input every clk_114 (15 kHz); beamfx31, beamfx60 the
#              same at 31 kHz and on the 60 Hz upsampler
#   dim        Scanlines dim (beam profile 2 + LUT page 2): flat-field beat
#              <= 2 %, light within 2 % of the source
#   dim_hv     dim + H and V filters (two-line beam, blur): same limits
#   lace       interlaced, dim: the two fields' line phases 0.5 +- 0.02
#              input line apart (their scanlines interleave)
#   split      lowres/hires split screen with mid-line BPLCON0 switches,
#              H filters on: each HD row gets the kernel of its own line only
#   osd        OSD config 0 -> dim during HD frame 3: frame 3 bit-identical,
#              frame 4 changed, the latch moves once, at a frame end
#   osdfx      the same for the new bits: 0 -> mask shadow + bloom high
#   osdspi     userio_osd over SPI: the video command's optional second byte
#              sets {bloom, mask}; one byte (an older firmware) leaves them 0
#   mask       mask grille (3-px R G B), scanlines off: period 3 in the
#              border, lit > dimmed, light within 3 % (LUT compensation)
#   mask2      mask grille strong: the same
#   maskmg     mask shadow (2-px magenta / green): period 2
#   mask_dim   grille + scanlines dim: light within 2 %, beat <= 2 %
#   bloom      dim + bloom high: white-bar scanline modulation <= 0.5 x
#              dim's, dark ramp bit-identical to dim, border light +- 6 %
#   bloom_lo   dim + bloom low: modulation <= 0.85 x dim's, border +- 3 %
#   bloom_hv   dim + H/V filters + bloom high against dim_hv: as bloom
#   beam_wWbB  horizontal beam spot (crt_beamh.v), Beam width W (1 sharp,
#              2 medium, 3 soft), Bloom B (0 off, 1 low, 2 high), on the
#              dither frame (crt_mkdither.py): its output stream over a whole
#              input field equals crt_beamh.py's model, every sample
#   beamalign  medium and soft + bloom high: the 720p picture equals the
#              picture of the model-filtered frame with the filter off,
#              delayed by the filter's sync delay -- bit-identical, so the
#              filtered picture sits where the plain one does
#   beammetric dither blending on the 720p picture (the study's metric):
#              lowres checkerboard contrast cv 15.8 +- 0.5 % at medium,
#              4.0 +- 0.5 at soft, 14.9 +- 0.5 at sharp + bloom low (the
#              study's numbers), sharp between medium and the study's
#              sigma-0.4 42.7; hires checkerboards <= 0.5 / 1.3 +- 0.5;
#              every 50 % patch's mean within 1 code of the linear mix
#   osdbeam    OSD config 0 -> beam medium during HD frame 3: frame 3
#              bit-identical, frame 4 changed, the beam latch moves once,
#              in the vertical blank (input lines 2..6)
#
# Usage: crt_run.sh [leg ...] (default: all).  Needs iverilog, verilator,
# python3 with numpy and PIL.  Pictures and logs: build/img/.  ~6 min on 4
# cores (CRT_JOBS=N for N parallel simulations).
set -e
cd "$(dirname "$0")"
./crt_build.sh > /dev/null
mkdir -p build/img
V=build/tb_crt_frame/Vtb
I=build/img
declare -A ARGS=(
	[bypass15]="+frames=2"
	[bypass31]="+dbl +frames=2"
	[gate31]="+dbl +cfg=fff"
	[bypass60]="+force60 +frames=2"
	[rtg]="+rtg +cfg=fff"
	[beamfx15]="+cfg=3ff"
	[beamfx31]="+dbl +cfg=3ff"
	[beamfx60]="+force60 +cfg=3ff"
	[osdbeam]="+cfg=000 +cfg2=800 +cfgframe=3 +cfgline=300 +frames=2"
	[dim]="+cfg=01 +out=$I/dim"
	[dim_hv]="+cfg=3d +out=$I/dim_hv"
	[lace]="+cfg=01 +lace +frames=2 +out=$I/lace"
	[split]="+cfg=14 +split +out=$I/split"
	[osd]="+cfg=00 +cfg2=01 +cfgframe=3 +cfgline=300 +frames=2"
	[osdfx]="+cfg=000 +cfg2=2c0 +cfgframe=3 +cfgline=300 +frames=2"
	[mask]="+cfg=040 +out=$I/mask"
	[mask2]="+cfg=080 +out=$I/mask2"
	[maskmg]="+cfg=0c0 +out=$I/maskmg"
	[mask_dim]="+cfg=041 +out=$I/mask_dim"
	[bloom]="+cfg=201 +out=$I/bloom"
	[bloom_lo]="+cfg=101 +out=$I/bloom_lo"
	[bloom_hv]="+cfg=23d +out=$I/bloom_hv"
)
DITHER="+frame=build/dither.hex +hires=build/dither_hires.hex"
BEAMS=""
for w in 1 2 3; do for b in 0 1 2; do
	BEAMS="$BEAMS beam_w${w}b${b}"
	ARGS[beam_w${w}b${b}]="$DITHER +cfg=$(printf %03x $(( (w << 10) | (b << 8) ))) +out=$I/beam_w${w}b${b} +sdump=$I/beam_w${w}b${b}.sd"
done; done
ALL="unit osdspi ripple bypass15 bypass31 gate31 bypass60 rtg beamfx15 beamfx31 beamfx60 dim dim_hv lace split osd osdfx osdbeam mask mask2 maskmg mask_dim bloom bloom_lo bloom_hv $BEAMS beamalign beammetric"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
# the bloom legs compare against the same picture without bloom
want() { local x; for x in "${legs[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
{ want bloom || want bloom_lo; } && ! want dim && legs+=(dim)
want bloom_hv && ! want dim_hv && legs+=(dim_hv)
# beamalign and beammetric use the beam legs' pictures
want beamalign && { want beam_w2b0 || legs+=(beam_w2b0); want beam_w3b2 || legs+=(beam_w3b2); }
want beammetric && for x in beam_w1b0 beam_w2b0 beam_w3b0 beam_w1b1; do want $x || legs+=($x); done
# the Verilator legs, CRT_JOBS (4) at a time (one core each)
P=${CRT_JOBS:-4}
sims=(); for l in "${legs[@]}"; do [ -n "${ARGS[$l]}" ] && sims+=("$l"); done
for l in "${sims[@]}"; do echo "$l ${ARGS[$l]}"; done | \
	xargs -P $P -L 1 bash -c 'l=$0; '"$V"' "$@" > '"$I"'/$l.log 2>&1 || echo "$l: simulation failed"'
# beamalign: the model-filtered dither frame, filter off, delayed by the
# sync delay the filter reported
if want beamalign; then
	for x in w2b0 w3b2; do
		w=${x:1:1}; b=${x:3:1}
		python3 crt_beamh.py prefilter build/dither.hex $I/pre_$x.hex $w $b
		d=$(grep -m1 'beam latched .* -> 1' $I/beam_$x.log | sed 's/.*sync delay //')
		echo "${d:-0}" > $I/align_$x.delay
		echo "align_$x +frame=$I/pre_$x.hex +hires=build/dither_hires.hex +cfg=000 +srcdelay=${d:-0} +out=$I/align_$x"
	done | xargs -P $P -L 1 bash -c 'l=$0; '"$V"' "$@" > '"$I"'/$l.log 2>&1 || echo "$l: simulation failed"'
fi

fail=0
pass() { echo "  pass  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }
diffs() { grep -E '^frame [0-9]+: [0-9]+ pixels differ' $I/$1.log; }
# the beam filter's bypass: no mismatch while off; $2 = 1: never on either
beamoff() {
	local m; m=$(grep '^beam bypass:' $I/$1.log)
	echo "$m" | awk -v never=$2 '{ exit !($3 == 0 && $5 > 1000000 && (never == 0 || $9 == 0)) }'
}
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
		echo "$u" | grep -q "bloom alone identity: 0 mismatches" && pass "unit bloom alone: identity" || bad "unit bloom alone: identity"
		for n in 1 2 3; do
			echo "$u" | grep -q "^mask=$n: .* OK" && pass "unit mask $n: column pattern" || { bad "unit mask $n"; echo "$u" | grep "^mask=$n"; }
		done
		echo "$u" | grep -q "^bloom gap .* OK" && pass "unit bloom: white gap filled (high > low > off), dark grey untouched" \
			|| { bad "unit bloom"; echo "$u" | grep "^bloom gap"; }
		u=$(vvp -n build/tb_crt_post_unit_zero.vvp)
		echo "$u" | grep -q "bypass identity: 0 mismatches" && pass "unit bypass identity with both tables zero" || bad "unit bypass identity with both tables zero"
		;;
	osdspi)
		u=$(vvp -n build/tb_osd_video.vvp)
		echo "$u" | grep FAIL | sed 's/^/        /'
		echo "$u" | grep -q "osd video: 0 errors" && pass "osdspi: second byte -> {bloom, mask}, one byte leaves them off" || bad "osdspi"
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
		beamoff $l 1 && pass "$l: beam filter off, its output = its input ($(grep '^beam bypass:' $I/$l.log | cut -d: -f2))" \
			|| { bad "$l: beam bypass"; grep '^beam bypass:' $I/$l.log; }
		;;
	beamfx15|beamfx31|beamfx60)
		beamoff $l 1 && pass "$l: every other effect on, beam off: its output = its input ($(grep '^beam bypass:' $I/$l.log | cut -d: -f2))" \
			|| { bad "$l"; grep '^beam bypass:' $I/$l.log; tail -3 $I/$l.log; }
		;;
	beam_w[123]b[012])
		w=${l:6:1}; b=${l:8:1}
		m=$(python3 crt_beamh.py stream build/dither.hex $I/$l.sd $w $b) && ok=1 || ok=0
		echo "        $m"
		grep -q 'beam latched .* -> 1' $I/$l.log || ok=0
		[ $ok -eq 1 ] && pass "$l: output stream = model, every sample of a field" || { bad "$l"; tail -3 $I/$l.log; }
		;;
	beamalign)
		for x in w2b0 w3b2; do
			if [ -f $I/beam_${x}_3.hex ] && [ -f $I/align_${x}_3.hex ] && cmp -s $I/beam_${x}_3.hex $I/align_${x}_3.hex \
			   && grep -q ' 0 mismatches' $I/align_$x.log
			then pass "beamalign $x: picture = model-filtered frame, filter off, delayed $(cat $I/align_$x.delay) clk_114"
			else bad "beamalign $x"; fi
		done
		;;
	beammetric)
		m=$(python3 crt_beamh.py metrics build/dither_regions.json $I/beam_w1b0_3.hex $I/beam_w2b0_3.hex $I/beam_w3b0_3.hex $I/beam_w1b1_3.hex) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /' | cut -c1-200
		cv() { echo "$m" | grep "^$I/beam_$1_3.hex" | grep -o "$2 e[0-9]* cv[0-9.]*" | sed 's/.*cv//'; }
		emax=$(echo "$m" | grep -o ' e[0-9]* ' | tr -d ' e' | sort -n | tail -1)
		r=$(awk -v a=$(cv w1b0 chk_bw_lo) -v b=$(cv w2b0 chk_bw_lo) -v c=$(cv w3b0 chk_bw_lo) -v d=$(cv w1b1 chk_bw_lo) \
		        -v bh=$(cv w2b0 chk_bw_hi) -v dh=$(cv w1b1 chk_bw_hi) -v e=${emax:-99} 'BEGIN {
			ok = (b >= 15.3 && b <= 16.3) && (c >= 3.5 && c <= 4.5) && (d >= 14.4 && d <= 15.4) &&
			     (a > b && a < 42.7) && (bh <= 0.5) && (dh >= 0.8 && dh <= 1.8) && (e <= 1)
			printf "lowres cv sharp %.1f medium %.1f soft %.1f sharp+bloom-low %.1f, hires medium %.1f sharp+bloom-low %.1f, max err %d\n", a, b, c, d, bh, dh, e
			exit !ok }') && ok2=1 || ok2=0
		[ $ok -eq 1 ] && [ $ok2 -eq 1 ] && pass "beammetric: $r" || bad "beammetric: $r"
		;;
	dim|dim_hv|mask_dim)
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
	osdbeam)
		f3=$(grep -E '^frame 3: ' $I/$l.log | awk '{ print $3 }')
		f4=$(grep -E '^frame 4: ' $I/$l.log | awk '{ print $3 }')
		nl=$(grep -c '^beam latched' $I/$l.log || true)
		ln=$(grep -m1 '^beam latched' $I/$l.log | sed 's/.*input line \([0-9]*\).*/\1/')
		grep '^beam latched\|^cfg change' $I/$l.log | sed 's/^/        /'
		if [ "$f3" = "0" ] && [ -n "$f4" ] && [ "$f4" != "0" ] && [ "$nl" = "1" ] && [ -n "$ln" ] && [ "$ln" -ge 2 ] && [ "$ln" -le 6 ]
		then pass "$l: frame 3 unchanged, frame 4 changed ($f4 px), beam latched once, in input line $ln"
		else bad "$l (frame 3: $f3, frame 4: $f4, beam latches: $nl, line: $ln)"; fi
		;;
	osd|osdfx)
		f3=$(grep -E '^frame 3: ' $I/$l.log | awk '{ print $3 }')
		f4=$(grep -E '^frame 4: ' $I/$l.log | awk '{ print $3 }')
		nl=$(grep -c '^cfg latched' $I/$l.log || true)
		grep '^cfg' $I/$l.log | sed 's/^/        /'
		if [ "$f3" = "0" ] && [ -n "$f4" ] && [ "$f4" != "0" ] && [ "$nl" = "1" ] && grep -q '^cfg latched.*at frame end: 1' $I/$l.log
		then pass "$l: frame 3 unchanged, frame 4 changed ($f4 px), latched once at the frame end"
		else bad "$l (frame 3: $f3, frame 4: $f4, latches: $nl)"; fi
		;;
	mask|mask2|maskmg)
		p=3; [ $l = maskmg ] && p=2
		m=$(python3 crt_check.py mask $I/${l}_3.hex $p) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: period $p, lit > dimmed, light within 3 %" || bad "$l"
		;;
	bloom|bloom_lo|bloom_hv)
		r=dim; [ $l = bloom_hv ] && r=dim_hv
		x=0.5; bd=0.06; [ $l = bloom_lo ] && { x=0.85; bd=0.03; }
		m=$(python3 crt_check.py bloom $I/${l}_3.hex $I/${r}_3.hex $x $bd) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: white-bar modulation <= $x x $r's, dark ramp unchanged" || bad "$l"
		;;
	esac
done
# pictures of the effects, for the eye
for l in "${legs[@]}"; do
	case $l in dim|dim_hv|mask*|bloom*) [ -f $I/${l}_3.hex ] && python3 crt_tohex2img.py $I/${l}_3.hex > /dev/null ;; esac
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
