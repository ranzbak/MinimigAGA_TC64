# guard.tcl -- fpga/openaars/aars_v5.0/xc7a100t/sd_card_engine.tcl in a
# project run, the way tools/vivado/build_ap040.tcl uses it (an unmanaged Tcl
# constraint file, PROCESSING_ORDER LATE, USED_IN synthesis and
# implementation), on one of four small designs (five cases):
#
#   vivado -mode batch -source guard.tcl -tclargs <outdir> <case>
#
# Run it through go.sh (`go.sh <name> guard <case>`; libtinfo shim, no -stack),
# or all five at once with `go.sh guard guard` (about 3 minutes).
#
#   engine         ooc_sdcard_top (sdcard_spi + bridge + mux) as a top with IO
#                  buffers on the card's package pins: the engine branch, both
#                  blocks applied; the run must complete, the generated clock
#                  sdc_sck and the Gray-count bound must be in the design.
#                  Then replicas of q_gray_reg[0], sck_r_reg and cd_s2_reg
#                  (phys_opt_design -force_replication_on_nets, as a routed
#                  build may have them) and the file sourced again, as
#                  build_ap040.tcl's open_run impl_1 does: no exit, both
#                  blocks applied.
#   noengine       a top with the same ports and the card on a plain register
#                  SPI (no sdc_spi, no SDCGAYLE1): the no-engine branch, the
#                  two false paths; the run must complete.
#   rename_spi     the engine with sdcard_spi.v's sck_r renamed (a copy in
#                  <outdir>): the file must stop the run with its error naming
#                  *sdc_spi/sck_r_reg (before the fix it fell through to the
#                  no-engine branch and false-pathed the engine's pins).
#   rename_bridge  the engine with sdcard_gayle.v's q_gray renamed: the run
#                  must stop with the bridge error.
#   rename_spi_impl  as rename_spi with the file used in implementation only:
#                  synthesis completes, link_design must stop the run.
# A failure must print the file's "ERROR: sd_card_engine.tcl: ..." line in the
# run's log and make wait_on_run fail (Vivado makes a plain error in a
# constraint file a critical warning and runs on; see the file's header).
#
# Synthesis, then implementation to opt_design (the constraints are read in
# both).  Ends "=== GUARD <case> PASS" or "=== GUARD <case> FAIL: <why>";
# result.txt in <outdir> holds the same line.
set outdir [file normalize [lindex $argv 0]]
set case   [lindex $argv 1]
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../../..]
set part xc7a100tfgg676-2
set xdcdir $repo/fpga/openaars/aars_v5.0/xc7a100t
set eng $xdcdir/sd_card_engine.tcl
file mkdir $outdir

proc result {ok why} {
    global outdir case
    set l [expr {$ok ? "=== GUARD $case PASS" : "=== GUARD $case FAIL: $why"}]
    set fh [open $outdir/result.txt w]; puts $fh $l; close $fh
    puts $l
    exit [expr {$ok ? 0 : 1}]
}

# a copy of <src> in outdir with the string map <map> applied; the copy's path
proc patched {src map} {
    global outdir
    set fh [open $src r]; set t [read $fh]; close $fh
    set t2 [string map $map $t]
    if {$t2 eq $t} { error "guard.tcl: $map changes nothing in $src" }
    set dst $outdir/[file tail $src]
    set fh [open $dst w]; puts -nonewline $fh $t2; close $fh
    return $dst
}

set spi    $repo/rtl/host/sdcard_spi.v
set bridge $repo/rtl/minimig/sdcard_gayle.v
set top    ooc_sdcard_top
set srcs   {}
switch -- $case {
    engine        { }
    rename_spi - rename_spi_impl { set spi [patched $spi {sck_r sck_q}] }
    rename_bridge { set bridge [patched $bridge {q_gray q_grey}] }
    noengine {
        # the card on a register SPI master, as with cfide's (no engine cell)
        set top noengine_top
        set f $outdir/noengine_top.v
        set fh [open $f w]
        puts $fh {module noengine_top (
    input wire clk_g, input wire clk, input wire reset_g, input wire bus_req,
    output reg sd_m_clk = 1'b0, output reg sd_m_d3 = 1'b1, output reg sd_m_cmd = 1'b1,
    input wire sd_m_d0, input wire sd_m_cdet, output wire sd_m_d1, output wire sd_m_d2,
    output reg [7:0] rx = 8'h00
);
    assign sd_m_d1 = 1'b1;
    assign sd_m_d2 = 1'b1;
    reg [7:0] tx = 8'hA5;
    always @(posedge clk_g) begin
        sd_m_clk <= bus_req ? ~sd_m_clk : 1'b0;
        sd_m_d3  <= reset_g | sd_m_cdet;
        if (bus_req && sd_m_clk) begin tx <= {tx[6:0], tx[7]}; sd_m_cmd <= tx[7]; end
        if (bus_req && !sd_m_clk) rx <= {rx[6:0], sd_m_d0};
    end
endmodule}
        close $fh
        set srcs [list $f]
    }
    default { error "guard.tcl: case must be engine, noengine, rename_spi, rename_spi_impl or rename_bridge" }
}
if {$case ne "noengine"} {
    set srcs [list $spi $bridge $here/ooc_sdcard_top.v]
}

