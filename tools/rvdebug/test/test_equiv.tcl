# test_equiv.tcl -- unit equivalence: the reference TAP answering a byte
# stream bit by bit (reftap A) against the bridge core + shim (Vivado
# semantics) + a second reference TAP driven scan-wise (reftap B).  The
# replies must be identical byte for byte, and the Capture/Update/
# Test-Logic-Reset/Run-Test-Idle counts, the IR and the USER4 register of
# both TAPs equal.  Sourced by run_all.tcl.

proc equiv_case {name stream chunking args} {
    set r [equiv::run $stream $chunking {*}$args]
    if {![dict get $r ok]} {
        error "$name ([chunk_name $chunking]): [dict get $r why]"
    }
    return $r
}

proc chunk_name {c} {
    if {$c in {whole bytes random}} { return $c }
    return "OpenOCD flush points ([llength $c])"
}

# ---------------------------------------------------------------------------
# OpenOCD-shaped streams

foreach kind {autoprobe dmi pauses} {
    lassign [oocd::session $kind] k stream flushes blocks
    test::case "equiv: OpenOCD $kind ([string length $stream] bytes, [llength $blocks] blocking reads)" [list apply {{stream flushes blocks} {
        # OpenOCD's own flush points, with the block check (every R answered
        # at each blocking read, no timer)
        foreach ra {0 1} {
            set r [equiv_case openocd $stream $flushes -blocks $blocks -ra $ra]
            set s [dict get $r stats]
            puts "     read-ahead $ra: scans [dict get $s scans], partial [dict get $s partial],\
                longest scan [dict get $s max_scan], longest shift [dict get $s max_shift],\
                replies [dict get $r replies] (read ahead [dict get $s readahead])"
            foreach c {whole random bytes} {
                equiv_case openocd $stream $c -ra $ra
            }
        }
    }} $stream $flushes $blocks]
}

# ---------------------------------------------------------------------------
# recorded OpenOCD session (sim/rv_dbg attach1, +rbblog: OpenOCD 0.12's real
# byte stream through minimig-rv-bscan.cfg: init, autoprobe, IR capture,
# BSCANE2 tunnel DMI traffic, halt, resume, shutdown)

set fx [file join $here fixtures attach1.rbb.in]
set fh [open $fx rb]
set recorded [read $fh]
close $fh
test::case "equiv: recorded OpenOCD attach1 session ([string length $recorded] bytes)" {
    set r [equiv_case recorded $recorded whole]
    set s [dict get $r stats]
    puts "     whole: scans [dict get $s scans], partial [dict get $s partial],\
        longest scan [dict get $s max_scan], longest shift [dict get $s max_shift], replies [dict get $r replies]"
    foreach ra {0 1} {
        for {set k 0} {$k < 3} {incr k} {
            equiv_case recorded $recorded random -ra $ra
        }
        set r [equiv_case recorded $recorded bytes -ra $ra]
        set s [dict get $r stats]
        puts "     byte by byte, read-ahead $ra: scans [dict get $s scans], partial [dict get $s partial],\
            read ahead [dict get $s readahead]"
    }
}

# ---------------------------------------------------------------------------
# random legal streams

set nrand 1000
if {[info exists env(RANDOM_STREAMS)]} { set nrand $env(RANDOM_STREAMS) }
test::case "equiv: $nrand random streams, each in random 1..300-byte chunks and byte by byte (read-ahead off), byte by byte (on)" {
    set bytes 0
    set nscan 0
    set npart 0
    set maxs 0
    for {set k 0} {$k < $nrand} {incr k} {
        set s [rnd::stream]
        incr bytes [string length $s]
        foreach {c ra} {random 0 bytes 0 bytes 1} {
            set r [equiv::run $s $c -ra $ra]
            if {![dict get $r ok]} {
                set f [file join [pwd] failing_stream.rbb]
                set fh [open $f wb]
                puts -nonewline $fh $s
                close $fh
                error "stream $k ($c, [string length $s] bytes, saved to $f): [dict get $r why]"
            }
            set st [dict get $r stats]
            incr nscan [dict get $st scans]
            incr npart [dict get $st partial]
            if {[dict get $st max_shift] > $maxs} { set maxs [dict get $st max_shift] }
        }
    }
    puts "     $bytes bytes in all; scans $nscan, partial $npart, longest shift $maxs"
}

# ---------------------------------------------------------------------------
# teeth: the checks above catch a wrong bridge

# a back end that maps Update + Capture from Pause-DR to Pause-DR onto
# nothing (the naive "stay in DRPAUSE" mapping of back-to-back scans)
namespace eval naive {}
proc naive::be_reset {} { shim::be_reset }
proc naive::be_idle {n} { shim::be_idle $n }
proc naive::be_scan {t n b e} { shim::be_scan $t $n $b $e }
proc naive::be_goto {s {p {}}} {
    if {$s eq "DRPAUSE" && $shim::st eq "DRPAUSE"} return
    shim::be_goto $s $p
}

