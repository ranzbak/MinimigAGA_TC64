# Capture the CPU side of the DDR3 Zorro-III fast RAM during a real Amiga boot.
#
#   vivado -mode batch -source tools/vivado/ila_fastram_capture.tcl \
#          -tclargs <csv-out> [<ltx>] [<timeout-s>]
#
# THIS SCRIPT DOES NOT PROGRAM THE FPGA.  The ILA lives in the bitstream, so
# arming it only makes sense once that bitstream is loaded and the debug hub is
# alive.  The order is always:
#
#   1. supervisor programs build/stageB2/minimig_openaars_top.bit (hardware
#      manager, openFPGALoader, whatever is used on this board),
#   2. run this script -- it arms and then waits,
#   3. supervisor lets the board boot Workbench into the DDR3 fast RAM.
#
# Arming after programming matters twice over: programming resets the debug
# hub (an ILA armed before it would simply be wiped), and the interesting
# traffic is the first fast-RAM access of the boot, which happens seconds after
# configuration.  Hence the long wait (default 120 s) rather than the 20 s of
# tools/vivado/ila_capture.tcl.
#
# Vivado 2023.2 needs libtinfo.so.5 and must NOT be given -stack.
#
# Trigger      : the first cpuena (cache acknowledge) rising edge while
#                ddr_ready is high, i.e. the first completed CPU access to the
#                DDR3 fast RAM after the island has finished initialising.
#
#                NOTE since the DDR3 became Zorro-III board 3 rather than
#                board 1 (findings/ddr3/z3ram3-on-ddr3-plan.md): the first
#                DDR3 access is no longer the Kickstart relocation into
#                0x40000000, which now goes to the SDRAM.  Exec adds boards in
#                autoconfig order, so the DDR3 is only touched once the OS
#                spills past the SDRAM boards -- much later in the boot, and
#                not at all on a short one.  Arm accordingly, and do not read
#                "no trigger" as "no DDR3 traffic" without checking that the
#                board was configured at all.
# Storage      : only cycles that carry information -- a CPU access is
#                selected (cpustate[2], the active-low chip select, is 0) OR
#                the backend FSM is not idle (bstate != 0).  Idle clk_114
#                cycles, of which there are thousands between accesses, are not
#                stored, so the 4096-sample buffer holds thousands of DDR3
#                transactions instead of 36 us of nothing.
# Position     : 256, so a quarter of a K of pre-trigger history is kept -- the
#                accesses that set up the one that trips the trigger.
#
# Probe names are matched loosely (-filter {NAME =~ *<name>*}) because
# synthesis decorates them with the instance path.  The names in
# build/stageB2/minimig_openaars_top.ltx, in probe order, are:
#
#   probe0   25  openaars_virtual_top/tg68_ddraddr          cpuAddr[25:1]
#   probe1    7  openaars_virtual_top/tg68_ddrcpustate      cpustate[6:0]
#   probe2    1  openaars_virtual_top/tg68_cuds             cpuU
#   probe3    1  openaars_virtual_top/tg68_clds             cpuL
#   probe4   16  openaars_virtual_top/tg68_cin              cpuWR
#   probe5   16  openaars_virtual_top/tg68_ddrout           cpuRD
#   probe6    1  openaars_virtual_top/tg68_ddrena           cpuena
#   probe7    1  openaars_virtual_top/tg68_ddrready         ddr_ready
#   probe8    1  openaars_virtual_top/ddr3_dbg_req_rd       CDC request: read
#   probe9   16  openaars_virtual_top/ddr3_dbg_req_be         byte enables
#   probe10  32  openaars_virtual_top/ddr3_dbg_req_addr       address
#   probe11 128  openaars_virtual_top/ddr3_dbg_req_wdata      write payload
#   probe12 128  openaars_virtual_top/ddr3_dbg_resp_rdata   response payload
#   probe13   1  openaars_virtual_top/ddr3_dbg_ack_tgl      ack toggle (synced)
#   probe14   2  openaars_virtual_top/ddr3_dbg_bstate       backend FSM state
#   probe15   1  openaars_virtual_top/ddr3_dbg_sdr_read_req
#   probe16   1  openaars_virtual_top/ddr3_dbg_sdr_read_ack
#   probe17  16  openaars_virtual_top/ddr3_dbg_sdr_dat_r
#   probe18   1  openaars_virtual_top/ddr3_dbg_sdr_write_req
#   probe19   1  openaars_virtual_top/ddr3_dbg_sdr_write_ack
#   probe20  25  openaars_virtual_top/ddr3_dbg_sdr_adr
#   probe21  32  openaars_virtual_top/ddr3_dbg_sdr_dat_w
#   probe22   4  openaars_virtual_top/ddr3_dbg_sdr_dqm_w
#   probe23   4  .../g_ddr3_fastram_ila.ddr3_dbg_cdc_state
#                  {cdc_ready, cdc_req, cdc_done, req_tgl}

