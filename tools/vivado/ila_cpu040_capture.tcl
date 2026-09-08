# Capture the AP68040's bus and fault state while the machine boots.
#
#   vivado -mode batch -source tools/vivado/ila_cpu040_capture.tcl \
#          -tclargs <bitstream-dir> <out.csv> [minutes] [program]
#
# Needs a bitstream built with CPU040_DEBUG_ILA=1 (tools/vivado/build_ap040.tcl
# with <ila> = 1), which puts ila_cpu040 on dbg_pc / tg68_adr / bus_ctl /
# dbg_flags / dbg_ir / cpustate.
#
# Trigger: dbg_flags[3] = fault.  Storage is qualified on !as, so the 4096
# samples are bus cycles rather than idle clocks, and the trigger sits near the
# END of the buffer -- what matters is the history LEADING UP to a fault, not
# what the machine does afterwards.
#
# If it never triggers, that is the result: the boot took no access fault.
#
# wait_on_hw_ila -timeout is in MINUTES (verified the hard way), so <minutes>
# is how long you have to get the machine to the point of interest.
set dir     [lindex $argv 0]
set out     [lindex $argv 1]
set minutes [expr {[llength $argv] > 2 ? [lindex $argv 2] : 10}]
set doprog  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
set_property PROGRAM.FILE     $dir/minimig_openaars_top.bit $dev
if {$doprog} { program_hw_device $dev }
refresh_hw_device $dev

# hw_ila objects are called hw_ila_1, hw_ila_2 ... -- the hierarchy is not in
# their NAME, so pick the core by a probe only the CPU ILA has.
set ila {}
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_flags*}]]} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "=== NO CPU ILA in this bitstream -- build with <ila> = 1 ==="
    puts "=== cores present: [get_hw_ilas -of_objects $dev] ==="
    close_hw_manager
    return
}
puts "=== using ILA: $ila ==="

proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }

set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 3584 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
# store only real bus cycles: as is bus_ctl[3], active low
set_property CONTROL.CAPTURE_MODE BASIC $ila
set_property CAPTURE_COMPARE_VALUE {eq4'b0XXX} [pr $ila *bus_ctl*]
# trigger on the fault flag, dbg_flags[3]
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property TRIGGER_COMPARE_VALUE {eq4'b1XXX} [pr $ila *dbg_flags*]

run_hw_ila $ila
puts "=== ILA armed at [clock format [clock seconds] -format %H:%M:%S] -- boot the machine now ==="
flush stdout
set rc [catch {wait_on_hw_ila -timeout $minutes $ila} err]
if {$rc} {
    puts "=== NO TRIGGER within $minutes minutes: the boot took no access fault ==="
    puts "=== ($err) ==="
} else {
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file $out -force [current_hw_ila_data]
    puts "=== FAULT captured, CSV written: $out ==="
}
close_hw_manager
