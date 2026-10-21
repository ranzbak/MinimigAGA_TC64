# jtag_probe2.tcl: isolate why rvb::raw_self_test fails where the global sequence works
proc P {msg} { puts "PROBE: $msg"; flush stdout }
proc G {} {
    run_state_hw_jtag RESET; run_state_hw_jtag IDLE
    set ir [scan_ir_hw_jtag 6 -tdi 09]; set dr [scan_dr_hw_jtag 32 -tdi 00000000]
    P "    scans ir=$ir dr=$dr"
    run_state_hw_jtag RESET
}
namespace eval nsx {}
proc nsx::N {} {
    run_state_hw_jtag RESET; run_state_hw_jtag IDLE
    set ir [scan_ir_hw_jtag 6 -tdi 09]; set dr [scan_dr_hw_jtag 32 -tdi 00000000]
    P "    scans ir=$ir dr=$dr"
    run_state_hw_jtag RESET
}
proc tryit {name cmd} {
    set rc [catch {uplevel #0 $cmd} r]
    P "$name: [expr {$rc ? "ERROR: [string map {"\n" " | "} $r]" : "ok '$r'"}]"
    if {$rc} { catch {run_state_hw_jtag RESET} r2; P "    recovery RESET -> $r2" }
}
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets] 0]
current_hw_target $t
open_hw_target -jtag_mode on $t
P "target open"
tryit "A global proc G" G
tryit "B namespace proc nsx::N" nsx::N
tryit "C rvb::raw_self_test" rvb::raw_self_test
tryit "D global proc G again" G
P "E: rvb::raw_self_test pieces, global, with the bridge's hex helpers"
tryit "E1 bits_to_hex IR" {rvb::bits_to_hex [rbb::int_to_bits 0x09 6]}
tryit "E2 bits_to_hex DR" {rvb::bits_to_hex [string repeat 0 32]}
tryit "E3 seq with helper hex" {run_state_hw_jtag RESET; run_state_hw_jtag IDLE; scan_ir_hw_jtag 6 -tdi [rvb::bits_to_hex [rbb::int_to_bits 0x09 6]]; scan_dr_hw_jtag 32 -tdi [rvb::bits_to_hex [string repeat 0 32]]; run_state_hw_jtag RESET}
P "end"
catch {close_hw_target}
catch {disconnect_hw_server}
close_hw_manager
