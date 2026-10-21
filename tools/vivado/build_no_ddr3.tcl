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

# The OSD host CPU file groups (hostcpu_apply / hostcpu_restore): the board
# top builds the RISC-V host CPU, whose
# sources project_1 does not list.
source [file dirname [info script]]/hostcpu.tcl

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

# The CPU enable cadence (Task 4, one source for sdram_ctrl and the bench).
# KEEP IN SYNC WITH tools/vivado/build.tcl: project_1.xpr predates the file,
# and a source that is not in sources_1 is simply not compiled.
add_src $R/rtl/sdram/cpu_enable_cadence.v
# The second Gayle IDE port (findings/cdrom/plan.md 7.3): gayle.v instantiates
# gayle_port.v once per port; project_1.xpr predates the file.
add_src $R/rtl/minimig/gayle_port.v

#-----------------------------------------------------------------------------
# No debug cores: see the note in tools/vivado/build.tcl.  The VIO and ILA
# belong to build_bist.tcl and build_ila.tcl, which create them on demand.
#
# Build
#-----------------------------------------------------------------------------
set_property generic {HAVEDDR3=0} [get_filesets sources_1]
# The host CPU sources in, retired ones out, for this run (restored below).
hostcpu_apply $R
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set_property generic {} [get_filesets sources_1]
puts "build_no_ddr3.tcl: HAVEDDR3 generic cleared: '[get_property generic [get_filesets sources_1]]'"
hostcpu_restore
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization -file $out/utilization.rpt
puts "=== ALL DONE ==="
