#!/bin/bash
# sim/hdmi_upsample: the 60 Hz upsampler never puts stale line-buffer content
# on the screen (tb_upsample_stale.v).  Legs: PAL (64 us) and 31 kHz (32 us)
# input lines, OSD offset 0, 40 and -40 (signed), with one colour for all lines (stale
# marker check) and one colour per line (each output line shows exactly one
# input line, unbroken).  Before the fix, 32 us lines put stale content on
# the right edge from hd x 1096, and offset 40 at the left edge.  Then
# tb_frame_freq.v (below).  Needs iverilog and Verilator.
set -e
cd "$(dirname "$0")"
A=../../rtl/openaars/adv7511
mkdir -p build
iverilog -g2012 -o build/tb_upsample_stale.vvp tb_upsample_stale.v $A/pal_to_hd_upsample.sv $A/bram_tdp.v $A/signal_generator.sv
fail=0
for L in 64000 32000; do
	for h in 0 40 -40; do
		for m in "" "+perline"; do
			out=$(vvp build/tb_upsample_stale.vvp +linens=$L +hoffset=$h $m)
			if echo "$out" | grep -q "ALL TESTS PASSED"; then echo "  pass  line ${L}ns offset $h $m"
			else echo "  FAIL  line ${L}ns offset $h $m"; echo "$out" | grep -E "FAIL|perline|^lines"; fail=1; fi
		done
	done
done

# frame_freq.sv against the old frame_freq.v + pal_to_ddr r_50hz chain
# (tb_frame_freq.v, ref/frame_freq_ref.v): every clock of the boundary sweeps
# (+-200 periods, two frames each) at the window edges lo / hi and at the old
# counter's us-wrap artefact 13.000 / 20.000 of its ms (lo13 / hi20), about
# 1.5-2.4 G clocks each, the standards and a PAL -> NTSC -> PAL switch.
# Verilator with the clock from a C++ loop (iverilog -g2012 builds it too but
# runs at about 0.3 M clocks/s); FF_JOBS legs at a time (default 2).
F=$PWD/build/tb_frame_freq
mkdir -p $F
iverilog -g2012 -o build/tb_frame_freq.vvp tb_frame_freq.v ref/frame_freq_ref.v $A/frame_freq.sv
cat > $F/main.cpp <<'EOF'
#include <memory>
#include <verilated.h>
#include "Vtb_frame_freq.h"
int main(int argc, char** argv) {
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_frame_freq> top{new Vtb_frame_freq{ctx.get()}};
    top->clk = 0;
    top->eval();
    while (!ctx->gotFinish()) {
        top->clk = !top->clk;
        top->eval();
    }
    top->final();
    return 0;
}
EOF
verilator --cc --exe --build -j 2 -O3 -DTB_EXT_CLK -Wno-fatal -Wno-lint -Wno-style -MAKEFLAGS OPT_FAST=-O2 \
	--Mdir build/tb_frame_freq --top-module tb_frame_freq -o Vtb \
	$F/main.cpp tb_frame_freq.v ref/frame_freq_ref.v $A/frame_freq.sv > $F/build.log 2>&1 \
	|| { tail -30 $F/build.log; exit 1; }
FF_LEGS="switch std lo hi lo13 hi20"
declare -A FF_ARGS=(
	[switch]="+leg=switch"
	[std]="+leg=std"
	[lo]="+leg=lo +half=200"
	[hi]="+leg=hi +half=200"
	[lo13]="+leg=lo +center=1937003 +half=200"
	[hi20]="+leg=hi +center=2980003 +half=200"
)
for l in $FF_LEGS; do rm -f $F/$l.log; done
for l in $FF_LEGS; do echo "$l ${FF_ARGS[$l]}"; done \
	| xargs -P "${FF_JOBS:-2}" -L 1 sh -c 'l=$0; "'"$F"'/Vtb" "$@" > "'"$F"'/$l.log" 2>&1'
for l in $FF_LEGS; do
	if grep -q "ALL TESTS PASSED" $F/$l.log; then echo "  pass  frame_freq $l: $(grep 'clocks compared' $F/$l.log)"
	else echo "  FAIL  frame_freq $l"; grep -E "FAIL|compared" $F/$l.log | head -20; fail=1; fi
done

[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
