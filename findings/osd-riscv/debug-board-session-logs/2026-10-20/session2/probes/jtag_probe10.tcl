# probe10: runtest_hw_jtag -end_state <pause> as the scan end state; shift continuation; no capture on re-entry
proc P {m} { puts "PROBE10: $m"; flush stdout }
proc T {c} {
    set rc [catch {uplevel #0 $c} r]
    P "  \[$c\] -> [expr {$rc ? "ERROR: [string map {"\n" " | "} $r]" : "ok '$r'"}]"
}
proc setup_bypass {} {
    runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 1
    run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
    scan_ir_hw_jtag 6 -tdi 3f
    run_state_hw_jtag DRPAUSE
}
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
P "a: in DRPAUSE (captured), runtest -wait DRPAUSE -end DRPAUSE -tck 0, scans a5 then 00 (continuation: 4a, 01)"
setup_bypass
T {runtest_hw_jtag -wait_state DRPAUSE -end_state DRPAUSE -tck 0}
T {scan_dr_hw_jtag 8 -tdi a5}; T {scan_dr_hw_jtag 8 -tdi 00}
T {run_state_hw_jtag -state {DREXIT2 DRUPDATE IDLE} IDLE}
P "b: same with -tck 1"
setup_bypass
T {runtest_hw_jtag -wait_state DRPAUSE -end_state DRPAUSE -tck 1}
T {scan_dr_hw_jtag 8 -tdi a5}; T {scan_dr_hw_jtag 8 -tdi 00}
P "c: runtest -wait DRPAUSE -end DRPAUSE between two scans (re-entry must not capture: 4a, then 01)"
setup_bypass
T {runtest_hw_jtag -wait_state DRPAUSE -end_state DRPAUSE -tck 0}
T {scan_dr_hw_jtag 8 -tdi a5}
T {runtest_hw_jtag -wait_state DRPAUSE -end_state DRPAUSE -tck 0}
T {scan_dr_hw_jtag 8 -tdi 00}
P "d: IR in IRPAUSE: runtest -wait IRPAUSE -end IRPAUSE -tck 0; scans 2a then 3f (35, then 2a = continued)"
runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 1
run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
T {runtest_hw_jtag -wait_state IRPAUSE -end_state IRPAUSE -tck 0}
T {scan_ir_hw_jtag 6 -tdi 2a}; T {scan_ir_hw_jtag 6 -tdi 3f}
T {run_state_hw_jtag -state {IREXIT2 IRUPDATE IDLE} IDLE}
P "e: IDCODE with pause end states: IR 09 ends IRPAUSE, -> DRPAUSE (update+capture), DR 32 ends DRPAUSE, -> IDLE"
runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 1
run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
T {runtest_hw_jtag -wait_state IRPAUSE -end_state IRPAUSE -tck 0}
T {scan_ir_hw_jtag 6 -tdi 09}
T {run_state_hw_jtag -state {IREXIT2 IRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE} DRPAUSE}
T {runtest_hw_jtag -wait_state DRPAUSE -end_state DRPAUSE -tck 0}
T {scan_dr_hw_jtag 16 -tdi 0000}; T {scan_dr_hw_jtag 16 -tdi 0000}
T {run_state_hw_jtag -state {DREXIT2 DRUPDATE IDLE} IDLE}
T {runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 4}
P end
catch {close_hw_target}; catch {disconnect_hw_server}; close_hw_manager
