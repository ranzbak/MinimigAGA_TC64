# fake_vivado.tcl -- the hw_jtag commands of Vivado 2023.2 as MEASURED on the
# board (2026-10-20, Platform Cable USB II, XC7A100T; probes and results in
# findings/osd-riscv/debug.md "Board session"), on the shim's pin driver
# (shim::set_driver: a reference TAP in the unit tests).  vbe (the Vivado
# back end in rv_jtag_bridge.tcl) runs on these, unchanged:
#   run_state_hw_jtag [-state path] S   default path from the current state,
#       or the given path (each step a legal transition, ending in S); the
#       path {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE} (with or without
#       a leading IDLE) from IDLE is refused as on the board
#   scan_ir_hw_jtag / scan_dr_hw_jtag n -tdi <hex>   the documented entry
#       path (from xRPAUSE: Exit2 -> Shift, no capture), n bits, then ALWAYS
#       Exit1 -> Update -> IDLE (whatever run_state/runtest said before)
#   runtest_hw_jtag ... -tck n          to IDLE (default path), n clocks
# State: shim::st.  Every call is counted in fakeviv::calls.

namespace eval fakeviv {
    variable calls 0
    variable refused 0
}

proc fakeviv::Opts {argv} {
    set o [dict create]
    set pos {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {[string match -* $a]} {
            dict set o $a [lindex $argv [incr i]]
        } else {
            lappend pos $a
        }
    }
    return [list $o $pos]
}

proc run_state_hw_jtag {args} {
    incr fakeviv::calls
    lassign [fakeviv::Opts $args] o pos
    set target [lindex $pos 0]
    set path [expr {[dict exists $o -state] ? [dict get $o -state] : {}}]
    if {$target ni {RESET IDLE DRPAUSE IRPAUSE}} {
        error "fake run_state_hw_jtag: $target is not a stable state"
    }
    if {$path ne {}} {
        if {$shim::st eq "IDLE" && $target eq "IRPAUSE" &&
            ($path eq {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE} ||
             $path eq {IDLE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE})} {
            incr fakeviv::refused
            error "ERROR: \[Labtoolstcl 44-271\] run_state_hw_jtag failed chain_0"
        }
        if {[catch {shim::PathTms $shim::st $path}]} {
            incr fakeviv::refused
            error "ERROR: \[Labtoolstcl 44-271\] run_state_hw_jtag failed chain_0 (path {$path} from $shim::st)"
        }
    }
    shim::RunState $target $path
    return $target
}

proc fakeviv::Scan {type argv} {
    incr fakeviv::calls
    lassign [Opts $argv] o pos
    set n [lindex $pos 0]
    set bits [rvb::hex_to_bits [dict get $o -tdi] $n]
    set u [string toupper $type]
    set entry $shim::ENTRY($type,$shim::st)
    set etms [shim::PathTms $shim::st $entry]
    set xtms [shim::PathTms ${u}EXIT1 [list ${u}UPDATE IDLE]]
    set ne [string length $etms]
    set tms $etms[string repeat 0 [expr {$n - 1}]]1$xtms
    set tdi [string repeat 0 $ne]$bits[string repeat 0 [string length $xtms]]
    set tdo [shim::Clock $tms $tdi $ne [expr {$ne + $n}]]
    set shim::st IDLE
    return [rvb::bits_to_hex $tdo]
}

proc scan_ir_hw_jtag {args} { fakeviv::Scan ir $args }
proc scan_dr_hw_jtag {args} { fakeviv::Scan dr $args }

proc runtest_hw_jtag {args} {
    incr fakeviv::calls
    lassign [fakeviv::Opts $args] o pos
    set n [expr {[dict exists $o -tck] ? [dict get $o -tck] : 0}]
    if {$shim::st ne "IDLE"} {
        set tms [shim::PathTms $shim::st $shim::RUNSTATE($shim::st,IDLE)]
        shim::Clock $tms [string repeat 0 [string length $tms]]
        set shim::st IDLE
    }
    if {$n > 0} {
        shim::Clock [string repeat 0 $n] [string repeat 0 $n]
    }
    return IDLE
}
