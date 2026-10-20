# rbb_core.tcl -- OpenOCD remote_bitbang -> JTAG scan bridge core (plain Tcl
# 8.5/8.6: Vivado 2023.2 runs Tcl 8.5.14, the unit tests run in both)
#
# No Vivado commands in this file.  It parses OpenOCD 0.12's remote_bitbang
# byte stream, tracks the IEEE 1149.1 TAP state from the TMS bits on every
# rising TCK edge, turns the bit-level traffic into whole-register operations
# and hands them to a back end with Vivado's capabilities (scans and moves
# between the stable states RESET, IDLE, DRPAUSE, IRPAUSE only):
#
#   ${be}::be_scan  ir|dr <nbits> <tdi-bits> <end-state>  -> TDO bits
#   ${be}::be_goto  <stable-state> ?<path>?
#   ${be}::be_idle  <n>          n Run-Test/Idle clocks (TAP in IDLE)
#   ${be}::be_reset              Test-Logic-Reset
#
# Bit strings are '0'/'1' strings, index 0 = the first bit shifted (TDI) or
# sampled (TDO).  <path> lists the states entered on each TCK, excluding the
# start state and ending in <stable-state> (run_state_hw_jtag -state).
#
# Back ends: rv_jtag_bridge.tcl (Vivado hw_server), shim_rbb_backend.tcl
# (Vivado's documented semantics replayed as TMS/TDI bits; simulation and
# the unit tests).  How the mapping works: README.md "End-state mapping".
#
#   source rbb_core.tcl
#   rbb::configure -backend ::shim
#   rbb::serve -port 33582 ?-exit_on_disconnect 1? ?-minute_log 1?
#
# or, without a socket (unit tests): rbb::conn_open; rbb::feed <bytes>;
# rbb::drain now|timeout|close; rbb::take_out.

namespace eval rbb {
    # IEEE 1149.1 TAP: T(state,tms) -> next state, Vivado's state names
    variable T
    foreach {s n0 n1} {
        RESET     IDLE      RESET
        IDLE      IDLE      DRSELECT
        DRSELECT  DRCAPTURE IRSELECT
        DRCAPTURE DRSHIFT   DREXIT1
        DRSHIFT   DRSHIFT   DREXIT1
        DREXIT1   DRPAUSE   DRUPDATE
        DRPAUSE   DRPAUSE   DREXIT2
        DREXIT2   DRSHIFT   DRUPDATE
        DRUPDATE  IDLE      DRSELECT
        IRSELECT  IRCAPTURE RESET
        IRCAPTURE IRSHIFT   IREXIT1
        IRSHIFT   IRSHIFT   IREXIT1
        IREXIT1   IRPAUSE   IRUPDATE
        IRPAUSE   IRPAUSE   IREXIT2
        IREXIT2   IRSHIFT   IRUPDATE
        IRUPDATE  IDLE      DRSELECT
    } {
        set T($s,0) $n0
        set T($s,1) $n1
    }
    unset s n0 n1

    variable be ::shim          ;# back-end namespace
    variable logcmd {}          ;# command prefix called with one log line; {} = stdout
    variable idcode_bits {}     ;# the chain's IDCODE (32 bits) once a self-test passed
    variable readahead 1        ;# answer the post-reset IDCODE interrogation ahead (README)
    variable split_test 0       ;# test knob: split every shift after this many bits (0 = off)
    variable idcode_ir 100100   ;# the XC7's IDCODE instruction 0x09, IR 6 bits (first bit first)
    variable client_buf 255     ;# OpenOCD 0.12 remote_bitbang buf_size: it blocks after this many R of a scan
    variable shift_hold_ms 100  ;# fewer R owed inside a shift: wait this long before splitting
    variable hold_ms 2          ;# how long the caller waits after drain "wait"

