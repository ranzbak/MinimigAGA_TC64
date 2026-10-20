# testlib.tcl -- shared pieces of the bridge unit tests (tclsh 8.6)
#
#   test::case <name> <body>   one test; an error or a failed check fails it
#   test::check <cond> <msg>   a check inside a test
#   reftap::*                  bit-level reference TAP (IEEE 1149.1, IR 6,
#                              IDCODE, BYPASS, 48-bit USER4 with a capture
#                              value that depends on every Update and Capture)
#   oocd::*                    OpenOCD 0.12 bitbang.c / remote_bitbang.c byte
#                              streams, with OpenOCD's flush and block points
#   rnd::stream                random legal remote_bitbang streams
#   equiv::run                 reference TAP vs. bridge core + shim + reference TAP

set here [file dirname [file normalize [info script]]]
source [file join $here .. rbb_core.tcl]
source [file join $here .. shim_rbb_backend.tcl]

namespace eval test {
    variable pass 0
    variable fail 0
    variable failed {}
    variable verbose 0
}

proc test::case {name body} {
    variable pass
    variable fail
    variable failed
    set t0 [clock milliseconds]
    if {[catch {uplevel 1 $body} err opts]} {
        incr fail
        lappend failed $name
        puts "FAIL $name: $err"
        if {[info exists ::env(TEST_TRACE)]} { puts [dict get $opts -errorinfo] }
    } else {
        incr pass
        puts "ok   $name ([expr {[clock milliseconds] - $t0}] ms)"
    }
    flush stdout
}

proc test::check {cond msg} {
    if {![uplevel 1 [list expr $cond]]} {
        error "check failed: $msg"
    }
}

proc test::eq {got want msg} {
    if {$got ne $want} {
        error "$msg: got '$got', expected '$want'"
    }
}

# ---------------------------------------------------------------------------
# reference TAP

namespace eval reftap {
    variable D
    variable IRCAP 0x11
    variable USER4 0x23
    variable IDC 0x09
    variable K 0xA5C30F965A3C
    variable M48 0xFFFFFFFFFFFF
}

# quirks (a list; {} = IEEE 1149.1):
#   idreload  the IDCODE register reloads on every rising edge outside
#             Shift-DR while IR = IDCODE (Vivado's JTAG_SIME2, xc7_tap.v)
#   tunnel    USER4 is 41 bits (the DMI register) and shifts in TDI delayed
#             by 9 rising edges through a free-running delay line
#             (VexRiscv's JtagTunnel in VexOsd_DMT.v:
#             io_instruction_tdi_delay_1..8, tap_tdiBuffer): extra TCKs
#             inside a shift corrupt it, before the shift they do not (the
#             first 9 bits shifted are pushed out by a scan >= 50 bits)
proc reftap::new {id {idcode 0x13631093} {quirks {}}} {
    variable D
    array unset D $id,*
    array set D [list $id,st RESET $id,ir 9 $id,dr {} $id,irsh {} $id,user4 0 \
        $id,quirk [expr {"idreload" in $quirks}] $id,tunnel [expr {"tunnel" in $quirks}] \
        $id,dl 000000000 $id,u4len [expr {"tunnel" in $quirks ? 41 : 48}] \
        $id,ncap4 0 $id,idcode $idcode $id,tck 0 $id,trst 0 \
        $id,capdr 0 $id,capir 0 $id,upddr 0 $id,updir 0 $id,resets 0 $id,idleclk 0]
}

proc reftap::counters {id} {
    variable D
    set r {}
    foreach k {capdr capir upddr updir resets idleclk ir user4 st} {
        lappend r $k $D($id,$k)
    }
    return $r
}

proc reftap::tdo {id} {
    variable D
    switch -- $D($id,st) {
        DRSHIFT { return [string index $D($id,dr) 0] }
        IRSHIFT { return [string index $D($id,irsh) 0] }
        default { return 1 }
    }
}

