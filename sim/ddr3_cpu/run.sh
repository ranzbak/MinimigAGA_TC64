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
#   ./run.sh --ap040      AP68040 kernel          -> xsim_run_pass_ap040.log
#   ./run.sh --lwmutant   AP68040 with the longword_pair gate reverted; MUST fail
#   ./run.sh --mmu        AP68040, the stage-B MMU walker program
#   ./run.sh --mmumutant  the same with walker_ack tied low; MUST fail
#   ./run.sh --chipbus    turbochipram = 0, chip RAM over the 7 MHz chipset bus
#
# The flags combine in that order, e.g.
#   ./run.sh --ap040 --chipbus   -> xsim_run_pass_ap040_chipbus.log
#
# The mutant is the wrapper as it stood before the chipset_cycle fix; it MUST
# fail.  The two variants build in separate directories (run_pass/, run_mutant/)
# so they can run at the same time without sharing an xsim work library.
#
# RUN THEM ONE AT A TIME ANYWAY.  On 2026-09-06 a pass run started alongside a
# mutant run reported a read-back failure (code 2) and 362 wrong words in the
# backdoor check; the identical configuration passed three times when run on
# its own, before and after.  The cause was never found -- the separate
# directories look right -- so this is one unexplained observation, not a
# diagnosis.  It is enough to distrust a concurrent run: a false failure here
# costs an afternoon chasing a bug that is not in the design.
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
IS_MUTANT=0
if [ "$1" = "--mutant" ]; then VARIANT=mutant; IS_MUTANT=1; shift; fi

# --lwmutant: the AP040 run with the longword_pair gate reverted, i.e. the
# wrapper as it stood before commit c2ecc99, when cpustate(6) carried the raw
# longword flag to a core that answers a longword with two independent word
# cycles.  That is the bug that reached hardware as the AllocMem hang, and the
# bench was blind to it.  It MUST fail now.  Implies --ap040.
IS_LWMUTANT=0
if [ "$1" = "--lwmutant" ]; then IS_LWMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi

# --mmu: the stage-B walker bench.  A different 68k program (asm/mmu_walk_test.asm)
# builds a two-level table with the root in chip RAM and the leaves in the DDR3
# fast RAM, turns translation on and exercises a warm page, a cold one (which
# forces U and M write-backs -- walker WRITES), an invalid descriptor and a
# table branch that decodes as nothing.  Implies --ap040: the TG68K has no MMU.
#
# --mmumutant is the same run with walker_ack tied low, i.e. the stage-A
# tie-off.  It MUST fail; that is what says the bench can see the walker at all.
IS_MMU=0
IS_MMUMUTANT=0
if [ "$1" = "--mmu" ];       then IS_MMU=1;                  shift; set -- --ap040 "$@"; fi
if [ "$1" = "--mmumutant" ]; then IS_MMU=1; IS_MMUMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi

# Which CPU core the wrapper is built with.  The AP68040 (lib/AP68040) presents
# a TG68K-shaped port set, so the whole bench -- chipset model, DDR3 chain,
# 68k program -- is the same; only the kernel inside rtl/soc/TG68K.vhd changes.
#   ./run.sh            TG68K   -> run_pass/        xsim_run_pass.log
#   ./run.sh --ap040    AP68040 -> run_pass_ap040/  xsim_run_pass_ap040.log
CPU=tg68k
if [ "$1" = "--ap040" ]; then CPU=ap040; shift; fi
if [ "$CPU" = "ap040" ]; then
    # The mutant is a TG68K-specific mutation (the chipset_cycle term); there is
    # nothing for it to mean with a different kernel.
    if [ "$IS_MUTANT" = "1" ] && [ "$IS_LWMUTANT" = "0" ] && [ "$IS_MMUMUTANT" = "0" ]; then
        echo "--mutant and --ap040 are not a combination: the mutant is the" >&2
        echo "TG68K wrapper as it stood before the chipset_cycle fix." >&2
        exit 2
    fi
    VARIANT=pass_ap040
    if [ "$IS_LWMUTANT" = "1" ];  then VARIANT=lwmutant_ap040;  fi
    if [ "$IS_MMU" = "1" ];       then VARIANT=mmu_ap040;       fi
    if [ "$IS_MMUMUTANT" = "1" ]; then VARIANT=mmumutant_ap040; fi
