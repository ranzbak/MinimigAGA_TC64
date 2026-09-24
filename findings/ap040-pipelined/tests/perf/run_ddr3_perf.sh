#!/usr/bin/env bash
# SysInfo SPEED loop on sim/ddr3_cpu (integration worktree), pipelined core,
# with the perf probe.  ONE AT A TIME (sim-ddr3-cpu-bench-traps: concurrent
# xsim runs corrupt each other), and a NEW tag every run (it refuses an
# existing work directory rather than deleting it).
#   SYSINFO=<SysInfo 4.4 executable> ./run_ddr3_perf.sh <tag> [BASE] [CACRV] [NITER]
# e.g. ./run_ddr3_perf.sh ddr3_idde '$41000000' '$80008000' 3
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=$1; BASE=${2:-'$41000000'}; CACRV=${3:-'$80008000'}; NITER=${4:-3}
INT=${INT:-/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-pipelined}
PIPE_DIR=${PIPE_DIR:-/home/paul/work/fpga/Xilinx/artix7/AP68040-pipelined}
SYSINFO=${SYSINFO:?set SYSINFO to the SysInfo 4.4 executable}
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LD_LIBRARY_PATH=${TINFO_SHIM:-/home/paul/lib/tinfo5}   # libtinfo.so.5 (vivado-lab-gotchas)
D=$INT/sim/ddr3_cpu
R=$INT
LIB=$R/lib/core_ddr3_controller
W=$D/run_perf_$TAG
if [ -e "$W" ]; then echo "run_ddr3_perf.sh: $W exists; pick a new tag" >&2; exit 2; fi
mkdir -p "$W"
python3 "$HERE/mk_siloop.py" "$SYSINFO" "$W/siloop_blk.bin" "$(printf '%d' "0x${BASE#\$}")"
( cd "$W" && vasmm68k_mot -m68040 -Fbin -o prog.bin -DBASE="$BASE" -DCACRV="$CACRV" -DNITER=$NITER "$HERE/siloop_ddr3.asm" > asm.log )
cd "$W"
PRJ=project.prj; : > $PRJ
for f in "$R/rtl/akiko/cornerturn.vhd" "$R/rtl/akiko/akiko.vhd" "$R/rtl/soc/ap040_ram_seq.vhd" "$R/rtl/soc/TG68K.vhd"; do
  echo "vhdl work \"$f\"" >> $PRJ; done
for f in "$LIB/src_v/ddr3_dfi_seq.sv" "$LIB/src_v/ddr3_core.sv" "$D/ddr3_cpu_tb.sv" "$HERE/perf_probe_ddr3.sv"; do
  echo "sv work \"$f\"" >> $PRJ; done
PR=$PIPE_DIR/rtl
echo "sv work \"$PR/ap040_pipe_pkg.sv\"" >> $PRJ
for f in $PR/ap040_*.v $PR/compat/*.v; do echo "sv work \"$f\"" >> $PRJ; done
echo "verilog work \"$R/rtl/cpu040/dpram.v\"" >> $PRJ
for f in "$LIB/src_v/phy/xc7/ddr3_dfi_phy.v" "$LIB/tb/ddr3_core_xc7/ddr3.v" "$R/rtl/ddr3/ddr3_pll.v" "$R/rtl/ddr3/ddr3_bist.v" \
         "$R/rtl/ddr3/ddr3_top.v" "$R/rtl/ddr3/ddr3_cdc.v" "$R/rtl/ddr3/ddr3_fastram.v" "$R/rtl/sdram/cpu_enable_cadence.v" \
         "$R/rtl/sdram/sdram_ctrl.v" "$R/lib/models/AS4C16M16SA.v" "$R/rtl/sdram/cpu_cache_new.v" "$R/rtl/sdram/dpram_inf_256x32.v" \
         "$R/rtl/sdram/dpram_inf_be_1024x32.v" "$R/rtl/sdram/dpram_inf_generic.v" "$VIVADO_PATH/data/verilog/src/glbl.v"; do
  echo "verilog work \"$f\"" >> $PRJ; done
printf 'run all\nquit\n' > run.tcl
"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" -i "$PIPE_DIR/rtl" -i "$PIPE_DIR/rtl/compat" -i "$PIPE_DIR/tb/perf" \
    -d AP040_PIPELINED -d SOC_SIM -d REALSDRAM -i "$D" -debug typical -relax \
    -L secureip -L unisims_ver -L unimacro_ver ddr3_cpu_tb perf_probe_ddr3 glbl -s cpu_sim > elab.log 2>&1 || { tail -30 elab.log; exit 1; }
"$VIVADO_PATH/bin/xsim" cpu_sim -t run.tcl -testplusarg "prog=$W/prog.bin" -testplusarg TURBOCHIP=1 -testplusarg MMUTEST \
    > xsim.log 2>&1 || true
grep -E "^(PERF|INFO: program phase|PASS|FAIL|DDR3 CPU TB)" xsim.log || true
