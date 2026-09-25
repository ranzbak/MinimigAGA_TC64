# Screen-free boot probe for the AP68040 builds -- "did the Amiga boot?"
# answered over JTAG, with nobody in front of the monitor.
#
#   vivado -mode batch -source tools/vivado/ila_boot_probe.tcl \
#          -tclargs <bitstream-dir> <out-prefix> <program 0|1> [boot-wait-s]
#
# Needs a bitstream built with CPU040_DEBUG_ILA=1 (tools/vivado/build_ap040.tcl
# with <ila> = 1).  Programs the board (optionally), waits, then takes THREE
# captures from the CPU ILA in one hw session -- one session at a time is a
# hard rule of this lab.
#
#   <prefix>_now.csv    trigger on anything, capture every clock: where is the
#                       CPU this instant.
#   <prefix>_busy.csv   trigger on the first cycle the CPU wants the bus: what
#                       wakes an idle machine.
#   <prefix>_write.csv  trigger on the first WRITE, storage qualified on !as,
#                       three quarters of the window is history: what the
#                       machine still stores, and from where.
#
# Decode with tools/vivado/ila_bus_decode.py <csv> --longs --pc.
#
# THE REFERENCE SIGNATURE, measured 2026-09-09 00:31 on a machine Paul had just
# confirmed was sitting at Workbench (build/stage_ap040_x3_ila, Kickstart
# 46.143):
#
#   now    4096 of 4096 samples at dbg_pc = $00F815D2, dbg_ir = 4E72 (STOP),
#          dbg_flags = 0, `as` never low -- Exec's dispatcher idle loop.
#   busy   the level-3 autovector: $6C -> $F81354, INTENAR ($DFF01C) = $602C,
#          INTREQR ($DFF01E) with VERTB set, ExecBase from $4 = $40000864 (a
#          FAST RAM pointer -- the board window), then the VERTB server chain.
#   write  the chain runs on into Exec's server dispatch at $F8190A, clears
#          INTREQ ($DFF09C), and enters a ROM server at $F945AC.  On a booted
#          machine the trace also shows PCs in the $40xxxxxx fast-RAM window
#          (disk-loaded code) or, with a program running, a drawing loop
#          storing bytes into chip RAM.
#
# THERE IS NO FAULT MODE, and that is deliberate.  Any trigger pattern with a
# 1 in it on the dbg_flags probe -- eq4'b1xxx, eq4'b1XXX, BASIC capture or
# ALWAYS -- comes back one second after arming with a dataset holding the OTHER
# ILA core's columns and no samples.  Five attempts, two scripts, with the core
# selected by CELL_NAME and current_hw_ila set explicitly; the modes below,
# which trigger on eq4'bxxxx and on bus_ctl, work every time in the same
# session.  tools/vivado/ila_cpu040_capture.tcl's "fault" mode does the same
# thing, so its "fired instantly with zero samples" means nothing about the
# machine.  Do not read a fault trigger's result as evidence until someone
# works out why.
#
# What a machine that has NOT finished booting looks like, same build, 60 s
# and 110 s after programming: `now` spread over a dozen ROM PCs ($00F81EF6,
# $00FB7FAC ...), `busy` reading CIA-B ($00BFD800/$00BFDF00) or spinning on
# DMACONR ($00DFF002) in WaitBlit.  So the discriminator is not one address --
# it is "idle in STOP at $F815D2, woken only by VERTB" versus "still working".
# Give a cold boot four to five minutes before believing an untriggered probe.
set dir     [lindex $argv 0]
set pfx     [lindex $argv 1]
set doprog  [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0}]
set bootw   [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
set_property PROGRAM.FILE     $dir/minimig_openaars_top.bit $dev
if {$doprog} {
    puts "=== programming $dir at [clock format [clock seconds] -format %H:%M:%S] ==="
    program_hw_device $dev
}
refresh_hw_device $dev

set ila {}
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_flags*}]]} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "=== NO CPU ILA in this bitstream ==="
    close_hw_manager
    return
}
puts "=== using ILA: $ila ==="

if {$bootw > 0} {
    puts "=== waiting ${bootw}s for the machine to boot ==="
    flush stdout
    after [expr {$bootw * 1000}]
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
    puts "=== $label armed at [clock format [clock seconds] -format %H:%M:%S] ==="
    flush stdout
    set rc [catch {wait_on_hw_ila -timeout $minutes $ila} err]
    if {$rc} {
        puts "=== $label: NO TRIGGER within $minutes minute(s) ==="
        puts "=== ($err) ==="
        return 0
    }
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -csv_file $out -force $data
    puts "=== $label: captured -> $out ==="
    return 1
}

set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila

# --- now: where is the CPU this instant ---------------------------------
clear_all $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]
grab $ila ${pfx}_now.csv "now" 1

# --- busy: what wakes it --------------------------------------------------
clear_all $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_POSITION 16 $ila
set_property TRIGGER_COMPARE_VALUE {eq7'bxxxxxx1} [pr $ila *tg68_ram_hs*]
grab $ila ${pfx}_busy.csv "busy" 2

# --- write: the first store, with its history -----------------------------
# bus_ctl = {as, rw, uds, lds}, active low: a write cycle is as=0, rw=0.
clear_all $ila
set_property CONTROL.CAPTURE_MODE BASIC $ila
# Three quarters of the window is history, whatever depth the image was built
# with (a fixed 3072 fails on a 1024-deep core: "trigger position must be a
# value less than data depth").
set_property CONTROL.TRIGGER_POSITION [expr {[get_property CONTROL.DATA_DEPTH $ila] * 3 / 4}] $ila
set_property CAPTURE_COMPARE_VALUE {eq4'b0XXX} [pr $ila *bus_ctl*]
set_property TRIGGER_COMPARE_VALUE {eq4'b00XX} [pr $ila *bus_ctl*]
grab $ila ${pfx}_write.csv "write" 2

close_hw_manager
