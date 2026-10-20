# rv_jtag_bridge.tcl -- Vivado hw_server JTAG-scan bridge for OpenOCD's
# remote_bitbang adapter (Phase 5.4: GDB on the board's VexRiscv OSD host
# CPU through the Platform Cable USB II, which OpenOCD 0.12 cannot drive).
#
#   OpenOCD (minimig-rv-bscan.cfg, remote_bitbang 127.0.0.1:33582)
#     -> this bridge (rbb_core.tcl: TAP tracking, scan aggregation/splitting)
#     -> scan_ir_hw_jtag / scan_dr_hw_jtag / run_state_hw_jtag / runtest_hw_jtag
#     -> hw_server -> cable -> XC7A100T TAP -> BSCANE2 USER4 -> debug module
#
# Run (Vivado 2023.2; close every other hardware manager first):
#   vivado -mode batch -nojournal -log rvbridge.log \
#       -source tools/rvdebug/rv_jtag_bridge.tcl [-tclargs <options>]
# Options (-tclargs) and their environment variables:
#   -port <p>            RBB_PORT       remote_bitbang port on 127.0.0.1 (33582;
#                                       in use: a free port, printed)
#   -url <host:port>     HW_SERVER_URL  hw_server (localhost:3121)
#   -xvc_url <host:port> XVC_URL        open an XVC target instead of a cable
#   -target <pattern>    TARGET         get_hw_targets pattern (default: the
#                                       only target; more than one: list, exit)
#   -freq <Hz>           JTAG_FREQ      TCK (hw_target PARAM.FREQUENCY; default:
#                                       the cable's own, 6 MHz on the Platform
#                                       Cable USB II)
#   -exit_on_disconnect 1               close the target and exit after the
#                                       first OpenOCD connection ends
#   -self_test 0                        skip the self-test (not recommended;
#                                       also disables the IDCODE read-ahead)
#   -idcode_readahead 0                 split OpenOCD's IDCODE autoprobe through
#                                       DRPAUSE instead of answering it ahead
#                                       (README "IDCODE read-ahead")
# Board session: findings/osd-riscv/debug-board-session.md.
#
# Self-test before serving: the raw Vivado commands (run_state_hw_jtag RESET,
# IR 0x09 6 bits, DR 32 bits) and then the same through the bridge core
# (IDCODE 0x?3631093, IR capture ..01, BYPASS delays DR by one bit); a
# mismatch prints the value read and exits 1 (a wrong value points at the
# bit order or the chain length).
#
# RVBRIDGE_NO_MAIN=1 in the environment: only define the procedures (the
# hex-conversion unit test, tools/rvdebug/test/test_hex.tcl).

# Vivado's source echoes every command unless -notrace (tclsh has no -notrace)
if {[catch {source -notrace [file join [file dirname [file normalize [info script]]] rbb_core.tcl]}]} {
    source [file join [file dirname [file normalize [info script]]] rbb_core.tcl]
}

namespace eval rvb {
    variable warned 0
}

# Bit string (index 0 = first bit shifted = LSB) -> Vivado hex argument:
# most significant digit first, ceil(n/4) digits, lower case.  The scan's
# bit 0 is the LSB of -tdi (help scan_dr_hw_jtag: "0x00_0010 (LSB first)").
proc rvb::bits_to_hex {bits} {
    set n [string length $bits]
    if {$n == 0 || ![regexp {^[01]+$} $bits]} {
        error "rvb::bits_to_hex: '$bits' is not a bit string"
    }
    set hex {}
    for {set d [expr {($n + 3) / 4 - 1}]} {$d >= 0} {incr d -1} {
        set v 0
        for {set b 3} {$b >= 0} {incr b -1} {
            set i [expr {4 * $d + $b}]
            set v [expr {2 * $v + ($i < $n ? [string index $bits $i] : 0)}]
        }
        append hex [format %x $v]
    }
    return $hex
}

# Vivado's TDO hex (most significant digit first, optional 0x, either case,
# leading zeros optional) -> <n> bits, index 0 = the first bit shifted out
# (the LSB).  Set bits above <n> are reported once (they mean the TDO is
# not LSB-aligned as documented) and dropped.
proc rvb::hex_to_bits {hex n} {
    variable warned
    set h [string trim $hex]
    regsub {^0[xX]} $h {} h
    if {$h eq {} || ![regexp {^[0-9a-fA-F]+$} $h]} {
        error "rvb::hex_to_bits: TDO '$hex' is not one hex number"
    }
    set nd [string length $h]
    set bits {}
    for {set i 0} {$i < $n} {incr i} {
        set d [expr {$nd - 1 - $i / 4}]
        if {$d < 0} {
            append bits 0
        } else {
            append bits [expr {("0x[string index $h $d]" >> ($i % 4)) & 1}]
        }
    }
    # anything above bit n-1?
    set extra 0
    for {set d [expr {$nd - 1 - $n / 4}]} {$d >= 0} {incr d -1} {
        set v [expr {"0x[string index $h $d]"}]
        if {$d == $nd - 1 - $n / 4} { set v [expr {$v >> ($n % 4)}] }
        if {$v} { set extra 1 }
    }
    if {$extra && !$warned} {
        set warned 1
        rbb::log "rvb: WARNING: TDO '$hex' has bits set above bit [expr {$n - 1}] (dropped; reported once)"
    }
    return $bits
}

# ---------------------------------------------------------------------------
# the back end: Vivado hw_jtag commands (target opened with -jtag_mode on)