create_project -force guard $outdir/proj -part $part
add_files -norecurse $srcs
set_property top $top [current_fileset]

# clocks as on the board (related, aligned, wizard.xdc's 1:4 multicycles), the
# card pins from sd_card.xdc's own lines, every other port LVTTL anywhere
set base $outdir/base.xdc
set fh [open $base w]
puts $fh {create_clock -name clk_114 -period 8.815 [get_ports clk_g]
create_clock -name dll_28 -period 35.26 [get_ports clk]
set_multicycle_path -setup -end 4 -from [get_clocks dll_28] -to [get_clocks clk_114]
set_multicycle_path -hold  -end 3 -from [get_clocks dll_28] -to [get_clocks clk_114]
set_multicycle_path -setup -start 4 -from [get_clocks clk_114] -to [get_clocks dll_28]
set_multicycle_path -hold  -start 3 -from [get_clocks clk_114] -to [get_clocks dll_28]
set_property IOSTANDARD LVTTL [get_ports *]}
set sfh [open $xdcdir/sd_card.xdc r]; set src [read $sfh]; close $sfh
set on 0
foreach line [split $src "\n"] {
    if {$line eq "# <<< sdc_pins"} { set on 0 }
    if {$on} { puts $fh $line }
    if {$line eq "# >>> sdc_pins"} { set on 1 }
}
close $fh
add_files -fileset constrs_1 -norecurse [list $base $eng]
set ef [get_files -of_objects [get_filesets constrs_1] $eng]
# rename_spi_impl: the file in implementation only, so the guard meets the
# missing register in link_design rather than in synthesis
set_property USED_IN [expr {$case eq "rename_spi_impl" ? {implementation} : {synthesis implementation}}] $ef
set_property PROCESSING_ORDER LATE $ef

