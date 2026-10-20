# probe9: TAP state after a scan that starts in a pause state; can a DR shift continue across scans?
proc P {m} { puts "PROBE9: $m"; flush stdout }
proc T {c} {
    set rc [catch {uplevel #0 $c} r]
    P "  \[$c\] -> [expr {$rc ? "ERROR" : "ok '$r'"}]"
}
proc setup_bypass {} {
    run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
    scan_ir_hw_jtag 6 -tdi 3f
    run_state_hw_jtag DRPAUSE
}
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
P "1 after a DR scan from DRPAUSE: is the TAP in DRPAUSE? (path from DRPAUSE accepted)"
setup_bypass; T {scan_dr_hw_jtag 8 -tdi a5}; T {run_state_hw_jtag -state {DREXIT2 DRUPDATE IDLE} IDLE}
P "2 same: is it in IDLE? (one-TCK IDLE path accepted only from IDLE/RESET)"
setup_bypass; T {scan_dr_hw_jtag 8 -tdi a5}; T {run_state_hw_jtag -state {IDLE} IDLE}
P "3 same, then DREXIT2 DRSHIFT? (-state into a shift state)"
setup_bypass; T {scan_dr_hw_jtag 8 -tdi a5}; T {run_state_hw_jtag -state {DREXIT2 DRSHIFT DREXIT1 DRPAUSE} DRPAUSE}; T {scan_dr_hw_jtag 8 -tdi 00}
P "4 IR: after run_state IRPAUSE + scan_ir, where is the TAP? (path from IRPAUSE)"
run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
T {scan_ir_hw_jtag 6 -tdi 09}; T {run_state_hw_jtag -state {IREXIT2 IRUPDATE IDLE} IDLE}
P "5 IR: scan then the one-TCK IDLE path"
run_state_hw_jtag RESET; run_state_hw_jtag IDLE; run_state_hw_jtag IRPAUSE
T {scan_ir_hw_jtag 6 -tdi 09}; T {run_state_hw_jtag -state {IDLE} IDLE}
P "6 three DR scans in a row from DRPAUSE, BYPASS, a5/ff/00 (no capture between would give 4a, 01|fe.., ...)"
setup_bypass; T {scan_dr_hw_jtag 8 -tdi a5}; T {scan_dr_hw_jtag 8 -tdi ff}; T {scan_dr_hw_jtag 8 -tdi 00}
P "7 scan_dr directly from IDLE, end state after it"
run_state_hw_jtag RESET; run_state_hw_jtag IDLE
T {scan_dr_hw_jtag 32 -tdi 00000000}; T {run_state_hw_jtag -state {IDLE} IDLE}
P end
catch {close_hw_target}; catch {disconnect_hw_server}; close_hw_manager
