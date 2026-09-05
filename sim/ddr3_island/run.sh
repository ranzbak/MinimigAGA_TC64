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
# Usage: [VIVADO_PATH=...] ./run.sh [skew_ps ...] [-- extra xsim plusargs]
#
#   ./run.sh                 # 1000 4000 8000 ps, the three acceptance runs
#   ./run.sh 4000            # one skew only
#   ./run.sh 4000 -- QUICK   # smoke run (plusargs given without the '+')
#
# One log per skew: xsim_run_skew<ps>.log (plus xsim_run.log for the middle
# case, which is the reference run).  The runs are independent, so they are
# started in parallel, each in its own scratch directory (xsim writes xsim.jou
# / xsim.log into the current directory).
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

# Split the arguments: skews before "--", extra xsim plusargs after it.
SKEWS=()
EXTRA=()
seen_sep=0
for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ $seen_sep -eq 1 ]; then EXTRA+=("$a"); else SKEWS+=("$a"); fi
done
[ ${#SKEWS[@]} -eq 0 ] && SKEWS=(1000 4000 8000)

# -O3 with no -debug is ~2x faster than "-debug typical" and this bench is
# self-checking, so no waveform is needed.  Set XSIM_DEBUG=1 to get one back.
DBG="-O3"
[ "${XSIM_DEBUG:-0}" = "1" ] && DBG="-debug typical"

# The Micron model includes 2048Mb_ddr3_parameters.vh from its own directory.
"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" \
    $DBG -relax \
    -L secureip -L unisims_ver -L unimacro_ver \
    ddr3_island_tb glbl -s island_sim

HERE=$(pwd)
PIDS=()
for skew in "${SKEWS[@]}"; do
    d="run_skew${skew}"
    rm -rf "$d"; mkdir -p "$d"
    # Each run needs its OWN copy of the snapshot: xsim rewrites
    # xsim.dir/<snapshot>/xsim_script.tcl with the plusargs of the run that is
    # starting, so a shared (or symlinked) xsim.dir makes every parallel run
    # use the last one's plusargs.
    cp -a "$HERE/xsim.dir" "$d/xsim.dir"
    # NOTE: build the argument list INSIDE the subshell.  If it were built in
    # the loop body the background job would expand it after the next
    # iteration had already overwritten it, and every run would get the last
    # skew value.
    ( cd "$d"
      PA=(-testplusarg "SKEW_PS=$skew")
      for e in "${EXTRA[@]}"; do PA+=(-testplusarg "$e"); done
      "$VIVADO_PATH/bin/xsim" island_sim -t "$HERE/run.tcl" \
        "${PA[@]}" > "$HERE/xsim_run_skew${skew}.log" 2>&1 ) &
    PIDS+=($!)
done

rc=0
for p in "${PIDS[@]}"; do wait "$p" || rc=1; done

for skew in "${SKEWS[@]}"; do
    echo
    echo "===== skew ${skew} ps ====="
    grep -E "^(PASS|FAIL|GRID |INFO: |DDR3 ISLAND TB)" "xsim_run_skew${skew}.log" || true
done

# The 4000 ps run is the reference; keep it under the historical name too.
if [ -f xsim_run_skew4000.log ]; then cp xsim_run_skew4000.log xsim_run.log; fi

exit $rc
