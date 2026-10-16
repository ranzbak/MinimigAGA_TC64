# usage: vivado -mode batch -source run.tcl -tclargs <outdir> <VexOsd|VexOsd_DMT|VexOsd_DMJ> <period_ns> [GEN=VAL ...]
# env VEXSRC overrides the Verilog file (scratch variants of the core); default rtl/host/vexriscv/<variant>.v
set outdir [file normalize [lindex $argv 0]]; set variant [lindex $argv 1]; set period [lindex $argv 2]
set gens [lrange $argv 3 end]
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../../..]
file mkdir $outdir
set_part xc7a100tfgg676-2
set src $repo/rtl/host/vexriscv/$variant.v
if {[info exists ::env(VEXSRC)]} { set src $::env(VEXSRC) }
read_verilog $src
read_verilog $here/wvex.v
set defs [list VEXMOD=$variant]
if {[string match *_DMT $variant]} { lappend defs DMT }
if {[string match *_DMJ $variant]} { lappend defs DMJ }
set_property verilog_define $defs [current_fileset]
set gargs {}
foreach g $gens { lappend gargs -generic $g }
set extra {}
if {[info exists ::env(EXTRA_SYNTH)]} { set extra $::env(EXTRA_SYNTH) }
synth_design -top wtop -part xc7a100tfgg676-2 -mode out_of_context -flatten_hierarchy rebuilt {*}$gargs {*}$extra
create_clock -name clk -period $period [get_ports clk]
if {[llength $defs] > 1} {
  create_clock -name tck -period 50.0 [get_ports tck]
  set_clock_groups -asynchronous -group clk -group tck
}
report_utilization -hierarchical -hierarchical_depth 2 -file $outdir/util_synth_hier.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file $outdir/util_hier.rpt
report_timing_summary -max_paths 5 -file $outdir/timing.rpt
report_timing -max_paths 1 -nworst 1 -group clk -file $outdir/crit.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup -group clk]]
set fp [open $outdir/summary.txt w]; puts $fp "variant=$variant src=$src period=$period wns=$wns gens=$gens extra=$extra version=[version -short]"; close $fp
