# probe8: every goto form the bridge core emits, -state path vs plain, and whether plain gotos capture
proc P {m} { puts "PROBE8: $m"; flush stdout }
proc T {c} {
    set rc [catch {uplevel #0 $c} r]
    P "  \[$c\] -> [expr {$rc ? "ERROR" : "ok '$r'"}]"
    return $rc
}
proc from {st} {
    # bring the TAP to stable state st with plain (documented default) transitions
    run_state_hw_jtag RESET
    switch $st { RESET {} IDLE { run_state_hw_jtag IDLE } default { run_state_hw_jtag IDLE; run_state_hw_jtag $st } }
}
open_hw_manager
connect_hw_server -url localhost:3121
set t [lindex [get_hw_targets -quiet *] 0]; current_hw_target $t; open_hw_target -jtag_mode on $t
P "=== A: -state paths (as rbb::Emit builds them) and the plain form, per start state"
foreach {st target path} {
    RESET   IDLE    {IDLE}
    IDLE    IRPAUSE {DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
    IDLE    DRPAUSE {DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
    DRPAUSE IDLE    {DREXIT2 DRUPDATE IDLE}
    IRPAUSE IDLE    {IREXIT2 IRUPDATE IDLE}
    DRPAUSE DRPAUSE {DREXIT2 DRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
    IRPAUSE DRPAUSE {IREXIT2 IRUPDATE DRSELECT DRCAPTURE DREXIT1 DRPAUSE}
    DRPAUSE IRPAUSE {DREXIT2 DRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
    IRPAUSE IRPAUSE {IREXIT2 IRUPDATE DRSELECT IRSELECT IRCAPTURE IREXIT1 IRPAUSE}
} {
    P "$st -> $target"
    from $st; T [list run_state_hw_jtag -state $path $target]
    from $st; T [list run_state_hw_jtag $target]
}
P "=== B: does a plain goto capture? (IR capture 0x35; IDCODE 13631093; BYPASS)"
from RESET
T {run_state_hw_jtag IDLE}
T {run_state_hw_jtag IRPAUSE}
T {scan_ir_hw_jtag 6 -tdi 2a}
P "  (expect '35' = captured on the way to IRPAUSE)"
T {scan_ir_hw_jtag 6 -tdi 3f}
P "  (scan from IRPAUSE again without a goto: expect '2a' = no capture, shifted value back)"
T {run_state_hw_jtag IRPAUSE}
T {scan_ir_hw_jtag 6 -tdi 3f}
P "  (IRPAUSE -> IRPAUSE plain then scan: '35' = recaptured, '3f' = not)"
P "  -> BYPASS is now in IR (3f, updated by the IRPAUSE->IRPAUSE goto if it passed IRUPDATE)"
T {run_state_hw_jtag DRPAUSE}
T {scan_dr_hw_jtag 8 -tdi a5}
P "  (BYPASS, captured 0: expect 4a = a5 delayed one bit, first bit out 0 -> bits 0..7 = 0,1,0,1,0,0,1,0 -> 0x4a)"
T {scan_dr_hw_jtag 8 -tdi 00}
P "  (no goto: continues the same shift: expect 01 or 00 + the last bit of a5 = 1 -> 0x01)"
T {run_state_hw_jtag DRPAUSE}
T {scan_dr_hw_jtag 8 -tdi a5}
P "  (DRPAUSE -> DRPAUSE plain: capture loads 0 -> 4a again; no capture -> carries the bit left in BYPASS)"
P "=== C: IDCODE through plain gotos"
from RESET
T {run_state_hw_jtag IDLE}
T {run_state_hw_jtag IRPAUSE}
T {scan_ir_hw_jtag 6 -tdi 09}
T {run_state_hw_jtag DRPAUSE}
T {scan_dr_hw_jtag 32 -tdi 00000000}
T {run_state_hw_jtag IDLE}
T {run_state_hw_jtag RESET}
P end
catch {close_hw_target}; catch {disconnect_hw_server}; close_hw_manager
