# sdc_ila_capture.tcl -- arm u_ila_sdc (the SD card path ILA of an SDC_ILA=1
# build, tools/vivado/sdc_ila.tcl), wait for the trigger, save the capture.
#
#   vivado -mode batch -nojournal -nolog -source tools/vivado/sdc_ila_capture.tcl \
#          -tclargs <ltx> <outdir> <trigger> [<capture>] [<timeout-min>] [<position>]
#
#   trigger   opstart   busy rising: any op the firmware starts (CMD accepted)
#             cmdwrite  a CMD register write, accepted or not: hw_req = 1,
#                       ext_req_d = 0 (the access's first cycle), wr = 1,
#                       addr[23] = 1, addr[7:2] = 4
#             errirq    IRQPEND bit 3 (error) rising
#             refuse    STATUS 6 (refused) rising
#             gerr      STATUS 7 (Gayle error) rising OR the bridge's g_err
#             now       no condition: captures at once
#   capture   events (default): capture control, a sample is stored only when
#                       the OSD CPU starts a hardware access (hw_req rising),
#                       busy, irq or CS changes, a Gayle op starts or ends
#                       (g_req_r), or the bridge's error toggle flips; one
#                       condition per ILA port (a port's comparator takes one
#                       value), any of them (OR)
#             all       every clk_114 cycle (2048 cycles = 18 us: bit level)
#   timeout   minutes, default 10 (wait_on_hw_ila counts minutes)
#   position  trigger position in the 2048 samples, default 1024
#
# Writes <outdir>/sdc_ila_<trigger>.csv and .ila (read_hw_ila_data) and prints
# "=== ARMED ===" when the ILA waits: do the action on the Amiga only after
# that line (arm, then act).  THIS SCRIPT DOES NOT PROGRAM THE FPGA (that is
# tools/vivado/program.tcl), and it cannot run while anything else holds the
# cable (the RISC-V GDB bridge, tools/rvdebug/rv_jtag_bridge.tcl, another
# hardware manager): close those first.
#
# Signals are the probes sdc_<signal> that <ltx dir>/sdc_ila_hwprobes.tcl
# makes (written by tools/vivado/sdc_ila.tcl with the core:
# create_hw_probe -map from each signal's ILA port bits, bit k of the probe
# = bit k of the signal), their widths from <ltx dir>/sdc_ila_map.txt (the
# same insertion's table).  Synthesis names the probes' nets differently in
# every build; neither file depends on those names, so nothing is guessed
# (final review M5: the arming used sdc_ila_names.py's reading of the .ltx,
# whose bit order was an assumption).  A compare value is built per signal
# probe from the bits given (X for the others), MSB first.
# On a wait timeout the core is triggered by hand (run_hw_ila -trigger_now)
# so the upload has data: the NOT TRIGGERED capture is written too.
# Not run on hardware yet (written with the build, Task 14; checked in
# tclsh against a mocked hardware manager and the stage's files).
set ltx    [file normalize [lindex $argv 0]]
set outdir [file normalize [lindex $argv 1]]
set trig   [lindex $argv 2]
set capt   [expr {[llength $argv] > 3 ? [lindex $argv 3] : "events"}]
set tmo    [expr {[llength $argv] > 4 ? [lindex $argv 4] : 10}]
set pos    [expr {[llength $argv] > 5 ? [lindex $argv 5] : 1024}]
if {$trig ni {opstart cmdwrite errirq refuse gerr now}} { error "sdc_ila_capture.tcl: trigger '$trig': opstart cmdwrite errirq refuse gerr now" }
if {$capt ni {events all}} { error "sdc_ila_capture.tcl: capture '$capt': events or all" }
if {![file exists $ltx]} { error "sdc_ila_capture.tcl: no $ltx" }
file mkdir $outdir

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
set ila [get_hw_ilas -of_objects $dev -filter {CELL_NAME =~ *u_ila_sdc*}]
if {[llength $ila] != 1} { error "sdc_ila_capture.tcl: [llength $ila] ILAs named u_ila_sdc (the lab bitstream and its .ltx loaded?)" }
puts "=== ILA: $ila, [get_property CONTROL.DATA_DEPTH $ila] samples ==="

