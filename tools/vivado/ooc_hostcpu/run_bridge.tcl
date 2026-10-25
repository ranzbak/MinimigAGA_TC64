# usage: vivado -mode batch -source run_bridge.tcl -tclargs <outdir> <rv0|rv1|rv2> <period_ns>
# OOC synthesis + implementation of the whole host_bridge (= hostcpu: CPU, bridge, hostcache, boot ROM).
# env: RVROM (OSDBoot_rv_ROM.vhd; default sim/host_bridge t_lanes ROM built by make)
set outdir [file normalize [lindex $argv 0]]; set mode [lindex $argv 1]; set period [lindex $argv 2]
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../../..]
file mkdir $outdir
set_part xc7a100tfgg676-2
switch $mode {
  rv0 { set gens {-generic rv_debug=0} }
  rv1 { set gens {-generic rv_debug=1} }
  rv2 { set gens {-generic rv_debug=2} }
  default { error "mode must be rv0, rv1 or rv2" }
}
read_verilog $repo/rtl/host/hostcache.v
read_verilog $repo/rtl/sdram/dpram_inf_generic.v
set rom $repo/sim/host_bridge/build/t_lanes/OSDBoot_rv_ROM.vhd
if {[info exists ::env(RVROM)]} { set rom $::env(RVROM) }
read_vhdl $rom
read_verilog $repo/rtl/host/rv_hostcpu.v
read_verilog $repo/rtl/host/vexriscv/VexOsd.v
if {$mode eq "rv2"} { read_verilog $repo/rtl/host/vexriscv/VexOsd_DMJ.v }
if {$mode eq "rv1"} {
  read_verilog $repo/rtl/host/vexriscv/VexOsd_DMT.v
  read_verilog $repo/rtl/host/xilinx/rv_bscane2.v
}
read_vhdl $repo/rtl/host/host_bridge.vhd
synth_design -top host_bridge -part xc7a100tfgg676-2 -mode out_of_context -flatten_hierarchy rebuilt {*}$gens
create_clock -name clk -period $period [get_ports clk]
if {$mode eq "rv2"} {
  create_clock -name tck -period 50.0 [get_ports rv_jtag_tck]
  set_clock_groups -asynchronous -group clk -group tck
}
if {$mode eq "rv1"} {
  # the BSCANE2 TCK output (USER4 tunnel), as a board build would constrain it
  set bs [get_cells -hier -filter {REF_NAME == BSCANE2}]
  puts "BSCANE2 cells: [llength $bs] : $bs"
  create_clock -name tck -period 50.0 [get_pins $bs/TCK]
  set_clock_groups -asynchronous -group clk -group tck
}
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_synth_hier.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $outdir/routed.dcp
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
report_timing_summary -max_paths 5 -file $outdir/timing.rpt
report_timing -max_paths 5 -nworst 1 -unique_pins -group clk -file $outdir/crit.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup -group clk]]
foreach pat {*hw_req_reg* *wr_reg*} {
  set c [get_cells -hier -filter "NAME =~ $pat"]
  puts "CELLS $pat: [llength $c] : $c"
  lappend cells "$pat=[llength $c]"
}
set fp [open $outdir/summary.txt w]; puts $fp "mode=$mode period=$period wns=$wns gens=$gens cells=$cells version=[version -short]"; close $fp
