# test_core.tcl -- unit tests of rbb_core.tcl, one group per behaviour of
# the brief (protocol bytes, TAP tracking, shifts and end states, mid-shift
# reads, TMS-only moves, self-test, TCP server).  Sourced by run_all.tcl.

# Recording back end: logs every call, then lets the shim (Vivado
# semantics) drive reference TAP B.
namespace eval rec {
    variable calls {}
}
proc rec::be_reset {} { variable calls; lappend calls reset; shim::be_reset }
proc rec::be_goto {s {p {}}} { variable calls; lappend calls [list goto $s $p]; shim::be_goto $s $p }
proc rec::be_idle {n} { variable calls; lappend calls [list idle $n]; shim::be_idle $n }
proc rec::be_scan {t n b e} {
    variable calls
    lappend calls [list scan $t $n $e]
    shim::be_scan $t $n $b $e
}

# fresh core on the recording back end, reference TAP B behind it
proc rec::open {{idcode 0x13631093}} {
    variable calls {}
    reftap::new B $idcode
    shim::set_driver {reftap::drive B} RESET
    rbb::configure -backend ::rec -log {apply {{m} {}}} -idcode {} -idcode_readahead 1
    rbb::conn_open
    set calls {}
}

# one TCK cycle the way OpenOCD writes it: low (TMS/TDI), [R], high
proc cyc {tms {tdi 0} {r 0}} {
    set v [expr {2 * $tms + $tdi}]
    return "$v[expr {$r ? "R" : ""}][expr {$v + 4}]"
}
proc cycs {tmsbits} {
    set s {}
    foreach t [split $tmsbits {}] { append s [cyc $t] }
    return $s
}

# ---------------------------------------------------------------------------
# 1. protocol bytes

test::case "bytes: 0..7 R r..u B b accepted, Q ends the stream" {
    rec::open
    test::eq [rbb::feed "01234567RrstuBbR"] ok "feed"
    rbb::drain close
    test::eq [string length [rbb::take_out]] 2 "two R answered"
    rec::open
    test::eq [rbb::feed "0R4Q0R4"] {quit 4} "Q at offset 4"
    rbb::drain close
    test::eq [rbb::take_out] 1 "only the R before Q answered"
    set s [rbb::stats]
    test::eq [dict get $s reads] 1 "reads counted"
    test::eq [dict get $s writes] 2 "pin writes counted"
}

test::case "bytes: any other byte is refused with its offset" {
    foreach {stream bad off} {"01X4" 0x58 2 "\x00" 0x00 0 "4567q" 0x71 4 "RR8" 0x38 2 "\xff" 0xff 0} {
        rec::open
        test::eq [rbb::feed $stream] [list bad $bad $off] "feed {$stream}"
    }
}

test::case "bytes: TRST ('t'/'u') resets the TAP and holds it, 'r'/'s' release; SRST ignored" {
    rec::open
    # to Shift-IR, load USER4, then IDLE
    rbb::feed [cycs 01100][rbb::bb_shift [rbb::int_to_bits 0x23 6] 0][cycs 10]
    test::eq $rbb::vs IDLE "in IDLE"
    test::check {$reftap::D(B,ir) == 0x23} "IR = USER4"
    set rec::calls {}
    rbb::feed "t[cycs 0000]"
    test::eq $rbb::vs RESET "TRST: Test-Logic-Reset"
    test::eq $rec::calls {reset} "one be_reset"
    rbb::feed "r[cycs 0]"
    test::eq $rbb::vs IDLE "released: TMS 0 -> IDLE"
    test::check {$reftap::D(B,ir) == 9} "IR = IDCODE after reset"
    rbb::feed "s"
    test::eq $rbb::vs IDLE "SRST does not touch the TAP"
}

# ---------------------------------------------------------------------------
# 2. TAP state from TMS on rising edges, all 16 states; R answers the TDO
#    the state presents before the next rising edge