# the build's signal probes: sdc_<signal> on the core (create_hw_probe), and
# each signal's width from the insertion's map ("probe<n> [hi:lo] <signal> ...")
set sdir [file dirname $ltx]
foreach f {sdc_ila_hwprobes.tcl sdc_ila_map.txt} {
    if {![file exists $sdir/$f]} { error "sdc_ila_capture.tcl: no $sdir/$f (tools/vivado/sdc_ila.tcl writes it with the core; build_ap040.tcl copies it next to the .ltx)" }
}
source $sdir/sdc_ila_hwprobes.tcl
set fh [open $sdir/sdc_ila_map.txt r]
foreach line [split [read $fh] "\n"] {
    if {[regexp {^probe\d+\s+\[(\d+)(?::(\d+))?\]\s+(\S+)} $line -> hi lo sig]} {
        if {$lo eq ""} { set lo $hi }
        set ::sigw($sig) [expr {$hi - $lo + 1}]
    }
}
close $fh
proc hwprobe {sig} {
    global ila
    set p [get_hw_probes -quiet sdc_$sig -of_objects $ila]
    if {[llength $p] != 1} { error "sdc_ila_capture.tcl: no hardware probe sdc_$sig (sdc_ila_hwprobes.tcl sourced?)" }
    return $p
}
# compare <TRIGGER|CAPTURE> {<signal> <value bits, MSB first, of signal bits
# lo..> <lo>} ...: e.g. {addr 000100 0}, {irq_pend R 3}; on the probe
# sdc_<signal>, bit k = signal bit k
proc compare {kind args} {
    array set cv {}
    foreach a $args {
        lassign $a sig val lo
        if {![info exists ::sigw($sig)]} { error "sdc_ila_capture.tcl: no signal $sig in sdc_ila_map.txt" }
        set w $::sigw($sig)
        set n [string length $val]
        if {$lo < 0 || $lo + $n > $w} { error "sdc_ila_capture.tcl: $sig\[[expr {$lo + $n - 1}]:$lo\] outside its $w bits" }
        if {![info exists cv($sig)]} { set cv($sig) [string repeat X $w] }
        for {set i 0} {$i < $n} {incr i} {
            set bit [expr {$lo + $n - 1 - $i}]
            set k [expr {$w - 1 - $bit}]
            set cv($sig) [string replace $cv($sig) $k $k [string index $val $i]]
        }
    }
    foreach sig [lsort [array names cv]] {
        set w $::sigw($sig)
        set_property ${kind}_COMPARE_VALUE "eq$w'b$cv($sig)" [hwprobe $sig]
        puts "sdc_ila_capture.tcl: $kind sdc_$sig = eq$w'b$cv($sig)"
    }
}

foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set_property CONTROL.TRIGGER_POSITION $pos $ila
set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila
switch -- $trig {
    opstart {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        compare TRIGGER {busy R 0}
    }
    cmdwrite {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        compare TRIGGER {hw_req 1 0} {wr 1 0} {ext_req_d 0 0} {addr23 1 0} {addr 000100 0}
    }
    errirq {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        compare TRIGGER {irq_pend R 3}
    }
    refuse {
        set_property CONTROL.TRIGGER_CONDITION AND $ila
        compare TRIGGER {st_refused R 0}
    }
    gerr {
        set_property CONTROL.TRIGGER_CONDITION OR $ila
        compare TRIGGER {st_gerr R 0}
        compare TRIGGER {q_err 1 0}
    }
    now { }
}
if {$capt eq "events"} {
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION OR $ila
    # one condition per ILA port (its capture comparator takes one value)
    compare CAPTURE {hw_req R 0}
    compare CAPTURE {busy B 0}
    compare CAPTURE {cs_n_r B 0}
    compare CAPTURE {irq_r B 0}
    compare CAPTURE {g_req_r B 0}
    compare CAPTURE {etog B 0}
} else {
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
}
run_hw_ila $ila
puts "=== ARMED: trigger $trig, capture $capt, position $pos, timeout $tmo min: act now ==="
set triggered 1
if {[catch {wait_on_hw_ila -timeout $tmo $ila} msg]} {
    # not triggered: trigger by hand, so the upload has a buffer to read
    # (an un-triggered core has none; the upload would fail before any file)
    puts "=== wait ended: $msg: triggering now ==="
    set triggered 0
    run_hw_ila -trigger_now $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} msg2]} { puts "=== the manual trigger: $msg2 ===" }
}
if {[catch {upload_hw_ila_data $ila} msg]} {
    close_hw_manager
    error "sdc_ila_capture.tcl: upload_hw_ila_data: $msg (nothing written)"
}
set base $outdir/sdc_ila_$trig
write_hw_ila_data -csv_file $base.csv -force [current_hw_ila_data]
write_hw_ila_data $base.ila -force [current_hw_ila_data]
puts "=== [expr {$triggered ? {TRIGGERED} : {NOT TRIGGERED (timeout)}}]: $base.csv, $base.ila ==="
close_hw_manager
