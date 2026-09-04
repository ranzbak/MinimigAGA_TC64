set out [file dirname [info script]]
set src $out/rtl
create_project -in_memory -part xc7a100tfgg676-2
set_property include_dirs $src [current_fileset]
foreach f [glob $src/*.v] { read_verilog -sv $f }
synth_design -top ap040_tg68k_compat -part xc7a100tfgg676-2 -mode out_of_context \
  -generic AP040_HAS_MMU=1 -generic AP040_HAS_FPU=1 -generic AP040_ENABLE_CACHE=1
create_clock -period 20.000 -name clk [get_ports clk]
report_utilization -file $out/util_synth_fixedram.rpt
puts "=== SYNTH DONE ==="
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $out/util_routed.rpt
report_timing_summary -no_detailed_paths -file $out/timing_routed.rpt
report_timing -max_paths 5 -file $out/worst_routed.rpt
# slack histogram over the 5000 worst endpoints: how many need >2, >3, >4 cycles of 8.815ns
set paths [get_timing_paths -max_paths 5000 -nworst 1 -unique_pins]
set n2 0; set n3 0; set n4 0; set n5 0; set tot 0
foreach p $paths {
  set d [get_property DATAPATH_DELAY $p]; incr tot
  if {$d > 17.63} {incr n2}; if {$d > 26.45} {incr n3}; if {$d > 35.26} {incr n4}; if {$d > 44.08} {incr n5}
}
set fh [open $out/histogram.txt w]
puts $fh "endpoints examined: $tot"
puts $fh "datapath > 2 x 8.815 ns (17.63): $n2"
puts $fh "datapath > 3 x 8.815 ns (26.45): $n3"
puts $fh "datapath > 4 x 8.815 ns (35.26): $n4"
puts $fh "datapath > 5 x 8.815 ns (44.08): $n5"
close $fh
write_checkpoint -force $out/ap040_routed.dcp
puts "=== PNR DONE ==="