# a back end whose TDO comes back in reverse order (an LSB/MSB mix-up)
namespace eval reversed {}
proc reversed::be_reset {} { shim::be_reset }
proc reversed::be_idle {n} { shim::be_idle $n }
proc reversed::be_goto {s {p {}}} { shim::be_goto $s $p }
proc reversed::be_scan {t n b e} { string reverse [shim::be_scan $t $n $b $e] }

test::case "teeth: naive back-to-back mapping (no Update/Capture) is caught" {
    # IR = USER4, then two DR scans back to back through Update -> Select-DR
    set s [cycs 01100][rbb::bb_shift 110001][cycs 1100]
    append s [rbb::bb_shift [oocd::randbits 48]][cycs 1100][rbb::bb_shift [oocd::randbits 48]][cycs 10]
    set r [equiv::run $s whole -be ::naive]
    test::check {![dict get $r ok]} "naive mapping not caught"
    puts "     caught: [dict get $r why]"
}

test::case "teeth: reversed TDO bit order is caught" {
    lassign [oocd::session dmi] k stream flushes blocks
    set r [equiv::run $stream whole -be ::reversed]
    test::check {![dict get $r ok]} "reversed TDO not caught"
    puts "     caught: [dict get $r why]"
}

test::case "teeth: a drain that never splits a shift deadlocks OpenOCD's autoprobe (caught)" {
    lassign [oocd::session autoprobe] k stream flushes blocks
    rename rbb::drain rbb::drain_real
    proc rbb::drain {mode} {
        # broken: never scans before the shift has ended
        set sb $rbb::sh_bits
        set rbb::sh_bits {}
        set r [rbb::drain_real $mode]
        append rbb::sh_bits $sb
        return $r
    }
    set r [catch {equiv::run $stream $flushes -blocks $blocks} res]
    rename rbb::drain {}
    rename rbb::drain_real rbb::drain
    test::check {$r == 0 && ![dict get $res ok]} "not caught: $res"
    puts "     caught: [dict get $res why]"
}

# ---------------------------------------------------------------------------
# IDCODE read-ahead (the finding of bridge_sim: Vivado's JTAG_SIME2 reloads
# the IDCODE register outside Shift-DR, so a DRPAUSE split of OpenOCD's
# autoprobe reads the IDCODE again)

test::case "read-ahead: autoprobe on a JTAG_SIME2-like TAP: split -> wrong, read-ahead -> right" {
    lassign [oocd::session autoprobe] k stream flushes blocks
    set r [equiv::run $stream $flushes -blocks $blocks -quirk idreload -ra 0]
    test::check {![dict get $r ok]} "splitting the autoprobe was expected to read the IDCODE again"
    puts "     without read-ahead: [dict get $r why]"
    set r [equiv::run $stream $flushes -blocks $blocks -quirk idreload -ra 1]
    if {![dict get $r ok]} { error "with read-ahead: [dict get $r why]" }
    set s [dict get $r stats]
    puts "     with read-ahead: scans [dict get $s scans], partial [dict get $s partial],\
        read ahead [dict get $s readahead], longest scan [dict get $s max_scan]"
    test::eq [dict get $s readahead_bad] 0 "read-ahead confirmed by the scan"
    test::check {[dict get $s readahead] >= 510} "the blocked reads answered ahead"
}

test::case "read-ahead: the recorded session on a JTAG_SIME2-like TAP, byte by byte" {
    set r [equiv::run $recorded bytes -quirk idreload -ra 1]
    if {![dict get $r ok]} { error [dict get $r why] }
    test::eq [dict get [dict get $r stats] readahead_bad] 0 "no contradiction"
}

test::case "read-ahead: IR = IDCODE (0x09) loaded explicitly, JTAG_SIME2-like TAP, byte by byte" {
    # IR scan of 0x09, DR scan of 100 bits, IR BYPASS, DR scan (split, no read-ahead)
    set s [cycs 01100][rbb::bb_shift 100100][cycs 1100][rbb::bb_shift [oocd::randbits 100]][cycs 10]
    append s [cycs 1100][rbb::bb_shift 111111][cycs 1100][rbb::bb_shift [oocd::randbits 50]][cycs 10]
    set r [equiv::run $s bytes -quirk idreload -ra 0]
    test::check {![dict get $r ok]} "without read-ahead the split should read the IDCODE again"
    set r [equiv::run $s bytes -quirk idreload -ra 1]
    if {![dict get $r ok]} { error [dict get $r why] }
    set st [dict get $r stats]
    test::eq [dict get $st readahead] 100 "100 reads answered ahead"
    test::check {[dict get $st partial] > 0} "the BYPASS scan split"
}

