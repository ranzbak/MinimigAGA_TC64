# Program the ila=1 bitstream, then take one untriggered 4096-sample window every
# <gap> seconds for <count> windows, so a boot can be judged from the CPU's own
# state over minutes rather than from one instant: dbg_flags = E is a halted
# core, a healthy one idles at $00F815D2 (Exec's STOP loop) and wakes on
# interrupts across $F813xx-$F819xx.  Summarise the CSVs with boot_summary.py.
#
#   vivado -mode batch -source boot-check.tcl -tclargs <bitstream-dir> <out-prefix> [count] [gap-s]
#
# libtinfo shim on LD_LIBRARY_PATH, no -stack; wait_on_hw_ila -timeout is minutes.
set dir   [lindex $argv 0]
set out   [lindex $argv 1]
set count [expr {[llength $argv] > 2 ? [lindex $argv 2] : 8}]
set gap   [expr {[llength $argv] > 3 ? [lindex $argv 3] : 30}]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
set_property PROGRAM.FILE     $dir/minimig_openaars_top.bit $dev
program_hw_device $dev
refresh_hw_device $dev
set t0 [clock seconds]
puts "=== programmed at [clock format $t0 -format %H:%M:%S] ==="
set ila {}
foreach c [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $c -filter {NAME =~ *dbg_flags*}]]} { set ila $c; break }
}
if {$ila eq ""} { puts "=== NO CPU ILA -- build with <ila> = 1 ==="; close_hw_manager; return }
proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]
for {set i 1} {$i <= $count} {incr i} {
    after [expr {$gap * 1000}]
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} e]} { puts "=== window $i: no trigger ==="; continue }
    set f [format "%s_%02d.csv" $out $i]
    write_hw_ila_data -csv_file $f -force [upload_hw_ila_data $ila]
    puts "=== window $i at +[expr {[clock seconds] - $t0}] s -> $f ==="
    flush stdout
}
close_hw_manager
