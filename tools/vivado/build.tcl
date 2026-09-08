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
# AP68040 (lib/AP68040, submodule pinned at 0e76761): an MC68040 with MMU, FPU
# and split caches whose top level presents a TG68K-shaped port set.  Built in
# whenever the sources are present; which core is actually instantiated is the
# CPU_CORE generic on minimig_openaars_top, so an unused core costs parse time
# and nothing else.  findings/ap68040/plan-v2-with-ddr3.md.
#
# rtl/cpu040/dpram.v replaces the submodule's primitives/dpram.v: the original
# writes both RAM ports in one process, which Vivado will not infer as block
# RAM, and the core then does not fit the device.  See that file.
#-----------------------------------------------------------------------------
if {[file exists $R/lib/AP68040/rtl/ap040_tg68k_compat.v]} {
    foreach f [list ap040_tg68k_compat ap040_core ap040_alu ap040_muldiv \
                    ap040_regfile ap040_fpu ap040_mmu ap040_cache \
                    ap040_bus16_adapter ap040_bus_timeout ap040_walker_cdc \
                    ap040_fill_cdc] {
        add_src $R/lib/AP68040/rtl/$f.v
    }
    add_src $R/rtl/cpu040/dpram.v
    # ap040_defs.svh is `include`d by every one of them.
    set_property include_dirs [list $R/lib/AP68040/rtl] [get_filesets sources_1]
    # They use SystemVerilog (packed structs, always_ff); Vivado needs telling.
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] *ap040_*.v] {
        set_property file_type SystemVerilog $f
    }
} else {
    puts "build.tcl: lib/AP68040 not checked out; CPU_CORE=AP040 will not build"
    puts "build.tcl:   git submodule update --init lib/AP68040"
}

#-----------------------------------------------------------------------------
# No debug cores here.  The DDR3 bring-up VIO (vio_ddr3, DDR3_BIST_VIO) and
# the fast-RAM ILA (ila_fastram, DDR3_FASTRAM_ILA) are created and used only
# by tools/vivado/build_bist.tcl and tools/vivado/build_ila.tcl, which
# generate the IP into ip/ddr3 on demand; the RTL instantiates them only when
# those generics are 1, and the project defaults are 0.  Until 2026-09-07 this
# script created the VIO and ran its out-of-context synthesis on every default
# build, for a core that nothing instantiated -- wasted minutes and a pair of
# CRITICAL WARNINGs about IP constraints with no module to apply to.
#
# Build
#-----------------------------------------------------------------------------
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization -file $out/utilization.rpt
puts "=== ALL DONE ==="
