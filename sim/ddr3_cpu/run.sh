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
#   ./run.sh --lwmutant   AP68040 with the raw longword flag back on cpustate(6); MUST fail
#   ./run.sh --mmu        AP68040, the stage-B MMU walker program
#   ./run.sh --mmumutant  the same with walker_ack tied low; MUST fail
#   ./run.sh --fillmutant AP68040 with the line fill assembled backwards; MUST fail
#   ./run.sh --nofill     AP68040 with the fill channel off; the A/B reference
#   ./run.sh --snoop      AP68040 with chipset DMA write snoops driven
#   ./run.sh --snoopmutant  the same with the wrapper's snoop hold reverted; MUST fail
#   REALSDRAM=1 ./run.sh --gatemutant  phase gate opening on enaWRreg (as first built); placement MUST fail
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

# --lwmutant: the AP040 run with cpustate(6) carrying the raw longword flag
# again -- the wrapper as it stood before commit c2ecc99 -- to controllers that
# see a core answering a longword with two independent word cycles. (Since E4a
# cpustate(6) is the constant '0'; the mutant puts longword back there.)  That is the bug that reached hardware as the AllocMem hang, and the
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

# --fillmutant: the stage-D line-fill router with the eight words assembled in
# the WRONG ORDER -- shifted in from the left instead of the right, so word 0
# of the line ends up in fill_data[15:0] where the cache expects the word at
# offset 14 (ap040_cache.v:93-99).  That is not a straw man: it is exactly the
# layout cpu_cache_new and ddr3_fastram use internally (word k at [16k+15:16k],
# ddr3_fastram.v:47-60), and the two conventions are opposite, so getting them
# confused is the likely mistake.  Every line then comes back byte-reversed,
# which the pattern read-back must catch.  It MUST fail.  Implies --ap040.
IS_FILLMUTANT=0
if [ "$1" = "--fillmutant" ]; then IS_FILLMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi

# --nofill: the same wrapper with fill_ena_zorro tied low, so the cache's
# fill_ok is a constant 0 and every line goes down the bus16 adapter as eight
# 16-bit sub-cycles -- the pre-stage-D behaviour, with everything else
# (including the internal caches, see CACRVAL below) identical.  This is the
# A/B reference for the phase-timestamp table, NOT a mutant: it must PASS.
# The wrapper's own Task 1 state cannot be used for that comparison because it
# has no fl_* signals for the bench's fill counters to reference.  Implies
# --ap040.
IS_NOFILL=0
if [ "$1" = "--nofill" ]; then IS_NOFILL=1; shift; set -- --ap040 "$@"; fi

# --snoop: the chipset DMA write snoop, which nothing drove until stage D3.
# The bench asserts snoop_stb for one clk cycle at a time, at chip RAM
# addresses, walking all three clk phases relative to clk_cpu, and checks that
# every one of them reaches the core and invalidates a cache set.
#
# It has to be its own leg rather than being on in every leg, because a snoop
# invalidates a resident line and so perturbs the phase timestamps the other
# legs are compared on.  With the flag off snoop_stb is tied low exactly as it
# always was.  Implies --ap040: the TG68K has no cache to snoop.
#
# --snoopmutant is the same run with the wrapper's hold reverted -- the raw
# one-cycle pulse straight to the kernel, which is what stage D3 shipped with
# before this was found.  Two snoops in three then never reach a core on
# clk_cpu.  It MUST fail; that is what says this bench can see the bug at all.
IS_SNOOP=0
IS_SNOOPMUTANT=0
if [ "$1" = "--snoop" ];       then IS_SNOOP=1;                             shift; set -- --ap040 "$@"; fi
if [ "$1" = "--snoopmutant" ]; then IS_SNOOP=1; IS_SNOOPMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi

# --gatemutant: the phase gate opening ON enaWRreg (the gate as first built),
# i.e. TG68K.vhd's ena_sr(2) replaced by clkena_in. On hardware it lands chip-RAM
# acknowledges on 3/7/11/15 and corrupts. With REALSDRAM=1 the placement
# monitor MUST fail. Implies --ap040.
IS_GATEMUTANT=0
if [ "$1" = "--gatemutant" ]; then IS_GATEMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi

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
    if [ "$IS_MUTANT" = "1" ] && [ "$IS_LWMUTANT" = "0" ] && [ "$IS_MMUMUTANT" = "0" ] \
       && [ "$IS_FILLMUTANT" = "0" ] && [ "$IS_SNOOPMUTANT" = "0" ] \
       && [ "$IS_GATEMUTANT" = "0" ]; then
        echo "--mutant and --ap040 are not a combination: the mutant is the" >&2
        echo "TG68K wrapper as it stood before the chipset_cycle fix." >&2
        exit 2
    fi
    VARIANT=pass_ap040
    if [ "$IS_LWMUTANT" = "1" ];   then VARIANT=lwmutant_ap040;   fi
    if [ "$IS_MMU" = "1" ];        then VARIANT=mmu_ap040;        fi
    if [ "$IS_MMUMUTANT" = "1" ];  then VARIANT=mmumutant_ap040;  fi
    if [ "$IS_FILLMUTANT" = "1" ]; then VARIANT=fillmutant_ap040; fi
    if [ "$IS_NOFILL" = "1" ];     then VARIANT=nofill_ap040;     fi
    if [ "$IS_SNOOP" = "1" ];      then VARIANT=snoop_ap040;      fi
    if [ "$IS_SNOOPMUTANT" = "1" ]; then VARIANT=snoopmutant_ap040; fi
    if [ "$IS_GATEMUTANT" = "1" ]; then VARIANT=gatemutant_ap040; fi
