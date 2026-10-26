# run.tcl -- out-of-context size and timing of the OSD text layer
# rtl/openaars/adv7511/osd_text.v (findings/osd-redesign/plan.md Phase 1), with
# the 720p generator in front of it, in the registered-I/O wrapper wosd.v.
#
#   vivado -mode batch -source run.tcl -tclargs <outdir> <period_ns> [GEN=VAL ...]
#
# Run it through go.sh (libtinfo shim, no -stack).  clk = clk_148 (6.734 ns),
# wclk = dll_28 (35.26 ns), unrelated, with wizard.xdc's crossing bound
# (set_max_delay -datapath_only 6.734 into clk_148).  Results in <outdir>:
# util.rpt, util_hier.rpt (u_osd = the layer), timing.rpt, crit.rpt (worst
# clk -> clk paths, the generator's included), osd_crit.rpt (worst clk paths
# ending in u_osd), xing.rpt (worst wclk -> clk paths), summary.txt (one line:
# wns = all clk -> clk, wns_into_u_osd, wns_wclk_to_clk, whs).
set outdir [file normalize [lindex $argv 0]]; set period [lindex $argv 1]
set gens [lrange $argv 2 end]
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../../..]
set part xc7a100tfgg676-2
file mkdir $outdir
# the font RAM's $readmemh("osd_font.mem") is read from the run directory
file copy -force $repo/rtl/openaars/adv7511/osd_font.mem [pwd]/osd_font.mem
read_verilog -sv $repo/rtl/openaars/adv7511/signal_generator.sv
read_verilog $repo/rtl/openaars/adv7511/osd_text.v
read_verilog $here/wosd.v
set gargs {}
foreach g $gens { lappend gargs -generic $g }
synth_design -top wosd -part $part -mode out_of_context -flatten_hierarchy rebuilt {*}$gargs
create_clock -name clk  -period $period [get_ports clk]
create_clock -name wclk -period 35.26   [get_ports wclk]
set_max_delay -datapath_only 6.734 -from [get_clocks wclk] -to [get_clocks clk]
set_max_delay -datapath_only 8.815 -from [get_clocks clk] -to [get_clocks wclk]
report_utilization -hierarchical -hierarchical_depth 2 -file $outdir/util_synth_hier.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file $outdir/util_hier.rpt
report_timing_summary -max_paths 5 -file $outdir/timing.rpt
report_timing -from [get_clocks clk] -to [get_clocks clk] -max_paths 5 -nworst 1 -file $outdir/crit.rpt
report_timing -from [get_clocks wclk] -to [get_clocks clk] -max_paths 3 -nworst 1 -file $outdir/xing.rpt
set osd [get_cells -hier -filter {NAME =~ u_osd/* && IS_PRIMITIVE}]
report_timing -from [get_clocks clk] -to $osd -max_paths 5 -nworst 1 -file $outdir/osd_crit.rpt
set wns  [get_property SLACK [get_timing_paths -from [get_clocks clk] -to [get_clocks clk] -max_paths 1 -nworst 1 -setup]]
set wnso [get_property SLACK [get_timing_paths -from [get_clocks clk] -to $osd -max_paths 1 -nworst 1 -setup]]
set wnsx [get_property SLACK [get_timing_paths -from [get_clocks wclk] -to [get_clocks clk] -max_paths 1 -nworst 1 -setup]]
set whs  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fp [open $outdir/summary.txt w]
puts $fp "period=$period wns=$wns wns_into_u_osd=$wnso wns_wclk_to_clk=$wnsx whs=$whs gens=$gens version=[version -short]"
close $fp