    # --- connection state (conn_open resets it) ---
    variable vs RESET           ;# TAP state as OpenOCD drives it (the "virtual" TAP)
    variable tck 0
    variable tms 0
    variable tdi 0
    variable trst 0
    variable rs RESET           ;# where the back end's TAP is (a stable state)
    variable pendU {}           ;# dr/ir: the virtual TAP passed Update, the back end has not yet
    variable sh_type dr         ;# type of the shift in progress
    variable sh_bits {}         ;# TDI bits shifted (edges arrived) and not yet scanned
    variable total 0            ;# bits shifted in this connection (absolute bit numbers)
    variable scanned 0          ;# bits handed to be_scan; their TDO is known
    variable idle_n 0           ;# Run-Test/Idle clocks not yet passed on
    variable q {}               ;# replies owed, in order: -1 = '1', n >= 0 = TDO of shift bit n
    variable qi 0               ;# first unanswered entry of q
    variable out {}             ;# reply bytes ready to send
    variable held {}            ;# why the last drain returned "wait": redge / shift / update
    variable st                 ;# statistics (dict)
    variable run_bits 0         ;# bits of the current shift (capture .. exit), across splits
    variable idwin 1            ;# IDCODE selected: Test-Logic-Reset, or Update-IR of idcode_ir
    variable ir_run {}          ;# TDI bits of the current/last IR shift
    variable shift_r 0          ;# R received since the TAP entered Shift-xR (OpenOCD: per scan)
    variable run_id 0           ;# the current DR shift started in that window
    variable emu_n 0            ;# replies of the current shift answered ahead
}

proc rbb::configure {args} {
    variable be
    variable logcmd
    foreach {k v} $args {
        switch -- $k {
            -backend { set be $v }
            -log     { set logcmd $v }
            -idcode  {
                variable idcode_bits
                set idcode_bits [expr {$v eq {} ? {} : [int_to_bits $v 32]}]
            }
            -idcode_readahead { variable readahead $v }
            -split_test { variable split_test $v }
            -client_buf { variable client_buf $v }
            -shift_hold_ms { variable shift_hold_ms $v }
            default  { error "rbb::configure: unknown option $k" }
        }
    }
}

proc rbb::log {msg} {
    variable logcmd
    if {$logcmd eq {}} {
        puts $msg
        flush stdout
    } else {
        {*}$logcmd $msg
    }
}

proc rbb::Up {t} { string toupper $t }

# ---------------------------------------------------------------------------
# connection

# Fresh connection: the back end goes to Test-Logic-Reset, so that the
# virtual TAP (assumed in Test-Logic-Reset, TCK low) and the back end agree.
proc rbb::conn_open {} {
    variable be
    foreach {v x} {vs RESET tck 0 tms 0 tdi 0 trst 0 rs RESET pendU {} sh_type dr
                   sh_bits {} total 0 scanned 0 idle_n 0 q {} qi 0 out {} held {} run_bits 0
                   idwin 1 run_id 0 emu_n 0 ir_run {} shift_r 0} {
        variable $v
        set $v $x
    }
    variable st
    set st [dict create bytes 0 writes 0 reads 0 edges 0 resets 0 blinks 0 \
            scans 0 partial 0 max_scan 0 max_shift 0 scan_bits 0 \
            gotos 0 idles 0 idle_clocks 0 be_resets 0 readahead 0 readahead_bad 0]
    ${be}::be_reset
    dict incr st be_resets
}

proc rbb::stats {} {
    variable st
    return $st
}

# Replies queued and not yet answered (the unit tests' liveness check).
proc rbb::pending {} {
    variable q
    variable qi
    return [expr {[llength $q] - $qi}]
}

proc rbb::take_out {} {
    variable out
    set o $out
    set out {}
    return $o
}

# ---------------------------------------------------------------------------
# the byte stream

