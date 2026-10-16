#!/bin/bash
# usage: runneo.sh WS C [IC]
source /opt/Xilinx/2026.1/settings64.sh >/dev/null
export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}
T=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores
IC=${3:-0}; ICB=${4:-16}; BS=${5:-64}; D=$T/perf/xneo_ws$1_c$2_ic$IC${4:+_$4x$5}; mkdir -p $D; cd $D
isa=$([ $2 = 1 ] && echo rv32imc || echo rv32im)
N=$T/src/neorv32
xvhdl -2008 -work neorv32 $(sed "s#\$NEORV32_HOME#$N#" $N/rtl/file_list_core.f) > comp.log 2>&1
xvhdl -2008 $T/perf/tb/neo_dut.vhd >> comp.log 2>&1
xvlog -i $T/perf/tb -d WS=$1 -d C=$2 -d IC=$IC -d ICB=$ICB -d BS=$BS -d HEX=\"$T/perf/sw/dhry_$isa.hex\" $T/perf/tb/tb_neo.v >> comp.log 2>&1
xelab -debug off -L neorv32 tb -s tb_snap >> comp.log 2>&1
xsim tb_snap -R > sim.log 2>&1
grep -E "DHRY|DONE|TIMEOUT" sim.log
