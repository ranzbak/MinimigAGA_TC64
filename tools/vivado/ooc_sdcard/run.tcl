# run.tcl -- size and timing of the SD card engine (plan Task 8 step 5, the gate):
# rtl/host/sdcard_spi.v + rtl/minimig/sdcard_gayle.v (bridge and mux) in the
# wrapper ooc_sdcard_top.v, synthesised, placed and routed on their own.
#
#   vivado -mode batch -source run.tcl -tclargs <outdir> <ooc|io> [<t114 ns>] [<t28 ns>]
#
# Run it through go.sh (libtinfo shim, no -stack).
#
#   ooc  out of context (-mode out_of_context): the gate numbers.  clk_g =
#        clk_114 and clk = clk_28 as the board has them: related clocks, edges
#        aligned, clk_28 = clk_114 / 4, with wizard.xdc's 1:4 multicycles
#        between them (the board's rule for every dll_28 <-> clk_114 path).
#        Default periods 8.73 / 34.92 ns, a little under the board's 8.815 /
#        35.26 (113.4375 / 28.359375 MHz), as Tasks 5-7 measured.
#   io   the same wrapper as a top with IO buffers, the card pins on the
#        board's package pins (fpga/openaars/aars_v5.0/xc7a100t/sd_card.xdc),
#        every other port LVTTL wherever the placer puts it (untimed), and the
#        card's pin and timing constraints read from sd_card.xdc itself (its
#        sdc_pins block): proves those constraints and their slack.
# Both modes read sd_card.xdc's sdc_bridge block (the Gayle bridge's Gray
# count bound).
#
# Results in <outdir>: util.rpt, util_hier.rpt, timing.rpt (summary + the
# five worst paths per clock), worst5.rpt (the five worst setup paths of the
# design), ram.txt (the inferred RAM cells), summary.txt (one line, what
# go.sh prints: LUT FF RAMB18 LUTRAM WNS per clock group).
set outdir [file normalize [lindex $argv 0]]
set mode   [lindex $argv 1]
set t114   [expr {[llength $argv] > 2 ? [lindex $argv 2] : 8.73}]
set t28    [expr {[llength $argv] > 3 ? [lindex $argv 3] : 4 * $t114}]
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../../..]
set part xc7a100tfgg676-2
file mkdir $outdir

read_verilog $repo/rtl/host/sdcard_spi.v
read_verilog $repo/rtl/minimig/sdcard_gayle.v
read_verilog $here/ooc_sdcard_top.v

switch $mode {
    ooc { synth_design -top ooc_sdcard_top -part $part -mode out_of_context -flatten_hierarchy rebuilt }
    io  { synth_design -top ooc_sdcard_top -part $part -flatten_hierarchy rebuilt }
    default { error "mode must be ooc or io" }
}

# ---- clocks: clk_114 and dll_28 (the board's names), related, aligned (one
# MMCM on the board)
create_clock -name clk_114 -period $t114 [get_ports clk_g]
create_clock -name dll_28  -period $t28  [get_ports clk]
# wizard.xdc: dll_28 <-> clk_114 are phase-aligned 1:4 siblings
set_multicycle_path -setup -end 4   -from [get_clocks dll_28]  -to [get_clocks clk_114]
set_multicycle_path -hold  -end 3   -from [get_clocks dll_28]  -to [get_clocks clk_114]
set_multicycle_path -setup -start 4 -from [get_clocks clk_114] -to [get_clocks dll_28]
set_multicycle_path -hold  -start 3 -from [get_clocks clk_114] -to [get_clocks dll_28]

# xdc_block <name>: the lines of sd_card.xdc between "# >>> <name>" and
# "# <<< <name>", as <outdir>/<name>.xdc, read as constraints
proc xdc_block {name} {
    global repo outdir
    set fh [open $repo/fpga/openaars/aars_v5.0/xc7a100t/sd_card.xdc r]; set src [read $fh]; close $fh
    set on 0; set out {}
    foreach line [split $src "\n"] {
        if {$line eq "# <<< $name"} { set on 0 }
        if {$on} { lappend out $line }
        if {$line eq "# >>> $name"} { set on 1 }
    }
    if {[llength $out] == 0} { error "sd_card.xdc: no block $name" }
    set f $outdir/$name.xdc
    set fh [open $f w]; puts $fh [join $out "\n"]; close $fh
    read_xdc $f
    puts "=== read sd_card.xdc block $name ([llength $out] lines)"
}
xdc_block sdc_bridge

