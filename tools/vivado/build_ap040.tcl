# AP68040 build, the design's only CPU since Stage E4a: the MC68040 in
# lib/AP68040, with MMU, FPU and its split caches, inside rtl/soc/TG68K.vhd
# (which presents a TG68K-shaped port set; the TG68KdotC kernel itself was
# removed and builds at tag d3_stable).  Fileset generics
#   HAVEDDR3=1 DDR3_FASTRAM_ILA=<0|1>
# findings/ap68040/plan-v2-with-ddr3.md.
#
#   vivado -mode batch -source tools/vivado/build_ap040.tcl -tclargs <report-dir> [<ila>] [<repo-root>] [<post-stores>] [<cpu-clk-divide>] [<cpu-ila-depth>]
#
# <ila> = 1 (default) puts ila_fastram on the CPU side of the DDR3 fast RAM so
# a boot can be captured with tools/vivado/ila_fastram_capture.tcl; 0 builds
# the shipping configuration.  Use 1 for bring-up: the first AP040 boot is
# exactly when the traffic is worth seeing.
#
# The generics are set on sources_1 immediately before the run and cleared
# immediately after, so the project is left as it was found (project defaults
# are HAVEDDR3=1, DDR3_FASTRAM_ILA=0).
#
# Vivado 2023.2 needs libtinfo.so.5 and must NOT be given -stack.
#
# Note the runs use the constraints fileset XC7A100T, not constrs_1.
#
# (tools/vivado/build.tcl, which built the TG68K design, is retired since
# Stage E4a; this is the build script.)
set out [lindex $argv 0]
# Repo root, set explicitly: second -tclargs wins, else it is derived from
# this script's own location.
set ila [expr {[llength $argv] > 1 ? [lindex $argv 1] : 1}]
# Posted stores in the AP68040's data cache: 1 is the design, 0 makes every
# store synchronous.  The A/B leg for the D3 chip-RAM coherency defect -- with
# Turbo chip RAM on, a store to chip RAM is a store to a CACHEABLE page and is
# therefore acknowledged before it reaches memory, so display DMA or the
# blitter can read the buffer before the write lands.  Stage D3 tripled the
# core's rate against the bus and so tripled that window.
# findings/ap68040/sdd-d3/d3-snoop-coherency.md.
set post [expr {[llength $argv] > 3 ? [lindex $argv 3] : 1}]
# AP68040 island clock divider: 30 = clk_114/3 (stage D3, shipping),
# 40 = clk_114/4, which is the PRE-D3 CPU RATE with the D3 architecture
# otherwise untouched -- the single-variable bisect for whether the chip
# RAM corruption is a rate-dependent window or a structural fault.
set cpudiv [expr {[llength $argv] > 4 ? [lindex $argv 4] : 30}]
# ila_cpu040 capture depth (6th -tclargs, default 4096).  An ILA stores EVERY
# probe at the full depth, so a wide probe is expensive: the 384-bit dbg_phist
# histogram at 4096 samples pushed the design to 167 RAMB36 against 135 on the
# part.  The histogram needs one sample, so its builds pass 1024.
set cpuiladepth [expr {[llength $argv] > 5 ? [lindex $argv 5] : 4096}]
# Arguments 7-10 (phase gate, data register, gate delay, request gate) were
# folded into the RTL in Stage E4a: the shipping settings are the only ones.
# Refuse them rather than silently ignore a build that asks for something else.
if {[llength $argv] > 6} {
    error "build_ap040.tcl: arguments 7-10 were removed in Stage E4a (the phase gate is fixed in rtl/soc/TG68K.vhd); pass at most 6"
}
set R [expr {[llength $argv] > 2 ? [file normalize [lindex $argv 2]] \
                                 : [file normalize [file dirname [info script]]/../..]}]
open_project $R/project_1/project_1.xpr

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
# Add a design source once.
proc add_src {f} {
    if {[get_files -quiet -of_objects [get_filesets sources_1] $f] eq ""} {
        add_files -fileset sources_1 -norecurse $f
        puts "build.tcl: added source $f"
    }
}

