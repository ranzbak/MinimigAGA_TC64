# probe4: bisect rvb::main's open sequence; each variant opens, runs rvb::raw_self_test, closes
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
proc P {m} { puts "PROBE4: $m"; flush stdout }
proc run {name body} {
    P "--- $name"
    set rc [catch {uplevel #0 $body} r]
    if {$rc} { P "  open-part ERROR: $r"; return }
    set rc [catch {rvb::raw_self_test} r]
    P "  raw_self_test -> [expr {$rc ? "ERROR: $r" : "ok $r"}]"
    catch {close_hw_target} r; P "  close_hw_target -> $r"
}
open_hw_manager
connect_hw_server -url localhost:3121
run "V1 control (get_hw_targets, current, open)" {
    set t [lindex [get_hw_targets] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t }
run "V2 get_hw_targets -quiet *" {
    set ts [get_hw_targets -quiet *]; set t [lindex $ts 0]; current_hw_target $t; open_hw_target -jtag_mode on $t }
run "V3 V2 + catch get_property PARAM.FREQUENCY" {
    set ts [get_hw_targets -quiet *]; set t [lindex $ts 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
    set f {}; catch {set f [get_property PARAM.FREQUENCY $t]} }
run "V4 V3 + rbb::configure -backend ::vbe -idcode_readahead 1" {
    set ts [get_hw_targets -quiet *]; set t [lindex $ts 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
    set f {}; catch {set f [get_property PARAM.FREQUENCY $t]}; rbb::configure -backend ::vbe -idcode_readahead 1 }
namespace eval rvb {}
proc rvb::open_like_main {} {
    set ts [get_hw_targets -quiet *]; set t [lindex $ts 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
    set f {}; catch {set f [get_property PARAM.FREQUENCY $t]}
    rbb::log "rvb: target $t open in JTAG mode, PARAM.FREQUENCY $f"
    rbb::configure -backend ::vbe -idcode_readahead 1
}
run "V5 open inside proc rvb::open_like_main" { rvb::open_like_main }
run "V6 control again" {
    set t [lindex [get_hw_targets] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t }
P end
catch {disconnect_hw_server}
close_hw_manager
