# usage: vivado -mode batch -source run.tcl -tclargs <outdir> <srcs.tcl> <period_ns> [GEN=VAL ...]
set outdir [lindex $argv 0]; set srcs [lindex $argv 1]; set period [lindex $argv 2]
set gens [lrange $argv 3 end]
file mkdir $outdir
set_part xc7a100tfgg676-2
source $srcs
set gargs {}
foreach g $gens { lappend gargs -generic $g }
set extra {}
if {[info exists ::env(EXTRA_SYNTH)]} { set extra $::env(EXTRA_SYNTH) }
synth_design -top wtop -part xc7a100tfgg676-2 -mode out_of_context -flatten_hierarchy rebuilt {*}$gargs {*}$extra
create_clock -name clk -period $period [get_ports clk]
if {[llength [get_ports -quiet tck]]} { create_clock -name tck -period 50.0 [get_ports tck]
  set_clock_groups -asynchronous -group clk -group tck }
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
set fp [open $outdir/summary.txt w]; puts $fp "period=$period wns=$wns gens=$gens extra=$extra version=[version -short]"; close $fp