fi

# Turbo chip RAM.  Default on, as the bench has always run.  --chipbus clears
# it so chip RAM goes out over the 7 MHz chipset bus instead of the SDRAM-side
# port, which is what the core does when the user sets Turbo to none -- and is
# the one path an AP68040 run has never taken, because turbochipram used to be
# tied to 1 here.  Results land in run_<variant>_chipbus/.
TURBOCHIP=1
if [ "$1" = "--chipbus" ]; then TURBOCHIP=0; shift; fi

# Every flag this script understands has now been shifted off. Anything left
# is a flag we did not recognise -- most often a typo, or a combination whose
# earlier member already consumed the position the later one needed (e.g.
# "--mmu --nofill": --mmu shifts and re-inserts --ap040, so --nofill is never
# in $1 when the --nofill check runs, and used to be dropped on the floor
# silently, quietly running a plain --mmu instead). Reject rather than ignore.
[ $# -gt 0 ] && { echo "run.sh: unknown flag(s): $*" >&2; exit 2; }

# Chip RAM over the 7 MHz bus is roughly sixteen times slower per access than
# the SDRAM-side port, and the bench's TIMEOUT is 2.5 ms, so the default region
# sizes do NOT fit: the run dies mid-pattern with a timeout and a few hundred
# "DRAM mismatch" lines, which reads exactly like a corruption bug and is not
# one.  It cost an evening on 2026-09-08 -- the checked-in chipbus log had been
# made with the reduced sizes and said so only in its xsim command line.  So
# --chipbus picks the reduced sizes unless the caller has set them explicitly.
if [ "$TURBOCHIP" = "0" ]; then
    PATBYTES=${PATBYTES:-64}
    MISLINES=${MISLINES:-2}
    CNTN=${CNTN:-8}
fi

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
# RUNTAG=<word> gives a run its own directory and log, so legs that differ only
# in environment switches (CPU_RATIO, CPU_PHASE, ...) do not overwrite each other.
if [ -n "$RUNTAG" ]; then VARIANT="${VARIANT}_$RUNTAG"; fi

W="$D/run_$VARIANT"
rm -rf "$W"
mkdir -p "$W"

# The CACR the program writes.  The AP68040 masks MOVEC to CACR with
# $80008000 (ap040_core.v:3352), so the 68020 value 3 this program has always
# written leaves BOTH of its internal caches off -- and with no caches there
# are no line fills, which is why the fill counters read zero until this was
# found.  The TG68K is a 68020 and keeps the 68020 value, so its leg is
# unchanged; the AP68040 gets DE and IE set.
CACRVAL=3
if [ "$CPU" = "ap040" ]; then CACRVAL='$80008003'; fi

if [ "$IS_MMU" = "1" ]; then
    BIN="$W/prog.bin" SRC=mmu_walk_test.asm "$D/asm/build_68k_test.sh" \
        -DCACRVAL="$CACRVAL"
else
    BIN="$W/prog.bin" "$D/asm/build_68k_test.sh" \
        -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN -DCACRVAL="$CACRVAL" \
        ${P7LOOPS:+-DP7LOOPS=$P7LOOPS} ${P2CBLOCK:+-DP2CBLOCK=$P2CBLOCK}
fi

PLUS="+PATBYTES=$PATBYTES +MISLINES=$MISLINES +CNTN=$CNTN +TURBOCHIP=$TURBOCHIP"
# The MMU program writes no pattern, so the backdoor check of the DDR3 array
# has nothing to compare against and is skipped; the program's own phases are
# the check.
if [ "$IS_MMU" = "1" ]; then PLUS="$PLUS +MMUTEST"; fi
if [ "$IS_SNOOP" = "1" ]; then PLUS="$PLUS +SNOOP"; fi
if [ -n "$TRACE" ]; then PLUS="$PLUS +TRACE +TRMAX=${TRMAX:-200}"; fi
# XPLUS: extra +plusargs handed straight to xsim, e.g. XPLUS=+LBDBG for the
# SDRAM-port line-buffer trace.
if [ -n "$XPLUS" ]; then PLUS="$PLUS $XPLUS"; fi

# PREB1=<file> swaps in another copy of the wrapper, so a regression can be
# bisected against a known-good one without touching the working tree.
if [ -n "$PREB1" ]; then
    TG68K_SRC="$PREB1"
elif [ "$IS_MMUMUTANT" = "1" ]; then
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
elif [ "$IS_NOFILL" = "1" ]; then
    # Generated: the fill channel's enable tied low.  One line.
    TG68K_SRC="$W/TG68K_nofill.vhd"
    sed "s|fill_ena_zorro => '1',|fill_ena_zorro => '0',|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "fill_ena_zorro => '0'," "$TG68K_SRC"; then
        echo "--nofill: the fill_ena_zorro port map moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_SNOOPMUTANT" = "1" ]; then
    # Generated: the wrapper's snoop hold reverted, the raw one-cycle pulse
    # handed straight to a kernel on clk_cpu.  Two lines.
    TG68K_SRC="$W/TG68K_snoopmutant.vhd"
    sed -e "s|cache_snoop_stb  => snp_stb_held,|cache_snoop_stb  => snoop_stb,|" \
        -e "s|cache_snoop_addr => snp_addr_held,|cache_snoop_addr => snoop_addr,|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "cache_snoop_stb  => snoop_stb," "$TG68K_SRC" \
       || ! grep -q "cache_snoop_addr => snoop_addr," "$TG68K_SRC"; then
        echo "--snoopmutant: the snoop port map moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_GATEMUTANT" = "1" ]; then
    # Generated, not checked in: the phase gate reverted to open on clkena_in.
    TG68K_SRC="$W/TG68K_gatemutant.vhd"
    sed "s|ELSIF ena_sr(2) = '1' AND slower(0) = '0' THEN|ELSIF clkena_in = '1' AND slower(0) = '0' THEN|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "ELSIF clkena_in = '1' AND slower(0) = '0' THEN" "$TG68K_SRC"; then
        echo "--gatemutant: the phase gate line moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_FILLMUTANT" = "1" ]; then
    # Generated: the line-fill router's word assembly reversed.  One line.
    TG68K_SRC="$W/TG68K_fillmutant.vhd"
    sed "s|fl_line   <= fl_line(111 downto 0) \& datatg68;|fl_line   <= datatg68 \& fl_line(127 downto 16);|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "fl_line   <= datatg68 & fl_line(127 downto 16);" "$TG68K_SRC"; then
        echo "--fillmutant: the fill assembly line moved; fix the sed in run.sh" >&2
        exit 2
    fi