# Process the bytes of <data>.  Returns "ok", "quit <offset>" (a 'Q'; the
# bytes after it are ignored) or "bad <byte> <offset>" (an unknown byte: the
# caller closes the connection).
proc rbb::feed {data} {
    variable tck
    variable tms
    variable tdi
    variable vs
    variable sh_bits
    variable total
    variable idle_n
    variable q
    variable qi
    variable out
    variable st
    variable trst
    variable T
    variable split_test
    variable run_id
    variable shift_r
    set i 0
    set nw 0
    set nr 0
    set ne 0
    foreach c [split $data {}] {
        incr i
        switch -- $c {
            0 { set tck 0; set tms 0; set tdi 0; incr nw }
            1 { set tck 0; set tms 0; set tdi 1; incr nw }
            2 { set tck 0; set tms 1; set tdi 0; incr nw }
            3 { set tck 0; set tms 1; set tdi 1; incr nw }
            4 - 5 - 6 - 7 {
                incr nw
                set v [expr {$c - 4}]
                set tms [expr {$v >> 1}]
                set tdi [expr {$v & 1}]
                if {$tck} continue
                set tck 1
                if {$trst} continue
                incr ne
                # rising edge: the hot paths inline, the rest in Edge
                if {$vs eq "DRSHIFT" || $vs eq "IRSHIFT"} {
                    append sh_bits $tdi
                    incr total
                    if {!$tms} {
                        if {$split_test && [string length $sh_bits] >= $split_test && !$run_id} {
                            # test knob: a split as at a drain (not in the
                            # IDCODE window: see IDCODE read-ahead)
                            Emit shift
                        }
                        continue
                    }
                } elseif {$vs eq "IDLE" && !$tms} {
                    incr idle_n
                    continue
                }
                Edge
            }
            R {
                incr nr
                if {!$trst && ($vs eq "DRSHIFT" || $vs eq "IRSHIFT")} {
                    # the bit the next rising edge shifts out
                    lappend q $total
                    incr shift_r
                } elseif {$qi == [llength $q]} {
                    append out 1
                } else {
                    lappend q -1
                }
            }
            r - s {
                dict incr st resets
                set trst 0
            }
            t - u {
                dict incr st resets
                if {!$trst} {
                    Trst
                }
            }
            B - b { dict incr st blinks }
            Q {
                dict incr st bytes $i
                dict incr st writes $nw
                dict incr st reads $nr
                dict incr st edges $ne
                return [list quit $i]
            }
            default {
                dict incr st bytes $i
                dict incr st writes $nw
                dict incr st reads $nr
                dict incr st edges $ne
                binary scan $c cu b
                return [list bad [format 0x%02x $b] [expr {$i - 1}]]
            }
        }
    }
    dict incr st bytes $i
    dict incr st writes $nw
    dict incr st reads $nr
    dict incr st edges $ne
    return ok
}

# A rising TCK edge that changes state (the shift bit, if any, is already
# taken).  vs = the state before the edge, tms = TMS at the edge.
proc rbb::Edge {} {
    variable vs
    variable tms
    variable T
    variable idle_n
    set s $vs
    if {$s eq "DRSHIFT" || $s eq "IRSHIFT"} {
        # TMS = 1 ends the shift: the scan is complete
        set vs $T($s,1)
        Emit shift
        return
    }
    set n $T($s,$tms)
    if {$n eq $s} return            ;# TLR with TMS 1, a Pause with TMS 0
    if {$s eq "IDLE" && $idle_n} {
        Emit clk
    }
    set vs $n
    switch -- $n {
        RESET     { Emit reset }
        IDLE      { Emit idle }
        DRCAPTURE { Emit capture dr }
        IRCAPTURE { Emit capture ir }
        DRUPDATE  { Emit update dr }
        IRUPDATE  { Emit update ir }
        DRSHIFT   { variable sh_type dr; variable shift_r 0 }
        IRSHIFT   { variable sh_type ir; variable shift_r 0 }
    }
}

