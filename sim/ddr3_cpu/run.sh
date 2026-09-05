#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# sim/ddr3_cpu -- the TG68K wrapper driving the DDR3 Zorro-III fast RAM.
#
# Mixed VHDL + Verilog + SystemVerilog xsim flow, copied from sim/ddr3_full and
# extended with the VHDL half of the design (the TG68K wrapper, the TG68KdotC
# kernel and akiko).  glbl.v is elaborated alongside the top and the unisim /
# secureip / unimacro libraries are pulled in for the island's PLLE2_BASE,
# OSERDESE2, ISERDESE2, IDELAYE2 and IDELAYCTRL.  -d SOC_SIM makes
# cpu_cache_new.v use its inferred-RAM tag/data memories.
#
#   ./run.sh              real rtl/soc/TG68K.vhd  -> xsim_run_pass.log
#   ./run.sh --mutant     mutant/TG68K_mutant.vhd -> xsim_run_mutant.log
#
# The mutant is the wrapper as it stood before the chipset_cycle fix; it MUST
# fail.  The two variants build in separate directories (run_pass/, run_mutant/)
# so they can run at the same time without sharing an xsim work library.
#
# Vivado 2023.2 on modern Ubuntu needs libtinfo.so.5:
#   mkdir -p /somewhere/shim
#   ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 /somewhere/shim/libtinfo.so.5
#   export LD_LIBRARY_PATH=/somewhere/shim
#
# Takes roughly 15-20 minutes at the default region sizes.
#-----------------------------------------------------------------------------
set -e
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D"

VARIANT=pass
if [ "$1" = "--mutant" ]; then VARIANT=mutant; shift; fi

VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
R="$D/../.."
LIB="$R/lib/core_ddr3_controller"

# Region sizes.  The defaults are the ones the checked-in logs were made with;
# override them for a quick debug run, e.g.
#   PATBYTES=64 MISLINES=2 CNTN=8 TRACE=1 ./run.sh
# The same numbers go to vasm and to the bench, so the two can never disagree.
PATBYTES=${PATBYTES:-1024}
MISLINES=${MISLINES:-16}
CNTN=${CNTN:-64}

W="$D/run_$VARIANT"
rm -rf "$W"
mkdir -p "$W"

BIN="$W/prog.bin" "$D/asm/build_68k_test.sh" \
    -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN

PLUS="+PATBYTES=$PATBYTES +MISLINES=$MISLINES +CNTN=$CNTN"
if [ -n "$TRACE" ]; then PLUS="$PLUS +TRACE +TRMAX=${TRMAX:-200}"; fi

if [ "$VARIANT" = "mutant" ]; then
    TG68K_SRC="$D/mutant/TG68K_mutant.vhd"
else
    TG68K_SRC="$R/rtl/soc/TG68K.vhd"
fi

cd "$W"

PRJ=project.prj
: > $PRJ

# ---- VHDL, in dependency order -------------------------------------------
echo "vhdl work \"$R/rtl/tg68k/TG68K_Pack.vhd\""        >> $PRJ
echo "vhdl work \"$R/rtl/tg68k/TG68K_ALU.vhd\""         >> $PRJ
echo "vhdl work \"$R/rtl/tg68k/TG68KdotC_Kernel.vhd\""  >> $PRJ
echo "vhdl work \"$R/rtl/akiko/cornerturn.vhd\""        >> $PRJ
echo "vhdl work \"$R/rtl/akiko/akiko.vhd\""             >> $PRJ
echo "vhdl work \"$TG68K_SRC\""                         >> $PRJ

# ---- SystemVerilog --------------------------------------------------------
echo "sv work \"$LIB/src_v/ddr3_dfi_seq.sv\""           >> $PRJ
echo "sv work \"$LIB/src_v/ddr3_core.sv\""              >> $PRJ
echo "sv work \"$D/ddr3_cpu_tb.sv\""                    >> $PRJ

# ---- Verilog-2001 ---------------------------------------------------------
echo "verilog work \"$LIB/src_v/phy/xc7/ddr3_dfi_phy.v\"" >> $PRJ
echo "verilog work \"$LIB/tb/ddr3_core_xc7/ddr3.v\""      >> $PRJ
echo "verilog work \"$R/rtl/ddr3/ddr3_pll.v\""            >> $PRJ
echo "verilog work \"$R/rtl/ddr3/ddr3_bist.v\""           >> $PRJ
echo "verilog work \"$R/rtl/ddr3/ddr3_top.v\""            >> $PRJ
echo "verilog work \"$R/rtl/ddr3/ddr3_cdc.v\""            >> $PRJ
echo "verilog work \"$R/rtl/ddr3/ddr3_fastram.v\""        >> $PRJ
echo "verilog work \"$R/rtl/sdram/cpu_cache_new.v\""      >> $PRJ
echo "verilog work \"$R/rtl/sdram/dpram_inf_256x32.v\""   >> $PRJ
echo "verilog work \"$R/rtl/sdram/dpram_inf_be_1024x32.v\"" >> $PRJ
echo "verilog work \"$R/rtl/sdram/dpram_inf_generic.v\""  >> $PRJ
echo "verilog work \"$VIVADO_PATH/data/verilog/src/glbl.v\"" >> $PRJ

cat > run.tcl <<'EOF'
run all
quit
EOF

# The Micron model includes 2048Mb_ddr3_parameters.vh from its own directory.
"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" \
    -d SOC_SIM -debug typical -relax \
    -L secureip -L unisims_ver -L unimacro_ver \
    ddr3_cpu_tb glbl -s cpu_sim

"$VIVADO_PATH/bin/xsim" cpu_sim -t run.tcl \
    -testplusarg "prog=$W/prog.bin" \
    $(for a in $PLUS; do printf -- '-testplusarg %s ' "${a#+}"; done) \
    2>&1 | tee "$D/xsim_run_$VARIANT.log"

cd "$D"
echo
grep -E "^(PASS|FAIL|INFO:|DDR3 CPU TB|       )" "xsim_run_$VARIANT.log" || true

if [ "$VARIANT" = "mutant" ]; then
    # the mutant must NOT pass
    if grep -q "DDR3 CPU TB: PASS" "xsim_run_$VARIANT.log"; then
        echo "MUTANT DID NOT FAIL -- the bench has no teeth"; exit 1
    fi
    echo "mutant failed as required"
else
    grep -q "DDR3 CPU TB: 2 passed, 0 failed" "xsim_run_$VARIANT.log"
fi
