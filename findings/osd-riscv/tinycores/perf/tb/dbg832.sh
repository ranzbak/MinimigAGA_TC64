#!/bin/bash
source /opt/Xilinx/2026.1/settings64.sh >/dev/null
export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
D=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/perf/x832_ws0; cd $D
xvlog -i ../tb -d WS=0 -d MAXC=64\'d150000 -d HEX=\"$D/../sw832/dhry832.hex\" ../tb/tb_832.v > dbg.log 2>&1
xelab -debug off tb -s tb_dbg >> dbg.log 2>&1
xsim tb_dbg -R > dbgsim.log 2>&1
