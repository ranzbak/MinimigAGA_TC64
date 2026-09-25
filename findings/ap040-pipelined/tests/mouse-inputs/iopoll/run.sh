#!/bin/bash
# $BFE001 / $DFF016 polled with DE+IE on, Minimig cacheable windows (cache_allow_all=0).
# Normal must PASS; the mutant (everything cacheable) must FAIL at check 1.
set -e
H=$(cd "$(dirname "$0")" && pwd); AP=${AP:-$H/../../../../../../AP68040-pipelined}; RTL=$AP/rtl
W=${W:-/tmp/iopoll.$$}; mkdir -p $W; cd $W
cp $AP/tb/tb_ap040_pipe_compat.v . && patch -s -p0 tb_ap040_pipe_compat.v < $H/tb_ap040_pipe_compat.iopoll.patch
vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o t_iopoll.bin $H/t_iopoll.s && python3 $AP/tb/bin2hex.py t_iopoll.bin t_iopoll.hex
SRC="$RTL/ap040_pipe_pkg.sv $(ls $RTL/ap040_*.v | tr '\n' ' ') $(ls $RTL/compat/*.v | tr '\n' ' ') $RTL/compat/primitives/dpram.v"
iverilog -g2012 -I $RTL -I $RTL/compat -o n.vvp $SRC tb_ap040_pipe_compat.v
iverilog -g2012 -DIOPOLL_ALLOW=1\'b1 -I $RTL -I $RTL/compat -o m.vvp $SRC tb_ap040_pipe_compat.v
vvp n.vvp +prog=t_iopoll.hex +timeout=3000000 | grep -E "^(phase|FAIL|ALL|TEST)"
vvp m.vvp +prog=t_iopoll.hex +timeout=3000000 | grep -E "^(phase|FAIL|ALL|TEST)" | sed 's/^/mutant: /'
