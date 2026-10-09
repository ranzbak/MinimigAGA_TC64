#!/bin/bash
# Build the CRT benches: build/tb_crt_frame/Vtb (Verilator: one 720p frame
# of both HDMI paths takes seconds, against tens of minutes in vvp -- the
# study's renders came out byte-identical either way), build/tb_crt_post_unit.vvp
# (iverilog) and build/amiga_frame.hex (crt_mkframe.py).
set -e
cd "$(dirname "$0")"
A=../../rtl/openaars/adv7511
mkdir -p build
[ -f build/amiga_frame.hex ] || (cd build && python3 ../crt_mkframe.py > /dev/null)
iverilog -g2012 -o build/tb_crt_post_unit.vvp tb_crt_post_unit.v $A/crt_post.v
# -Wno-BLKANDNBLK: signal_generator.sv mixes = and <= on two registers in
# its reset branch only
verilator --binary --timing -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-BLKANDNBLK \
	--Mdir build/tb_crt_frame --top-module tb_crt_frame -o Vtb \
	tb_crt_frame.v $A/pal_to_ddr.sv $A/pal_to_hd_upsample.v $A/crt_post.v $A/bram_tdp.v \
	$A/signal_generator.sv $A/adv_ddr.v $A/frame_freq.v ref/pal_to_ddr_ref.sv ref/pal_to_hd_upsample_ref.v \
	> build/verilator.log 2>&1 || { tail -30 build/verilator.log; exit 1; }
echo "built"
