# probe6: rvb::main's body up to and including raw_self_test, as a copy, then variants
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
proc P {m} { puts "PROBE6: $m"; flush stdout }
proc rvb::mainA {argv selftest_call} {
    set port [opt $argv port RBB_PORT 33582]
    set url  [opt $argv url HW_SERVER_URL localhost:3121]
    set xvc  [opt $argv xvc_url XVC_URL {}]
    set pat  [opt $argv target TARGET *]
    set freq [opt $argv freq JTAG_FREQ {}]
    set ra [opt $argv idcode_readahead {} 1]
    rbb::log "rvb: mainA"
    open_hw_manager
    connect_hw_server -url $url
    set ts [get_hw_targets -quiet $pat]
    set t [lindex $ts 0]
    current_hw_target $t
    open_hw_target -jtag_mode on $t
    set f {}
    catch {set f [get_property PARAM.FREQUENCY $t]}
    rbb::log "rvb: target $t open in JTAG mode, PARAM.FREQUENCY $f"
    rbb::configure -backend ::vbe -idcode_readahead $ra
    return [uplevel 0 $selftest_call]
}
proc closeall {} { catch {close_hw_target}; catch {disconnect_hw_server}; catch {close_hw_manager} }
foreach {name call} {
    "1 mainA + raw_self_test" {raw_self_test}
    "2 mainA + raw_self_test again" {raw_self_test}
    "3 mainA + inline seq" {run_state_hw_jtag RESET; run_state_hw_jtag IDLE; scan_ir_hw_jtag 6 -tdi 09; scan_dr_hw_jtag 32 -tdi 00000000; run_state_hw_jtag RESET}
} {
    P "--- $name"
    set rc [catch {rvb::mainA {} $call} r]
    P "  -> [expr {$rc ? "ERROR: $r" : "ok $r"}]"
    closeall
}
P end