# TRST asserted ('t'/'u'): asynchronous Test-Logic-Reset, held while TRST is
# asserted.  Vivado has no TRST: the back end resets with TMS, which passes
# Update-DR/IR when the TAP is in a DR/IR column (README).
proc rbb::Trst {} {
    variable trst
    variable vs
    variable sh_bits
    variable idle_n
    variable q
    variable qi
    variable total
    if {$sh_bits ne {}} {
        Emit shift
    }
    if {$vs eq "IDLE" && $idle_n} {
        Emit clk
    }
    # an R whose rising edge never comes: answered '1'
    set j [llength $q]
    while {$j > $qi && [lindex $q [expr {$j - 1}]] >= $total} { incr j -1 }
    if {$j < [llength $q]} {
        set q [lreplace $q $j end {*}[lrepeat [expr {[llength $q] - $j}] -1]]
        log "rbb: TRST before the rising edge of a TDO read: answered 1"
    }
    if {$vs ne "RESET"} {
        set vs RESET
        Emit reset
    }
    set trst 1
    Resolve {} 0
}

# ---------------------------------------------------------------------------
# the mapper: target-visible events -> back-end calls
#
# Events, in the order the virtual TAP produces them:
#   reset        entered Test-Logic-Reset
#   idle         entered Run-Test/Idle
#   clk          idle_n clocks in Run-Test/Idle (TMS 0)
#   capture t    entered Capture-DR/IR
#   shift        sh_bits shifted (complete, or split at a drain)
#   update t     entered Update-DR/IR
# The back end's TAP rests in DRPAUSE/IRPAUSE while the virtual TAP is in
# the DR/IR column; Update is held (pendU) until the next event shows where
# the path goes.
proc rbb::Emit {ev {t {}}} {
    variable rs
    variable pendU
    variable be
    variable st
    switch -- $ev {
        reset {
            if {$rs ne "RESET"} {
                ${be}::be_reset
                dict incr st be_resets
            }
            set rs RESET
            set pendU {}
            variable idwin 1
        }
        idle {
            if {$pendU ne {}} {
                set p [Up $pendU]
                Goto IDLE [list ${p}EXIT2 ${p}UPDATE IDLE]
            } elseif {$rs eq "RESET"} {
                Goto IDLE {IDLE}
            } elseif {$rs ne "IDLE"} {
                error "rbb: Run-Test/Idle entered from $rs without Update"
            }
            set rs IDLE
            set pendU {}
        }
        clk {
            variable idle_n
            if {$rs ne "IDLE"} { error "rbb: idle clocks with the back end in $rs" }
            ${be}::be_idle $idle_n
            dict incr st idles
            dict incr st idle_clocks $idle_n
            set idle_n 0
        }
        capture {
            set u [Up $t]
            set path {}
            if {$pendU ne {}} {
                set p [Up $pendU]
                lappend path ${p}EXIT2 ${p}UPDATE
            } elseif {$rs ne "IDLE"} {
                error "rbb: Capture-$u from $rs"
            }
            lappend path DRSELECT
            if {$t eq "ir"} { lappend path IRSELECT }
            lappend path ${u}CAPTURE ${u}EXIT1 ${u}PAUSE
            Goto ${u}PAUSE $path
            set rs ${u}PAUSE
            set pendU {}
            variable run_bits 0
            variable run_id
            variable idwin
            variable emu_n 0
            set run_id [expr {$t eq "dr" && $idwin}]
            if {$t eq "ir"} {
                variable ir_run {}
            }
        }
        shift {
            Scan
        }
        update {
            set pendU $t
            if {$t eq "ir"} {
                # the IR takes the last 6 bits shifted (one 6-bit TAP: the
                # self-test proves it)
                variable ir_run
                variable idcode_ir
                variable idwin [expr {[string range $ir_run end-5 end] eq $idcode_ir}]
            }
        }
    }
}

proc rbb::Goto {stable path} {
    variable be
    variable st
    ${be}::be_goto $stable $path
    dict incr st gotos
}