# one rising TCK edge
proc reftap::edge {id tms tdi} {
    variable D
    variable IRCAP
    variable USER4
    variable IDC
    variable K
    variable M48
    set s $D($id,st)
    if {$D($id,tunnel)} {
        # free-running 9-edge TDI delay (every rising edge)
        set tdl [string index $D($id,dl) 0]
        set D($id,dl) [string range $D($id,dl) 1 end]$tdi
        if {$D($id,ir) == $USER4} { set tdi $tdl }
    }
    if {$s eq "DRSHIFT"} {
        set D($id,dr) [string range $D($id,dr) 1 end]$tdi
    } elseif {$D($id,quirk) && $D($id,ir) == $IDC} {
        set D($id,dr) [rbb::int_to_bits $D($id,idcode) 32]
    }
    if {$s eq "IRSHIFT"} {
        set D($id,irsh) [string range $D($id,irsh) 1 end]$tdi
    }
    set n $rbb::T($s,$tms)
    if {$n eq $s} {
        if {$s eq "IDLE"} { incr D($id,idleclk) }
        return
    }
    set D($id,st) $n
    switch -- $n {
        RESET {
            incr D($id,resets)
            set D($id,ir) [expr {$IDC}]
        }
        DRCAPTURE {
            incr D($id,capdr)
            set ir $D($id,ir)
            if {$ir == $IDC} {
                set D($id,dr) [rbb::int_to_bits $D($id,idcode) 32]
            } elseif {$ir == $USER4} {
                incr D($id,ncap4)
                set v [expr {(($D($id,user4) ^ $K) + $D($id,ncap4) * 0x10203) & $M48}]
                set D($id,dr) [rbb::int_to_bits $v $D($id,u4len)]
            } else {
                set D($id,dr) 0
            }
        }
        IRCAPTURE {
            incr D($id,capir)
            set D($id,irsh) [rbb::int_to_bits $IRCAP 6]
        }
        DRUPDATE {
            incr D($id,upddr)
            if {$D($id,ir) == $USER4} {
                set D($id,user4) [rbb::bits_to_int $D($id,dr)]
            }
        }
        IRUPDATE {
            incr D($id,updir)
            set D($id,ir) [rbb::bits_to_int $D($id,irsh)]
        }
    }
}

# remote_bitbang bytes -> the replies, bit-level (the reference)
proc reftap::rbb {id data} {
    variable D
    set out {}
    foreach c [split $data {}] {
        switch -- $c {
            0 - 1 - 2 - 3 { set D($id,tck) 0 }
            4 - 5 - 6 - 7 {
                set v [expr {$c - 4}]
                if {!$D($id,tck) && !$D($id,trst)} {
                    edge $id [expr {$v >> 1}] [expr {$v & 1}]
                }
                set D($id,tck) 1
            }
            R { append out [tdo $id] }
            r - s { set D($id,trst) 0 }
            t - u {
                if {$D($id,st) ne "RESET"} {
                    set D($id,st) RESET
                    incr D($id,resets)
                }
                set D($id,ir) [expr {$reftap::IDC}]
                set D($id,trst) 1
            }
            B - b {}
            Q { break }
            default { error "reftap: byte '$c'" }
        }
    }
    return $out
}

# pin driver for the shim: bits [from, to) sampled before their edge
proc reftap::drive {id tms tdi from to} {
    set r {}
    set n [string length $tms]
    for {set i 0} {$i < $n} {incr i} {
        if {$i >= $from && $i < $to} { append r [tdo $id] }
        edge $id [string index $tms $i] [string index $tdi $i]
    }
    return $r
}

# ---------------------------------------------------------------------------
# OpenOCD 0.12 streams (bitbang.c + remote_bitbang.c, jtag/interface.c
# short_tms_seqs): the bytes, the points where OpenOCD flushes its 512-byte
# send buffer, and the points where it blocks for replies (with the number
# of 'R' sent by then).

namespace eval oocd {
    variable s {}
    variable used 0
    variable flushes {}
    variable blocks {}
    variable nR 0
    variable state RESET
    variable endst RESET
    variable IDX {RESET 0 IDLE 1 DRSHIFT 2 DRPAUSE 3 IRSHIFT 4 IRPAUSE 5}
    # short_tms_seqs[from][to] = {binary literal, bits}; bit i (LSB first) = TMS i
    variable TBL {
        {{1111111 7} {0000000 7} {0010111 7} {0001010 7} {0011011 7} {0010110 7}}
        {{1111111 7} {0000000 7} {001 3}     {0101 4}    {0011 4}    {01011 5}}
        {{1111111 7} {011 3}     {00111 5}   {01 2}      {001111 6}  {0101111 7}}
        {{1111111 7} {011 3}     {01 2}      {0 1}       {001111 6}  {0101111 7}}
        {{1111111 7} {011 3}     {00111 5}   {010111 6}  {001111 6}  {01 2}}
        {{1111111 7} {011 3}     {00111 5}   {010111 6}  {01 2}      {0 1}}
    }
}