# Add a constraint file to the XC7A100T fileset once, and make sure it is not
# also sitting unused in constrs_1.
proc add_xdc {f} {
    if {[get_files -quiet -of_objects [get_filesets constrs_1] $f] ne ""} {
        remove_files -fileset constrs_1 $f
    }
    if {[get_files -quiet -of_objects [get_filesets XC7A100T] $f] eq ""} {
        add_files -fileset XC7A100T -norecurse $f
        puts "build.tcl: added constraint $f"
    }
    set_property USED_IN {synthesis implementation} \
        [get_files -of_objects [get_filesets XC7A100T] $f]
}

#-----------------------------------------------------------------------------
# Constraints
#-----------------------------------------------------------------------------
add_xdc $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc
add_xdc $R/fpga/openaars/aars_v5.0/xc7a100t/ddr3.xdc

#-----------------------------------------------------------------------------
# DDR3 island sources
#
# From the vendored controller only what synthesis needs: the two SystemVerilog
# controller sources and the xc7 PHY.  NOT ddr3_const.svh (dead code, nothing
# includes it), NOT the testbench, NOT examples/arty_a7/artix7_pll.v (the
# island has its own PLL wrapper, rtl/ddr3/ddr3_pll.v).
#-----------------------------------------------------------------------------
add_src $R/lib/core_ddr3_controller/src_v/ddr3_core.sv
add_src $R/lib/core_ddr3_controller/src_v/ddr3_dfi_seq.sv
add_src $R/lib/core_ddr3_controller/src_v/phy/xc7/ddr3_dfi_phy.v

add_src $R/rtl/ddr3/ddr3_pll.v
add_src $R/rtl/ddr3/ddr3_bist.v
add_src $R/rtl/ddr3/ddr3_top.v

# Zorro-III fast RAM: the cache backend and the clk_114 <-> clk100 handshake.
add_src $R/rtl/ddr3/ddr3_fastram.v
add_src $R/rtl/ddr3/ddr3_cdc.v

# The CPU enable cadence (Task 4, one source for sdram_ctrl and the bench).
# project_1.xpr predates the file,
# and a source that is not in sources_1 is simply not compiled.
add_src $R/rtl/sdram/cpu_enable_cadence.v
# Stage E2: the unit splitter TG68K.vhd instantiates for both RAM ports.
add_src $R/rtl/soc/ap040_ram_seq.vhd
# The XADC die-temperature reader, for the Chipset OSD menu's first line.
add_src $R/rtl/soc/fpga_temp.v

set ipdir $R/ip/ddr3
file mkdir $ipdir

#-----------------------------------------------------------------------------
# vio_ddr3: the bring-up VIO for the BIST and the PHY tap sweep
# (minimig_openaars_top.v parameter DDR3_BIST_VIO).  Not instantiated by this
# build (DDR3_BIST_VIO=0), but the IP is kept in the project so that switching
# back to tools/vivado/build_bist.tcl needs no regeneration.
#
# probe_in : 0 busy, 1 done, 2 err_count, 3 first_err_addr, 4 first_err_xor,
#            5 lines_done, 6 init_done, 7 pll_locked
# probe_out: 0 start, 1 pattern, 2 range_log2, 3 mode, 4 phy_cfg_valid,
#            5 dqs_inc, 6 dqs_rst, 7 dq_inc, 8 dq_rst, 9 rdlat (init 5),
#            10 rdsel
#-----------------------------------------------------------------------------
if {[get_ips -quiet vio_ddr3] eq ""} {
    puts "build_ap040.tcl: creating vio_ddr3"
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
        -module_name vio_ddr3 -dir $ipdir
    set_property -dict [list \
        CONFIG.C_NUM_PROBE_IN      {8} \
        CONFIG.C_PROBE_IN0_WIDTH   {1} \
        CONFIG.C_PROBE_IN1_WIDTH   {1} \
        CONFIG.C_PROBE_IN2_WIDTH   {32} \
        CONFIG.C_PROBE_IN3_WIDTH   {32} \
        CONFIG.C_PROBE_IN4_WIDTH   {32} \
        CONFIG.C_PROBE_IN5_WIDTH   {32} \
        CONFIG.C_PROBE_IN6_WIDTH   {1} \
        CONFIG.C_PROBE_IN7_WIDTH   {1} \
        CONFIG.C_NUM_PROBE_OUT     {11} \
        CONFIG.C_PROBE_OUT0_WIDTH  {1} \
        CONFIG.C_PROBE_OUT1_WIDTH  {3} \
        CONFIG.C_PROBE_OUT2_WIDTH  {5} \
        CONFIG.C_PROBE_OUT3_WIDTH  {1} \
        CONFIG.C_PROBE_OUT4_WIDTH  {1} \
        CONFIG.C_PROBE_OUT5_WIDTH  {2} \
        CONFIG.C_PROBE_OUT6_WIDTH  {2} \
        CONFIG.C_PROBE_OUT7_WIDTH  {2} \
        CONFIG.C_PROBE_OUT8_WIDTH  {2} \
        CONFIG.C_PROBE_OUT9_WIDTH  {3} \
        CONFIG.C_PROBE_OUT10_WIDTH {4} \
        CONFIG.C_PROBE_OUT2_INIT_VAL {0x1c} \
        CONFIG.C_PROBE_OUT9_INIT_VAL {0x5} \
    ] [get_ips vio_ddr3]
    generate_target all [get_files [get_property IP_FILE [get_ips vio_ddr3]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips vio_ddr3]]] }
}