set csv [lindex $argv 0]
if {$csv eq ""} {
    error "usage: ila_fastram_capture.tcl <csv-out> \[<ltx>\] \[<timeout-s>\]"
}
set R   [file normalize [file dirname [info script]]/../..]
set ltx [expr {[llength $argv] > 1 ? [file normalize [lindex $argv 1]] \
                                   : "$R/build/stageB2/minimig_openaars_top.ltx"}]
set tmo [expr {[llength $argv] > 2 ? [lindex $argv 2] : 240}]

if {![file exists $ltx]} { error "no probes file: $ltx" }

#-----------------------------------------------------------------------------
# Attach to the already-programmed device
#-----------------------------------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
if {[lsearch $argv program] >= 0} { set_property PROGRAM.FILE [file rootname $ltx].bit $dev; program_hw_device $dev; puts "=== programmed ===" }
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
if {$ila eq ""} {
    error "no ILA found -- is build/stageB2/minimig_openaars_top.bit programmed?"
}
puts "=== ILA: $ila, [get_property CONTROL.DATA_DEPTH $ila] samples ==="

# Look a probe up by a loose name match; fail loudly rather than silently
# arming with no condition at all.
proc probe {ila pat} {
    set p [get_hw_probes -quiet -of_objects $ila -filter "NAME =~ *$pat*"]
    if {[llength $p] == 0} { error "probe matching '*$pat*' not found" }
    return [lindex $p 0]
}

set p_cpuena    [probe $ila ddrena]
set p_ddrready  [probe $ila ddrready]
set p_cpustate  [probe $ila ddrcpustate]
set p_bstate    [probe $ila dbg_bstate]
puts "=== trigger on   : [get_property NAME $p_cpuena] rising & [get_property NAME $p_ddrready] ==="
puts "=== qualified by : [get_property NAME $p_cpustate] / [get_property NAME $p_bstate] ==="

#-----------------------------------------------------------------------------
# Trigger and storage qualification
#-----------------------------------------------------------------------------
foreach p [get_hw_probes -of_objects $ila] {
    set_property TRIGGER_COMPARE_VALUE {} $p
    set_property CAPTURE_COMPARE_VALUE {} $p
}

set_property CONTROL.TRIGGER_POSITION 256 $ila

# trigger: cpuena rising AND ddr_ready high
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property TRIGGER_COMPARE_VALUE {eq1'bR} $p_cpuena
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $p_ddrready

# storage qualification: CPU chip select low (cpustate[2] == 0, active low),
# or the backend busy.  x = don't care, MSB first, so bit 2 of a 7-bit probe
# is the fifth character.
set_property CONTROL.CAPTURE_MODE BASIC $ila
set_property CONTROL.CAPTURE_CONDITION OR $ila
set_property CAPTURE_COMPARE_VALUE {eq7'bxxxx0xx} $p_cpustate
set_property CAPTURE_COMPARE_VALUE {neq2'b00}     $p_bstate

#-----------------------------------------------------------------------------
# Arm and wait for the boot
#-----------------------------------------------------------------------------
run_hw_ila $ila
puts "=== ILA armed at [clock format [clock seconds] -format %H:%M:%S];\
 waiting up to ${tmo}s for the board to boot into DDR3 fast RAM ==="

# Poll rather than wait_on_hw_ila: the supervisor is reprogramming and booting
# the board while this runs, and a status line every few seconds is the only
# way to tell "still waiting for the trigger" from "the debug hub went away".
# Wait for the trigger (wait_on_hw_ila returns on trigger or timeout; there is no
# CORE_STATUS property on hw_ila objects).
set triggered 1
# wait_on_hw_ila -timeout takes MINUTES, not seconds -- verified empirically
# (a 5-unit timeout did not return within 60 real seconds; a prior "fix" here
# assumed seconds and was itself a regression, undone now). $tmo is specified
# in seconds by every caller of this script, so convert.
if {[catch {wait_on_hw_ila -timeout [expr {int(ceil($tmo/60.0))}] $ila} msg]} { puts "=== wait ended: $msg ==="; set triggered 0 }
upload_hw_ila_data $ila
file mkdir [file dirname [file normalize $csv]]
write_hw_ila_data -csv_file $csv -force [current_hw_ila_data]
puts "=== ILA CSV written: $csv ==="
close_hw_manager
