#!/bin/bash
# sim/hdmi_upsample: the golden frames of the HDMI path before the scaler
# work (findings/scaler/plan.md step 1; RTL as of 3987b84).
#
#   golden.sh record [leg ...]   run the legs, write golden/<leg>.txt
#   golden.sh check  [leg ...]   run the legs, compare with golden/<leg>.txt
#   GOLDEN_KINDS=pic,hd golden.sh check ...   compare only those record kinds
#                                (of pic,hd,sig,fsig; golden.py)
#
# Each leg runs tb_crt_frame (Verilator) for 8 HD frames (mode legs 26) and
# keeps, from HD frame / input field 2 on: the picture hash of every HD
# frame ("pic": every pixel adv_ddr got, raster order), its length ("hd":
# HD lines, vsyncs), and two signatures of pal_to_ddr's output pins
# (o_clk_pixel, o_de, o_vsync, o_hsync, o_data at both clk_148 edges, and
# the clk_148 count): "sig" from one o_vsync rising edge to the next,
# "fsig" per input field.  check passes when every one of them is equal,
# except around a 50/60 Hz path change: there the HD frame it happens in
# and the next (the "one-frame refill" of plan step 2: the two-chain design
# switched between two running chains, the one-chain design refills) and
# the input fields around it; "sig" is left to "fsig" in those legs (see
# golden.py).
#
# Legs: 50 Hz (PAL), 60 Hz (NTSC, and PAL forced onto the 60 Hz path), CRT
# off / scanlines dim / every effect (a7d: beam medium, bloom high, mask
# grille, both filters H+V, scanlines dim) / black + shadow + bloom low
# (1c2), RTG on (every effect selected: gated off), interlace, 31 kHz,
# Video Pos HPOS/VPOS, a VPOS change, and PAL -> NTSC -> PAL (input fields
# 8..15 NTSC) with CRT off and on.  ~4 min on 8 cores (GOLDEN_JOBS).
set -e
cd "$(dirname "$0")"
mode=$1; shift || true
[ "$mode" = record ] || [ "$mode" = check ] || { echo "usage: golden.sh record|check [leg ...]"; exit 2; }
./crt_build.sh > /dev/null
G=golden
B=build/golden
mkdir -p $B
declare -A ARGS=(
	[p50]=""
	[p50dim]="+cfg=01"
	[p50crt]="+cfg=a7d"
	[p50blk]="+cfg=1c2"
	[n60]="+ntsc"
	[n60dim]="+ntsc +cfg=01"
	[n60crt]="+ntsc +cfg=a7d"
	[f60]="+force60"
	[f60crt]="+force60 +cfg=a7d"
	[r50]="+rtg +cfg=a7d"
	[r60]="+ntsc +rtg"
	[r60crt]="+ntsc +rtg +cfg=a7d"
	[lace]="+lace +cfg=01"
	[nlace]="+ntsc +lace"
	[dbl]="+dbl"
	[dblcrt]="+dbl +cfg=a7d"
	[vp50]="+voff=8"
	[vm50]="+voff=-8"
	[vp60]="+ntsc +voff=8"
	[vm60]="+ntsc +voff=-8"
	[hp50]="+hoff=24"
	[hm60]="+ntsc +hoff=-24"
	[vchg]="+voff=8 +voff2=-4 +vofframe=4 +voffline=300"
	[mode]="+swfrom=8 +swto=16 +first=24"
	[modecrt]="+swfrom=8 +swto=16 +first=24 +cfg=a7d"
)
ALL="p50 p50dim p50crt p50blk n60 n60dim n60crt f60 f60crt r50 r60 r60crt lace nlace dbl dblcrt vp50 vm50 vp60 vm60 hp50 hm60 vchg mode modecrt"
legs=("$@"); [ ${#legs[@]} -eq 0 ] && legs=($ALL)
for l in "${legs[@]}"; do
	a="${ARGS[$l]}"; [[ "$a" == *first=* ]] || a="$a +first=6"
	echo "$l $a"
done | xargs -P ${GOLDEN_JOBS:-8} -L 1 bash -c 'l=$0; build/tb_crt_frame/Vtb "$@" > '"$B"'/$l.log 2>&1 || echo "$l: simulation failed"'
fail=0
for l in "${legs[@]}"; do
	if [ $mode = record ]; then
		python3 golden.py record $B/$l.log "${ARGS[$l]}" > $G/$l.txt
		echo "  recorded $l: $(grep -c . $G/$l.txt) lines"
	else
		m=$(python3 golden.py check $B/$l.log $G/$l.txt) && echo "  pass  $l: $m" || { echo "  FAIL  $l: $m"; fail=1; }
		# the vsync check at the pins (tb_crt_frame.v): one 5-line pulse per HD frame
		grep -q "^vsync FAIL" $B/$l.log && { echo "  FAIL  $l: $(grep -c '^vsync FAIL' $B/$l.log) vsync faults, first: $(grep -m1 '^vsync FAIL' $B/$l.log)"; fail=1; }
	fi
done
[ $mode = record ] && exit 0
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