# One back-end scan of sh_bits (the back end rests in the matching pause
# state and stays there), then the replies it answers.
proc rbb::Scan {} {
    variable be
    variable sh_type
    variable sh_bits
    variable rs
    variable pendU
    variable scanned
    variable st
    variable vs
    variable run_bits
    variable emu_n
    variable idcode_bits
    set u [Up $sh_type]
    if {$rs ne "${u}PAUSE" || $pendU ne {}} {
        error "rbb: $u scan with the back end in $rs (update pending: $pendU)"
    }
    set n [string length $sh_bits]
    set tdo [${be}::be_scan $sh_type $n $sh_bits ${u}PAUSE]
    if {[string length $tdo] != $n || ![regexp {^[01]*$} $tdo]} {
        error "rbb: be_scan returned '$tdo' for $n bits"
    }
    if {$emu_n && $run_bits == 0} {
        # replies of this scan went out ahead: the scan must agree
        set want [string range $idcode_bits$sh_bits 0 [expr {$n - 1}]]
        if {$tdo ne $want} {
            dict incr st readahead_bad
            log "rbb: WARNING: IDCODE read-ahead: the $n-bit scan returned TDO $tdo,\
                the read-ahead answered $emu_n reads from $want"
        }
        set emu_n 0
    }
    dict incr st scans
    dict incr st scan_bits $n
    incr run_bits $n
    if {$vs eq "${u}SHIFT"} {
        dict incr st partial
    } elseif {$run_bits > [dict get $st max_shift]} {
        dict set st max_shift $run_bits
    }
    if {$n > [dict get $st max_scan]} {
        dict set st max_scan $n
    }
    if {$sh_type eq "ir"} {
        variable ir_run
        append ir_run $sh_bits
    }
    set base $scanned
    incr scanned $n
    set sh_bits {}
    Resolve $tdo $base
}

# Answer the queued replies that are known: '1' entries and TDO bits below
# <scanned>; <tdo> holds the bits [base, scanned) of the last scan (refs are
# non-decreasing, so no older bit is ever asked for again).
proc rbb::Resolve {tdo base} {
    variable q
    variable qi
    variable out
    variable scanned
    set n [llength $q]
    while {$qi < $n} {
        set e [lindex $q $qi]
        if {$e < 0} {
            append out 1
        } elseif {$e < $scanned} {
            append out [string index $tdo [expr {$e - $base}]]
        } else {
            break
        }
        incr qi
    }
    if {$qi == $n} {
        set q {}
        set qi 0
    } elseif {$qi > 4096} {
        set q [lrange $q $qi end]
        set qi 0
    }
}

# The input is drained (no byte readable now).  mode:
#   now      flush what OpenOCD may be waiting for.  Inside a shift with
#            reads owed, split only when OpenOCD must be waiting: it reads
#            back after every 255th R of a scan (its buf_size; a scan = one
#            visit of Shift-xR).  Otherwise OpenOCD is not blocked (a TCP
#            segment boundary) and the bridge holds ("wait", hold_ms 100):
#            a split is not transparent to the BSCANE2 tunnel (README).  An
#            R whose rising edge has not arrived and a trailing Update are
#            held 2 ms.  The caller calls again with "timeout" after
#            [rbb::hold_ms] ms without input.
#   timeout  the hold expired: split (before a missing edge), finish the
#            Update through Run-Test/Idle
#   close    end of the connection: flush everything
# Returns "done" or "wait"; the replies are in take_out.
proc rbb::drain {mode} {
    variable q
    variable qi
    variable total
    variable sh_bits
    variable vs
    variable idle_n
    variable pendU
    variable held
    variable rs
    variable hold_ms
    variable client_buf
    variable shift_hold_ms
    variable shift_r
    set held {}
    if {$mode ne "close"} {
        ReadAhead
    }
    set nq [llength $q]
    set owed [expr {$nq - $qi}]
    if {$mode eq "now" && $owed} {
        if {[lindex $q end] >= $total} {
            set held redge
            set hold_ms 2
            return wait
        }
        if {$sh_bits ne {} && ($shift_r == 0 || $shift_r % $client_buf != 0)} {
            set held shift
            set hold_ms $shift_hold_ms
            return wait
        }
    }
    if {$sh_bits ne {} && ($owed || $mode eq "close")} {
        Emit shift
    }
    if {$vs eq "IDLE" && $idle_n} {
        Emit clk
    }
    if {$pendU ne {}} {
        if {$mode eq "now"} {
            set held update
            set hold_ms 2
            return wait
        }
        # Update, then Run-Test/Idle: an extra visit of Run-Test/Idle with no
        # clock in it; the next event starts from IDLE
        set p [Up $pendU]
        Goto IDLE [list ${p}EXIT2 ${p}UPDATE IDLE]
        set rs IDLE
        set pendU {}
    }
    return done
}

