set out [lindex $argv 0]
set R [file normalize [file dirname [info script]]/../..]
open_project $R/project_1/project_1.xpr
set x $R/fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc
if {[get_files -quiet -of_objects [get_filesets constrs_1] $x] ne ""} { remove_files -fileset constrs_1 $x }
if {[get_files -quiet -of_objects [get_filesets XC7A100T] $x] eq ""} { add_files -fileset XC7A100T -norecurse $x }
set_property USED_IN {synthesis implementation} [get_files -of_objects [get_filesets XC7A100T] $x]
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing_summary.rpt
report_utilization -file $out/utilization.rpt
puts "=== ALL DONE ==="
