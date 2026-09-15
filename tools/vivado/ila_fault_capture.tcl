# Capture the AP68040 around a FATAL HALT: trigger when dbg_flags bit 3
# (ap040_fault) is set, record every sample (ila_cpu040: dbg_pc, dbg_ir, the bus
# signals, dbg_flags) with the trigger near the start of the window.
#
#   vivado -mode batch -source tools/vivado/ila_fault_capture.tcl \
#          -tclargs <bitstream-dir> <out.csv> [timeout-minutes]
#
# WHAT IT DOES NOT SEE: an ordinary access error.  ap040_fault is the core's
# debug_fault = fault_r, and fault_r is set only in ap040_core.v's fatal_halt
# task (the double-fault path into S_HALT).  An MMU access error goes through
# aerr_start instead: it latches aer_fa (debug_status2[127:96], the wrapper's
# dbg_fault_addr) and exception vector 2 (dbg_exc_vec), and never touches
# fault_r.  Neither of those is on ila_cpu040 as of Stage E4a, so catching an
# access error needs a build that probes them.  (Found 2026-09-15 after a
# quiet 10-minute window during the RTG diagnosis proved nothing.)
# dbg_flags = {fault (fatal halt), in_exc, halted, busy} (TG68K.vhd).
# Vivado 2023.2: libtinfo shim, no -stack, LC_ALL=C; timeouts are in MINUTES.
set dir     [lindex $argv 0]
set out     [lindex $argv 1]
set timeout [expr {[llength $argv] > 2 ? [lindex $argv 2] : 10}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
refresh_hw_device $dev

# Pick the ILA by cell name; a probe-name test once armed the fast-RAM ILA.
set ila [get_hw_ilas -quiet -of_objects $dev -filter {CELL_NAME =~ *ila_cpu040*}]
if {[llength $ila] != 1} {
    puts "=== NO single ila_cpu040 in this bitstream (ILAs: [get_property CELL_NAME [get_hw_ilas -quiet -of_objects $dev]]) ==="
    close_hw_manager; return
}
set flags [get_hw_probes -quiet -of_objects $ila -filter {NAME =~ *dbg_flags*}]
if {[llength $flags] != 1} { puts "=== NO dbg_flags PROBE on ila_cpu040 ==="; close_hw_manager; return }
puts "=== using [get_property CELL_NAME $ila] ($ila), trigger probe [get_property NAME $flags] ==="

foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set_property CONTROL.WINDOW_COUNT      1 $ila
set_property CONTROL.TRIGGER_POSITION  64 $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.CAPTURE_MODE      ALWAYS $ila
set_property TRIGGER_COMPARE_VALUE {eq4'b1xxx} $flags

puts "=== armed: waiting for an AP68040 fault (timeout $timeout min) ==="
flush stdout
run_hw_ila $ila
if {[catch {wait_on_hw_ila -timeout $timeout $ila} e]} {
    puts "=== no fault within $timeout min ==="
    close_hw_manager; return
}
write_hw_ila_data -csv_file $out -force [upload_hw_ila_data $ila]
puts "=== written: $out ==="
close_hw_manager