# IDCODE read-ahead.  After Test-Logic-Reset, or after an Update-IR that
# loaded the IDCODE instruction, a DR scan reads the IDCODE register.  On the XC7 (Vivado's JTAG_SIME2 model,
# sim/rv_dbg/xc7_tap.v) that register reloads the IDCODE on every rising
# edge outside Shift-DR, so a split through DRPAUSE is not transparent and
# OpenOCD's 672-bit autoprobe (it blocks every 255 reads) would read the
# IDCODE again after each split.  With the chain known from the self-test
# (one TAP, 32-bit IDCODE, BYPASS delay 1) the TDO of that scan is known:
# bit i = IDCODE bit i (i < 32), else TDI bit i - 32.  The pending reads are
# answered from that, the shift is not split, and the real scan, issued
# when the shift ends, is checked against what was answered.
proc rbb::ReadAhead {} {
    variable readahead
    variable idcode_bits
    variable run_id
    variable run_bits
    variable vs
    variable q
    variable qi
    variable out
    variable scanned
    variable sh_bits
    variable emu_n
    variable st
    if {!$readahead || $idcode_bits eq {} || !$run_id || $run_bits || $vs ne "DRSHIFT"} {
        return
    }
    set model $idcode_bits$sh_bits
    set m [string length $model]
    set n [llength $q]
    while {$qi < $n} {
        set e [lindex $q $qi]
        if {$e < 0} {
            append out 1
        } else {
            set i [expr {$e - $scanned}]
            if {$i >= $m} break
            append out [string index $model $i]
            incr emu_n
            dict incr st readahead
        }
        incr qi
    }
    if {$qi == $n} {
        set q {}
        set qi 0
    }
}

proc rbb::held {} {
    variable held
    return $held
}

proc rbb::hold_ms {} {
    variable hold_ms
    return $hold_ms
}

# ---------------------------------------------------------------------------
# byte-stream builders (OpenOCD's bitbang shapes; the self-test and tests)

# TMS moves: per bit write(TCK 0), write(TCK 1); then TCK low (bitbang.c
# bitbang_execute_tms).
proc rbb::bb_tms {bits} {
    set s {}
    set t 0
    foreach t [split $bits {}] {
        append s [expr {2 * $t}] [expr {4 + 2 * $t}]
    }
    append s [expr {2 * $t}]
    return $s
}

# A shift from Shift-xR: per bit write(TCK 0), R (if read), write(TCK 1);
# TMS = 1 on the last bit (bitbang.c bitbang_scan); then TCK low.
proc rbb::bb_shift {bits {read 1}} {
    set s {}
    set n [string length $bits]
    set tms 0
    for {set i 0} {$i < $n} {incr i} {
        set tms [expr {$i == $n - 1}]
        set d [string index $bits $i]
        append s [expr {2 * $tms + $d}]
        if {$read} { append s R }
        append s [expr {4 + 2 * $tms + $d}]
    }
    append s [expr {2 * $tms}]
    return $s
}

proc rbb::bits_to_int {bits} {
    set v 0
    for {set i [expr {[string length $bits] - 1}]} {$i >= 0} {incr i -1} {
        set v [expr {($v << 1) | [string index $bits $i]}]
    }
    return $v
}

proc rbb::int_to_bits {v n} {
    set s {}
    for {set i 0} {$i < $n} {incr i} {
        append s [expr {($v >> $i) & 1}]
    }
    return $s
}

