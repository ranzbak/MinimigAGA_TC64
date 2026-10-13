#!/bin/bash
# Build the CRT benches: build/tb_crt_frame/Vtb (Verilator: one 720p frame
# of both HDMI paths takes seconds, against tens of minutes in vvp -- the
# study's renders came out byte-identical either way), build/tb_crt_post_unit.vvp
# (iverilog), build/tb_osd_video.vvp (iverilog) and build/amiga_frame.hex
# (crt_mkframe.py), build/dither.hex (crt_mkdither.py), build/scaler_*.hex
# (scaler/mkframes.py).
set -e
cd "$(dirname "$0")"
A=../../rtl/openaars/adv7511
mkdir -p build
[ -f build/amiga_frame.hex ] || (cd build && python3 ../crt_mkframe.py > /dev/null)
# the dither frame (study 2026-10-09) for the beam legs
[ -f build/dither.hex ] || python3 crt_mkdither.py build > /dev/null
# the scaler's test frames (scaler_run.sh: the study's native frame, PAL and NTSC)
[ -f build/scaler_pal.hex ] || python3 scaler/mkframes.py build > /dev/null
iverilog -g2012 -o build/tb_crt_post_unit.vvp tb_crt_post_unit.v $A/crt_post.v
# the same with all tables zero: what a board build that failed to load
# the .mem files would have -- everything off must still be the picture
python3 -c "open('build/zero_wrom.mem','w').write('00000\\n'*2048); open('build/zero_lut.mem','w').write('00\\n'*8192); open('build/zero_bloom.mem','w').write('00\\n'*8192); open('build/zero_sdec.mem','w').write('00000\\n'*256); open('build/zero_senc.mem','w').write('00\\n'*4096); open('build/zero_swrom.mem','w').write('000000000\\n'*2048)"
iverilog -g2012 -o build/tb_crt_post_unit_zero.vvp -Ptb_crt_post_unit.WROM=\"build/zero_wrom.mem\" \
	-Ptb_crt_post_unit.LUT=\"build/zero_lut.mem\" -Ptb_crt_post_unit.BLM=\"build/zero_bloom.mem\" \
	-Ptb_crt_post_unit.SDEC=\"build/zero_sdec.mem\" -Ptb_crt_post_unit.SENC=\"build/zero_senc.mem\" \
	-Ptb_crt_post_unit.SWROM=\"build/zero_swrom.mem\" \
	tb_crt_post_unit.v $A/crt_post.v
# the OSD video command over SPI (userio_osd.v: the second byte, mask and bloom)
iverilog -g2005 -I ../../fpga/openaars -I ../../rtl/minimig -DMINIMIG_XILINX -o build/tb_osd_video.vvp \
	tb_osd_video.v ../../rtl/minimig/userio_osd.v ../../rtl/minimig/userio_osd_spi.v ../../rtl/fifo/sync_fifo.v
# -Wno-BLKANDNBLK: signal_generator.sv mixes = and <= on two registers in
# its reset branch only
verilator --binary --timing -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-BLKANDNBLK \
	--Mdir build/tb_crt_frame --top-module tb_crt_frame -o Vtb \
	tb_crt_frame.v $A/pal_to_ddr.sv $A/pal_to_hd_upsample.v $A/crt_post.v $A/crt_beamh.v $A/bram_tdp.v \
	$A/signal_generator.sv $A/adv_ddr.v $A/frame_freq.v ref/pal_to_ddr_ref.sv ref/pal_to_hd_upsample_ref.v \
	> build/verilator.log 2>&1 || { tail -30 build/verilator.log; exit 1; }
echo "built"
