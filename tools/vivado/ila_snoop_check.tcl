# Is a chipset DMA write snoop ever LOST on its way into the AP68040?
#
#   vivado -mode batch -source tools/vivado/ila_snoop_check.tcl \
#          -tclargs <bitstream-dir> [samples] [gap-seconds]
#
# Needs a bitstream built with <ila> = 1 from a tree carrying TG68K.vhd's
# dbg_snoop (probe8 of ila_cpu040).  Two free-running counters ride that probe:
#
#   snp_in_cnt   (7:0)   every snoop the BUS offered,   counted on clk_114
#   snp_out_cnt (15:8)   every snoop the KERNEL saw,    counted on clk_38
#
# Both start at zero out of configuration and are never cleared, so at any
# instant  (in - out) mod 256  is the number of snoops that failed to cross --
# no waveform reasoning, one subtraction.  A steady difference of 0 or 1 is
# healthy (1 = a snoop in flight at the sampling instant, or the resync).  A
# difference that GROWS between samples is the defect
# (findings/ap68040/sdd-d3/d3-snoop-coherency.md).
#
# The counters are absolute, so this script does not care what the machine is
# doing or when the workload starts: take a sample, wait, take another, and the
# delta over that interval is the loss rate.
#
# Vivado 2023.2 needs libtinfo.so.5 on LD_LIBRARY_PATH and must NOT be given
# -stack.  wait_on_hw_ila -timeout is in MINUTES.
set dir     [lindex $argv 0]
set nsample [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20}]
set gap     [expr {[llength $argv] > 2 ? [lindex $argv 2] : 5}]

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
    if {[llength [get_hw_probes -quiet -of_objects $cand -filter {NAME =~ *dbg_snoop*}]]} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "=== NO dbg_snoop PROBE in this bitstream -- build the snoop tree with <ila> = 1 ==="
    close_hw_manager
    return
}
set snoop [get_hw_probes -of_objects $ila -filter {NAME =~ *dbg_snoop*}]

# Trigger on anything and keep the window after it, so a sample is taken the
# moment the ILA is armed whatever the machine is doing -- the counters are
# absolute and do not need a meaningful trigger.
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.CAPTURE_MODE ALWAYS $ila
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}
set_property TRIGGER_COMPARE_VALUE [format "eq41'b%s" [string repeat x 41]] $snoop

puts "=== snoop counters, $nsample samples ${gap}s apart -- RUN THE WORKLOAD NOW ==="
flush stdout

# Each sample is written as its own CSV and read back here.  Parsing Vivado's
# own CSV is the proven route in this repo (tools/vivado/ila_stall_burst.tcl);
# there is no supported Tcl accessor for an ILA probe's captured value.
set tmp [file join $dir snoopchk]
set prev_lost -1
for {set i 1} {$i <= $nsample} {incr i} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 1 $ila} e]} {
        puts "=== sample $i: no trigger within a minute, stopping ==="
        break
    }
    write_hw_ila_data -csv_file $tmp.csv -force [upload_hw_ila_data $ila]

    # Read the header for the dbg_snoop column, then the last data row.
    set fh [open $tmp.csv r]
    set hdr [split [string trim [gets $fh]] ","]
    set col -1
    for {set c 0} {$c < [llength $hdr]} {incr c} {
        if {[string match "*dbg_snoop*" [lindex $hdr $c]]} { set col $c ; break }
    }
    set last ""
    while {[gets $fh line] >= 0} { if {[string trim $line] ne ""} { set last $line } }
    close $fh
    if {$col < 0 || $last eq ""} {
        puts "=== sample $i: no dbg_snoop column in the CSV, stopping ==="
        break
    }
    # Vivado picks the CSV radix from the probe's DISPLAY_RADIX and writes HEX
    # by default; a probe left in BINARY writes 41 characters of 0/1/x.  Take
    # both rather than depend on a display property.
    set raw [string map {_ {} " " {} 0x {}} [lindex [split $last ","] $col]]
    if {[regexp {^[01]+$} $raw] && [string length $raw] == 41} {
        set val [expr 0b$raw]
    } elseif {[regexp {^[0-9a-fA-F]+$} $raw]} {
        set val [expr 0x$raw]
    } else {
        puts "=== sample $i: probe value '$raw' has unknown/undefined bits, skipping ==="
        continue
    }
    # dbg_snoop = addr(21:1) & 0 & cpu_ph2 & held & stb & out(7:0) & in(7:0)
    set in   [expr {$val & 0xff}]
    set out  [expr {($val >> 8) & 0xff}]
    set stb  [expr {($val >> 16) & 1}]
    set held [expr {($val >> 17) & 1}]
    set lost [expr {($in - $out) & 0xff}]
    set d ""
    if {$prev_lost >= 0} {
        set dl [expr {($lost - $prev_lost) & 0xff}]
        if {$dl > 127} { set dl [expr {$dl - 256}] }
        set d [format "   LOST since last sample: %+d" $dl]
    }
    puts [format "=== sample %2d  in %3d  out %3d  lost %3d  (stb %s held %s)%s" \
              $i $in $out $lost $stb $held $d]
    flush stdout
    set prev_lost $lost
    if {$i < $nsample} { after [expr {$gap * 1000}] }
}
puts "=== done ==="
close_hw_manager
