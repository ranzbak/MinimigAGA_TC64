#!/bin/bash
# usage: go.sh <name> <src> <period> [GEN=VAL...]
T=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/3b5e887b-e330-40a2-82fb-18928449948e/scratchpad/tinycores
if [ "$1" = "-lutram" ]; then export EXTRA_SYNTH="-max_bram 0"; shift; fi
name=$1; src=$2; per=$3; shift 3
source /opt/Xilinx/2026.1/settings64.sh
mkdir -p $T/runs/$name; cd $T/runs/$name
vivado -mode batch -nojournal -log vivado.log -source $T/wrap/run.tcl -tclargs $T/runs/$name $T/wrap/$src $per "$@" > /dev/null 2>&1
echo "$name done: $(cat $T/runs/$name/summary.txt 2>/dev/null || echo FAILED)"