elif [ "$IS_LWMUTANT" = "1" ]; then
    # Generated, not checked in: one line of the real wrapper, reverted.  The
    # sed must match or the mutation silently does nothing, so verify it did.
    TG68K_SRC="$W/TG68K_lwmutant.vhd"
    # (& in a sed replacement means the matched text, hence \&.)
    sed "s|cpustate <= '0' & clkena|cpustate <= longword \& clkena|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "cpustate <= longword & clkena" "$TG68K_SRC"; then
        echo "--lwmutant: the cpustate line moved; fix the sed in run.sh" >&2
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
             ap040_bus_timeout ap040_walker_cdc ap040_fill_cdc; do
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
echo "verilog work \"$R/rtl/sdram/cpu_enable_cadence.v\"" >> $PRJ
if [ -n "$REALSDRAM" ]; then
    # The REAL controller and the vendor SDRAM part, so that the AP68040, the
    # wrapper, sdram_ctrl and a chipset DMA master all run together -- the
    # configuration the hardware runs and that nothing simulated before.
    echo "verilog work \"$R/rtl/sdram/sdram_ctrl.v\""    >> $PRJ
    echo "verilog work \"$R/lib/models/AS4C16M16SA.v\""  >> $PRJ
fi
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
    -d SOC_SIM ${REALSDRAM:+-d REALSDRAM -i $D} ${NOCPU:+-d NOCPU} ${DMA_OVERLAP:+-d DMA_OVERLAP} ${P2CBLOCK:+-d P2CBLOCK=$P2CBLOCK} ${CPU_RATIO:+-d CPU_RATIO=$CPU_RATIO} ${CPU_PHASE:+-d CPU_PHASE=$CPU_PHASE} -debug typical -relax \
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
    # The mutant must NOT pass.  Test the SUMMARY line, not "DDR3 CPU TB: PASS":
    # that one is only the 68k program's own phases, and a mutant can complete
    # every phase while the bench's assertions fail around it.  --lwmutant does
    # exactly that (1895 32-bit-write protocol violations, program PASS), and
    # the old grep called that a mutant that did not fail.
    if grep -q "DDR3 CPU TB: 2 passed, 0 failed" "xsim_run_$VARIANT.log"; then
        echo "MUTANT DID NOT FAIL -- the bench has no teeth"; exit 1
    fi
    echo "mutant failed as required"
else
    grep -q "DDR3 CPU TB: 2 passed, 0 failed" "xsim_run_$VARIANT.log"
fi
