#!/bin/bash
# sim/hdmi_upsample: gates for the HDMI CRT emulation (pal_to_ddr.sv,
# pal_to_hd_upsample.v, crt_post.v; study 2026-10-08, design 2026-10-09).
#
#   unit       crt_post alone: all controls 0 = input unchanged (9-pixel
#              latency, all 256 values), also with all tables zero (a
#              build that lost the .mem files keeps today's picture);
#              bloom alone (no vertical effect) unchanged too; each mask
#              mode's column pattern;
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
#   rtg        RTG 1:1 path (per-pixel sampling, no reference to compare):
#              every CRT item selected (mask, bloom, beam too) and CRT off
#              (+cfg=0), both with RTG on: frame 3 byte-identical, so the
#              CRT effects stay gated off; the beam filter never on
#   beamfx15   every other CRT effect on, beam off: the beam filter's output
#              = its input every clk_114 (15 kHz); beamfx31, beamfx60 the
#              same at 31 kHz and on the 60 Hz upsampler
#   dim        Scanlines dim (beam profile 2 + LUT page 2): flat-field beat
#              <= 2 %, light within 2 % of the source
#   lace       interlaced, dim: the two fields' line phases 0.5 +- 0.02
#              input line apart (their scanlines interleave)
#   osd        OSD config 0 -> dim during HD frame 3: frame 3 bit-identical,
#              frame 4 changed, the latch moves once, at a frame end
#   osdfx      the same for the new bits: 0 -> mask shadow + bloom high
#   osdspi     userio_osd over SPI: the video command's optional second byte
#              sets {scaling, beam, bloom, mask}; one byte (an older
#              firmware) leaves them 0
#   mask       mask grille (3-px R G B), scanlines off: period 3 in the
#              border, lit > dimmed, light within 3 % (LUT compensation)
#   mask2      mask grille strong: the same
#   maskmg     mask shadow (2-px magenta / green): period 2
#   mask_dim   grille + scanlines dim: light within 2 %, beat <= 2 %
#   bloom      dim + bloom high: white-bar scanline modulation <= 0.5 x
#              dim's, dark ramp bit-identical to dim, border light +- 6 %
#   bloom_lo   dim + bloom low: modulation <= 0.85 x dim's, border +- 3 %
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
#   hposm      OSD Video Pos HPOS -24 (signed offset), 50 Hz: the picture
#              is hpos0's moved 24 HD pixels left, pixel for pixel; hposp
#              +24 moves it right; hposm60 / hposp60 the same on the 60 Hz
#              upsampler (against hpos060)
#   hposv      VPOS 16, HPOS 0 (50 Hz): no horizontal move against hpos0
#              (the 50 Hz path once took its horizontal offset from VPOS)
#   vposp      OSD Video Pos VPOS +8 (signed, 64 us steps = one 15 kHz input
#              line, positive down), 50 Hz: every non-black row is a row of
#              hpos0's picture moved 8 x 2.40 = 19.2 HD lines down (row
#              floor or ceil of y - 19.2), frames 6 and 7 identical, every
#              frame >= 730 HD lines with one vsync; vposm -8 up; vposp60 /
#              vposm60 the same on the 60 Hz upsampler (8 x 2.88 = 23.0 HD
#              lines, against hpos060); vposdbl +8 at 31 kHz moves 19.2 HD
#              lines too (against vposdbl0)
#   vposlace   interlaced, VPOS +8 (vposlacem -8): the picture of each field
#              is vposlace0's moved, and the two fields' line phases stay
#              0.5 +- 0.02 input line apart
#   vposchg    VPOS +8 -> +4 during HD frame 8: frames 9 and 10 at +4 and
#              frame 9 = frame 10 below the top 20 HD lines (each frame's
#              top four input lines show line buffers written before the
#              restart: after a frame of another length, other ones), 10 =
#              11, every frame >= 730 HD lines with one vsync, at most one
#              frame of another length; vposchg0 0 -> +4 the same (the
#              real-vsync path to the virtual one); vposchgz +4 -> 0 and
#              vposchgzm -4 -> 0 back to the real path: frames 10 and 11
#              bit-identical to the reference path
#   vposglide  VPOS -8 -> +8 during HD frame 8 (more than one frame may
#              shorten by): every frame a clean picture at one VPOS, the
#              position moving monotonically to +8 at most 5 steps a frame,
#              every frame >= 730 HD lines with one vsync, the last two
#              frames = vposp's
#   osdbeam    OSD config 0 -> beam medium during HD frame 3: frame 3
#              bit-identical, frame 4 changed, the beam latch moves once,
#              in the vertical blank (input lines 2..6)
#   osd2spi    userio_osd's OSD text layer commands over SPI
#              (tb_osd_text_spi.v): cells by lane, font, palette staging,
#              cfg + commit toggle, VERSION bytes 10-14, an unknown command
#              and 0x0C untouched; the two mutants (commit, lane) must fail
#   osd2off    the OSD text layer (osd_text.v) loaded, committed disabled:
#              the picture = the reference path's, and every record of the
#              golden p50 (pictures, frame lengths, pin signatures) equal
#   osd2win    the layer on, scale 2, 64 x 20 at (128, 40): adv_ddr's
#              picture = osd_text model.py over the generator's picture
#              (osd2_check.py, no stored golden); and at the pins, both
#              bus words of every pixel (adv_ddr's {r, g[7:4]}, {g[3:0], b})
#              = the model over the generator's picture, pin x = model x
#              (osd2_check.py pins: a layer pixel straddling two pin pixels
#              fails here, the one-clock-per-pixel picture cannot see it);
#              osd2win60 the same on the 60 Hz path; both print where the
#              pin raster sits on the generator's ("osd2 pins")
#   nosync     the Amiga hsync and vsync stop from HD frame 4 on (RTG mode
#              with its sync start past the frame size), RGB runs on: the
#              signal generator's watchdog ends one frame of 1500 lines
#              (vt_count 0..1499, the last one cut at its start like every
#              frame's: 1499 hsyncs, as a 750-line frame counts 749), then
#              the raster free-runs: every later frame 749 hsyncs, all with
#              one vsync, at least 6 of them; no frame longer than 1500
#
# The Lores/Hires Filter legs (dim_hv, bloom_hv, split, the unit's [1 6 1]/8
# and [1 2 1]/4 steps) went with the filters on 2026-10-26
# (findings/osd-redesign/plan.md 3.13); cfg bits 5:2 are reserved since.
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
	[rtg]="+rtg +cfg=fff +out=$I/rtg"
	[rtg0]="+rtg +cfg=0 +out=$I/rtg0"
	[beamfx15]="+cfg=3ff"
	[beamfx31]="+dbl +cfg=3ff"
	[beamfx60]="+force60 +cfg=3ff"
	[hpos0]="+out=$I/hpos0"
	[hposm]="+hoff=-24 +out=$I/hposm"
	[hposp]="+hoff=24 +out=$I/hposp"
	[hposv]="+voff=16 +out=$I/hposv"
	[hpos060]="+force60 +out=$I/hpos060"
	[hposm60]="+force60 +hoff=-24 +out=$I/hposm60"
	[hposp60]="+force60 +hoff=24 +out=$I/hposp60"
	[vposp]="+voff=8 +first=6 +frames=2 +out=$I/vposp"
	[vposm]="+voff=-8 +first=6 +frames=2 +out=$I/vposm"
	[vposp60]="+force60 +voff=8 +first=6 +frames=2 +out=$I/vposp60"
	[vposm60]="+force60 +voff=-8 +first=6 +frames=2 +out=$I/vposm60"
	[vposdbl0]="+dbl +first=6 +out=$I/vposdbl0"
	[vposdbl]="+dbl +voff=8 +first=6 +out=$I/vposdbl"
	[vposlace0]="+lace +first=6 +frames=2 +out=$I/vposlace0"
	[vposlace]="+lace +voff=8 +first=6 +frames=2 +out=$I/vposlace"
	[vposlacem]="+lace +voff=-8 +first=6 +frames=2 +out=$I/vposlacem"
	[vposchg]="+voff=8 +voff2=4 +vofframe=8 +voffline=300 +first=7 +frames=5 +out=$I/vposchg"
	[vposchg0]="+voff2=4 +vofframe=8 +voffline=300 +first=7 +frames=5 +out=$I/vposchg0"
	[vposchgz]="+voff=4 +voff2=0 +vofframe=8 +voffline=300 +first=7 +frames=5 +out=$I/vposchgz"
	[vposchgzm]="+voff=-4 +voff2=0 +vofframe=8 +voffline=300 +first=7 +frames=5 +out=$I/vposchgzm"
	[vposglide]="+voff=-8 +voff2=8 +vofframe=8 +voffline=300 +first=7 +frames=8 +out=$I/vposglide"
	[osdbeam]="+cfg=000 +cfg2=800 +cfgframe=3 +cfgline=300 +frames=2"
	[nosync]="+nosync=4 +first=2 +frames=12"
	[dim]="+cfg=01 +out=$I/dim"
	[lace]="+cfg=01 +lace +frames=2 +out=$I/lace"
	[osd]="+cfg=00 +cfg2=01 +cfgframe=3 +cfgline=300 +frames=2"
	[osdfx]="+cfg=000 +cfg2=2c0 +cfgframe=3 +cfgline=300 +frames=2"
	[mask]="+cfg=040 +out=$I/mask"
	[mask2]="+cfg=080 +out=$I/mask2"
	[maskmg]="+cfg=0c0 +out=$I/maskmg"
	[mask_dim]="+cfg=041 +out=$I/mask_dim"
	[bloom]="+cfg=201 +out=$I/bloom"
	[bloom_lo]="+cfg=101 +out=$I/bloom_lo"
	[osd2off]="+osd2=$I/osd2off.d +first=6"
	[osd2win]="+osd2=$I/osd2win.d +out=$I/osd2win +osd2gen=$I/osd2win_gen +pins=2 +pinsfile=$I/osd2win_pins.txt"
	[osd2win60]="+force60 +osd2=$I/osd2win.d +out=$I/osd2win60 +osd2gen=$I/osd2win60_gen +pins=2 +pinsfile=$I/osd2win60_pins.txt"
)
DITHER="+frame=build/dither.hex +hires=build/dither_hires.hex"
BEAMS=""
for w in 1 2 3; do for b in 0 1 2; do
	BEAMS="$BEAMS beam_w${w}b${b}"
	ARGS[beam_w${w}b${b}]="$DITHER +cfg=$(printf %03x $(( (w << 10) | (b << 8) ))) +out=$I/beam_w${w}b${b} +sdump=$I/beam_w${w}b${b}.sd"