# ---------------------------------------------------------------------------
# self-test through the core and the configured back end: IR capture, IDCODE
# (XC7A100T, version nibble masked: 0x?3631093) and BYPASS (DR 8 bits come
# back delayed by one bit).  Returns a dict: ok (0/1), msg, idcode, ircap.
proc rbb::self_test {{expect 0x03631093}} {
    variable split_test
    set knob $split_test
    set split_test 0
    conn_open
    # RESET -> IDLE -> Shift-IR; IDCODE (0x09); -> Shift-DR, 32 bits; -> IDLE
    set s [bb_tms 01100]
    append s [bb_shift [int_to_bits 0x09 6]]
    append s [bb_tms 1100]
    append s [bb_shift [string repeat 0 32]]
    append s [bb_tms 10]
    # BYPASS (all ones), DR 8 bits 0xA5
    set pat [int_to_bits 0xA5 8]
    append s [bb_tms 1100]
    append s [bb_shift 111111]
    append s [bb_tms 1100]
    append s [bb_shift $pat]
    append s [bb_tms 10]
    set r [feed $s]
    set split_test $knob
    if {$r ne "ok"} { error "rbb::self_test: feed returned $r" }
    drain close
    set rep [take_out]
    if {[string length $rep] != 52} {
        return [dict create ok 0 msg "self-test: [string length $rep] replies, expected 52" idcode {} ircap {}]
    }
    set ircap [bits_to_int [string range $rep 0 5]]
    set id [bits_to_int [string range $rep 6 37]]
    set byp [string range $rep 44 51]
    set res [dict create idcode [format 0x%08X $id] ircap [format 0x%02X $ircap] ok 1 msg {}]
    set why {}
    if {($ircap & 3) != 1} {
        lappend why "IR capture [format 0x%02X $ircap] does not end in binary 01"
    }
    if {($id & 0x0FFFFFFF) != ($expect & 0x0FFFFFFF)} {
        lappend why "IDCODE [format 0x%08X $id], expected [format 0x?%07X [expr {$expect & 0x0FFFFFFF}]]"
    }
    set want 0[string range $pat 0 6]
    if {$byp ne $want} {
        lappend why "BYPASS returned $byp for $pat, expected $want (one bit delay)"
    }
    variable idcode_bits
    if {[llength $why]} {
        dict set res ok 0
        dict set res msg [join $why {; }]
        set idcode_bits {}
    } else {
        dict set res msg "IDCODE [format 0x%08X $id], IR capture [format 0x%02X $ircap], BYPASS ok"
        # the chain is one XC7 TAP: the IDCODE read-ahead may use it
        set idcode_bits [string range $rep 6 37]
    }
    return $res
}

# ---------------------------------------------------------------------------
# TCP server: one remote_bitbang connection at a time (127.0.0.1)

namespace eval rbb {
    variable srv {}
    variable conn {}
    variable timer {}
    variable done 0
    variable opts
    array set opts {exit_on_disconnect 0 minute_log 0 on_close {}}
    variable nconn 0
    variable minute_prev {}
}

# rbb::serve -port <p> ?-exit_on_disconnect 0|1? ?-minute_log 0|1?
#            ?-on_close <cmd>?
# A port in use: a free port instead (printed).  Returns when a connection
# closed and -exit_on_disconnect is set (vwait loop).
proc rbb::serve {args} {
    variable srv
    variable opts
    variable done
    set port 33582
    foreach {k v} $args {
        switch -- $k {
            -port               { set port $v }
            -exit_on_disconnect { set opts(exit_on_disconnect) $v }
            -minute_log         { set opts(minute_log) $v }
            -on_close           { set opts(on_close) $v }
            default             { error "rbb::serve: unknown option $k" }
        }
    }
    if {[catch {socket -server rbb::Accept -myaddr 127.0.0.1 $port} srv]} {
        log "rbb: port $port: $srv; taking a free port"
        set srv [socket -server rbb::Accept -myaddr 127.0.0.1 0]
    }
    set p [lindex [fconfigure $srv -sockname] 2]
    log "=== RBB BRIDGE listening 127.0.0.1:$p"
    if {$opts(minute_log)} {
        after 60000 rbb::MinuteLog
    }
    set done 0
    vwait rbb::done
    close $srv
    set srv {}
}