# wait_on_run itself errors on a failed run (as in build_ap040.tcl, where that
# ends the build); caught here to look at the logs
set s_err [catch {launch_runs synth_1 -jobs 2; wait_on_run synth_1} s_msg]
set s_ok [expr {!$s_err && [get_property PROGRESS [get_runs synth_1]] eq "100%"}]
set i_ok 0
set i_err 0
if {$s_ok} {
    set i_err [catch {launch_runs impl_1 -to_step opt_design -jobs 2; wait_on_run impl_1} i_msg]
    set i_ok [expr {!$i_err && [llength [glob -nocomplain $outdir/proj/guard.runs/impl_1/*_opt.dcp]] == 1}]
}
puts "guard.tcl: synth_1 [get_property STATUS [get_runs synth_1]] (wait_on_run error $s_err), impl_1 [get_property STATUS [get_runs impl_1]] (wait_on_run error $i_err)"

proc logtext {run} {
    global outdir
    set f $outdir/proj/guard.runs/$run/runme.log
    if {![file exists $f]} { return "" }
    set fh [open $f r]; set t [read $fh]; close $fh
    return $t
}
set slog [logtext synth_1]
set ilog [logtext impl_1]

switch -- $case {
    engine {
        if {!$s_ok || !$i_ok} { result 0 "the run did not complete" }
        foreach m {"SD card engine constraints" "SD card engine bridge bound"} {
            if {[string first "sd_card_engine.tcl: $m" $ilog] < 0} { result 0 "impl_1 log lacks '$m'" }
            if {[string first "sd_card_engine.tcl: $m" $slog] < 0} { result 0 "synth_1 log lacks '$m'" }
        }
        open_checkpoint [glob $outdir/proj/guard.runs/impl_1/*_opt.dcp]
        if {[llength [get_clocks -quiet sdc_sck]] != 1} { result 0 "no clock sdc_sck" }
        report_exceptions -file $outdir/exceptions.rpt
        set fh [open $outdir/exceptions.rpt r]; set ex [read $fh]; close $fh
        if {![regexp {SDCGAYLE1[^\n]*max_dpo=8\.815} $ex]} { result 0 "no q_gray max delay in report_exceptions" }
        if {![regexp {sd_m_cdet} $ex]} { result 0 "no sd_m_cdet false path in report_exceptions" }
        # replicas: build_ap040.tcl's open_run impl_1 sources the file again
        # on the routed design, where phys_opt_design may have replicated a
        # register; the file must still match exactly its own cells (an exit
        # there would skip the build's restores).  Place, force a replica
        # of q_gray_reg[0], sck_r_reg and cd_s2_reg, source the file again
        # in this batch Vivado: it must not exit, and must apply both blocks.
        place_design
        set rep {}
        foreach c [list SDCGAYLE1/q_gray_reg\[0\] sdc_spi/sck_r_reg sdc_spi/cd_s2_reg] {
            lappend rep [get_nets -of_objects [get_pins -of_objects [get_cells $c] -filter {REF_PIN_NAME == Q}]]
        }
        phys_opt_design -force_replication_on_nets $rep
        set reps [get_cells -quiet -hierarchical -filter {NAME =~ *replica*}]
        set loose [get_cells -quiet -hierarchical -filter {NAME =~ *SDCGAYLE1/q_gray_reg*}]
        puts "guard.tcl: replicas: [llength $reps] ($reps); the old glob *SDCGAYLE1/q_gray_reg* now matches [llength $loose]"
        if {[llength $reps] < 1 || [llength $loose] < 4} { result 0 "phys_opt_design made no q_gray replica (the case would prove nothing)" }
        reset_timing
        source $base
        set ::sdc_reread ""
        set fh [open $eng r]; set src [read $fh]; close $fh
        source $eng
        if {[llength [get_clocks -quiet sdc_sck]] != 1} { result 0 "after the replicas: no clock sdc_sck" }
        report_exceptions -file $outdir/exceptions_replica.rpt
        set fh [open $outdir/exceptions_replica.rpt r]; set ex2 [read $fh]; close $fh
        if {![regexp {SDCGAYLE1[^\n]*max_dpo=8\.815} $ex2]} { result 0 "after the replicas: no q_gray max delay" }
        result 1 ""
    }
    noengine {
        if {!$s_ok || !$i_ok} { result 0 "the run did not complete" }
        if {[string first "sd_card_engine.tcl: no SD card engine" $ilog] < 0} { result 0 "impl_1 log lacks the no-engine line" }
        if {[string first "sd_card_engine.tcl: SD card engine" $ilog] >= 0} { result 0 "impl_1 log has an engine line" }
        open_checkpoint [glob $outdir/proj/guard.runs/impl_1/*_opt.dcp]
        if {[llength [get_clocks -quiet sdc_sck]] != 0} { result 0 "clock sdc_sck exists" }
        report_exceptions -file $outdir/exceptions.rpt
        set fh [open $outdir/exceptions.rpt r]; set ex [read $fh]; close $fh
        if {![regexp {sd_m_d0} $ex] || ![regexp {sd_m_cmd} $ex]} { result 0 "the two false paths are not in report_exceptions" }
        result 1 ""
    }
    rename_spi - rename_bridge - rename_spi_impl {
        set want [expr {$case eq "rename_bridge" ? "q_gray / s_gray1 match 0 / 3 cells" : "*sdc_spi/sck_r_reg (0 found, 1 expected)"}]
        set wlog [expr {$case eq "rename_spi_impl" ? $ilog : $slog}]
        if {$s_ok && $i_ok} { result 0 "the run completed (the guard did not stop it)" }
        if {$case eq "rename_spi_impl" && !$s_ok} { result 0 "synthesis failed (the file is not used there)" }
        if {[string first "ERROR: sd_card_engine.tcl:" $wlog] < 0} { result 0 "no ERROR line from the file in the [expr {$case eq "rename_spi_impl" ? "impl_1" : "synth_1"}] log" }
        if {$case eq "rename_spi_impl" ? !$i_err : !$s_err} { result 0 "wait_on_run did not fail" }
        if {[string first $want $wlog] < 0} { result 0 "the run failed, but its log lacks '$want'" }
        if {[string first "sd_card_engine.tcl: no SD card engine" "$slog$ilog"] >= 0} { result 0 "the no-engine branch ran" }
        result 1 ""
    }
}