done; done
ALL="unit osdspi ripple bypass15 bypass31 gate31 bypass60 rtg beamfx15 beamfx31 beamfx60 dim lace osd osdfx osdbeam mask mask2 maskmg mask_dim bloom bloom_lo $BEAMS beamalign beammetric hposm hposp hposv hposm60 hposp60 vposp vposm vposp60 vposm60 vposdbl vposlace vposlacem vposchg vposchg0 vposchgz vposchgzm vposglide nosync osd2spi osd2off osd2win osd2win60"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
# the bloom legs compare against the same picture without bloom
want() { local x; for x in "${legs[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
{ want bloom || want bloom_lo; } && ! want dim && legs+=(dim)
want rtg && ! want rtg0 && legs+=(rtg0)
# the Video Pos legs compare against the picture at offset 0
for x in hposm hposp hposv; do want $x && ! want hpos0 && legs+=(hpos0); done
for x in hposm60 hposp60; do want $x && ! want hpos060 && legs+=(hpos060); done
for x in vposp vposm vposchg vposchg0 vposchgz vposchgzm vposglide; do want $x && ! want hpos0 && legs+=(hpos0); done
for x in vposp60 vposm60; do want $x && ! want hpos060 && legs+=(hpos060); done
want vposdbl && ! want vposdbl0 && legs+=(vposdbl0)
for x in vposlace vposlacem; do want $x && ! want vposlace0 && legs+=(vposlace0); done
want vposglide && ! want vposp && legs+=(vposp)
# beamalign and beammetric use the beam legs' pictures
want beamalign && { want beam_w2b0 || legs+=(beam_w2b0); want beam_w3b2 || legs+=(beam_w3b2); }
want beammetric && for x in beam_w1b0 beam_w2b0 beam_w3b0 beam_w1b1; do want $x || legs+=($x); done
# the OSD text layer legs' data (osd2_check.py)
want osd2off && python3 osd2_check.py gen $I/osd2off.d off
{ want osd2win || want osd2win60; } && python3 osd2_check.py gen $I/osd2win.d win
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
# HD frames $2..$3 of leg $1: each >= 730 HD lines (past the HD vsync) with
# exactly one vsync; prints the lengths, fails otherwise
hdframes() {
	awk -v a=$2 -v b=$3 '/^hd frame / { n = $3 + 0; if (n >= a && n <= b) {
		l = $4 + 0; v = $6 + 0; s = s " " l; if (l < 730 || v != 1) bad = 1 } }
		END { printf "HD lines per frame %d..%d:%s\n", a, b, s; exit bad }' $I/$1.log
}
# how many of HD frames $2..$3 of leg $1 differ in length (by more than one
# HD line) from frame $2 - 1
hdother() {
	awk -v a=$2 -v b=$3 '/^hd frame / { n = $3 + 0; l = $4 + 0; if (n == a - 1) r = l;
		if (n >= a && n <= b && (l > r + 1 || l < r - 1)) c++ } END { print c + 0 }' $I/$1.log
}
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
		echo "$u" | grep -q "bloom alone identity: 0 mismatches" && pass "unit bloom alone: identity" || bad "unit bloom alone: identity"
		for n in 1 2 3; do
			echo "$u" | grep -q "^mask=$n: .* OK" && pass "unit mask $n: column pattern" || { bad "unit mask $n"; echo "$u" | grep "^mask=$n"; }
		done
		echo "$u" | grep -q "^bloom gap .* OK" && pass "unit bloom: white gap filled (high > low > off), dark grey untouched" \
			|| { bad "unit bloom"; echo "$u" | grep "^bloom gap"; }
		u=$(vvp -n build/tb_crt_post_unit_zero.vvp)
		echo "$u" | grep -q "bypass identity: 0 mismatches" && pass "unit bypass identity with both tables zero" || bad "unit bypass identity with both tables zero"
		;;
	hposm|hposp|hposm60|hposp60)
		n=24; [ ${l:4:1} = m ] && n=-24
		r=hpos0; [ ${l: -2} = 60 ] && r=hpos060
		m=$(python3 crt_hpos.py shift $I/${r}_3.hex $I/${l}_3.hex $n) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: Video Pos HPOS $n moves the picture $n HD pixels" || bad "$l"
		;;
	hposv)
		m=$(python3 crt_hpos.py rows $I/hpos0_3.hex $I/hposv_3.hex) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "hposv: VPOS does not move the 50 Hz picture sideways" || bad "hposv"
		;;
	vposp|vposm|vposp60|vposm60|vposdbl)
		n=8; [ ${l:4:1} = m ] && n=-8
		r=hpos0; hz=50; [ ${l: -2} = 60 ] && { r=hpos060; hz=60; }
		[ $l = vposdbl ] && r=vposdbl0
		f=3; [ $l = vposdbl ] && f=6
		m=$(python3 crt_vpos.py shift $I/${r}_$f.hex $I/${l}_6.hex $n $hz) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: VPOS $n moves the picture $n input lines" || bad "$l"
		if [ $l != vposdbl ]; then
			cmp -s $I/${l}_6.hex $I/${l}_7.hex && pass "$l: frames 6 and 7 identical" || bad "$l: frames 6 and 7 differ"
		fi
		m=$(hdframes $l 1 7) && pass "$l: $m" || bad "$l: $m"
		;;
	vposlace|vposlacem)
		n=8; [ $l = vposlacem ] && n=-8
		for f in 6 7; do
			m=$(python3 crt_vpos.py shift $I/vposlace0_$f.hex $I/${l}_$f.hex $n 50) && ok=1 || ok=0
			echo "$m" | sed 's/^/        /'
			[ $ok -eq 1 ] && pass "$l: field $f is vposlace0's moved $n input lines" || bad "$l: field $f"
		done
		m=$(python3 crt_check.py lace $I/${l}_phase.txt 6 7)
		echo "        $m"
		echo "$m" | awk '{ v = $(NF-6) + 0; exit !(v >= 0.48 && v <= 0.52) }' \
			&& pass "$l: phase 0.5 +- 0.02" || bad "$l: lace phase"
		m=$(hdframes $l 1 7) && pass "$l: $m" || bad "$l: $m"
		;;
	vposchg|vposchg0|vposchgz|vposchgzm)
		v=4; [ ${l:0:8} = vposchgz ] && v=0
		grep '^voff change' $I/$l.log | sed 's/^/        /'
		ok=1
		for f in 9 10; do
			m=$(python3 crt_vpos.py where $I/hpos0_3.hex $I/${l}_$f.hex 50 -10 10) || ok=0
			echo "        frame $f: $m"; [ "$m" = "at $v" ] || ok=0
		done
		cmp -s $I/${l}_10.hex $I/${l}_11.hex || ok=0
		python3 crt_vpos.py same $I/${l}_9.hex $I/${l}_10.hex 20 || ok=0
		[ $ok -eq 1 ] && pass "$l: frames 9 and 10 at VPOS $v, 10 and 11 identical, 9 = 10 below the top 20 HD lines" || bad "$l: frames 9..11"
		# back at VPOS 0: the real-vsync path again, bit-identical to the reference
		if [ $v = 0 ]; then
			d=$(grep -E '^frame (10|11): ' $I/$l.log | awk '{ print $3 }' | paste -sd' ')
			[ "$d" = "0 0" ] && pass "$l: frames 10 and 11 bit-identical to the reference path" || bad "$l: frames 10, 11 differ from the reference ($d)"
		fi
		m=$(hdframes $l 1 11) && pass "$l: $m" || bad "$l: $m"
		o=$(hdother $l 8 11)
		[ "$o" -le 1 ] && pass "$l: $o frame(s) of another length" || bad "$l: $o frames of another length"
		;;
	vposglide)
		grep '^voff change' $I/$l.log | sed 's/^/        /'
		ok=1; prev=-99; ks=""
		for f in 7 8 9 10 11 12 13; do
			m=$(python3 crt_vpos.py where $I/hpos0_3.hex $I/${l}_$f.hex 50 -10 10) || ok=0
			k=${m#at }; ks="$ks $m"
			if [ "$m" = "at $k" ]; then
				[ $f = 7 ] && [ "$k" != -8 ] && ok=0
				[ $prev != -99 ] && { [ $k -lt $prev ] || [ $((k - prev)) -gt 5 ]; } && ok=0
				prev=$k
			else ok=0; fi
		done
		echo "        frames 7..13:$ks"
		cmp -s $I/${l}_13.hex $I/vposp_6.hex && cmp -s $I/${l}_14.hex $I/vposp_6.hex || ok=0
		[ $ok -eq 1 ] && pass "$l: each frame clean, -8 -> +8 monotonic, <= 5 a frame, frames 13, 14 = vposp's" || bad "$l"
		m=$(hdframes $l 1 14) && pass "$l: $m" || bad "$l: $m"
		;;
	nosync)
		# from HD frame 4 (nosync) on: one watchdog frame (1500 lines, the
		# bench counts 1499 hsyncs), then free-run frames of 749 hsyncs,
		# each with 1 vsync; no frame longer than 1500
		m=$(awk '/^hd frame / { n = $3 + 0; l = $4 + 0; v = $6 + 0; if (l > 1500) bad = 1
			if (n >= 4) { s = s " " l "/" v
				if (!wd) { if (l == 1499 && v == 1) wd = n; else bad = 1 }
				else { c++; if (l != 749 || v != 1) bad = 1 } } }
			END { printf "HD lines/vsyncs per frame from 4:%s (watchdog frame %d, %d free-run)\n", s, wd, c
				exit bad || !wd || c < 6 }' $I/$l.log) && ok=1 || ok=0
		grep '^hd frame ' $I/$l.log | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: syncs stopped, $m" || bad "$l: $m"
		;;
	osdspi)
		u=$(vvp -n build/tb_osd_video.vvp)
		echo "$u" | grep FAIL | sed 's/^/        /'
		echo "$u" | grep -q "osd video: 0 errors" && pass "osdspi: second byte -> {scaling, beam, bloom, mask}, one byte leaves them off" || bad "osdspi"
		;;
	osd2spi)
		u=$(vvp -n build/tb_osd_text_spi.vvp)
		echo "$u" | grep FAIL | sed 's/^/        /'
		echo "$u" | grep -q "osd text spi: 0 errors" && pass "osd2spi: 0x2C/0x3C/0x4C/0x5C, VERSION 10-14, 0x6C and 0x0C" || bad "osd2spi"
		for m in OSD_TXT_MUTANT_COMMIT OSD_TXT_MUTANT_LANE; do
			vvp -n build/tb_osd_text_spi_$m.vvp | grep -q "osd text spi: 0 errors" && bad "osd2spi: mutant $m not caught" \
				|| pass "osd2spi: mutant $m caught"
		done
		;;
	osd2off)
		if allzero $l 1; then pass "$l: layer loaded, off: $(diffs $l | sed 's/ (.*//')"; else bad "$l"; diffs $l; fi
		m=$(python3 golden.py check $I/$l.log golden/p50.txt) && pass "$l: golden p50 $m" || bad "$l: golden p50 $m"
		;;
	osd2win|osd2win60)
		grep -m1 '^osd2 pins' $I/$l.log | sed 's/^/        /'
		m=$(python3 osd2_check.py check $I/osd2win.d $I/${l}_gen_3.hex $I/${l}_3.hex) && pass "$l: picture $m" || bad "$l: $m"
		# the pins (pin frame 2 = HD frame 3): both bus words of every pixel
		m=$(python3 osd2_check.py pins $I/osd2win.d $I/${l}_gen_3.hex $I/${l}_gen_3b.hex $I/${l}_pins.txt) && pass "$l: $m" || bad "$l: $m"
		;;
	ripple)
		r=$(python3 crt_check.py ripple ../../rtl/openaars/adv7511/crt_wrom.mem)
		echo "$r" | sed 's/^/        /'
		echo "$r" | awk '/scan [23]:/ { if ($7 + 0 > 1.1) b = 1 } END { exit b }' \
			&& pass "ripple <= 1.1 (two-line beam, scan 2 and 3, 50 and 60 Hz)" || bad "ripple"
		;;
	bypass15|bypass31|gate31|bypass60)
		n=1; [[ "${ARGS[$l]}" == *frames=2* ]] && n=2
		if allzero $l $n; then pass "$l: $(diffs $l | sed 's/ (.*//' | paste -sd, -)"
		else bad "$l"; diffs $l; tail -3 $I/$l.log; fi
		grep -q "non-black" $I/$l.log && ! grep -q " 0 non-black" $I/$l.log || bad "$l: empty picture"
		beamoff $l 1 && pass "$l: beam filter off, its output = its input ($(grep '^beam bypass:' $I/$l.log | cut -d: -f2))" \
			|| { bad "$l: beam bypass"; grep '^beam bypass:' $I/$l.log; }
		;;
	rtg)
		if cmp -s $I/rtg_3.hex $I/rtg0_3.hex; then pass "rtg: CRT effects all on = CRT off, frame 3 byte-identical"
		else bad "rtg: CRT on differs from CRT off"; fi
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
	dim|mask_dim)
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
	bloom|bloom_lo)
		r=dim
		x=0.5; bd=0.06; [ $l = bloom_lo ] && { x=0.85; bd=0.03; }
		m=$(python3 crt_check.py bloom $I/${l}_3.hex $I/${r}_3.hex $x $bd) && ok=1 || ok=0
		echo "$m" | sed 's/^/        /'
		[ $ok -eq 1 ] && pass "$l: white-bar modulation <= $x x $r's, dark ramp unchanged" || bad "$l"
		;;
	esac
done
# pictures of the effects, for the eye
for l in "${legs[@]}"; do
	case $l in dim|mask*|bloom*) [ -f $I/${l}_3.hex ] && python3 crt_tohex2img.py $I/${l}_3.hex > /dev/null ;; esac
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