test::case "read-ahead: a wrong known IDCODE is caught by the scan check" {
    lassign [oocd::session autoprobe] k stream flushes blocks
    set r [equiv::run $stream $flushes -blocks $blocks -ra 1 -idcode 0x13631193]
    test::check {![dict get $r ok]} "replies should differ"
    test::check {[dict get [dict get $r stats] readahead_bad] > 0} "the scan check should report it"
}

test::case "read-ahead: off after an Update-IR (IR no longer IDCODE)" {
    rec::open
    rbb::configure -idcode 0x13631093 -idcode_readahead 1
    # IR BYPASS, then a DR scan with a drain in the middle: split, no read-ahead
    rbb::feed [cycs 01100][rbb::bb_shift 111111 0][cycs 1100]
    set s [rbb::bb_shift [oocd::randbits 40]]
    rbb::feed [string range $s 0 59]
    test::eq [rbb::drain now] wait "hold (not OpenOCD's 255th read)"
    rbb::drain timeout
    test::eq [dict get [rbb::stats] readahead] 0 "no read-ahead"
    test::eq [dict get [rbb::stats] partial] 1 "split instead"
    rbb::configure -idcode {}
}

test::case "split knob: every shift split after 1..9 bits, 100 random streams + OpenOCD dmi" {
    set np 0
    lassign [oocd::session dmi] k stream flushes blocks
    for {set k 0} {$k < 101} {incr k} {
        if {$k < 100} { set s [rnd::stream] } else { set s $stream }
        rbb::configure -split_test [expr {1 + $k % 9}]
        set r [equiv::run $s random -ra [expr {$k % 2}]]
        rbb::configure -split_test 0
        if {![dict get $r ok]} { error "stream $k: [dict get $r why]" }
        incr np [dict get [dict get $r stats] partial]
    }
    puts "     $np partial scans"
}

# ---------------------------------------------------------------------------
# the BSCANE2 tunnel is not pause-transparent (found with bridge_sim and
# BRIDGE_SPLIT): the bridge splits a shift only when OpenOCD waits

test::case "tunnel: OpenOCD's 53-bit tunnel scans are never split (flush points, random chunks, bytes)" {
    lassign [oocd::session tunnel] k stream flushes blocks
    foreach c [list $flushes random bytes] {
        set r [equiv::run $stream $c -blocks [expr {$c eq $flushes ? $blocks : {}}] -quirk tunnel -timeout_p 0]
        if {![dict get $r ok]} { error "[chunk_name $c]: [dict get $r why]" }
        test::eq [dict get [dict get $r stats] partial] 0 "[chunk_name $c]: no partial scan"
    }
    set r [equiv::run $recorded bytes -quirk idreload -ra 1 -timeout_p 0]
    if {![dict get $r ok]} { error "recorded, byte by byte: [dict get $r why]" }
    test::eq [dict get [dict get $r stats] partial] 0 "recorded session byte by byte: no partial scan"
}

test::case "tunnel: a split USER4 scan is caught (teeth of the hold rule)" {
    lassign [oocd::session tunnel] k stream flushes blocks
    rbb::configure -split_test 7
    set r [equiv::run $stream $flushes -blocks $blocks -quirk tunnel -timeout_p 0]
    rbb::configure -split_test 0
    test::check {![dict get $r ok]} "split tunnel scans should differ"
    puts "     caught: [dict get $r why]"
    set r [equiv::run $stream bytes -quirk tunnel -timeout_p 1]
    test::check {![dict get $r ok]} "byte by byte with every hold expiring should differ"
    puts "     caught (hold expired at every byte): [dict get $r why]"
}

test::case "hold: fewer than 255 reads owed inside a shift -> wait 100 ms, then split" {
    rec::open
    rbb::feed [cycs 0100]
    set s [rbb::bb_shift [oocd::randbits 600]]
    # 100 complete bits
    rbb::feed [string range $s 0 299]
    test::eq [rbb::drain now] wait "held"
    test::eq [rbb::held] shift "held for the shift"
    test::eq [rbb::hold_ms] 100 "100 ms"
    test::eq [rbb::take_out] {} "no reply"
    rbb::drain timeout
    test::eq [string length [rbb::take_out]] 100 "split after the hold: 100 replies"
    # the 255th R of the scan (OpenOCD blocks): split at once
    rbb::feed [string range $s 300 [expr {255 * 3 - 1}]]
    test::eq [rbb::drain now] done "255th R of the scan: no hold"
    test::eq [string length [rbb::take_out]] 155 "the 155 owed replies"
}
