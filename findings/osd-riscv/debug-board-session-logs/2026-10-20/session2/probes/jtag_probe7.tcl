# probe7: trace every back-end call of rbb::self_test against real Vivado
set ::env(RVBRIDGE_NO_MAIN) 1
source -notrace /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
proc P {m} { puts "PROBE7: $m"; flush stdout }
foreach p {be_reset be_goto be_idle be_scan} {
    rename vbe::$p vbe::${p}_orig
    proc vbe::$p {args} [string map [list @P@ $p] {
        set rc [catch {vbe::@P@_orig {*}$args} r]
        P "  @P@ $args -> [expr {$rc ? "ERROR: [string map {"\n" " | "} $r]" : "ok '$r'"}]"
        if {$rc} { return -code error $r }
        return $r
    }]
}
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
rbb::configure -backend ::vbe -idcode_readahead 1
P "raw: [rvb::raw_self_test]"
set rc [catch {rbb::self_test} r]
P "rbb::self_test -> [expr {$rc ? "ERROR: $r" : "ok $r"}]"
catch {run_state_hw_jtag RESET} r; P "recovery RESET -> $r"
P "--- single calls"
foreach c {
    {run_state_hw_jtag RESET}
    {run_state_hw_jtag -state {IDLE} IDLE}
    {run_state_hw_jtag RESET}
    {run_state_hw_jtag -state {RESET IDLE} IDLE}
    {run_state_hw_jtag RESET}
    {run_state_hw_jtag IDLE}
    {run_state_hw_jtag -state {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE} IRPAUSE}
    {run_state_hw_jtag RESET}
    {run_state_hw_jtag IDLE}
    {run_state_hw_jtag -state {IDLE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE} IRPAUSE}
    {run_state_hw_jtag RESET}
} {
    set rc [catch {uplevel #0 $c} r]
    P "  \[$c\] -> [expr {$rc ? "ERROR: [string map {"\n" " | "} $r]" : "ok '$r'"}]"
}
P end
catch {close_hw_target}; catch {disconnect_hw_server}; close_hw_manager