proc rbb::Accept {ch addr port} {
    variable conn
    variable nconn
    if {$conn ne {}} {
        log "rbb: refused a second connection from $addr:$port (one at a time)"
        close $ch
        return
    }
    fconfigure $ch -blocking 0 -translation binary -buffering full
    set conn $ch
    incr nconn
    log "=== RBB BRIDGE connection $nconn from $addr:$port"
    if {[catch {conn_open} err]} {
        log "rbb: back end failed at connection start: $err"
        Close $ch "back end error"
        return
    }
    fileevent $ch readable [list rbb::Readable $ch]
}

proc rbb::Readable {ch} {
    variable timer
    if {$timer ne {}} {
        after cancel $timer
        set timer {}
    }
    while 1 {
        if {[catch {read $ch} d]} {
            Close $ch "read: $d"
            return
        }
        if {$d eq {}} break
        if {[catch {feed $d} r]} {
            log "rbb: back end error: $r"
            Close $ch "back end error"
            return
        }
        if {$r ne "ok"} {
            if {[lindex $r 0] eq "quit"} {
                Close $ch Q
            } else {
                log "rbb: unknown byte [lindex $r 1] at offset [lindex $r 2] of the stream: closing"
                Close $ch "unknown byte [lindex $r 1]"
            }
            return
        }
    }
    if {[eof $ch]} {
        Close $ch "peer closed"
        return
    }
    DrainSend $ch now
}

proc rbb::DrainSend {ch mode} {
    variable timer
    set timer {}
    if {[catch {drain $mode} r]} {
        log "rbb: back end error: $r"
        Close $ch "back end error"
        return
    }
    set o [take_out]
    if {$o ne {}} {
        if {[catch {puts -nonewline $ch $o; flush $ch} err]} {
            Close $ch "write: $err"
            return
        }
    }
    if {$r eq "wait"} {
        set timer [after [hold_ms] [list rbb::DrainSend $ch timeout]]
    }
}

proc rbb::Close {ch why} {
    variable conn
    variable timer
    variable done
    variable opts
    variable nconn
    if {$timer ne {}} {
        after cancel $timer
        set timer {}
    }
    if {[catch {drain close} err]} {
        log "rbb: back end error at close: $err"
    }
    catch {
        set o [take_out]
        if {$o ne {}} { puts -nonewline $ch $o; flush $ch }
    }
    catch {close $ch}
    set conn {}
    set s [stats]
    log "=== RBB BRIDGE connection $nconn closed ($why): bytes [dict get $s bytes],\
        edges [dict get $s edges], R [dict get $s reads], scans [dict get $s scans]\
        (partial [dict get $s partial], longest [dict get $s max_scan] bits,\
        longest shift [dict get $s max_shift] bits), IDCODE read-ahead [dict get $s readahead]\
        ([dict get $s readahead_bad] bad), gotos [dict get $s gotos],\
        idle runs [dict get $s idles] ([dict get $s idle_clocks] clocks),\
        resets [dict get $s be_resets], reset bytes [dict get $s resets], blink [dict get $s blinks]"
    if {$opts(on_close) ne {}} {
        catch {{*}$opts(on_close) $why}
    }
    if {$opts(exit_on_disconnect)} {
        set done 1
    }
}

proc rbb::MinuteLog {} {
    variable conn
    variable minute_prev
    variable st
    if {$conn ne {} && [info exists st]} {
        set sc [dict get $st scans]
        set pa [dict get $st partial]
        if {$minute_prev ne {}} {
            lassign $minute_prev s0 p0
        } else {
            set s0 0
            set p0 0
        }
        if {$sc < $s0} { set s0 0; set p0 0 }
        log "rbb: [clock format [clock seconds] -format %H:%M] scans in the last minute:\
            [expr {$sc - $s0}] (partial [expr {$pa - $p0}])"
        set minute_prev [list $sc $pa]
    } else {
        set minute_prev {}
    }
    after 60000 rbb::MinuteLog
}