proc oocd::begin {} {
    variable s {}
    variable used 0
    variable flushes {}
    variable blocks {}
    variable nR 0
    variable state RESET
    variable endst RESET
}

proc oocd::Put {c} {
    variable s
    variable used
    variable nR
    append s $c
    if {$c eq "R"} { incr nR }
    if {[incr used] >= 512} { Flush }
}

proc oocd::Flush {} {
    variable s
    variable used
    variable flushes
    set used 0
    if {[lindex $flushes end] != [string length $s]} {
        lappend flushes [string length $s]
    }
}

proc oocd::Block {} {
    variable s
    variable blocks
    variable nR
    Flush
    lappend blocks [list [string length $s] $nR]
}

proc oocd::write {tck tms tdi} {
    Put [expr {4 * $tck + 2 * $tms + $tdi}]
}

proc oocd::Path {from to} {
    variable IDX
    variable TBL
    # the literal is written MSB first; OpenOCD clocks bit 0 first
    lassign [lindex $TBL [dict get $IDX $from] [dict get $IDX $to]] lit n
    if {[string length $lit] != $n} { error "oocd: table entry $lit/$n" }
    return [string reverse $lit]
}

proc oocd::state_move {skip} {
    variable state
    variable endst
    set p [Path $state $endst]
    set tms 0
    for {set i $skip} {$i < [string length $p]} {incr i} {
        set tms [string index $p $i]
        write 0 $tms 0
        write 1 $tms 0
    }
    write 0 $tms 0
    set state $endst
}

proc oocd::queue_begin {} { Put B; Flush }
proc oocd::queue_end {} { Put b; Flush }
proc oocd::reset {trst srst} { Put [format %c [expr {114 + 2 * $trst + $srst}]]; Flush }
proc oocd::quit {} { Put Q; Flush }

proc oocd::tlr {} {
    variable endst RESET
    state_move 0
}

proc oocd::runtest {n end} {
    variable state
    variable endst
    if {$state ne "IDLE"} {
        set endst IDLE
        state_move 0
    }
    for {set i 0} {$i < $n} {incr i} {
        write 0 0 0
        write 1 0 0
    }
    write 0 0 0
    set endst $end
    if {$state ne $endst} { state_move 0 }
}

# bitbang_scan: <bits> TDI (index 0 first), read = 'R' per bit, buf_size 255
proc oocd::scan {ir bits read end} {
    variable state
    variable endst
    set sh [expr {$ir ? "IRSHIFT" : "DRSHIFT"}]
    if {$state ne $sh} {
        set endst $sh
        state_move 0
    }
    set endst $end
    set n [string length $bits]
    set buffered 0
    for {set i 0} {$i < $n} {incr i} {
        set tms [expr {$i == $n - 1}]
        set tdi [string index $bits $i]
        write 0 $tms $tdi
        if {$read} {
            Put R
            incr buffered
        }
        write 1 $tms $tdi
        if {$read && ($buffered == 255 || $i == $n - 1)} {
            Block
            set buffered 0
        }
    }
    if {$state ne $endst} { state_move 1 }
}

proc oocd::randbits {n} {
    set b {}
    for {set i 0} {$i < $n} {incr i} { append b [expr {int(rand() * 2)}] }
    return $b
}

