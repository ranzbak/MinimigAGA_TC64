# Program, then repeatedly arm on a chosen address with the window kept BEFORE
# the trigger, so the last capture that fires holds the history leading into
# the fatal access.  After the core halts there are no bus cycles, so arming
# stops firing and the loop ends by itself.
set dir [lindex $argv 0]
set out [lindex $argv 1]
set adr [lindex $argv 2]
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
puts "=== programmed at [clock format [clock seconds] -format %H:%M:%S] ==="
set ila {}
foreach c [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $c -filter {NAME =~ *dbg_flags*}]]} { set ila $c; break }
}
proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 4000 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set_property TRIGGER_COMPARE_VALUE "eq32'h$adr" [pr $ila *tg68_adr*]
set got 0
for {set i 1} {$i <= 400} {incr i} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} e]} {
        puts "=== stopped firing after $got captures at [clock format [clock seconds] -format %H:%M:%S] ==="
        break
    }
    incr got
    write_hw_ila_data -csv_file [format "%s_%03d.csv" $out $got] -force [upload_hw_ila_data $ila]
}
puts "=== $got captures; the last is the one that matters ==="
close_hw_manager