namespace eval vbe {}

proc vbe::be_reset {} {
    run_state_hw_jtag RESET
}

proc vbe::be_goto {stable {path {}}} {
    if {$path eq {}} {
        run_state_hw_jtag $stable
    } else {
        run_state_hw_jtag -state $path $stable
    }
}

proc vbe::be_idle {n} {
    runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck $n
}

# The core calls this with the TAP in <end> (the pause state of <type>,
# reached by be_goto, or left there by the scan before): the scan enters
# from xREXIT2 without a capture and ends in the same pause state.
proc vbe::be_scan {type n bits end} {
    set tdo [scan_${type}_hw_jtag $n -tdi [rvb::bits_to_hex $bits]]
    return [rvb::hex_to_bits $tdo $n]
}

# ---------------------------------------------------------------------------
# self-test with the raw Vivado commands (documented defaults only)

proc rvb::raw_self_test {} {
    run_state_hw_jtag RESET
    run_state_hw_jtag IDLE
    set ir [scan_ir_hw_jtag 6 -tdi [bits_to_hex [rbb::int_to_bits 0x09 6]]]
    set dr [scan_dr_hw_jtag 32 -tdi [bits_to_hex [string repeat 0 32]]]
    set id [rbb::bits_to_int [hex_to_bits $dr 32]]
    set irc [rbb::bits_to_int [hex_to_bits $ir 6]]
    rbb::log "rvb: raw self-test: scan_ir_hw_jtag 6 -> '$ir' (IR capture [format 0x%02X $irc]),\
        scan_dr_hw_jtag 32 -> '$dr' (IDCODE [format 0x%08X $id])"
    run_state_hw_jtag RESET
    return [expr {($id & 0x0FFFFFFF) == 0x03631093}]
}

# ---------------------------------------------------------------------------
# main

proc rvb::opt {argv name envname default} {
    set i [lsearch -exact $argv -$name]
    if {$i >= 0} { return [lindex $argv [expr {$i + 1}]] }
    if {$envname ne {} && [info exists ::env($envname)] && $::env($envname) ne {}} {
        return $::env($envname)
    }
    return $default
}

proc rvb::main {argv} {
    foreach a $argv {
        if {[string match -* $a] && $a ni {-port -url -xvc_url -target -freq -exit_on_disconnect -self_test -idcode_readahead}} {
            rbb::log "rvb: unknown option $a"
            exit 2
        }
    }
    set port [opt $argv port RBB_PORT 33582]
    set url  [opt $argv url HW_SERVER_URL localhost:3121]
    set xvc  [opt $argv xvc_url XVC_URL {}]
    set pat  [opt $argv target TARGET *]
    set freq [opt $argv freq JTAG_FREQ {}]
    set eod  [opt $argv exit_on_disconnect {} 0]
    set selftest [opt $argv self_test {} 1]
    set ra [opt $argv idcode_readahead {} 1]
    rbb::log "rvb: rv_jtag_bridge: hw_server $url, [expr {$xvc ne {} ? "XVC $xvc" : "target pattern '$pat'"}],\
        remote_bitbang 127.0.0.1:$port[expr {$freq ne {} ? ", TCK $freq Hz" : ""}]"

    open_hw_manager
    connect_hw_server -url $url
    if {$xvc ne {}} {
        open_hw_target -jtag_mode on -xvc_url $xvc
        set t [current_hw_target]
    } else {
        set ts [get_hw_targets -quiet $pat]
        if {[llength $ts] == 0} {
            rbb::log "rvb: no hardware target matches '$pat' on $url"
            exit 1
        }
        if {[llength $ts] > 1} {
            rbb::log "rvb: [llength $ts] targets match '$pat'; choose one with -target / TARGET:"
            foreach x $ts { rbb::log "    $x" }
            exit 2
        }
        set t [lindex $ts 0]
        current_hw_target $t
        if {$freq ne {}} {
            if {[catch {set_property PARAM.FREQUENCY $freq $t} err]} {
                rbb::log "rvb: WARNING: PARAM.FREQUENCY $freq not set: $err"
            }
        }
        open_hw_target -jtag_mode on $t
    }
    set f {}
    catch {set f [get_property PARAM.FREQUENCY $t]}
    rbb::log "rvb: target $t open in JTAG mode[expr {$f ne {} ? ", PARAM.FREQUENCY $f" : ""}]"

    rbb::configure -backend ::vbe -idcode_readahead $ra
    if {$selftest} {
        if {![raw_self_test]} {
            rbb::log "=== RVBRIDGE SELF-TEST FAIL (raw Vivado commands): IDCODE is not 0x?3631093"
            catch {close_hw_target}
            exit 1
        }
        set r [rbb::self_test]
        if {![dict get $r ok]} {
            rbb::log "=== RVBRIDGE SELF-TEST FAIL (through the bridge core): [dict get $r msg]"
            catch {close_hw_target}
            exit 1
        }
        rbb::log "=== RVBRIDGE SELF-TEST PASS: [dict get $r msg]"
    }
    rbb::serve -port $port -exit_on_disconnect $eod -minute_log 1
    catch {close_hw_target}
    catch {disconnect_hw_server}
    rbb::log "rvb: done"
}

if {![info exists ::env(RVBRIDGE_NO_MAIN)] || $::env(RVBRIDGE_NO_MAIN) in {{} 0}} {
    if {[catch {rvb::main $argv} err]} {
        rbb::log "rvb: ERROR: $err"
        exit 1
    }
    exit 0
}