test::case "TAP: all 16 states and 32 transitions (IEEE 1149.1 table)" {
    # (from tms to), typed from IEEE 1149.1 figure 6-1
    set ieee {
        RESET 0 IDLE  RESET 1 RESET  IDLE 0 IDLE  IDLE 1 DRSELECT
        DRSELECT 0 DRCAPTURE  DRSELECT 1 IRSELECT  DRCAPTURE 0 DRSHIFT  DRCAPTURE 1 DREXIT1
        DRSHIFT 0 DRSHIFT  DRSHIFT 1 DREXIT1  DREXIT1 0 DRPAUSE  DREXIT1 1 DRUPDATE
        DRPAUSE 0 DRPAUSE  DRPAUSE 1 DREXIT2  DREXIT2 0 DRSHIFT  DREXIT2 1 DRUPDATE
        DRUPDATE 0 IDLE  DRUPDATE 1 DRSELECT  IRSELECT 0 IRCAPTURE  IRSELECT 1 RESET
        IRCAPTURE 0 IRSHIFT  IRCAPTURE 1 IREXIT1  IRSHIFT 0 IRSHIFT  IRSHIFT 1 IREXIT1
        IREXIT1 0 IRPAUSE  IREXIT1 1 IRUPDATE  IRPAUSE 0 IRPAUSE  IRPAUSE 1 IREXIT2
        IREXIT2 0 IRSHIFT  IREXIT2 1 IRUPDATE  IRUPDATE 0 IDLE  IRUPDATE 1 DRSELECT
    }
    set seen {}
    foreach {from tms to} $ieee {
        rec::open
        # walk to <from> along the shortest path, then one edge
        set rnd::st RESET
        set p [rnd::PathTo $from]
        rbb::feed [cycs [join $p {}]]
        test::eq $rbb::vs $from "reached $from"
        rbb::feed [cyc $tms]
        test::eq $rbb::vs $to "$from --TMS $tms--> "
        rbb::drain close
        lappend seen $from
    }
    test::eq [llength [lsort -unique $seen]] 16 "states covered"
}

test::case "TAP: state changes only on the rising edge (TCK 0 -> 1)" {
    rec::open
    rbb::feed "2"
    test::eq $rbb::vs RESET "TCK low: no edge"
    rbb::feed "0"
    rbb::feed "4"
    test::eq $rbb::vs IDLE "rising edge with TMS 0"
    rbb::feed "6"
    test::eq $rbb::vs IDLE "TCK stays high: no edge"
    rbb::feed "26"
    test::eq $rbb::vs DRSELECT "next rising edge (TMS 1)"
}

test::case "TAP: R = TDO before the next rising edge (shift bits, '1' elsewhere)" {
    rec::open 0x13631093
    # RESET -> Shift-DR (IDCODE selected after reset); R in IDLE and Select
    set s "R[cyc 0 0 1][cyc 1 0 1][cyc 0 0 1][cyc 0]"
    # 32 bits, R before each edge; an extra R with TCK high after bit 0
    set id [rbb::int_to_bits 0x13631093 32]
    for {set i 0} {$i < 32} {incr i} {
        append s [cyc [expr {$i == 31}] 0 1]
        if {$i == 0} { append s R }
    }
    append s R
    rbb::feed $s
    rbb::drain now
    set r [rbb::take_out]
    # 4 R outside Shift-DR = 1111; then bit 0, bit 1 (TCK high after bit
    # 0's edge: the next bit), bits 1..31; then Exit1: 1
    set want 1111[string index $id 0][string range $id 1 31]1
    set want [string range $want 0 4][string index $id 1][string range $want 5 end]
    test::eq $r $want "replies"
}

# ---------------------------------------------------------------------------
# 3. shifts: one be_scan when TMS 1 ends the shift; end states

test::case "shift: one be_scan per shift, replies in order after it" {
    rec::open
    set bits [oocd::randbits 41]
    rbb::feed [cycs 0100]
    test::eq $rec::calls {{goto IDLE IDLE} {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}}} "RESET -> IDLE, capture -> goto DRPAUSE"
    set rec::calls {}
    set s [rbb::bb_shift $bits]
    # feed all but the last edge: no scan yet (no drain)
    rbb::feed [string range $s 0 end-2]
    test::eq $rec::calls {} "no scan before the end of the shift"
    test::eq [rbb::take_out] {} "no replies before the scan"
    rbb::feed [string range $s end-1 end]
    test::eq $rec::calls {{scan dr 41 DRPAUSE}} "one 41-bit scan when TMS 1 ends it"
    test::eq [string length [rbb::take_out]] 41 "41 replies"
}

proc mapping_case {name stream want_calls} {
    test::case "end-state mapping: $name" [list apply {{stream want_calls} {
        rec::open
        reftap::new A
        set ref [reftap::rbb A $stream]
        rbb::feed $stream
        rbb::drain close
        set got [rbb::take_out]
        test::eq $got $ref "replies"
        test::eq [dict remove [reftap::counters B] st] [dict remove [reftap::counters A] st] "Update/Capture/idle counts"
        test::eq $rec::calls [list {goto IDLE IDLE} {*}$want_calls] "back-end calls"
    }} $stream $want_calls]
}