# OpenOCD-shaped sessions; each returns {name bytes flushes blocks}
proc oocd::session {kind} {
    begin
    reset 0 0
    queue_begin; tlr; queue_end
    switch -- $kind {
        autoprobe {
            # jtag_examine_chain: 21 x 32 bits of ones, end DRPAUSE, then TLR
            queue_begin
            scan 0 [string repeat 1 704] 1 DRPAUSE
            tlr
            queue_end
            # IR capture check, 6 + JTAG_IRLEN_MAX... bits of ones, end IDLE
            queue_begin
            scan 1 [string repeat 1 70] 1 IDLE
            queue_end
        }
        dmi {
            # riscv: IR USER4 (out only), then DMI-shaped 41-bit DR scans
            # with idle clocks; IDCODE read in between
            queue_begin
            scan 1 [rbb::int_to_bits 0x23 6] 0 IDLE
            queue_end
            for {set k 0} {$k < 40} {incr k} {
                queue_begin
                scan 0 [randbits 41] 1 IDLE
                runtest [expr {int(rand() * 8)}] IDLE
                if {$k % 7 == 3} {
                    scan 0 [randbits 41] 1 IDLE
                }
                queue_end
            }
            queue_begin
            scan 1 [rbb::int_to_bits 0x09 6] 1 IDLE
            scan 0 [string repeat 0 32] 1 IDLE
            queue_end
        }
        pauses {
            # scans ending in DRPAUSE / IRPAUSE, OpenOCD's own continuation
            # (DRPAUSE -> DREXIT2 -> DRSHIFT), runtest ending in a pause
            queue_begin
            scan 1 [rbb::int_to_bits 0x23 6] 1 IRPAUSE
            scan 1 [rbb::int_to_bits 0x23 6] 1 IDLE
            scan 0 [randbits 30] 1 DRPAUSE
            scan 0 [randbits 30] 1 DRPAUSE
            scan 0 [randbits 300] 1 IDLE
            runtest 5 DRPAUSE
            scan 0 [randbits 48] 1 IRPAUSE
            scan 1 [rbb::int_to_bits 0x3F 6] 1 IRPAUSE
            scan 0 [randbits 9] 0 IDLE
            scan 0 [randbits 600] 1 IDLE
            queue_end
        }
        tunnel {
            # OpenOCD's tunnel DR scans are 53 bits (sim/rv_dbg shim log);
            # here with zeros in the last 12 bits, so that the TDI history
            # before the next shift (the tunnel's pre-shift "garbage") is
            # the same with and without the bridge's pause states
            queue_begin
            scan 1 [rbb::int_to_bits 0x23 6] 0 IDLE
            runtest 10 IDLE
            queue_end
            for {set k 0} {$k < 40} {incr k} {
                queue_begin
                scan 0 [randbits 41][string repeat 0 12] 1 IDLE
                runtest [expr {int(rand() * 3)}] IDLE
                if {$k % 5 == 2} {
                    scan 0 [randbits 41][string repeat 0 12] 1 IDLE
                }
                queue_end
            }
        }
        default { error "oocd::session $kind" }
    }
    quit
    variable s
    variable flushes
    variable blocks
    return [list $kind $s $flushes $blocks]
}

# ---------------------------------------------------------------------------
# random legal streams

namespace eval rnd {
    variable s
    variable st
    variable tck
    variable trst
}

proc rnd::Byte {c} {
    variable s
    append s $c
}

# one TCK cycle with TMS <tms>: low write, maybe R, high write (sometimes
# with other TMS/TDI values first, an R with TCK high, duplicate writes)
proc rnd::Clock {tms {tdi -1} {pr 0.3}} {
    variable st
    variable tck
    variable trst
    if {$tdi < 0} { set tdi [expr {int(rand() * 2)}] }
    if {rand() < 0.05} {
        Byte [expr {int(rand() * 4)}]
    }
    Byte [expr {2 * $tms + $tdi}]
    if {rand() < $pr} { Byte R }
    if {rand() < 0.05} {
        Byte [expr {2 * $tms + $tdi}]
    }
    Byte [expr {4 + 2 * $tms + $tdi}]
    if {rand() < 0.05} { Byte R }
    if {rand() < 0.03} { Byte [expr {4 + 2 * $tms + $tdi}] }
    if {!$trst} {
        set st $rbb::T($st,$tms)
    }
}

# shortest TMS path from the current state to <target>
proc rnd::PathTo {target} {
    variable st
    if {$st eq $target} { return {} }
    set seen [dict create $st {}]
    set fr [list $st]
    while {[llength $fr]} {
        set nf {}
        foreach x $fr {
            foreach t {0 1} {
                set y $rbb::T($x,$t)
                if {![dict exists $seen $y]} {
                    dict set seen $y [concat [dict get $seen $x] $t]
                    if {$y eq $target} { return [dict get $seen $y] }
                    lappend nf $y
                }
            }
        }
        set fr $nf
    }
    error "rnd: no path to $target"
}

proc rnd::Go {target} {
    foreach t [PathTo $target] { Clock $t }
}

