#!/usr/bin/env bash
# Zorro-III fast RAM integration bench: rtl/ddr3/ddr3_fastram.v +
# rtl/ddr3/ddr3_top.v + the Micron DDR3 model, driven through the CPU port with
# the TG68K handshake.  This is the bench that stands in for the real 68k.
#
# Flow copied from sim/ddr3_island/run.sh (which copied it from
# lib/core_ddr3_controller/tb/ddr3_core_xc7/makefile):
#   * per-file language in the .prj file (sv for the SystemVerilog controller
#     sources and this bench, verilog for the rest),
#   * glbl.v elaborated alongside the top,
#   * unisims/secureip/unimacro for PLLE2_BASE, OSERDESE2, ISERDESE2,
#     IDELAYE2 and IDELAYCTRL,
#   * -d SOC_SIM so cpu_cache_new.v picks the inferred-RAM variants of its
#     tag/data memories instead of the Altera primitives.
#
# Vivado 2023.2 on modern Ubuntu needs libtinfo.so.5:
#   mkdir -p /somewhere/shim && ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 /somewhere/shim/libtinfo.so.5
#   export LD_LIBRARY_PATH=/somewhere/shim
#
# Usage: [VIVADO_PATH=/opt/Xilinx/Vivado/2023.2] ./run.sh [seed]
# Takes roughly 10-20 minutes.
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
echo "sv work \"$(readlink -f ./ddr3_full_tb.sv)\""          >> $PRJ
# Verilog-2001
echo "verilog work \"$(readlink -f $LIB/src_v/phy/xc7/ddr3_dfi_phy.v)\"" >> $PRJ
echo "verilog work \"$(readlink -f $LIB/tb/ddr3_core_xc7/ddr3.v)\""      >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_pll.v)\""            >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_bist.v)\""           >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_top.v)\""            >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_cdc.v)\""            >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/ddr3/ddr3_fastram.v)\""        >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/sdram/cpu_cache_new.v)\""      >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/sdram/dpram_inf_256x32.v)\""   >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/sdram/dpram_inf_be_1024x32.v)\"" >> $PRJ
echo "verilog work \"$(readlink -f $R/rtl/sdram/dpram_inf_generic.v)\""  >> $PRJ
echo "verilog work \"$VIVADO_PATH/data/verilog/src/glbl.v\""             >> $PRJ

# The Micron model includes 2048Mb_ddr3_parameters.vh from its own directory.
"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" \
    -d SOC_SIM -debug typical -relax \
    -L secureip -L unisims_ver -L unimacro_ver \
    ddr3_full_tb glbl -s full_sim

"$VIVADO_PATH/bin/xsim" full_sim -t run.tcl ${1:+-testplusarg seed=$1} 2>&1 | tee xsim_run.log

echo
grep -E "^(PASS|FAIL|INFO:|DDR3 FULL TB)" xsim_run.log || true
grep -q "DDR3 FULL TB: .* 0 failed" xsim_run.log