# from RESET: Idle, Select-DR, Capture-DR, Shift-DR, then the path variants
set pre [cycs 0100]
set sh [rbb::bb_shift 1011]
mapping_case "Exit1 Update Idle (n clocks)" "$pre$sh[cycs 10000]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto IDLE {DREXIT2 DRUPDATE IDLE}} {idle 3}}
mapping_case "back to back DR: Exit1 Update Select-DR Capture-DR Shift-DR" "$pre$sh[cycs 1100]$sh[cycs 10]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto DRPAUSE {DREXIT2 DRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto IDLE {DREXIT2 DRUPDATE IDLE}}}
mapping_case "DR then IR: Update-DR Select-DR Select-IR Capture-IR" "$pre$sh[cycs 11100]$sh[cycs 10]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto IRPAUSE {DREXIT2 DRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}} {scan ir 4 IRPAUSE}
    {goto IDLE {IREXIT2 IRUPDATE IDLE}}}
mapping_case "OpenOCD continuation: Exit1 Pause Exit2 Shift (no capture)" "$pre$sh[cycs 0010]$sh[cycs 10]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE} {scan dr 4 DRPAUSE}
    {goto IDLE {DREXIT2 DRUPDATE IDLE}}}
mapping_case "capture without shift: Capture-DR Exit1 Update Idle" "[cycs 010]R[cycs 1100]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {goto IDLE {DREXIT2 DRUPDATE IDLE}} {idle 1}}
mapping_case "Capture-DR Exit1 Pause Exit2 Shift" "[cycs 01010010]$sh[cycs 10]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto IDLE {DREXIT2 DRUPDATE IDLE}}}
mapping_case "scan then Test-Logic-Reset from Pause-DR (autoprobe end)" "$pre$sh[cycs 01111111]" {
    {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE} reset}
mapping_case "Update-IR then Select-DR (no Idle) Capture-DR" "[cycs 01100][rbb::bb_shift 110001][cycs 1100]$sh[cycs 10]" {
    {goto IRPAUSE {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}} {scan ir 6 IRPAUSE}
    {goto DRPAUSE {IREXIT2 IRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}} {scan dr 4 DRPAUSE}
    {goto IDLE {DREXIT2 DRUPDATE IDLE}}}
unset pre sh

# ---------------------------------------------------------------------------
# 4. mid-shift reads

test::case "mid-shift: 704-bit autoprobe answered in 255-bit pieces (DRPAUSE splits)" {
    oocd::begin
    oocd::scan 0 [string repeat 1 704] 1 DRPAUSE
    oocd::tlr
    set s $oocd::s
    set blocks $oocd::blocks
    test::eq [llength $blocks] 3 "OpenOCD blocks 3 times (255, 255, 194)"
    rec::open
    set pos 0
    set got {}
    foreach b $blocks {
        lassign $b off nr
        rbb::feed [string range $s $pos [expr {$off - 1}]]
        set pos $off
        test::eq [rbb::drain now] done "drain at the block"
        append got [rbb::take_out]
        test::eq [string length $got] $nr "all R answered at the block"
    }
    rbb::feed [string range $s $pos end]
    rbb::drain close
    set st [rbb::stats]
    test::eq [dict get $st partial] 2 "two partial scans"
    test::eq [dict get $st max_scan] 255 "longest scan 255"
    test::eq [dict get $st max_shift] 704 "longest shift 704"
    set scans {}
    foreach c $rec::calls { if {[lindex $c 0] eq "scan"} { lappend scans [lindex $c 2] } }
    test::eq $scans {255 255 194} "scan lengths"
    # the reference TAP: IDCODE, then the ones shifted in
    reftap::new A
    test::eq $got [reftap::rbb A $s] "replies = reference"
    test::eq $reftap::D(B,capdr) 1 "one Capture-DR"
}

test::case "mid-shift: R before its rising edge -> wait; more input -> no split" {
    rec::open
    rbb::feed [cycs 0100]
    set s [rbb::bb_shift [oocd::randbits 20]]
    # cut after the 10th bit's low write and R (its high write missing)
    set cut [expr {9 * 3 + 2}]
    rbb::feed [string range $s 0 [expr {$cut - 1}]]
    test::eq [rbb::drain now] wait "drain waits"
    test::eq [rbb::held] redge "held for the missing edge"
    test::eq [rbb::take_out] {} "no reply yet"
    rbb::feed [string range $s $cut end]
    test::eq [rbb::drain now] done "done"
    test::eq [string length [rbb::take_out]] 20 "20 replies"
    test::eq [dict get [rbb::stats] partial] 0 "no partial scan"
}

