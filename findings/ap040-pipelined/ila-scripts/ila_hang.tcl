# SysInfo MHz hang: where is the CPU (5 "now" samples 5 s apart), then 4096
# samples of CIA-only bus cycles ($BFxxxx, storage-qualified on !as).
set dir [lindex $argv 0]
set pfx [lindex $argv 1]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
refresh_hw_device $dev
set ila {}
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_flags*}]]} { set ila $cand; break }
}
proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }
proc clear_all {ila} {
    foreach p [get_hw_probes -of_objects $ila] {
        set_property TRIGGER_COMPARE_VALUE {} $p
        set_property CAPTURE_COMPARE_VALUE {} $p
    }
}
proc grab {ila out label minutes} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout $minutes $ila} err]} { puts "=== $label: NO TRIGGER ==="; return 0 }
    write_hw_ila_data -csv_file $out -force [upload_hw_ila_data $ila]
    puts "=== $label: captured [clock format [clock seconds] -format %H:%M:%S] ==="
    return 1
}
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
for {set i 0} {$i < 3} {incr i} {
    clear_all $ila
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]
    grab $ila ${pfx}_now$i.csv "now$i" 1
    after 5000
}
# What wakes the CPU (first bus request after now), the CIA-B ICR reads, the CIA-A ICR reads.
proc cia_trap {ila out label adr} {
    clear_all $ila
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION AND $ila
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property CAPTURE_COMPARE_VALUE {eq4'b0XXX} [pr $ila *bus_ctl*]
    set_property TRIGGER_COMPARE_VALUE "eq32'h$adr" [pr $ila *tg68_adr*]
    grab $ila $out $label 1
}
clear_all $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_POSITION 16 $ila
set_property TRIGGER_COMPARE_VALUE {eq7'bxxxxxx1} [pr $ila *tg68_ram_hs*]
grab $ila ${pfx}_busy.csv "busy" 1
cia_trap $ila ${pfx}_icrb.csv "icr-b" 00BFDD00
cia_trap $ila ${pfx}_icra.csv "icr-a" 00BFED01
cia_trap $ila ${pfx}_ciab.csv "cia-b any" 00BFDXXX
close_hw_manager
