#!/bin/bash
# sim/hdmi_upsample: the 60 Hz upsampler never puts stale line-buffer content
# on the screen (tb_upsample_stale.v).  Legs: PAL (64 us) and 31 kHz (32 us)
# input lines, OSD offset 0 and 40, with one colour for all lines (stale
# marker check) and one colour per line (each output line shows exactly one
# input line, unbroken).  Before the fix, 32 us lines put stale content on
# the right edge from hd x 1096, and offset 40 at the left edge.  Needs iverilog.
set -e
cd "$(dirname "$0")"
A=../../rtl/openaars/adv7511
mkdir -p build
iverilog -g2012 -o build/tb_upsample_stale.vvp tb_upsample_stale.v $A/pal_to_hd_upsample.v $A/bram_tdp.v $A/signal_generator.sv
fail=0
for L in 64000 32000; do
	for h in 0 40; do
		for m in "" "+perline"; do
			out=$(vvp build/tb_upsample_stale.vvp +linens=$L +hoffset=$h $m)
			if echo "$out" | grep -q "ALL TESTS PASSED"; then echo "  pass  line ${L}ns offset $h $m"
			else echo "  FAIL  line ${L}ns offset $h $m"; echo "$out" | grep -E "FAIL|perline|^lines"; fail=1; fi
		done
	done
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
