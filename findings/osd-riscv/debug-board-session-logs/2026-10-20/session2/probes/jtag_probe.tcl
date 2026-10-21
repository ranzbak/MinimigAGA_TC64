# jtag_probe.tcl: which run_state_hw_jtag forms work after scans (read-only JTAG: IDCODE/BYPASS only)
proc P {msg} { puts "PROBE: $msg"; flush stdout }
proc T {cmd} {
    set rc [catch {uplevel #0 $cmd} r]
    if {$rc} { P "  \[$cmd\] -> ERROR: [string map {"\n" " | "} $r]" } else { P "  \[$cmd\] -> ok '$r'" }
    return $rc
}
proc prelude {{what both}} {
    T {run_state_hw_jtag RESET}
    T {run_state_hw_jtag IDLE}
    if {$what in {both ir}} { T {scan_ir_hw_jtag 6 -tdi 09} }
    if {$what in {both dr}} { T {scan_dr_hw_jtag 32 -tdi 00000000} }
}
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets] 0]
current_hw_target $t
open_hw_target -jtag_mode on $t
P "target $t open, PARAM.FREQUENCY [get_property PARAM.FREQUENCY $t]"
catch { P "hw_jtag objects: [get_hw_jtags]" }
P "V0 control: RESET, IDLE, RESET without scans"
T {run_state_hw_jtag RESET}; T {run_state_hw_jtag IDLE}; T {run_state_hw_jtag RESET}
P "V1 plain: prelude, run_state_hw_jtag RESET"
prelude; T {run_state_hw_jtag -verbose RESET}
P "V2 explicit path: prelude, run_state_hw_jtag -state {IDLE DRSELECT IRSELECT RESET} RESET"
prelude; T {run_state_hw_jtag -verbose -state {IDLE DRSELECT IRSELECT RESET} RESET}
P "V2b explicit path without leading IDLE: -state {DRSELECT IRSELECT RESET} RESET"
prelude; T {run_state_hw_jtag -verbose -state {DRSELECT IRSELECT RESET} RESET}
P "V3 via IDLE: prelude, run_state_hw_jtag IDLE, then RESET"
prelude; T {run_state_hw_jtag -verbose IDLE}; T {run_state_hw_jtag -verbose RESET}
P "V4 to DRPAUSE: prelude, run_state_hw_jtag DRPAUSE, then IRPAUSE, IDLE, RESET"
prelude; T {run_state_hw_jtag -verbose DRPAUSE}; T {run_state_hw_jtag -verbose IRPAUSE}; T {run_state_hw_jtag -verbose IDLE}; T {run_state_hw_jtag -verbose RESET}
P "V5 IR scan only, then RESET"
prelude ir; T {run_state_hw_jtag -verbose RESET}
P "V6 DR scan only, then RESET"
prelude dr; T {run_state_hw_jtag -verbose RESET}
P "V7 runtest after scans: runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 8, then RESET"
prelude; T {runtest_hw_jtag -wait_state IDLE -end_state IDLE -tck 8}; T {run_state_hw_jtag -verbose RESET}
P "V8 pause-state scans (bridge core style): RESET, DRPAUSE, scan_dr 32, scan_dr 32, IDLE, RESET"
T {run_state_hw_jtag RESET}; T {run_state_hw_jtag DRPAUSE}; T {scan_dr_hw_jtag 32 -tdi 00000000}; T {scan_dr_hw_jtag 32 -tdi 00000000}; T {run_state_hw_jtag IDLE}; T {run_state_hw_jtag RESET}
P "end"
catch {close_hw_target}
catch {disconnect_hw_server}
close_hw_manager