proc rnd::Shift {type n {pr 0.9}} {
    variable st
    set u [string toupper $type]
    Go ${u}SHIFT
    for {set i 0} {$i < $n} {incr i} {
        set last [expr {$i == $n - 1}]
        if {!$last && rand() < 0.01} {
            # pause in the middle and continue (Exit1 Pause.. Exit2 Shift)
            Clock 1 -1 $pr
            Clock 0
            for {set k [expr {int(rand() * 3)}]} {$k > 0} {incr k -1} { Clock 0 }
            Clock 1
            Clock 0
            continue
        }
        Clock $last -1 $pr
    }
}

proc rnd::stream {} {
    variable s {}
    variable st RESET
    variable tck 0
    variable trst 0
    set nops [expr {5 + int(rand() * 40)}]
    for {set k 0} {$k < $nops} {incr k} {
        set x [expr {rand()}]
        if {$x < 0.20} {
            # IR load: USER4 mostly
            set v [lindex {0x23 0x23 0x23 0x09 0x3F 0x15} [expr {int(rand() * 6)}]]
            Go IRSHIFT
            set bits [rbb::int_to_bits $v 6]
            for {set i 0} {$i < 6} {incr i} {
                Clock [expr {$i == 5}] [string index $bits $i] 0.5
            }
        } elseif {$x < 0.55} {
            set n [expr {1 + int(rand() * (rand() < 0.1 ? 400 : 70))}]
            Shift dr $n
        } elseif {$x < 0.65} {
            Go IDLE
            for {set i [expr {int(rand() * 12)}]} {$i > 0} {incr i -1} { Clock 0 }
        } elseif {$x < 0.70} {
            for {set i [expr {5 + int(rand() * 3)}]} {$i > 0} {incr i -1} { Clock 1 }
        } elseif {$x < 0.85} {
            # random TMS walk
            for {set i [expr {1 + int(rand() * 10)}]} {$i > 0} {incr i -1} {
                Clock [expr {int(rand() * 2)}]
            }
        } elseif {$x < 0.92} {
            # stable-state stops: pauses, update paths
            Go [lindex {DRPAUSE IRPAUSE IDLE DRUPDATE IRUPDATE DREXIT2} [expr {int(rand() * 6)}]]
        } elseif {$x < 0.96} {
            Byte [lindex {B b r s R R} [expr {int(rand() * 6)}]]
        } else {
            # TRST (only outside the DR/IR columns: see README)
            if {$st in {RESET IDLE DRSELECT IRSELECT DRUPDATE IRUPDATE}} {
                Byte [lindex {t u} [expr {int(rand() * 2)}]]
                variable trst 1
                Clock [expr {int(rand() * 2)}]
                Byte r
                set trst 0
                set st RESET
            }
        }
    }
    if {rand() < 0.5} { Byte Q }
    return $s
}

# ---------------------------------------------------------------------------
# equivalence: the reference TAP answers <stream> directly; the core + shim
# + a second reference TAP answer it fed in chunks.  chunking: whole,
# bytes, random (1..300), or a list of flush offsets (OpenOCD's); blocks:
# OpenOCD's block points {offset nR}: there every R sent so far must be
# answered without the 2 ms timer.  be: back-end namespace (teeth tests
# wrap the shim).  Returns {ok 1} or {ok 0 why ...}; stats in the result.

namespace eval equiv {
    variable nr 0       ;# R bytes seen so far
    variable tck 0      ;# TCK after the bytes seen so far
    variable noedge 0   ;# the last R so far has no rising TCK edge after it
    variable rtail 0    ;# R bytes after the last rising TCK edge
}

# Advance the independent bookkeeping over the next chunk of the stream.
proc equiv::Track {chunk} {
    variable nr
    variable tck
    variable noedge
    variable rtail
    foreach c [split $chunk {}] {
        switch -- $c {
            R { incr nr; set noedge 1; incr rtail }
            0 - 1 - 2 - 3 { set tck 0 }
            4 - 5 - 6 - 7 {
                if {!$tck} { set noedge 0; set rtail 0 }
                set tck 1
            }
        }
    }
}

