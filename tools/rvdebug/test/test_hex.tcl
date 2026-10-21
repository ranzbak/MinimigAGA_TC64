# test_hex.tcl -- the bit-string <-> Vivado hex conversion of
# rv_jtag_bridge.tcl (rvb::bits_to_hex, rvb::hex_to_bits) against
# hand-computed vectors.  Runs in tclsh (sourced by run_all.tcl) and in
# Vivado batch mode (no hardware: sources rv_jtag_bridge.tcl with
# RVBRIDGE_NO_MAIN=1); prints "=== HEX TEST PASS <n> vectors" or FAIL.
#
# Convention (help scan_dr_hw_jtag, Vivado 2023.2): the scan's first bit
# (bit string index 0) is the LSB of the -tdi value and of the returned TDO.

set hexdir [file dirname [file normalize [info script]]]
if {[info commands rvb::bits_to_hex] eq {}} {
    set ::env(RVBRIDGE_NO_MAIN) 1
    source [file join $hexdir .. rv_jtag_bridge.tcl]
}
if {[info commands test::case] eq {}} {
    # standalone (Vivado): a minimal test::case
    namespace eval test { variable pass 0; variable fail 0 }
    proc test::case {name body} {
        if {[catch {uplevel 1 $body} err]} {
            incr test::fail
            puts "FAIL $name: $err"
        } else {
            incr test::pass
            puts "ok   $name"
        }
    }
    proc test::eq {got want msg} {
        if {$got ne $want} { error "$msg: got '$got', expected '$want'" }
    }
}

namespace eval hextest { variable n 0; variable fail0 $test::fail }

# bits (first shifted first) <-> hex (most significant digit first)
#   0x09 = 0b001001          -> bits 1,0,0,1,0,0
#   0x3F                     -> 111111
#   0x23 = 0b100011 (USER4)  -> 1,1,0,0,0,1
#   5 bits, only bit 4 set   -> 0x10
#   0xA5 = 0b10100101        -> 1,0,1,0,0,1,0,1
#   0x03631093 = 0000 0011 0110 0011 0001 0000 1001 0011
#     digits from the LSB: 3=1100 9=1001 0=0000 1=1000 3=1100 6=0110 3=1100 0=0000
#   41 bits, bits 0 and 40   -> 0x10000000001 (11 digits)
#   41 bits, bit 1 and bit 39 -> 0x08000000002
set hextest::vectors {
    100100 09
    111111 3f
    110001 23
    1 1
    0 0
    00001 10
    10100101 a5
    11001001000010001100011011000000 03631093
    10000000000000000000000000000000000000001 10000000001
    01000000000000000000000000000000000000010 08000000002
}

test::case "hex: bits_to_hex, hand-computed vectors" {
    foreach {bits hex} $hextest::vectors {
        test::eq [rvb::bits_to_hex $bits] $hex "bits_to_hex $bits"
        incr hextest::n
    }
}

test::case "hex: hex_to_bits, hand-computed vectors and Vivado's spellings" {
    foreach {bits hex} $hextest::vectors {
        set n [string length $bits]
        test::eq [rvb::hex_to_bits $hex $n] $bits "hex_to_bits $hex $n"
        test::eq [rvb::hex_to_bits [string toupper $hex] $n] $bits "upper case $hex"
        test::eq [rvb::hex_to_bits 0x$hex $n] $bits "0x$hex"
        test::eq [rvb::hex_to_bits 00$hex $n] $bits "leading zeros 00$hex"
        incr hextest::n 4
    }
    # leading zeros left out (as -tdi accepts them): 0x3631093 = 0x03631093
    test::eq [rvb::hex_to_bits 3631093 32] 11001001000010001100011011000000 "short IDCODE"
    test::eq [rvb::hex_to_bits 1 6] 100000 "1 in 6 bits"
    test::eq [rvb::hex_to_bits " 3F\n" 6] 111111 "white space trimmed"
    incr hextest::n 3
    foreach bad {{} xyz 0x {12 34} 1_2} {
        if {![catch {rvb::hex_to_bits $bad 8}]} { error "hex_to_bits '$bad' accepted" }
        incr hextest::n
    }
    if {![catch {rvb::bits_to_hex 102}]} { error "bits_to_hex 102 accepted" }
    incr hextest::n
}

test::case "hex: round trip, 1..300 bits" {
    for {set n 1} {$n <= 300} {incr n} {
        set b {}
        for {set i 0} {$i < $n} {incr i} { append b [expr {int(rand() * 2)}] }
        test::eq [rvb::hex_to_bits [rvb::bits_to_hex $b] $n] $b "round trip $n"
        test::eq [string length [rvb::bits_to_hex $b]] [expr {($n + 3) / 4}] "digits for $n bits"
        incr hextest::n
    }
}

if {$test::fail == $hextest::fail0} {
    puts "=== HEX TEST PASS $hextest::n vectors"
} else {
    puts "=== HEX TEST FAIL"
}
