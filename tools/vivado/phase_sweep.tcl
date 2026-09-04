# usage: vivado -mode batch -source sweep.tcl -tclargs <target_steps> [reset]
#   moves sdr_rd to <target_steps> x 15.74 ps from the static 0 deg, then optionally pulses the system reset
set target [lindex $argv 0]
set do_rst [expr {[llength $argv] > 1}]
set bit [lindex $argv 0]
set ltx [file rootname $bit].ltx
open_hw_manager; connect_hw_server -allow_non_jtag; open_hw_target
set dev [lindex [get_hw_devices] 0]; current_hw_device $dev
set_property PROBES.FILE $ltx $dev; set_property FULL_PROBES.FILE $ltx $dev; set_property PROGRAM.FILE $bit $dev
if {[lindex $argv 0] eq "program"} { program_hw_device $dev; set target 0 }
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]
proc rd {vio name} { refresh_hw_vio $vio; scan [get_property INPUT_VALUE [get_hw_probes openaars_virtual_top/amiga_clk/amiga_clk_i/$name -of_objects $vio]] %x v; return $v }
proc rdo {vio name} { scan [get_property OUTPUT_VALUE [get_hw_probes openaars_virtual_top/amiga_clk/amiga_clk_i/$name -of_objects $vio]] %x v; return $v }
proc wr {vio name val} { set w [expr {$name eq "vio_nsteps" ? 2 : 1}]; set_property OUTPUT_VALUE [format %0${w}X $val] [get_hw_probes openaars_virtual_top/amiga_clk/amiga_clk_i/$name -of_objects $vio]; commit_hw_vio $vio }
foreach target [lrange $argv 1 end] {
  if {$target eq "reset" || $target eq "program"} continue
  puts "=== POINT [format %.2f [expr {$target*0.01574}]] ns  ([clock format [clock seconds] -format %H:%M:%S]) ==="
set cnt [rd $vio ps_count_1]; if {$cnt > 32767} { set cnt [expr {$cnt - 65536}] }
  puts "=== current ps_count $cnt  locked [rd $vio locked_sync_reg] ==="
  set delta [expr {$target - $cnt}]
  wr $vio vio_incdec [expr {$delta >= 0 ? 1 : 0}]
  set remaining [expr {abs($delta)}]
  set trig [rdo $vio vio_trig]
  while {$remaining > 0} {
    set n [expr {$remaining > 255 ? 255 : $remaining}]
    wr $vio vio_nsteps $n
    set trig [expr {$trig ^ 1}]; wr $vio vio_trig $trig
    after 50; while {[rd $vio busy] == 1} { after 20 }
    set remaining [expr {$remaining - $n}]
  }
  set cnt [rd $vio ps_count_1]; if {$cnt > 32767} { set cnt [expr {$cnt - 65536}] }
  puts [format "=== ps_count now %d = %+.3f ns on sdr_rd ===" $cnt [expr {$cnt * 0.01574}]]
  if {$do_rst} { for {set i 0} {$i < 5} {incr i} { wr $vio vio_rst 1; after 200; wr $vio vio_rst 0; puts "=== system reset pulsed ($i) ==="; after 6000 } }
  
}
close_hw_manager
