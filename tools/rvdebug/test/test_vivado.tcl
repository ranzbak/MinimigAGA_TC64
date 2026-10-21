# test_vivado.tcl -- vbe (the Vivado back end of rv_jtag_bridge.tcl) on the
# MEASURED Vivado 2023.2 behaviour (fake_vivado.tcl: scans end Exit1 ->
# Update -> IDLE; -state IDLE -> IRPAUSE refused), with the core and a
# reference TAP: self-test, OpenOCD sessions and the recorded session equal
# to the bit-level reference; teeth: the mapping before the fix fails as the
# board did; a split shift is reported.  Sourced by run_all.tcl.

if {[info commands rvb::bits_to_hex] eq {}} {
    set ::env(RVBRIDGE_NO_MAIN) 1
    source [file join $here .. rv_jtag_bridge.tcl]
}
source [file join $here fake_vivado.tcl]

# the vbe of 42f7cbb..cfa3be2 (passes every path to -state, assumes a scan
# ends in the pause state): what failed on the board
namespace eval vbe_old {}
proc vbe_old::be_reset {} { run_state_hw_jtag RESET }
proc vbe_old::be_goto {stable {path {}}} {
    if {$path eq {}} { run_state_hw_jtag $stable } else { run_state_hw_jtag -state $path $stable }
}
proc vbe_old::be_idle {n} { runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck $n }
proc vbe_old::be_scan {type n bits end} {
    return [rvb::hex_to_bits [scan_${type}_hw_jtag $n -tdi [rvb::bits_to_hex $bits]] $n]
}

proc viv_selftest {be} {
    reftap::new B 0x13631093
    shim::set_driver {reftap::drive B} RESET
    rbb::configure -backend $be -log {apply {{m} {}}}
    set r [rbb::self_test]
    rbb::configure -idcode {}
    return $r
}

test::case "vivado: raw self-test sequence on the measured semantics (IR capture xx01, IDCODE)" {
    reftap::new B 0x13631093
    shim::set_driver {reftap::drive B} RESET
    test::eq [rvb::raw_self_test] 1 "raw self-test"
}

test::case "vivado: bridge self-test through vbe passes (IDCODE, IR capture, BYPASS)" {
    set r [viv_selftest ::vbe]
    test::check {[dict get $r ok]} "self-test: [dict get $r msg]"
    puts "     [dict get $r msg]"
}

test::case "teeth: the old vbe fails the self-test on the measured semantics, as on the board" {
    set rc [catch {viv_selftest ::vbe_old} err]
    test::check {$rc} "old vbe passed"
    test::check {[string match *44-271* $err]} "old vbe failed differently: $err"
    puts "     caught: $err"
}

foreach kind {dmi tunnel} {
    lassign [oocd::session $kind] k stream flushes blocks
    test::case "vivado: OpenOCD $kind through vbe equals the reference (flush points, random, bytes)" [list apply {{kind stream flushes blocks} {
        set q [expr {$kind eq "tunnel" ? "tunnel" : {}}]
        foreach c [list $flushes random bytes] {
            set vbe::splits 0
            set r [equiv::run $stream $c -be ::vbe -quirk $q -timeout_p 0 \
                -blocks [expr {$c eq $flushes ? $blocks : {}}]]
            if {![dict get $r ok]} { error "[chunk_name $c]: [dict get $r why]" }
            test::eq $vbe::splits 0 "[chunk_name $c]: split shifts"
        }
        puts "     scans [dict get [dict get $r stats] scans], Vivado calls $fakeviv::calls"
    }} $kind $stream $flushes $blocks]
}

test::case "vivado: OpenOCD autoprobe with the IDCODE read-ahead through vbe (no split)" {
    lassign [oocd::session autoprobe] k stream flushes blocks
    set vbe::splits 0
    set r [equiv::run $stream $flushes -be ::vbe -ra 1 -quirk idreload -timeout_p 0 -blocks $blocks]
    if {![dict get $r ok]} { error [dict get $r why] }
    test::eq $vbe::splits 0 "split shifts"
}

test::case "vivado: recorded OpenOCD attach1 session through vbe (whole, random, bytes; read-ahead on)" {
    foreach c {whole random bytes} {
        set vbe::splits 0
        set r [equiv::run $recorded $c -be ::vbe -ra 1 -quirk idreload -timeout_p 0]
        if {![dict get $r ok]} { error "$c: [dict get $r why]" }
        test::eq $vbe::splits 0 "$c: split shifts"
    }
}

# OpenOCD's own continuation of a shift through Pause-xR (scan ... DRPAUSE,
# then the next scan from DRPAUSE) cannot be done on Vivado: reported
test::case "vivado: OpenOCD's continuation through Pause-xR (session pauses) is reported as a split" {
    lassign [oocd::session pauses] k stream flushes blocks
    set vbe::splits 0
    set r [equiv::run $stream $flushes -be ::vbe -timeout_p 0 -blocks $blocks]
    test::check {$vbe::splits > 0} "no split reported"
    puts "     $vbe::splits splits reported ([expr {[dict get $r ok] ? "replies equal" : [dict get $r why]}])"
}

# A stream that leaves Shift-xR and never reaches Update-xR (it stops in
# Exit1/Pause/Exit2, or TRST resets the TAP from there) differs on Vivado in
# the Update counters only: Vivado's scan has already done the Update.  The
# replies are compared for every stream.
test::case "vivado: 200 random streams through vbe, byte by byte, no timer" {
    set nsplit 0
    set nearly 0
    set column {DRSHIFT DREXIT1 DRPAUSE DREXIT2 IRSHIFT IREXIT1 IRPAUSE IREXIT2}
    for {set k 0} {$k < 200} {incr k} {
        set s [rnd::stream]
        set vbe::splits 0
        set r [equiv::run $s bytes -be ::vbe -timeout_p 0]
        if {$vbe::splits} { incr nsplit; continue }
        if {[dict get $r ok]} continue
        set why [dict get $r why]
        reftap::new A 0x13631093
        reftap::rbb A $s
        if {[string match "counters differ*" $why] && ($reftap::D(A,st) in $column || [regexp {[tu]} $s])} {
            incr nearly
            continue
        }
        error "stream $k: $why (reference ends in $reftap::D(A,st))"
    }
    puts "     $nsplit of 200 with a split shift (reported); $nearly with no Update-xR after the last shift (replies equal, Update counters differ as expected)"
}

test::case "vivado: a split shift (split knob) is reported by vbe" {
    lassign [oocd::session dmi] k stream flushes blocks
    set vbe::splits 0
    rbb::configure -split_test 5
    set r [equiv::run $stream whole -be ::vbe -timeout_p 0]
    rbb::configure -split_test 0
    test::check {$vbe::splits > 0} "no split reported"
    test::check {![dict get $r ok]} "a split shift on Vivado compared equal (the reference must differ)"
    puts "     $vbe::splits splits reported; reference: [dict get $r why]"
}
