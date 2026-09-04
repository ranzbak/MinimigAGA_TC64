# usage: -tclargs <phase_steps>   : programs nothing; sets phase, arms ILA (trigger: hostce rising), pulses reset, waits, dumps CSV
set target [lindex $argv 0]
set base [lindex $argv 1]
set ltx $base/tree/project_1/project_1.runs/impl_1/minimig_openaars_top.ltx
set bit $base/tree/project_1/project_1.runs/impl_1/minimig_openaars_top.bit
set P openaars_virtual_top/amiga_clk/amiga_clk_i/
open_hw_manager; connect_hw_server -allow_non_jtag; open_hw_target
set dev [lindex [get_hw_devices] 0]; current_hw_device $dev
set_property PROBES.FILE $ltx $dev; set_property FULL_PROBES.FILE $ltx $dev; set_property PROGRAM.FILE $bit $dev
if {[lindex $argv 1] eq "program"} { program_hw_device $dev }
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]
set ila [get_hw_ilas -of_objects $dev]
proc rd {vio name} { global P; refresh_hw_vio $vio; scan [get_property INPUT_VALUE [get_hw_probes $P$name -of_objects $vio]] %x v; return $v }
proc rdo {vio name} { global P; scan [get_property OUTPUT_VALUE [get_hw_probes $P$name -of_objects $vio]] %x v; return $v }
proc wr {vio name val} { global P; set w [expr {$name eq "vio_nsteps" ? 2 : 1}]; set_property OUTPUT_VALUE [format %0${w}X $val] [get_hw_probes $P$name -of_objects $vio]; commit_hw_vio $vio }
# phase
set cnt [rd $vio ps_count_1]; if {$cnt > 32767} { set cnt [expr {$cnt - 65536}] }
set delta [expr {$target - $cnt}]; wr $vio vio_incdec [expr {$delta >= 0 ? 1 : 0}]; set remaining [expr {abs($delta)}]; set trig [rdo $vio vio_trig]
while {$remaining > 0} { set n [expr {$remaining > 255 ? 255 : $remaining}]; wr $vio vio_nsteps $n; set trig [expr {$trig ^ 1}]; wr $vio vio_trig $trig; after 50; while {[rd $vio busy] == 1} { after 20 }; set remaining [expr {$remaining - $n}] }
set cnt [rd $vio ps_count_1]; if {$cnt > 32767} { set cnt [expr {$cnt - 65536}] }
puts [format "=== phase %d steps = %+.3f ns ===" $cnt [expr {$cnt * 0.01574}]]
# ILA: store only command / data / drive cycles; trigger on the first CPU-port acknowledge (68k fetching the uploaded program)
set_property CONTROL.TRIGGER_POSITION 64 $ila
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.CAPTURE_CONDITION OR $ila
foreach p [get_hw_probes -of_objects $ila] { set_property CAPTURE_COMPARE_VALUE {} $p; set_property TRIGGER_COMPARE_VALUE {} $p }
set_property CAPTURE_COMPARE_VALUE {neq4'hF} [get_hw_probes -of_objects $ila -filter {NAME =~ *sd_cmd*}]
set_property CAPTURE_COMPARE_VALUE {eq1'b1} [get_hw_probes -of_objects $ila -filter {NAME =~ *cache_fill_1_d*}]
set_property CAPTURE_COMPARE_VALUE {eq1'b1} [get_hw_probes -of_objects $ila -filter {NAME =~ *cache_fill_2_d*}]
set_property CAPTURE_COMPARE_VALUE {eq1'b1} [get_hw_probes -of_objects $ila -filter {NAME =~ *sdata_oe*}]
set_property CONTROL.TRIGGER_CONDITION AND $ila

set_property TRIGGER_COMPARE_VALUE {eq1'bR} [get_hw_probes -of_objects $ila -filter {NAME =~ *init_done*}]
run_hw_ila $ila; after 500; wr $vio vio_rst 1; after 100; wr $vio vio_rst 0; puts "=== ILA armed, then reset pulsed ==="
wait_on_hw_ila -timeout 20 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file $base/ila_up_[format %+d $cnt].csv -force [current_hw_ila_data]
puts "=== ILA CSV written: $base/ila_up_[format %+d $cnt].csv ==="
close_hw_manager