#-----------------------------------------------------------------------------
# ila_fastram: the CPU-path capture core (minimig_virtual_top.v parameter
# DDR3_FASTRAM_ILA).  Clocked by CLK_114; every probe is a clk_114 register of
# ddr3_fastram / the clk_114 half of ddr3_cdc, so the core adds no crossing of
# its own.
#
# probe0  cpu_wadr[25:1]       probe12 dbg_resp_rdata[127:0]
# probe1  ddr_ila_st[6:0]      probe13 dbg_ack_tgl        (Stage E2: probes 0-6
# probe2  ddr_ila_two          probe14 dbg_bstate[1:0]     are the unit port,
# probe3  cpu_ir               probe15 dbg_sdr_read_req    widths unchanged)
# probe4  cpu_wdat[31:16]      probe16 dbg_sdr_read_ack
# probe5  cpu_rdat[31:16]      probe17 dbg_sdr_dat_r[15:0]
# probe6  cpu_ack              probe18 dbg_sdr_write_req
# probe7  ddr_ready            probe19 dbg_sdr_write_ack
# probe8  dbg_req_rd           probe20 dbg_sdr_adr[25:1]
# probe9  dbg_req_be[15:0]     probe21 dbg_sdr_dat_w[31:0]
# probe10 dbg_req_addr[31:0]   probe22 dbg_sdr_dqm_w[3:0]
# probe11 dbg_req_wdata[127:0] probe23 {cdc_ready,cdc_req,cdc_done,req_tgl}
#
# Comparators: only four probes take part in a trigger or storage-qualifier
# condition (probe1 ddr_ila_st and probe14 bstate qualify storage, probe6 cpu_ack
# and probe7 ddr_ready arm the trigger -- see
# tools/vivado/ila_fastram_capture.tcl), and those get two match units each so
# the supervisor can put either probe on either side.  Every other probe is
# recorded only, and one match unit for a 128-bit probe is a lot of LUTs, so
# ALL_PROBE_SAME_MU is off.  This is not cosmetic: with two match units on all
# 24 probes the core costs about 3.9k LUTs on clk_114, and the congestion that
# adds pushes the TG68K-ALU-to-cache path in the Minimig core into a setup
# violation, i.e. the debug build would no longer be a faithful copy of the
# design under investigation.
#
# 461 probe bits.  ILA_DEPTH is the sample depth; the capture RAM costs
# ceil(461 * ILA_DEPTH / 36864) RAMB36 and this device has 85 tiles free after
# the Minimig core, so 8192 (about 103 tiles) does not fit and 4096 (about 52)
# does.  Storage qualification (C_EN_STRG_QUAL) is what makes the shallower
# buffer sufficient: only cycles with a CPU access or a busy backend are
# stored, so 4096 samples are thousands of DDR3 transactions rather than
# 36 microseconds of idle.
set ILA_DEPTH 4096
if {[get_ips -quiet ila_fastram] eq ""} {
    puts "build_ap040.tcl: creating ila_fastram (depth $ILA_DEPTH)"
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
        -module_name ila_fastram -dir $ipdir
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES     {24} \
        CONFIG.C_DATA_DEPTH        $ILA_DEPTH \
        CONFIG.C_EN_STRG_QUAL      {1} \
        CONFIG.C_ADV_TRIGGER       {false} \
        CONFIG.C_TRIGIN_EN         {false} \
        CONFIG.C_TRIGOUT_EN        {false} \
        CONFIG.C_INPUT_PIPE_STAGES {1} \
        CONFIG.ALL_PROBE_SAME_MU     {false} \
        CONFIG.C_PROBE1_MU_CNT  {2} \
        CONFIG.C_PROBE6_MU_CNT  {2} \
        CONFIG.C_PROBE7_MU_CNT  {2} \
        CONFIG.C_PROBE14_MU_CNT {2} \
        CONFIG.C_PROBE0_WIDTH  {25} \
        CONFIG.C_PROBE1_WIDTH  {7} \
        CONFIG.C_PROBE2_WIDTH  {1} \
        CONFIG.C_PROBE3_WIDTH  {1} \
        CONFIG.C_PROBE4_WIDTH  {16} \
        CONFIG.C_PROBE5_WIDTH  {16} \
        CONFIG.C_PROBE6_WIDTH  {1} \
        CONFIG.C_PROBE7_WIDTH  {1} \
        CONFIG.C_PROBE8_WIDTH  {1} \
        CONFIG.C_PROBE9_WIDTH  {16} \
        CONFIG.C_PROBE10_WIDTH {32} \
        CONFIG.C_PROBE11_WIDTH {128} \
        CONFIG.C_PROBE12_WIDTH {128} \
        CONFIG.C_PROBE13_WIDTH {1} \
        CONFIG.C_PROBE14_WIDTH {2} \
        CONFIG.C_PROBE15_WIDTH {1} \
        CONFIG.C_PROBE16_WIDTH {1} \
        CONFIG.C_PROBE17_WIDTH {16} \
        CONFIG.C_PROBE18_WIDTH {1} \
        CONFIG.C_PROBE19_WIDTH {1} \
        CONFIG.C_PROBE20_WIDTH {25} \
        CONFIG.C_PROBE21_WIDTH {32} \
        CONFIG.C_PROBE22_WIDTH {4} \
        CONFIG.C_PROBE23_WIDTH {4} \
    ] [get_ips ila_fastram]
    generate_target all [get_files [get_property IP_FILE [get_ips ila_fastram]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips ila_fastram]]] }
}

