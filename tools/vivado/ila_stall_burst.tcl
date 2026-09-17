# Burst stall capture: open ONE hardware session and take N windows back to
# back, so a benchmark that only runs for a few seconds can still be sampled.
#
#   vivado -mode batch -source tools/vivado/ila_stall_burst.tcl \
#          -tclargs <bitstream-dir> <out-prefix> [count] [mode]
#
# Opening a hw session costs ~25 s; arming, waiting and uploading inside an
# open one costs well under a second, so <count> windows land inside a short
# run instead of one window landing wherever the session happened to finish.
# Each window is 4096 clk_114 samples = 36.1 us.
#
# <mode> busy (default) triggers on the CPU wanting the bus, which is what a
# stall measurement needs -- an idle Amiga sits in STOP with no bus cycles at
# all and an untriggered capture measures nothing.  <mode> fast triggers only
# on an access to Zorro III fast RAM ($40000000 and up), which skips chipset
# traffic and is the one to use when judging CPU-side work: see the
# 2026-09-09 log in findings/ap68040/plan-v2-with-ddr3.md for why a demo is
# the wrong benchmark for that.
#
# Needs a bitstream built with CPU040_DEBUG_ILA=1.  Read the CSVs with
# findings/ap68040/sdd-2026-09-09/stall_stats.py.
#
# Vivado 2023.2 needs libtinfo.so.5 on LD_LIBRARY_PATH and must NOT be given
# -stack.  wait_on_hw_ila -timeout is in MINUTES.
set dir    [lindex $argv 0]
set out    [lindex $argv 1]
set count  [expr {[llength $argv] > 2 ? [lindex $argv 2] : 16}]
set mode   [expr {[llength $argv] > 3 ? [lindex $argv 3] : "busy"}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE      $dir/minimig_openaars_top.ltx $dev
set_property FULL_PROBES.FILE $dir/minimig_openaars_top.ltx $dev
refresh_hw_device $dev

# Pick the CPU core by a probe only it has; the ILA instances are named
# hw_ila_1/2 with no hierarchy in the name.
set ila {}
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_flags*}]]} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "=== NO CPU ILA in this bitstream -- build with <ila> = 1 ==="
    close_hw_manager
    return
}
proc pr {ila pat} { return [get_hw_probes -of_objects $ila -filter "NAME =~ $pat"] }

set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 16 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
if {$mode eq "now"} {
    # Trigger on anything and keep the whole window after it, so the 4096
    # samples are an UNBIASED run of consecutive clocks.  This is the mode for
    # measuring a rate -- what fraction of clocks the core advances -- because
    # busy/fast both start their window at an access and would over-represent
    # the cycles that follow one.
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property TRIGGER_COMPARE_VALUE {eq4'bxxxx} [pr $ila *dbg_flags*]
} elseif {$mode eq "fast"} {
    # any access whose address is in the Zorro III window, i.e. fast RAM
    set_property TRIGGER_COMPARE_VALUE {eq32'b01000xxxxxxxxxxxxxxxxxxxxxxxxxxx} [pr $ila *tg68_adr*]
} else {
    # tg68_ram_hs[0]: the CPU is using a bus (cpustate[1:0] /= "01" before E2)
    set_property TRIGGER_COMPARE_VALUE {eq7'bxxxxxx1} [pr $ila *tg68_ram_hs*]
}

puts "=== armed at [clock format [clock seconds] -format %H:%M:%S], $count windows, mode $mode -- START THE WORKLOAD NOW ==="
flush stdout
set got 0
for {set i 1} {$i <= $count} {incr i} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} e]} {
        puts "=== window $i: no trigger within a minute, stopping ==="
        break
    }
    write_hw_ila_data -csv_file [format "%s_%02d.csv" $out $i] -force [upload_hw_ila_data $ila]
    incr got
}
puts "=== $got windows written to ${out}_NN.csv ([expr {$got * 36.1}] us total) ==="
close_hw_manager
