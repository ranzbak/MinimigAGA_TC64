# probe5: open_hw_manager + connect_hw_server inside a proc (as rvb::main does) vs at global level
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
proc P {m} { puts "PROBE5: $m"; flush stdout }
proc rvb::full_open {} {
    open_hw_manager
    connect_hw_server -url localhost:3121
    set ts [get_hw_targets -quiet *]; set t [lindex $ts 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
}
proc chk {name} {
    set rc [catch {rvb::raw_self_test} r]
    P "$name: raw_self_test -> [expr {$rc ? "ERROR: $r" : "ok $r"}]"
    catch {close_hw_target}; catch {disconnect_hw_server}; catch {close_hw_manager}
}
P "--- A global open"
open_hw_manager; connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
chk A
P "--- B open inside proc rvb::full_open"
if {[catch {rvb::full_open} e]} { P "B open error $e" } else { chk B }
P "--- C global open again"
open_hw_manager; connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
chk C
P end
