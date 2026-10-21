# shim_rbb_backend.tcl -- test back end of the bridge core: Vivado's
# documented hw_jtag semantics (help scan_ir_hw_jtag / scan_dr_hw_jtag /
# run_state_hw_jtag / runtest_hw_jtag, Vivado 2023.2) replayed as bit-level
# TMS/TDI sequences on a pin driver:
#
#   - a remote_bitbang server (the Verilator harness sim/rv_dbg): run as a
#     script, this file is the simulation bridge (OpenOCD -> rbb_core.tcl ->
#     this shim -> harness), see "main" below;
#   - the Tcl reference TAP of the unit tests (shim::set_driver).
#
# Semantics implemented (README.md "Vivado semantics in the shim"):
#   run_state_hw_jtag [-state path] S: the documented default path from the
#     current stable state (the table of help run_state_hw_jtag; its typos
#     IDLE->IRPAUSE "DRPAUSE" and DRPAUSE->IRPAUSE "IREXIT12" read as
#     DRSELECT / IREXIT1) or the given path (each step a legal transition,
#     ending in S); S becomes the scans' end state.
#   scan_xr_hw_jtag n: the documented entry path from the current stable
#     state to xRSHIFT (scan_ir's "IDLE: IRSELECT" read as DRSELECT >
#     IRSELECT), n bits (TMS 1 on the last), then to the end state; only the
#     scan's own pause state and IDLE are accepted as end states (anything
#     else is not documented: error).
#   runtest_hw_jtag -tck n: to IDLE (default path), n clocks with TMS 0;
#     IDLE becomes the end state (pessimistic: the help leaves open whether
#     runtest's end state also applies to scans).
# Each bit: write(TCK 0, TMS, TDI), R where TDO is wanted, write(TCK 1);
# after a command TCK goes low again (OpenOCD's bitbang shape).
#
# Every call is logged (shim::configure -log <channel>).

namespace eval shim {
    variable st RESET           ;# Vivado's TAP state (stable)
    variable endst IDLE         ;# end state of scans (last run_state / runtest)
    variable drv {}             ;# pin driver: {*}$drv <tms-bits> <tdi-bits> <from> <to> -> TDO
    variable logch {}
    variable n_calls 0

