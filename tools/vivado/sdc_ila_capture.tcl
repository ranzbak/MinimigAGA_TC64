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
# Signals are found through <ltx dir>/sdc_ila_bits.txt (written for the build by
# tools/vivado/sdc_ila_names.py from the .ltx and sdc_ila_map.txt): synthesis
# names the probes' nets differently in every build, so names are never
# guessed here.  A compare value is built per hardware probe from the signal
# bits it holds (X for the others), MSB first.
# Not run on hardware yet (written with the build, Task 14).
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

# signal bit -> {hw probe name, width, bit in the probe}
set bitsf [file dirname $ltx]/sdc_ila_bits.txt
if {![file exists $bitsf]} { error "sdc_ila_capture.tcl: no $bitsf (python3 tools/vivado/sdc_ila_names.py [file dirname $ltx])" }
set fh [open $bitsf r]
foreach line [split [read $fh] "\n"] {
    if {$line eq "" || [string index $line 0] eq "#"} continue
    lassign $line sig bit name width pos
    set ::sigbit($sig,$bit) [list $name $width $pos]
}
close $fh
proc hwprobe {name} {
    global ila
    foreach p [get_hw_probes -of_objects $ila] {
        set n [get_property NAME $p]
        if {$n eq $name || [regsub {\[[0-9:]+\]$} $n {}] eq $name} { return $p }
    }
    error "sdc_ila_capture.tcl: no hardware probe $name"
}
# compare <TRIGGER|CAPTURE> {<signal> <value bits, MSB first, of signal bits
# lo..> <lo>} ...: e.g. {addr 000100 0}, {irq_pend R 3}
proc compare {kind args} {
    array set cv {}
    array set wd {}
    foreach a $args {
        lassign $a sig val lo
        set n [string length $val]
        for {set i 0} {$i < $n} {incr i} {
            set bit [expr {$lo + $n - 1 - $i}]
            if {![info exists ::sigbit($sig,$bit)]} { error "sdc_ila_capture.tcl: no $sig bit $bit in sdc_ila_bits.txt" }
            lassign $::sigbit($sig,$bit) name width pos
            if {![info exists cv($name)]} { set cv($name) [string repeat X $width]; set wd($name) $width }
            set k [expr {$width - 1 - $pos}]
            set cv($name) [string replace $cv($name) $k $k [string index $val $i]]
        }
    }
    foreach name [array names cv] {
        set_property ${kind}_COMPARE_VALUE "eq$wd($name)'b$cv($name)" [hwprobe $name]
        puts "sdc_ila_capture.tcl: $kind $name = eq$wd($name)'b$cv($name)"
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
if {[catch {wait_on_hw_ila -timeout $tmo $ila} msg]} { puts "=== wait ended: $msg ==="; set triggered 0 }
upload_hw_ila_data $ila
set base $outdir/sdc_ila_$trig
write_hw_ila_data -csv_file $base.csv -force [current_hw_ila_data]
write_hw_ila_data $base.ila -force [current_hw_ila_data]
puts "=== [expr {$triggered ? {TRIGGERED} : {NOT TRIGGERED (timeout)}}]: $base.csv, $base.ila ==="
close_hw_manager