# Make sure the IPs' out-of-context synthesis results exist before the top run.
foreach ip {vio_ddr3 ila_fastram} {
    set ipr [get_runs -quiet ${ip}_synth_1]
    if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
        launch_runs $ipr -jobs 8
        wait_on_run $ipr
    }
}

#-----------------------------------------------------------------------------
# Build
#-----------------------------------------------------------------------------
#-----------------------------------------------------------------------------
# ila_cpu040: the chipset bus, with its data, and where the CPU is.
#
# This started as a fault capture -- vector, faulting address, SR -- because a
# yellow Kickstart screen was assumed to be an exception before the trap
# handlers existed.  It is not.  The 040 reaches Exec with no exception at all
# and spins in AllocMem (Kickstart 46.143 $F8068E-$F806A0), so the fault ports
# earn nothing and the read/write data earns everything: telling "the memory
# region is small" from "the free list is corrupt" needs the mc_Bytes the
# allocator reads back, and both look identical in an address-only trace.
#
#   probe0 pc[31:0]      probe1 adr[31:0]   probe2 data_read[15:0]
#   probe3 data_write[15:0]  probe4 {as,rw,uds,lds}  probe5 flags[3:0]
#   probe6 ir[15:0]      probe7 tg68_ram_hs[6:0] (unit-port handshakes + busy, E2)
#   probe8 dbg_phist[383:0] -- chip-RAM acknowledge phase histogram
#   probe9 dbg_rtg[31:0]    probe10 {rtg_ena,rtg_16bit,rtg_clut,pixelwidth,baseaddr}[28:0]
# (The stage D3 dbg_snoop counters were removed in Stage E4a; they proved no
# snoop is lost across clk_114 -> clk_38.)
#
# 4096 deep, and storage qualification stays on: with Turbo off a chip access
# is a 7 MHz chipset cycle against an 8.8 ns clock, so capturing on !as is the
# difference between 4096 real transfers and about 64.
#-----------------------------------------------------------------------------
if {$ila} {
    set ipdir $R/ip/ddr3
    file mkdir $ipdir
    if {[get_ips -quiet ila_cpu040] eq ""} {
        puts "build_ap040.tcl: creating ila_cpu040"
        create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
            -module_name ila_cpu040 -dir $ipdir
    }
    # Applied every run, not only on creation.  The probe map changed once
    # already; an existing IP left at the old widths would elaborate against
    # the new port list and fail somewhere far from here.  Re-applying is free
    # when nothing changed -- Vivado only marks the IP out of date if it did.
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES {11} \
        CONFIG.C_DATA_DEPTH $cpuiladepth \
        CONFIG.C_TRIGIN_EN {false} \
        CONFIG.C_EN_STRG_QUAL {1} \
        CONFIG.C_ADV_TRIGGER {false} \
        CONFIG.C_PROBE0_WIDTH {32} \
        CONFIG.C_PROBE1_WIDTH {32} \
        CONFIG.C_PROBE2_WIDTH {16} \
        CONFIG.C_PROBE3_WIDTH {16} \
        CONFIG.C_PROBE4_WIDTH {4} \
        CONFIG.C_PROBE5_WIDTH {4} \
        CONFIG.C_PROBE6_WIDTH {16} \
        CONFIG.C_PROBE7_WIDTH {7} \
        CONFIG.C_PROBE8_WIDTH {384} \
        CONFIG.C_PROBE9_WIDTH {32} \
        CONFIG.C_PROBE10_WIDTH {29} \
    ] [get_ips ila_cpu040]
    generate_target all [get_files [get_property IP_FILE [get_ips ila_cpu040]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips ila_cpu040]]] }
    set ipr [get_runs -quiet ila_cpu040_synth_1]
    if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
        launch_runs $ipr -jobs 8
        wait_on_run $ipr
    }
}