    variable RUNSTATE
    array set RUNSTATE {
        DRPAUSE,RESET   {DREXIT2 DRUPDATE DRSELECT IRSELECT RESET}
        DRPAUSE,IDLE    {DREXIT2 DRUPDATE IDLE}
        DRPAUSE,DRPAUSE {DREXIT2 DRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
        DRPAUSE,IRPAUSE {DREXIT2 DRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
        IDLE,RESET      {DRSELECT IRSELECT RESET}
        IDLE,IDLE       {}
        IDLE,DRPAUSE    {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
        IDLE,IRPAUSE    {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
        IRPAUSE,RESET   {IREXIT2 IRUPDATE DRSELECT IRSELECT RESET}
        IRPAUSE,IDLE    {IREXIT2 IRUPDATE IDLE}
        IRPAUSE,DRPAUSE {IREXIT2 IRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
        IRPAUSE,IRPAUSE {IREXIT2 IRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
        RESET,RESET     {}
        RESET,IDLE      {IDLE}
        RESET,DRPAUSE   {IDLE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
        RESET,IRPAUSE   {IDLE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
    }
    variable ENTRY
    array set ENTRY {
        dr,RESET   {IDLE DRSELECT DRCAPTURE DRSHIFT}
        dr,IDLE    {DRSELECT DRCAPTURE DRSHIFT}
        dr,IRPAUSE {IREXIT2 IRUPDATE DRSELECT DRCAPTURE DRSHIFT}
        dr,DRPAUSE {DREXIT2 DRSHIFT}
        ir,RESET   {IDLE DRSELECT IRSELECT IRCAPTURE IRSHIFT}
        ir,IDLE    {DRSELECT IRSELECT IRCAPTURE IRSHIFT}
        ir,DRPAUSE {DREXIT2 DRUPDATE DRSELECT IRSELECT IRCAPTURE IRSHIFT}
        ir,IRPAUSE {IREXIT2 IRSHIFT}
    }
}

proc shim::configure {args} {
    variable logch
    foreach {k v} $args {
        switch -- $k {
            -log { set logch $v }
            default { error "shim::configure: unknown option $k" }
        }
    }
}

# Driver and the TAP's starting state (the driver's TAP must be there).
proc shim::set_driver {cmd {state RESET}} {
    variable drv
    variable st
    variable endst
    set drv $cmd
    set st $state
    set endst IDLE
}

proc shim::Log {msg} {
    variable logch
    variable n_calls
    incr n_calls
    if {$logch ne {}} {
        puts $logch $msg
    }
}

# TMS bits that walk <path> (states entered per TCK) from <from>.
proc shim::PathTms {from path} {
    set tms {}
    set s $from
    foreach n $path {
        if {$rbb::T($s,0) eq $n} {
            append tms 0
        } elseif {$rbb::T($s,1) eq $n} {
            append tms 1
        } else {
            error "shim: $s -> $n is not a TAP transition"
        }
        set s $n
    }
    return $tms
}

proc shim::Clock {tms tdi {from 0} {to 0}} {
    variable drv
    {*}$drv $tms $tdi $from $to
}

proc shim::RunState {target path} {
    variable st
    variable endst
    variable RUNSTATE
    if {$target ni {RESET IDLE DRPAUSE IRPAUSE}} {
        error "shim: run_state_hw_jtag: $target is not a stable state"
    }
    if {$path eq {}} {
        set path $RUNSTATE($st,$target)
    } elseif {[lindex $path end] ne $target} {
        error "shim: run_state_hw_jtag -state {$path} does not end in $target"
    }
    set tms [PathTms $st $path]
    if {$tms ne {}} {
        Clock $tms [string repeat 0 [string length $tms]]
    }
    set st $target
    set endst $target
}

# --- the back-end interface (rbb_core.tcl) ---

proc shim::be_reset {} {
    Log "reset (run_state_hw_jtag RESET)"
    RunState RESET {}
}

proc shim::be_goto {stable {path {}}} {
    variable st
    if {$path eq {}} {
        Log "goto $stable (run_state_hw_jtag $stable, from $st)"
    } else {
        Log "goto $stable -state {$path}"
    }
    RunState $stable $path
}

proc shim::be_idle {n} {
    variable st
    variable endst
    variable RUNSTATE
    Log "idle $n (runtest_hw_jtag -tck $n)"
    if {$st ne "IDLE"} {
        set tms [PathTms $st $RUNSTATE($st,IDLE)]
        Clock $tms [string repeat 0 [string length $tms]]
        set st IDLE
    }
    if {$n > 0} {
        Clock [string repeat 0 $n] [string repeat 0 $n]
    }
    set endst IDLE
}

proc shim::be_scan {type n bits end} {
    variable st
    variable endst
    variable ENTRY
    set u [string toupper $type]
    Log "scan $type $n end $end (from $st)"
    if {$end ne $endst} {
        error "shim: scan_${type}_hw_jtag would end in $endst, the bridge asked for $end"
    }
    if {$n < 1 || [string length $bits] != $n} {
        error "shim: scan_${type}_hw_jtag $n with [string length $bits] TDI bits"
    }
    if {$endst eq "${u}PAUSE"} {
        set exit ${u}PAUSE
    } elseif {$endst eq "IDLE"} {
        set exit [list ${u}UPDATE IDLE]
    } else {
        error "shim: scan_${type}_hw_jtag with end state $endst: not documented"
    }
    set entry $ENTRY($type,$st)
    set etms [PathTms $st $entry]
    set xtms [PathTms ${u}EXIT1 $exit]
    set ne [string length $etms]
    set tms $etms[string repeat 0 [expr {$n - 1}]]1$xtms
    set tdi [string repeat 0 $ne]$bits[string repeat 0 [string length $xtms]]
    set tdo [Clock $tms $tdi $ne [expr {$ne + $n}]]
    set st $endst
    return $tdo
}

# ---------------------------------------------------------------------------
# remote_bitbang client driver (the Verilator harness)

namespace eval shim {
    variable rbbch {}
}

proc shim::rbb_connect {host port} {
    variable rbbch
    set rbbch [socket $host $port]
    fconfigure $rbbch -translation binary -blocking 1 -buffering full
    fconfigure $rbbch -buffersize 1048576
    set_driver shim::RbbClock RESET
    # bring the TAP to Test-Logic-Reset whatever its state (TMS 1 x 6)
    RbbClock 111111 000000 0 0
}

proc shim::rbb_quit {} {
    variable rbbch
    if {$rbbch ne {}} {
        catch {puts -nonewline $rbbch Q; flush $rbbch}
        catch {close $rbbch}
        set rbbch {}
    }
}

# Bits [from, to) are sampled (R before their rising edge); the others not.
proc shim::RbbClock {tms tdi from to} {
    variable rbbch
    set s {}
    set n [string length $tms]
    for {set i 0} {$i < $n} {incr i} {
        set v [expr {2 * [string index $tms $i] + [string index $tdi $i]}]
        append s $v
        if {$i >= $from && $i < $to} { append s R }
        append s [expr {$v + 4}]
    }
    append s [expr {2 * [string index $tms end]}]
    # A command without TDO still waits for one 'R' (TDO outside Shift:
    # ignored): each command completes before the next, as in Vivado, and
    # no write waits for a delayed ACK (Tcl sockets have no TCP_NODELAY;
    # unanswered writes cost ~40 ms each through Nagle + delayed ACK).
    set want [expr {$to - $from}]
    set sync [expr {$want <= 0}]
    if {$sync} {
        append s R
        set want 1
    }
    puts -nonewline $rbbch $s
    flush $rbbch
    set r [read $rbbch $want]
    if {[string length $r] != $want} {
        error "shim: harness closed ([string length $r] of $want replies)"
    }
    if {$sync} {
        return {}
    }
    return $r
}

# ---------------------------------------------------------------------------
# main: the simulation bridge
#   tclsh shim_rbb_backend.tcl -target 127.0.0.1:<harness port> ?-port <p>?
#         ?-log <shim call log>? ?-exit_on_disconnect 0|1? ?-self_test 0|1?
#         ?-idcode_readahead 0|1? ?-split_test <n>?
# -split_test n (test knob): split every shift after n bits through the
# pause state, as a drain would (proves the splits on the real RTL).
# -port default $RBB_BRIDGE_PORT, else 33582 (in use: a free port, printed).

proc shim::main {argv} {
    variable logch
    set port 33582
    if {[info exists ::env(RBB_BRIDGE_PORT)]} { set port $::env(RBB_BRIDGE_PORT) }
    set target {}
    set logf {}
    set eod 1
    set selftest 1
    foreach {k v} $argv {
        switch -- $k {
            -target             { set target $v }
            -port               { set port $v }
            -log                { set logf $v }
            -exit_on_disconnect { set eod $v }
            -self_test          { set selftest $v }
            -idcode_readahead   { rbb::configure -idcode_readahead $v }
            -split_test         { rbb::configure -split_test $v }
            default             { puts stderr "shim: unknown option $k"; exit 2 }
        }
    }
    if {$target eq {}} {
        puts stderr "usage: tclsh shim_rbb_backend.tcl -target <host:port> ?-port p? ?-log f?"
        exit 2
    }
    if {$logf ne {}} {
        configure -log [open $logf w]
    }
    lassign [split $target :] host hport
    rbb_connect $host $hport
    puts "=== SHIM connected to the remote_bitbang server $host:$hport"
    flush stdout
    if {$selftest} {
        set r [rbb::self_test]
        if {![dict get $r ok]} {
            puts "=== SHIM SELF-TEST FAIL: [dict get $r msg]"
            rbb_quit
            exit 1
        }
        puts "=== SHIM SELF-TEST PASS: [dict get $r msg]"
        flush stdout
    }
    rbb::serve -port $port -exit_on_disconnect $eod
    rbb_quit
    if {$logch ne {}} {
        puts $logch "calls $shim::n_calls"
        close $logch
    }
    puts "=== SHIM done"
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    source [file join [file dirname [info script]] rbb_core.tcl]
    rbb::configure -backend ::shim
    shim::main $argv
}
