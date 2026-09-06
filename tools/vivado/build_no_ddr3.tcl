# Diagnostic build: exactly tools/vivado/build.tcl, but with the fileset
# generic HAVEDDR3=0, reverting Zorro-III fast RAM to the original SDRAM-
# backed path (sel_z3ram_sdram in TG68K.vhd) instead of the DDR3 island.
# Used to determine whether a hardware/software failure with Fast=Maximum
# is specific to the DDR3 backend or pre-exists independent of it.
# The generic is set on sources_1 immediately before the run and cleared
# immediately after, so the project is left exactly as it was found (the
# project default is HAVEDDR3=1).
#
#   vivado -mode batch -source tools/vivado/build_no_ddr3.tcl -tclargs <report-dir>
#
# Full build: refresh the file/constraint set, then synthesise, implement and
# write the bitstream.  Idempotent: every add below is guarded, so running the
# script twice changes nothing.
#
#   vivado -mode batch -source tools/vivado/build.tcl -tclargs <report-dir>
#
# Vivado 2023.2 needs libtinfo.so.5 (see findings/ddr3/implementation-plan.md
# section 0) and must NOT be given -stack (router segfault).
#
# Note the runs use the constraints fileset XC7A100T, not constrs_1; a file
# added to constrs_1 is silently ignored.

set out [lindex $argv 0]
set R [file normalize [file dirname [info script]]/../..]
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
# Task 2 deliberately left these out (nothing instantiated them yet); task 4
# wires them into minimig_virtual_top.v, so they must be in the build now.
add_src $R/rtl/ddr3/ddr3_fastram.v
add_src $R/rtl/ddr3/ddr3_cdc.v

#-----------------------------------------------------------------------------
# vio_ddr3: the bring-up VIO for the BIST and the PHY tap sweep
# (minimig_openaars_top.v parameter DDR3_BIST_VIO).
#
# probe_in : 0 busy, 1 done, 2 err_count, 3 first_err_addr, 4 first_err_xor,
#            5 lines_done, 6 init_done, 7 pll_locked
# probe_out: 0 start, 1 pattern, 2 range_log2, 3 mode, 4 phy_cfg_valid,
#            5 dqs_inc, 6 dqs_rst, 7 dq_inc, 8 dq_rst, 9 rdlat (init 5),
#            10 rdsel
#-----------------------------------------------------------------------------
set ipdir $R/ip/ddr3
file mkdir $ipdir
if {[get_ips -quiet vio_ddr3] eq ""} {
    puts "build.tcl: creating vio_ddr3"
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

# Make sure the IP's out-of-context synthesis result exists before the top run.
set ipr [get_runs -quiet vio_ddr3_synth_1]
if {$ipr ne "" && [get_property PROGRESS $ipr] ne "100%"} {
    launch_runs $ipr -jobs 8
    wait_on_run $ipr
}

#-----------------------------------------------------------------------------
# Build
#-----------------------------------------------------------------------------
set_property generic {HAVEDDR3=0} [get_filesets sources_1]
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set_property generic {} [get_filesets sources_1]
puts "build_no_ddr3.tcl: HAVEDDR3 generic cleared: '[get_property generic [get_filesets sources_1]]'"
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization -file $out/utilization.rpt
puts "=== ALL DONE ==="