if {$mode eq "io"} {
    # two clock-capable pins for the two clock ports, away from the card's
    set cc [get_package_pins -filter {IS_CLK_CAPABLE && IS_GENERAL_PURPOSE && PIN_FUNC =~ "*P_T*CC*"}]
    set used {D26 E25 E26 G26 F23 D25 H26}
    set picks {}
    foreach p $cc { if {[lsearch $used $p] < 0} { lappend picks $p }; if {[llength $picks] == 2} break }
    set_property PACKAGE_PIN [lindex $picks 0] [get_ports clk_g]
    set_property PACKAGE_PIN [lindex $picks 1] [get_ports clk]
    set_property IOSTANDARD LVTTL [get_ports *]
    # the card pins: sd_card.xdc's own lines
    xdc_block sdc_pins
}

report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_synth_hier.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $outdir/routed.dcp
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
report_timing_summary -max_paths 5 -report_unconstrained -file $outdir/timing.rpt
report_timing -setup -max_paths 5 -nworst 1 -unique_pins -sort_by slack -file $outdir/worst5.rpt
report_timing -hold -max_paths 5 -nworst 1 -unique_pins -sort_by slack -file $outdir/worst5_hold.rpt
if {$mode eq "io"} {
    report_timing -setup -max_paths 3 -to [get_ports {sd_m_cmd sd_m_d3}] -file $outdir/io_out.rpt
    report_timing -setup -max_paths 3 -from [get_ports sd_m_d0] -file $outdir/io_in.rpt
    report_timing -hold  -max_paths 3 -to [get_ports {sd_m_cmd sd_m_d3}] -file $outdir/io_out_hold.rpt
    report_timing -hold  -max_paths 3 -from [get_ports sd_m_d0] -file $outdir/io_in_hold.rpt
}

# RAM cells: one RAMB18 expected, no LUTRAM
set rams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set lutram [get_cells -hier -filter {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256* || REF_NAME =~ SRL*}]
set fh [open $outdir/ram.txt w]
foreach r $rams { puts $fh "BRAM [get_property REF_NAME $r] $r" }
foreach r $lutram { puts $fh "LUTRAM [get_property REF_NAME $r] $r" }
close $fh

proc wns_of {args} {
    set p [get_timing_paths -setup -max_paths 1 -nworst 1 {*}$args]
    if {$p eq ""} { return "-" }
    return [format %.3f [get_property SLACK $p]]
}
proc whs_of {args} {
    set p [get_timing_paths -hold -max_paths 1 -nworst 1 {*}$args]
    if {$p eq ""} { return "-" }
    return [format %.3f [get_property SLACK $p]]
}
set fh [open $outdir/util.rpt r]; set u [read $fh]; close $fh
regexp {Slice LUTs\*?\s*\|\s*(\d+)} $u -> luts
regexp {Slice Registers\s*\|\s*(\d+)} $u -> ffs
regexp {RAMB18\s*\|\s*(\d+)} $u -> rb18
regexp {RAMB36/FIFO\*?\s*\|\s*(\d+)} $u -> rb36
regexp {LUT as Memory\s*\|\s*(\d+)} $u -> lutmem
set s "mode=$mode t114=$t114 t28=$t28 LUT=$luts FF=$ffs RAMB18=$rb18 RAMB36=$rb36 LUTRAM=$lutmem"
append s " WNS=[wns_of] WHS=[whs_of]"
append s " WNS_114=[wns_of -from [get_clocks clk_114] -to [get_clocks clk_114]]"
append s " WNS_28=[wns_of -from [get_clocks dll_28] -to [get_clocks dll_28]]"
append s " WNS_114to28=[wns_of -from [get_clocks clk_114] -to [get_clocks dll_28]]"
append s " WNS_28to114=[wns_of -from [get_clocks dll_28] -to [get_clocks clk_114]]"
append s " WNS_gray=[wns_of -from [get_cells SDCGAYLE1/q_gray_reg*] -to [get_cells SDCGAYLE1/s_gray1_reg*]]"
if {$mode eq "io"} {
    append s " WNS_out=[wns_of -to [get_ports {sd_m_cmd sd_m_d3}]] WHS_out=[whs_of -to [get_ports {sd_m_cmd sd_m_d3}]]"
    append s " WNS_in=[wns_of -from [get_ports sd_m_d0]] WHS_in=[whs_of -from [get_ports sd_m_d0]]"
}
append s " version=[version -short]"
set fh [open $outdir/summary.txt w]; puts $fh $s; close $fh
puts "=== $s"
