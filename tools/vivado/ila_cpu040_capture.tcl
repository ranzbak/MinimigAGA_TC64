# Capture the AP68040's bus and fault state while the machine boots.
#
#   vivado -mode batch -source tools/vivado/ila_cpu040_capture.tcl \
#          -tclargs <bitstream-dir> <out.csv> [minutes] [program] [fault|now]
#
# Needs a bitstream built with CPU040_DEBUG_ILA=1 (tools/vivado/build_ap040.tcl
# with <ila> = 1), which puts ila_cpu040 on dbg_pc / tg68_adr / bus_ctl /
# dbg_flags / dbg_ir / tg68_ram_hs (the unit-port handshakes, cpustate before E2).
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
set mode    [expr {[llength $argv] > 4 ? [lindex $argv 4] : "fault"}]

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

# WINDOW_COUNT must be 1: the depth is split across windows, so a stale window
# count leaves one sample per window and the capture looks empty.
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.TRIGGER_POSITION 3584 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
# store only real bus cycles: as is bus_ctl[3], active low
set_property CONTROL.CAPTURE_MODE BASIC $ila
set_property CAPTURE_COMPARE_VALUE {eq4'b0XXX} [pr $ila *bus_ctl*]
# trigger on the fault flag, dbg_flags[3] -- or, with <mode> = now, on
# anything, which captures whatever the CPU is executing at this instant.
# "now" is what answers "is it running, and where": a PC that moves through a
# handful of values in a 200-byte window is a spin, not progress.
set_property CONTROL.TRIGGER_CONDITION AND $ila
if {$mode eq "busy"} {
    # Fire on the first cycle the CPU actually uses a bus (tg68_ram_hs[0]: a
    # RAM unit request or the chipset address strobe; cpustate[1:0] /= 01
    # before Stage E2), then capture every clock from there.  This is what to use
    # for a stall measurement: an idle Amiga sits in STOP with the PC frozen
    # and no bus cycles at all, so an untriggered capture measures nothing.
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    set_property CONTROL.TRIGGER_POSITION 16 $ila
    set_property TRIGGER_COMPARE_VALUE {eq7'bxxxxxx1} [pr $ila *tg68_ram_hs*]
} elseif {$mode eq "now"} {
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]
} else {
    set_property TRIGGER_COMPARE_VALUE {eq4'b1xxx} [pr $ila *dbg_flags*]
}

run_hw_ila $ila
puts "=== ILA armed at [clock format [clock seconds] -format %H:%M:%S] -- boot the machine now ==="
flush stdout
set rc [catch {wait_on_hw_ila -timeout $minutes $ila} err]
if {$rc} {
    puts "=== NO TRIGGER within $minutes minutes: the boot took no access fault ==="
    puts "=== ($err) ==="
} else {
    # Write the object upload_hw_ila_data RETURNS.  [current_hw_ila_data] looks
    # like it should work and is what the older scripts here use, but with this
    # core it yields a one-sample file -- four attempts went into finding that.
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -csv_file $out -force $data
    puts "=== FAULT captured, CSV written: $out ==="
}
close_hw_manager
