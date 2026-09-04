#!/usr/bin/env bash
# DDR3 island bench (rtl/ddr3/ddr3_top.v) under xsim.
#
# Flow copied from lib/core_ddr3_controller/tb/ddr3_core_xc7/makefile, which
# task 1 fixed for Vivado 2023.2:
#   * per-file language in the .prj file (sv for the SystemVerilog controller
#     sources and this bench, verilog for the rest),
#   * glbl.v elaborated alongside the top,
#   * unisims/secureip/unimacro for PLLE2_BASE, OSERDESE2, ISERDESE2,
#     IDELAYE2 and IDELAYCTRL.
#
# Vivado 2023.2 on modern Ubuntu needs libtinfo.so.5:
#   mkdir -p /somewhere/shim && ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 /somewhere/shim/libtinfo.so.5
#   export LD_LIBRARY_PATH=/somewhere/shim
#
# Usage: [VIVADO_PATH=/opt/Xilinx/Vivado/2023.2] ./run.sh
set -e
cd "$(dirname "$0")"

VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
R=../..
LIB=$R/lib/core_ddr3_controller

PRJ=project.prj
: > $PRJ
# SystemVerilog
echo "sv work \"$(readlink -f $LIB/src_v/ddr3_dfi_seq.sv)\"" >> $PRJ
echo "sv work \"$(readlink -f $LIB/src_v/ddr3_core.sv)\""    >> $PRJ
echo "sv work \"$(readlink -f ./ddr3_island_tb.sv)\""        >> $PRJ
# Verilog-2001
echo "verilog work \"$(readlink -f $LIB/src_v/phy/xc7/ddr3_dfi_phy.v)\"" >> $PRJ
echo "verilog work \"$(readlink -f $LIB/tb/ddr3_core_xc7/ddr3.v)\""      >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_pll.v)\""            >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_bist.v)\""           >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_top.v)\""            >> $PRJ
echo "verilog work \"$VIVADO_PATH/data/verilog/src/glbl.v\""             >> $PRJ

# The Micron model includes 2048Mb_ddr3_parameters.vh from its own directory.
"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" \
    -debug typical -relax \
    -L secureip -L unisims_ver -L unimacro_ver \
    ddr3_island_tb glbl -s island_sim

"$VIVADO_PATH/bin/xsim" island_sim -t run.tcl 2>&1 | tee xsim_run.log

echo
grep -E "^(PASS|FAIL|INFO: |DDR3 ISLAND TB)" xsim_run.log || true
