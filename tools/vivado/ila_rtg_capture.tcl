# Capture every Akiko access (dbg_rtg, ila_cpu040 probe9) while Paul activates
# an RTG screen mode. Storage qualification keeps only samples with akiko_req
# high, so the 1024-deep window holds 1024 register accesses, not idle clocks.
#
#   vivado -mode batch -source tools/vivado/ila_rtg_capture.tcl \
#          -tclargs <bitstream-dir> <out.csv> [timeout-minutes]
#
# Decode with tools/vivado/rtg_decode.py. Vivado 2023.2: libtinfo shim, no
# -stack, LC_ALL=C; wait_on_hw_ila -timeout is in MINUTES.
# Stage E0, findings/ap68040/stage-e/2026-09-15-e0-e1-plan.md Task 7.
set dir     [lindex $argv 0]
set out     [lindex $argv 1]
set timeout [expr {[llength $argv] > 2 ? [lindex $argv 2] : 5}]
# Capture mode (4th -tclargs):
#   always  (default) every sample from the trigger on, trigger at position 64.
#           One Akiko access completes the 1024-sample window in ~9 ms, so a
#           driver that only reads the ID register still gives data.
#   qual    storage-qualified on akiko_req: the window holds 1024 Akiko
#           accesses.  Only for a busy mode switch -- with a few accesses the
#           window never fills, and Vivado discards an unfilled window as "No
#           data to upload" even when it DID trigger (three empty captures on
#           2026-09-15 could not tell "no access" from "a few accesses").
set mode    [expr {[llength $argv] > 3 ? [lindex $argv 3] : "always"}]
if {$mode ne "always" && $mode ne "qual"} { puts "=== mode must be always or qual, not $mode ==="; return }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
refresh_hw_device $dev

# Pick the ILA by its cell name.  Looping over the ILAs and asking each for a
# probe by name is NOT safe: on 2026-09-15 that test matched hw_ila_1, the
# fast-RAM ILA, which was armed for 15 minutes and uploaded nothing.
set ila [get_hw_ilas -quiet -of_objects $dev -filter {CELL_NAME =~ *ila_cpu040*}]
if {[llength $ila] != 1} {
    puts "=== NO single ila_cpu040 in this bitstream (ILAs: [get_property CELL_NAME [get_hw_ilas -quiet -of_objects $dev]]) ==="
    close_hw_manager; return
}
set rtg [get_hw_probes -quiet -of_objects $ila -filter {NAME =~ *dbg_rtg*}]
if {[llength $rtg] != 1} { puts "=== NO dbg_rtg PROBE on ila_cpu040 in this bitstream ==="; close_hw_manager; return }
puts "=== using [get_property CELL_NAME $ila] ($ila), trigger probe [get_property NAME $rtg] ==="

foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set req_only [format "eq32'b1%s" [string repeat x 31]]
set_property CONTROL.WINDOW_COUNT      1 $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property TRIGGER_COMPARE_VALUE $req_only $rtg
if {$mode eq "qual"} {
    set_property CONTROL.TRIGGER_POSITION  0 $ila
    set_property CONTROL.CAPTURE_MODE      BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION AND $ila
    set_property CAPTURE_COMPARE_VALUE $req_only $rtg
} else {
    set_property CONTROL.TRIGGER_POSITION  64 $ila
    set_property CONTROL.CAPTURE_MODE      ALWAYS $ila
}
puts "=== capture mode $mode ==="

puts "=== armed: ACTIVATE AN RTG SCREEN MODE NOW (timeout $timeout min) ==="
flush stdout
run_hw_ila $ila
if {[catch {wait_on_hw_ila -timeout $timeout $ila} e]} {
    puts "=== window not full after $timeout min; uploading what was stored ==="
}
write_hw_ila_data -csv_file $out -force [upload_hw_ila_data $ila]
puts "=== written: $out ==="
close_hw_manager