# options: -blocks {offset nR ...} -be <ns> -ra 0|1 (IDCODE read-ahead with
# the reference IDCODE known) -quirk {idreload tunnel} (both TAPs, see
# reftap::new) -idcode <value the bridge believes> -timeout_p <p> (chance
# that a hold expires at a chunk boundary)
proc equiv::run {stream chunking args} {
    array set o {-blocks {} -be ::shim -ra 0 -quirk {} -idcode 0x13631093 -timeout_p 0.5}
    array set o $args
    set blocks $o(-blocks)
    set timeout_p $o(-timeout_p)
    reftap::new A 0x13631093 $o(-quirk)
    set ref [reftap::rbb A $stream]
    reftap::new B 0x13631093 $o(-quirk)
    shim::set_driver {reftap::drive B} RESET
    rbb::configure -backend $o(-be) -log {apply {{m} {}}} \
        -idcode [expr {$o(-ra) ? $o(-idcode) : {}}] -idcode_readahead $o(-ra)
    rbb::conn_open
    # chunk boundaries
    set n [string length $stream]
    switch -- $chunking {
        whole  { set cuts [list $n] }
        bytes  { set cuts {}; for {set i 1} {$i <= $n} {incr i} { lappend cuts $i } }
        random {
            set cuts {}
            set i 0
            while {$i < $n} {
                incr i [expr {1 + int(rand() * 300)}]
                if {$i > $n} { set i $n }
                lappend cuts $i
            }
        }
        default { set cuts [lsort -integer -unique [concat $chunking [list $n]]] }
    }
    variable nr 0
    variable tck 0
    variable noedge 0
    variable rtail 0
    set bset [dict create]
    foreach b $blocks { dict set bset [lindex $b 0] [lindex $b 1] }
    set got {}
    set pos 0
    set quit 0
    foreach c $cuts {
        if {$c <= $pos} continue
        set chunk [string range $stream $pos [expr {$c - 1}]]
        set r [rbb::feed $chunk]
        if {$r ne "ok"} {
            if {[lindex $r 0] eq "quit"} {
                Track [string range $chunk 0 [expr {[lindex $r 1] - 1}]]
                set pos [expr {$pos + [lindex $r 1]}]
                set quit 1
                break
            }
            return [list ok 0 why "feed: $r"]
        }
        set pos $c
        Track $chunk
        set d [rbb::drain now]
        append got [rbb::take_out]
        variable nr
        variable noedge
        if {[dict exists $bset $pos]} {
            # OpenOCD blocks here: everything answered, no timer
            if {[string length $got] != [dict get $bset $pos] || $d ne "done" && [rbb::held] eq "redge"} {
                return [list ok 0 why "block at $pos: [string length $got] replies of [dict get $bset $pos] (drain $d [rbb::held])"]
            }
        }
        if {[rbb::held] eq "redge"} {
            if {!$noedge} {
                return [list ok 0 why "held an R at $pos that has its rising edge"]
            }
        } elseif {[rbb::held] eq "shift"} {
            # held inside a shift (OpenOCD's block points are checked above)
            if {$rbb::vs ni {DRSHIFT IRSHIFT}} {
                return [list ok 0 why "held a shift at $pos in $rbb::vs"]
            }
        } elseif {[string length $got] != $nr} {
            return [list ok 0 why "after $pos bytes: [string length $got] replies of $nr R"]
        }
        if {$d eq "wait" && rand() < $timeout_p} {
            rbb::drain timeout
            append got [rbb::take_out]
        }
    }
    rbb::drain close
    append got [rbb::take_out]
    # R bytes at the very end of the stream with no rising edge after them,
    # read in Shift-xR, ask for a bit that is never shifted: no scan can
    # answer them (the connection is over; OpenOCD never does this)
    set p [rbb::pending]
    if {$p > $rtail} {
        return [list ok 0 why "$p replies unanswered at the end, only $rtail R after the last edge"]
    }
    if {$p} {
        set ref [string range $ref 0 end-$p]
    }
    set ca [reftap::counters A]
    set cb [reftap::counters B]
    # the final state may differ when the stream stops outside a stable state
    set ca [dict remove $ca st]
    set cb [dict remove $cb st]
    set res [list ok 1 stats [rbb::stats] replies [string length $got]]
    if {$got ne $ref} {
        set i 0
        while {[string index $got $i] eq [string index $ref $i]} { incr i }
        return [list ok 0 why "replies differ at reply $i of [string length $ref] (got [string length $got])" stats [rbb::stats]]
    }
    if {$ca ne $cb} {
        return [list ok 0 why "counters differ: reference {$ca}, bridge {$cb}" stats [rbb::stats]]
    }
    return $res
}