test::case "mid-shift: R before its rising edge, 100 ms hold expires -> forced split before that bit" {
    rec::open
    reftap::new A
    set s [cycs 0100][rbb::bb_shift [oocd::randbits 20]][cycs 10]
    set ref [reftap::rbb A $s]
    # after the 10th bit's low write and R
    set cut [expr {[string length [cycs 0100]] + 9 * 3 + 2}]
    rbb::feed [string range $s 0 [expr {$cut - 1}]]
    test::eq [rbb::drain now] wait "drain waits"
    test::eq [rbb::hold_ms] 100 "the shift hold, not 2 ms (OpenOCD never waits there)"
    rbb::drain timeout
    set got [rbb::take_out]
    test::eq [dict get [rbb::stats] forced] 1 "counted as forced"
    test::eq [string length $got] 9 "9 replies; the 10th waits for its edge"
    test::eq [lindex $rec::calls end] {scan dr 9 DRPAUSE} "partial scan of 9 bits"
    test::eq [rbb::pending] 1 "one reply pending"
    rbb::feed [string range $s $cut end]
    rbb::drain now
    append got [rbb::take_out]
    test::eq $got $ref "replies = reference"
    test::eq [dict get [rbb::stats] partial] 1 "one partial scan"
}

test::case "drain: trailing Update held 2 ms, then finished through Run-Test/Idle" {
    rec::open
    rbb::feed [cycs 0100][rbb::bb_shift 1111 0][cycs 1]
    test::eq $rbb::vs DRUPDATE "in Update-DR"
    test::eq [rbb::drain now] wait "waits"
    test::eq [rbb::held] update "held for the Update"
    set rec::calls {}
    rbb::drain timeout
    test::eq $rec::calls {{goto IDLE {DREXIT2 DRUPDATE IDLE}}} "Update via IDLE"
    # the TAP then goes on from Update-DR: Select-DR, Capture-DR
    set rec::calls {}
    rbb::feed [cycs 10]
    test::eq $rec::calls {{goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}}} "capture from IDLE"
    test::eq $reftap::D(B,upddr) 1 "one Update-DR"
    test::eq $reftap::D(B,capdr) 2 "two Capture-DR"
}

test::case "drain: shift bits without pending R are not split" {
    rec::open
    rbb::feed [cycs 0100][string range [rbb::bb_shift [oocd::randbits 30] 0] 0 29]
    test::eq [rbb::drain now] done "done"
    test::eq [lsearch -index 0 $rec::calls scan] -1 "no scan"
    rbb::drain close
    test::eq [lindex $rec::calls end] {scan dr 15 DRPAUSE} "close flushes the 15 bits"
}

# ---------------------------------------------------------------------------
# 5. TMS-only moves

test::case "TMS: Test-Logic-Reset (>= 5 TMS 1) -> be_reset" {
    foreach {pre name} [list [cycs 0] IDLE [cycs 0101] DREXIT1 [cycs 01100] IRSHIFT [cycs 0100][rbb::bb_shift 101 0][cycs 0] DRPAUSE] {
        rec::open
        rbb::feed $pre
        set rec::calls {}
        rbb::feed [cycs 11111]
        test::eq $rbb::vs RESET "from $name"
        test::eq [lindex $rec::calls end] reset "be_reset from $name"
        test::eq [llength [lsearch -all $rec::calls reset]] 1 "one reset"
    }
}

test::case "TMS: Run-Test/Idle with n rising edges -> be_idle n (split at drains)" {
    rec::open
    rbb::feed [cycs 0]
    test::eq $rec::calls {{goto IDLE IDLE}} "RESET -> IDLE"
    set rec::calls {}
    rbb::feed [cycs 0000000]
    test::eq [rbb::drain now] done "drain"
    rbb::feed [cycs 000]
    rbb::feed [cycs 1]
    test::eq $rec::calls {{idle 7} {idle 3}} "7 + 3 clocks"
    test::eq $reftap::D(B,idleclk) 10 "reference TAP: 10 idle clocks"
}

test::case "TMS: other paths to stable states -> be_goto" {
    rec::open
    rbb::feed [cycs 01010]
    test::eq $rbb::vs DRPAUSE "virtual Pause-DR"
    test::eq $rec::calls {{goto IDLE IDLE} {goto DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}}} "be_goto IDLE, DRPAUSE"
    set rec::calls {}
    rbb::feed [cycs 110]
    test::eq $rec::calls {{goto IDLE {DREXIT2 DRUPDATE IDLE}}} "Pause-DR -> IDLE"
    set rec::calls {}
    rbb::feed [cycs 11011]
    test::eq $rec::calls {{goto IRPAUSE {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}}} "IDLE -> Pause-IR"
    test::eq $reftap::D(B,st) IRPAUSE "the back end's TAP in IRPAUSE"
    test::eq $rbb::vs IRUPDATE "virtual in Update-IR"
}

