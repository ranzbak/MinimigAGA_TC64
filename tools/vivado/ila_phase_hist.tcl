# Read the chip-RAM acknowledge phase histogram (TG68K.vhd dbg_phist,
# ila_cpu040 probe9) while a workload runs.
#
#   vivado -mode batch -source tools/vivado/ila_phase_hist.tcl \
#          -tclargs <bitstream-dir> <out-prefix> [samples] [gap-seconds]
#
# The RTL snapshots the histogram every 2**22 clk cycles (~37 ms) and holds it,
# so ONE sample is one complete window; this takes <samples> of them <gap> s
# apart and writes each as a CSV.  Decode with tools/vivado/phase_hist.py.
#
# Build the same tree at CPU_CLK_DIVIDE 30 (ratio 3, corrupts) and 40 (ratio 4,
# clean), run the same demo on each, and compare.
#
# Vivado 2023.2 needs libtinfo.so.5 on LD_LIBRARY_PATH, must NOT be given
# -stack, wants LC_ALL=C next to other Xilinx tools; wait_on_hw_ila -timeout is
# in MINUTES.
set dir     [lindex $argv 0]
set out     [lindex $argv 1]
set nsample [expr {[llength $argv] > 2 ? [lindex $argv 2] : 10}]
set gap     [expr {[llength $argv] > 3 ? [lindex $argv 3] : 3}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
refresh_hw_device $dev

set ila {}
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_phist*}]]} {
        set ila $cand; break
    }
}
if {$ila eq ""} {
    puts "=== NO dbg_phist PROBE in this bitstream ==="
    close_hw_manager; return
}
set hist [get_hw_probes -of_objects $ila -filter {NAME =~ *dbg_phist*}]

set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
# trigger on anything: the histogram is a held snapshot, any instant will do
set_property TRIGGER_COMPARE_VALUE [format "eq384'b%s" [string repeat x 384]] $hist

puts "=== phase histogram: $nsample samples ${gap}s apart -- RUN THE WORKLOAD NOW ==="
flush stdout
for {set i 1} {$i <= $nsample} {incr i} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} e]} {
        puts "=== sample $i: no trigger within a minute, stopping ==="; break
    }
    write_hw_ila_data -csv_file [format "%s_%02d.csv" $out $i] -force [upload_hw_ila_data $ila]
    puts "=== sample $i written ==="
    flush stdout
    if {$i < $nsample} { after [expr {$gap * 1000}] }
}
puts "=== done ==="
close_hw_manager
