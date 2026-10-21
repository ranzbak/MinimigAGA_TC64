#!/bin/bash
# usage: run832.sh WS
source /opt/Xilinx/2026.1/settings64.sh >/dev/null
export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}
D=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores/perf/x832_ws$1; mkdir -p $D; cd $D
R=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo/RTL
xvhdl $R/eightthirtytwo_pkg.vhd $R/eightthirtytwo_shifter.vhd $R/eightthirtytwo_alu.vhd $R/eightthirtytwo_aligner.vhd $R/eightthirtytwo_aligner_le.vhd $R/eightthirtytwo_decode.vhd $R/eightthirtytwo_fetchloadstore.vhd $R/eightthirtytwo_hazard.vhd $R/eightthirtytwo_debug.vhd $R/eightthirtytwo_cpu.vhd > comp.log 2>&1
xvlog -i ../tb -d WS=$1 -d HEX=\"$D/../sw832/dhry832.hex\" ../tb/tb_832.v >> comp.log 2>&1
xelab -debug off tb -s tb_snap >> comp.log 2>&1
xsim tb_snap -R > sim.log 2>&1
grep -E "DHRY|DONE|TIMEOUT" sim.log