#-----------------------------------------------------------------------------
# AP040_PIPE_DIR=<AP68040-pipelined checkout> in the environment builds the
# pipelined core (findings/ap040-pipelined/PLAN.md M5, hardware gate 1):
# TG68K's ap040_pipelined generic, the pipelined sources and its rtl/compat
# (which carries lifted copies of lib/AP68040's cache and adapters under the
# same module names -- so lib/AP68040's files are disabled for the run and
# re-enabled afterwards), MMU and FPU reported absent.
#
# Without AP040_PIPE_DIR, the lib/AP68040-pipelined submodule is used when it
# is checked out (branch 5.0-040-pipelined), so a fresh clone builds the
# pipelined core.  AP040_PIPE_DIR=none builds the reference core instead.
#-----------------------------------------------------------------------------
set pipe_gen ""
set pipe_off {}
set pipe_dir ""
if {[info exists ::env(AP040_PIPE_DIR)] && $::env(AP040_PIPE_DIR) ne ""} {
    if {$::env(AP040_PIPE_DIR) ne "none"} { set pipe_dir $::env(AP040_PIPE_DIR) }
} elseif {[file isdirectory $R/lib/AP68040-pipelined/rtl]} {
    set pipe_dir $R/lib/AP68040-pipelined
}
if {$pipe_dir ne ""} {
    set P [file normalize $pipe_dir]/rtl
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] $R/lib/AP68040/rtl/*.v] {
        if {[get_property IS_ENABLED $f]} {
            set_property IS_ENABLED false $f
            lappend pipe_off $f
        }
    }
    set pf [list $P/ap040_pipe_pkg.sv]
    foreach f [glob $P/ap040_*.v] { lappend pf $f }
    foreach f [glob $P/compat/*.v] { lappend pf $f }
    foreach f $pf {
        add_src $f
        set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
        set_property IS_ENABLED true [get_files -of_objects [get_filesets sources_1] $f]
    }
    set inc [get_property include_dirs [get_filesets sources_1]]
    foreach d [list $P $P/compat] { if {[lsearch -exact $inc $d] < 0} { lappend inc $d } }
    set_property include_dirs $inc [get_filesets sources_1]
    # AP040_PIPE_MMU=1 in the environment: the lifted MMU on (plan M7, gate 2)
    set pmmu [expr {[info exists ::env(AP040_PIPE_MMU)] && $::env(AP040_PIPE_MMU) eq "1" ? 1 : 0}]
    # AP040_PIPE_FPU=1: the lifted FPU on (plan M10.1 step 3, hardware gate 3).
    # It defaults to 0 -- the LC040 configuration every image so far was built
    # with -- because the FP instruction set is only partly sequenced: the
    # control registers, FMOVEM, FSAVE/FRESTORE and the arithmetic exceptions
    # are M10's remaining steps.  A 1 here is a measurement build, not a gate
    # image.
    set pfpu [expr {[info exists ::env(AP040_PIPE_FPU)] && $::env(AP040_PIPE_FPU) eq "1" ? 1 : 0}]
    set pipe_gen " AP040_PIPELINED=1 AP040_HAS_MMU=$pmmu AP040_HAS_FPU=$pfpu"
    puts "build_ap040.tcl: PIPELINED build from $P ([llength $pipe_off] lib/AP68040 files disabled)"
}

# The one functional difference from build.tcl: which kernel the wrapper
# elaborates, and whether the fast-RAM ILA comes along for the ride.
# FASTRAM_ILA=0 in the environment keeps the CPU ILA but drops the fast-RAM
# one: with M14's cache copies in block RAM, both ILAs together need 279
# RAMB18-equivalents of the 270 the device has (2026-09-24).
set fila [expr {[info exists ::env(FASTRAM_ILA)] && $::env(FASTRAM_ILA) ne "" ? $::env(FASTRAM_ILA) : $ila}]
set_property generic "HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=$fila CPU040_DEBUG_ILA=$ila AP040_POST_STORES=$post CPU_CLK_DIVIDE=$cpudiv$pipe_gen" \
    [get_filesets sources_1]

# The debug core adds a few thousand LUTs and flip-flops to clk_114, and with
# the default implementation strategy (no physical optimisation at all) the
# extra congestion costs the Minimig core about 0.4 ns on the TG68K-ALU to
# cpu_cache path -- a debug bitstream that violates setup on the very path
# being investigated is worthless.  Both physical-optimisation steps are
# therefore enabled for this run only and restored afterwards, exactly like the
# generics above.
set impl [get_runs impl_1]
set ppo_was [get_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $impl]
set pro_was [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $impl]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl

# IMPL_EFFORT=high in the environment raises the implementation effort for ONE
# run and restores the previous directives afterwards, exactly like the two
# switches above.  It is for the case where a build misses timing by a tenth of
# a nanosecond on a path that is route-bound rather than structural -- not a
# way to make a structurally failing design "pass"
# (findings/ap040-pipelined/PLAN.md Q11).  The directives are the ones Xilinx
# documents for each step; a step that rejects its name fails the build rather
# than silently running the default.
set eff_was {}
if {[info exists ::env(IMPL_EFFORT)] && $::env(IMPL_EFFORT) eq "high"} {
    foreach {st dirname} {PLACE_DESIGN ExtraTimingOpt
                          PHYS_OPT_DESIGN AggressiveExplore
                          ROUTE_DESIGN AggressiveExplore
                          POST_ROUTE_PHYS_OPT_DESIGN AggressiveExplore} {
        set prop STEPS.$st.ARGS.DIRECTIVE
        dict set eff_was $st [get_property $prop $impl]
        set_property $prop $dirname $impl
    }
    puts "build_ap040.tcl: IMPL_EFFORT=high -- place ExtraTimingOpt, phys_opt/route/post-route AggressiveExplore"
}

# RE-SYNTHESISE ONLY WHEN SOMETHING ACTUALLY CHANGED.  This was an
# unconditional `reset_run synth_1`, so every build re-ran the longest stage
# even when only a constraint file had changed (an XDC is read by
# implementation, not synthesis).  Vivado already tracks its own inputs:
# NEEDS_REFRESH covers edited sources, and the generic string above is
# compared by hand because setting it does not always mark the run stale.
# A stale synthesis is never reused: any doubt resets the run.
#
# NOT INCREMENTAL IMPLEMENTATION.  Reusing a previous routed checkpoint
# (INCREMENTAL_CHECKPOINT) would cut implementation time too, and it is
# deliberately not used here: Paul has had builds that met timing with it and
# then misbehaved on the board, while the same design built from scratch was
# fine.  The result depends on the reference checkpoint, which is exactly what
# a timing-critical design must not do.  Do not add it.
set synthrun [get_runs synth_1]
set gen_now  [get_property generic [get_filesets sources_1]]
set gen_file $R/project_1/.last_generics
set gen_was  ""
if {[file exists $gen_file]} {
    set fh [open $gen_file r]; set gen_was [string trim [read $fh]]; close $fh
}
if {$gen_now ne $gen_was
    || [get_property NEEDS_REFRESH $synthrun]
    || [get_property PROGRESS $synthrun] ne "100%"
    || [get_property STATUS $synthrun] eq "Not started"} {
    puts "build_ap040.tcl: re-synthesising (generics or sources changed)"
    reset_run synth_1
} else {
    puts "build_ap040.tcl: synthesis is up to date, implementing only"
}
set fh [open $gen_file w]; puts $fh $gen_now; close $fh

# STOP_AFTER_ROUTE=1 in the environment skips write_bitstream: a timing-only
# experiment does not need a file it will never load.
set last_step "write_bitstream"
if {[info exists ::env(STOP_AFTER_ROUTE)] && $::env(STOP_AFTER_ROUTE) eq "1"} {
    set last_step "route_design"
    puts "build_ap040.tcl: STOP_AFTER_ROUTE=1, no bitstream will be written"
}
launch_runs impl_1 -to_step $last_step -jobs 8
wait_on_run impl_1
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization   -file $out/utilization.rpt
# The point of this build: prove that every clk_114 <-> clk_ddr100 path is now
# timed, that the exceptions written for them are applied and not overridden,
# and that no crossing is left unprotected.
report_exceptions              -file $out/exceptions.rpt
report_exceptions -ignored     -file $out/exceptions_ignored.rpt
report_cdc                     -file $out/cdc.rpt
report_cdc -show_waiver        -file $out/cdc_with_waivers.rpt
report_waivers                 -file $out/waivers.rpt
report_cdc -details -from [get_clocks clk_114] -to [get_clocks clk_ddr100] \
    -file $out/cdc_114_to_100.rpt
report_cdc -details -from [get_clocks clk_ddr100] -to [get_clocks clk_114] \
    -file $out/cdc_100_to_114.rpt
report_cdc -details -from [get_clocks dll_28] -to [get_clocks clk_ddr100] \
    -file $out/cdc_28_to_100.rpt
report_clock_interaction -delay_type min_max -file $out/clock_interaction.rpt

# Deliverables next to the other stage bitstreams.
set impldir $R/project_1/project_1.runs/impl_1
file mkdir $out
foreach ext {bit ltx} {
    if {[file exists $impldir/minimig_openaars_top.$ext]} {
        file copy -force $impldir/minimig_openaars_top.$ext $out/
        puts "build_ap040.tcl: copied minimig_openaars_top.$ext to build/stage_ap040/"
    } else {
        puts "build_ap040.tcl: WARNING minimig_openaars_top.$ext not produced"
    }
}

set_property generic {} [get_filesets sources_1]
foreach f $pipe_off { set_property IS_ENABLED true $f }
if {$pipe_gen ne ""} {
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] $P/*] { set_property IS_ENABLED false $f }
    puts "build_ap040.tcl: lib/AP68040 re-enabled, pipelined sources disabled"
}
foreach {st was} $eff_was { set_property STEPS.$st.ARGS.DIRECTIVE $was $impl }
if {[dict size $eff_was]} { puts "build_ap040.tcl: implementation directives restored" }
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $ppo_was $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $pro_was $impl
puts "build_ap040.tcl: generics cleared: '[get_property generic [get_filesets sources_1]]'"
puts "build_ap040.tcl: phys_opt steps restored to $ppo_was / $pro_was"
puts "=== ALL DONE ==="