fi

# Turbo chip RAM.  Default on, as the bench has always run.  --chipbus clears
# it so chip RAM goes out over the 7 MHz chipset bus instead of the SDRAM-side
# port, which is what the core does when the user sets Turbo to none -- and is
# the one path an AP68040 run has never taken, because turbochipram used to be
# tied to 1 here.  Results land in run_<variant>_chipbus/.
TURBOCHIP=1
if [ "$1" = "--chipbus" ]; then TURBOCHIP=0; shift; fi

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

if [ "$TURBOCHIP" = "0" ]; then VARIANT="${VARIANT}_chipbus"; fi

W="$D/run_$VARIANT"
rm -rf "$W"
mkdir -p "$W"

if [ "$IS_MMU" = "1" ]; then
    BIN="$W/prog.bin" SRC=mmu_walk_test.asm "$D/asm/build_68k_test.sh"
else
    BIN="$W/prog.bin" "$D/asm/build_68k_test.sh" \
        -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN
fi

PLUS="+PATBYTES=$PATBYTES +MISLINES=$MISLINES +CNTN=$CNTN +TURBOCHIP=$TURBOCHIP"
# The MMU program writes no pattern, so the backdoor check of the DDR3 array
# has nothing to compare against and is skipped; the program's own phases are
# the check.
if [ "$IS_MMU" = "1" ]; then PLUS="$PLUS +MMUTEST"; fi
if [ -n "$TRACE" ]; then PLUS="$PLUS +TRACE +TRMAX=${TRMAX:-200}"; fi

if [ "$IS_MMUMUTANT" = "1" ]; then
    # Generated: the walker acknowledge tied low again, which is exactly stage
    # A.  A walk then never completes and the core's watchdog turns it into an
    # access fault -- on hardware that was the SetPatch crash.
    TG68K_SRC="$W/TG68K_mmumutant.vhd"
    sed "s|walker_ack     => wk_ack,|walker_ack     => '0',|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "walker_ack     => '0'," "$TG68K_SRC"; then
        echo "--mmumutant: the walker_ack port map moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_LWMUTANT" = "1" ]; then
    # Generated, not checked in: one line of the real wrapper, reverted.  The
    # sed must match or the mutation silently does nothing, so verify it did.
    TG68K_SRC="$W/TG68K_lwmutant.vhd"
    sed "s|longword_pair <= '0' WHEN use_ap040 ELSE longword;|longword_pair <= longword;|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "longword_pair <= longword;" "$TG68K_SRC"; then
        echo "--lwmutant: the longword_pair line moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_MUTANT" = "1" ]; then
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

# ---- AP68040, when that is the core under test ----------------------------
# SystemVerilog; ap040_defs.svh is on the include path passed to xelab below.
# The RAM primitive is the project's, not the submodule's -- rtl/cpu040/dpram.v.
if [ "$CPU" = "ap040" ]; then
    AP=$R/lib/AP68040/rtl
    for f in ap040_tg68k_compat ap040_core ap040_alu ap040_muldiv ap040_regfile \
             ap040_fpu ap040_mmu ap040_cache ap040_bus16_adapter \
             ap040_bus_timeout ap040_walker_cdc; do
        echo "sv work \"$AP/$f.v\""                      >> $PRJ
    done
    echo "verilog work \"$R/rtl/cpu040/dpram.v\""        >> $PRJ
fi

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
AP040_ELAB=""
if [ "$CPU" = "ap040" ]; then AP040_ELAB="-i $R/lib/AP68040/rtl -d CPU_AP040"; fi

"$VIVADO_PATH/bin/xelab" -prj $PRJ -i "$LIB/tb/ddr3_core_xc7" $AP040_ELAB \
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

if [ "$IS_MUTANT" = "1" ]; then
    # the mutant must NOT pass
    if grep -q "DDR3 CPU TB: PASS" "xsim_run_$VARIANT.log"; then
        echo "MUTANT DID NOT FAIL -- the bench has no teeth"; exit 1
    fi
    echo "mutant failed as required"
else
    grep -q "DDR3 CPU TB: 2 passed, 0 failed" "xsim_run_$VARIANT.log"
fi
