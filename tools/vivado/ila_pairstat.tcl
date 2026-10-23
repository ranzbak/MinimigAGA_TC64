# Read the faster core's dual-issue counters (ap68040_minimig.sv PSTAT) off
# ila_cpu040's dbg_phist probe while the machine runs a workload.
#
#   vivado -mode batch -nolog -nojournal -source tools/vivado/ila_pairstat.tcl \
#          -tclargs <bitstream-dir> <out-prefix> [snapshots 2] [interval-s 20] [sample-runs 4]
#
# Writes <out-prefix>_c<i>.csv: one immediate capture per snapshot, <interval>
# seconds apart (the counters wrap in 75 s: keep the interval below that),
# then <out-prefix>_s<i>.csv: captures that store only the clocks the sampler
# strobes (dbg_phist[383]), one in 4096 slow / not-slot-2 / split events.
# tools/pairstat.py <out-prefix> turns them into rates and histograms.
#
# The bitstream is not programmed: run this against the image already on
# the board (build_ap040.tcl with <ila> = 1 and the bridge's PSTAT = 1).
set dir   [lindex $argv 0]
set out   [lindex $argv 1]
set nsnap [expr {[llength $argv] > 2 ? [lindex $argv 2] : 2}]
set ival  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 20}]
set nsamp [expr {[llength $argv] > 4 ? [lindex $argv 4] : 4}]

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
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_flags*}]]} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "=== NO CPU ILA in this bitstream ==="
    close_hw_manager
    return
}
proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]

proc grab {ila file} {
    run_hw_ila $ila
    wait_on_hw_ila -timeout 2 $ila
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -csv_file $file -force $data
}

# the counters: any one sample will do
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
for {set i 0} {$i < $nsnap} {incr i} {
    if {$i > 0} { after [expr {$ival * 1000}] }
    grab $ila ${out}_c$i.csv
    puts "=== snapshot $i at [clock format [clock seconds] -format %H:%M:%S] ==="
    flush stdout
}

# the samples: only the sampler's strobe clocks are stored
set_property CONTROL.CAPTURE_MODE BASIC $ila
set_property CAPTURE_COMPARE_VALUE "eq384'b1[string repeat X 383]" [pr $ila *dbg_phist*]
for {set i 0} {$i < $nsamp} {incr i} {
    grab $ila ${out}_s$i.csv
    puts "=== sample run $i at [clock format [clock seconds] -format %H:%M:%S] ==="
    flush stdout
    after 3000
}
close_hw_manager
