# ooc.tcl - out-of-context synth of the pipelined AP68040 block (plan M0.7).
#
#   vivado -mode batch -nolog -nojournal -source ooc.tcl -tclargs <pipe-tree> [<top>] [<outdir>] [<generics...>]
#
# <pipe-tree>  the AP68040-pipelined checkout (reads <pipe-tree>/rtl/*.v and,
#              once the bus lands, the adapters it pulls from the reference)
# <top>        default ap040_pipe_core (the whole pipeline with its L1 array
#              until M5); from M5 on ap040_pipe_tg68k_compat
# <outdir>     default ./out_<top>
# generics     name=value pairs passed as -generic
#
# Budget check (plan 1.3): 26.4 ns on clk = the CPU island's 37.8125 MHz.
# Prints two lines the caller greps:
#   === LUT <n>
#   === WNS <ns>
# Run through ooc.sh, which supplies the libtinfo.so.5 shim Vivado 2023.2
# needs and never passes -stack.
set tree [lindex $argv 0]
set top  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "ap040_pipe_core"}]
set out  [expr {[llength $argv] > 2 ? [lindex $argv 2] : "out_$top"}]
set gens [lrange $argv 3 end]
file mkdir $out
set src $tree/rtl
create_project -in_memory -part xc7a100tfgg676-2
set_property include_dirs [list $src] [current_fileset]
# the L1 test array (until M5) is budgeted out: black box
set here [file dirname [file normalize [info script]]]
foreach f [glob -nocomplain $src/*.sv] { read_verilog -sv $f }
foreach f [glob $src/*.v] {
	if {[file tail $f] eq "ap040_pipe_l1.v"} { read_verilog -sv $here/l1_blackbox.v; continue }
	read_verilog -sv $f
}
if {[file exists $src/primitives/dpram.v]} { read_verilog -sv $src/primitives/dpram.v }
# the wrapper and what it lifted from the reference (M5 on): rtl/compat
if {[file isdirectory $src/compat]} {
	set_property include_dirs [list $src $src/compat] [current_fileset]
	foreach f [glob $src/compat/*.v] { read_verilog -sv $f }
	# AP040_DPRAM: the RAM primitive the Minimig build uses (rtl/cpu040/dpram.v,
	# block RAM) instead of the lifted generic one, which synthesises to LUTs
	if {[info exists ::env(AP040_DPRAM)]} { read_verilog -sv $::env(AP040_DPRAM) } else { read_verilog -sv $src/compat/primitives/dpram.v }
}
set gargs {}
foreach g $gens { lappend gargs -generic $g }
synth_design -top $top -part xc7a100tfgg676-2 -mode out_of_context {*}$gargs
create_clock -period 26.4 -name clk [get_ports clk]
report_utilization -file $out/util.rpt
report_utilization -hierarchical -file $out/util_hier.rpt
report_timing_summary -no_detailed_paths -file $out/timing.rpt
report_timing -max_paths 5 -file $out/worst.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fh [open $out/util.rpt r]; set u [read $fh]; close $fh
regexp {Slice LUTs\*?\s*\|\s*(\d+)} $u -> luts
puts "=== LUT $luts"
puts "=== WNS $wns"