# ---------------------------------------------------------------------------
# self-test through the core

test::case "self-test: XC7A100T IDCODE (any version), IR capture xx01, BYPASS" {
    foreach {idc ok} {0x03631093 1 0x13631093 1 0xF3631093 1 0x03631092 0 0x03632093 0} {
        rec::open $idc
        set r [rbb::self_test]
        test::eq [dict get $r ok] $ok "IDCODE $idc: [dict get $r msg]"
    }
    set reftap::IRCAP 0x12
    rec::open
    set r [rbb::self_test]
    set reftap::IRCAP 0x11
    test::eq [dict get $r ok] 0 "IR capture 0x12 refused: [dict get $r msg]"
    set reftap::IRCAP 0x3D
    rec::open
    set r [rbb::self_test]
    set reftap::IRCAP 0x11
    test::eq [dict get $r ok] 1 "IR capture 0x3D accepted (only the 01 LSBs are checked)"
}

# ---------------------------------------------------------------------------
# TCP server: real socket, binary, 2 ms timer, Q / unknown byte close

proc tcp_session {stream {split {}}} {
    set ::tcp(got) {}
    set ::tcp(log) {}
    set ::tcp(stream) $stream
    set ::tcp(split) [lindex $split 0]
    set ::tcp(delay) [lindex $split 1]
    rbb::configure -backend ::rec -log tcp_log -idcode {}
    reftap::new B
    shim::set_driver {reftap::drive B} RESET
    set ::tcp(eof) 0
    rbb::serve -port 0 -exit_on_disconnect 1
    if {!$::tcp(eof)} { vwait ::tcp(eof) }
    return $::tcp(got)
}
proc tcp_log {m} {
    lappend ::tcp(log) $m
    if {[regexp {listening 127\.0\.0\.1:(\d+)} $m -> p]} {
        after 0 [list tcp_client $p]
    }
}
proc tcp_client {p} {
    set c [socket 127.0.0.1 $p]
    fconfigure $c -translation binary -blocking 0 -buffering none
    set ::tcp(c) $c
    fileevent $c readable [list tcp_read $c]
    set s $::tcp(stream)
    if {$::tcp(split) eq {}} {
        puts -nonewline $c $s
    } else {
        # first part now, the rest after tcp(delay) ms
        puts -nonewline $c [string range $s 0 [expr {$::tcp(split) - 1}]]
        after $::tcp(delay) [list catch [list puts -nonewline $c [string range $s $::tcp(split) end]]]
    }
}
proc tcp_read {c} {
    set d [read $c]
    append ::tcp(got) $d
    if {[eof $c]} { close $c; set ::tcp(eof) 1 }
}

test::case "tcp: replies over a socket, Q closes; an R before its edge: 30 ms gap held, 150 ms gap split and logged" {
    reftap::new A
    set s [cycs 0100][rbb::bb_shift [oocd::randbits 20]][cycs 10]Q
    set ref [reftap::rbb A $s]
    set cut [expr {[string length [cycs 0100]] + 9 * 3 + 2}]
    set got [tcp_session $s [list $cut 30]]
    test::eq $got $ref "replies (30 ms gap)"
    set closed [lsearch -inline $::tcp(log) "*closed (Q)*"]
    test::check {$closed ne {}} "closed on Q: $::tcp(log)"
    test::check {[string match "*partial 0, forced by a timer 0,*" $closed]} "30 ms: held, not split: $closed"
    set got [tcp_session $s [list $cut 150]]
    test::eq $got $ref "replies (150 ms gap)"
    set closed [lsearch -inline $::tcp(log) "*closed (Q)*"]
    test::check {[string match "*partial 1, forced by a timer 1,*" $closed]} "150 ms: one forced split: $closed"
    test::check {[lsearch $::tcp(log) "*WARNING: DR shift split after a 100 ms hold*"] >= 0} "logged: $::tcp(log)"
}

test::case "tcp: an unknown byte closes the connection with an error line" {
    set got [tcp_session "0R4R0x4R"]
    test::eq $got 11 "the two R before the bad byte answered"
    test::check {[lsearch $::tcp(log) "*unknown byte 0x78 at offset 5*"] >= 0} "logged: $::tcp(log)"
    test::check {[lsearch $::tcp(log) "*closed (unknown byte 0x78)*"] >= 0} "closed: $::tcp(log)"
}
