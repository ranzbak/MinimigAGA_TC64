# AP68040 build: tools/vivado/build.tcl with the fileset generics
#   CPU_IS_AP040=1 HAVEDDR3=1 DDR3_FASTRAM_ILA=<0|1>
# so that rtl/soc/TG68K.vhd elaborates its AP040 generate branch -- the
# MC68040 in lib/AP68040, with MMU, FPU and its split caches -- instead of the
# TG68KdotC kernel.  Everything else in the design is unchanged; that core
# presents a TG68K-shaped port set.  findings/ap68040/plan-v2-with-ddr3.md.
#
#   vivado -mode batch -source tools/vivado/build_ap040.tcl -tclargs <report-dir> [<ila>] [<repo-root>]
#
# <ila> = 1 (default) puts ila_fastram on the CPU side of the DDR3 fast RAM so
# a boot can be captured with tools/vivado/ila_fastram_capture.tcl; 0 builds
# the shipping configuration.  Use 1 for bring-up: the first AP040 boot is
# exactly when the traffic is worth seeing.
#
# The generics are set on sources_1 immediately before the run and cleared
# immediately after, so the project is left as it was found (project defaults
# are CPU_IS_AP040=0, HAVEDDR3=1, DDR3_FASTRAM_ILA=0).
#
# Vivado 2023.2 needs libtinfo.so.5 and must NOT be given -stack.
#
# Note the runs use the constraints fileset XC7A100T, not constrs_1.
#
# KEEP IN SYNC WITH tools/vivado/build.tcl.
set out [lindex $argv 0]
# Repo root, set explicitly: second -tclargs wins, else it is derived from
# this script's own location.
set ila [expr {[llength $argv] > 1 ? [lindex $argv 1] : 1}]
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
# KEEP IN SYNC WITH tools/vivado/build.tcl: project_1.xpr predates the file,
# and a source that is not in sources_1 is simply not compiled.
add_src $R/rtl/sdram/cpu_enable_cadence.v

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
# probe0  cpuAddr[25:1]        probe12 dbg_resp_rdata[127:0]
# probe1  cpustate[6:0]        probe13 dbg_ack_tgl
# probe2  cpuU                 probe14 dbg_bstate[1:0]
# probe3  cpuL                 probe15 dbg_sdr_read_req
# probe4  cpuWR[15:0]          probe16 dbg_sdr_read_ack
# probe5  cpuRD[15:0]          probe17 dbg_sdr_dat_r[15:0]
# probe6  cpuena               probe18 dbg_sdr_write_req
# probe7  ddr_ready            probe19 dbg_sdr_write_ack
# probe8  dbg_req_rd           probe20 dbg_sdr_adr[25:1]
# probe9  dbg_req_be[15:0]     probe21 dbg_sdr_dat_w[31:0]
# probe10 dbg_req_addr[31:0]   probe22 dbg_sdr_dqm_w[3:0]
# probe11 dbg_req_wdata[127:0] probe23 {cdc_ready,cdc_req,cdc_done,req_tgl}
#
# Comparators: only four probes take part in a trigger or storage-qualifier
# condition (probe1 cpustate and probe14 bstate qualify storage, probe6 cpuena
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
#   probe6 ir[15:0]      probe7 cpustate[6:0]
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
        CONFIG.C_NUM_OF_PROBES {8} \
        CONFIG.C_DATA_DEPTH {4096} \
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
    ] [get_ips ila_cpu040]
    generate_target all [get_files [get_property IP_FILE [get_ips ila_cpu040]]]
    catch { create_ip_run [get_files [get_property IP_FILE [get_ips ila_cpu040]]] }
    set ipr [get_runs -quiet ila_cpu040_synth_1]
    if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
        launch_runs $ipr -jobs 8
        wait_on_run $ipr
    }
}

# The one functional difference from build.tcl: which kernel the wrapper
# elaborates, and whether the fast-RAM ILA comes along for the ride.
set_property generic "CPU_IS_AP040=1 HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=$ila CPU040_DEBUG_ILA=$ila" \
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

reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
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
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $ppo_was $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $pro_was $impl
puts "build_ap040.tcl: generics cleared: '[get_property generic [get_filesets sources_1]]'"
puts "build_ap040.tcl: phys_opt steps restored to $ppo_was / $pro_was"
puts "=== ALL DONE ==="
