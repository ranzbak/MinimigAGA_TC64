# SD card timing: an unmanaged Tcl constraint file (XDC has no "if"), read
# after the XDC files (tools/vivado/build_ap040.tcl adds it, PROCESSING_ORDER
# LATE).  The pins themselves (LOC, IOSTANDARD, slew) are in sd_card.xdc.
#
# With the SD card engine (SD_ENGINE = 1 in minimig_openaars_top.v, the
# sdc_spi cell of rtl/host/sdcard_spi.v exists): its SCK / CMD / DAT0 / DAT3 /
# card-detect timing and the Gayle bridge's Gray-count bound.  Without it
# (SD_ENGINE = 0, the card on cfide's SPI): the false paths those pins had
# before (sd_card.xdc: from sd_m_d0; wizard.xdc: to sd_m_cmd / sd_m_d3), so
# such a build is constrained exactly as before.
#
# Which of the two is decided by whether the engine is in the netlist at all
# (any cell under an instance named sdc_spi / SDCGAYLE1, the names
# minimig_virtual_top.v, minimig.v and the OOC wrapper give them), never by
# the registers the constraints name: if the engine is there but one of those
# registers or ports is not (renamed, merged, optimised away), the file stops
# with an error that names what is missing, instead of quietly leaving the
# engine's pins unconstrained or false-pathed.  How it stops: Vivado makes an
# error in a constraint file a critical warning ([Common 17-1548]) and carries
# on, and even raised to an ERROR (set_msg_config) it stops synth_design but
# not link_design ("link_design completed successfully", 1 error).  So in
# batch mode -- every synthesis and implementation run, which Vivado runs as
# a batch child even from the GUI -- the file prints "ERROR: <why>" and exits
# that Vivado: the run fails (synth_1 / impl_1 "... ERROR") and wait_on_run
# fails with it, which ends tools/vivado/build_ap040.tcl.  In the GUI or Tcl
# mode (a design opened by hand) it must not quit the session: there the
# message is raised to an ERROR and the file stops with it.  Test:
# tools/vivado/ooc_sdcard/go.sh guard (both branches and the error).
#
# The blocks between "# >>> <name>" and "# <<< <name>" (each complete
# commands) are also read on their own by the engine's size and timing
# check (tools/vivado/ooc_sdcard/run.tcl): sdc_io in io mode, sdc_bridge in
# both modes.  Keep them free of other cells' names.

# >>> sdc_io
# SCK is sdcard_spi's sck_r register, clk_114 / (2 * (div + 1)) in SPI mode 0
# (idles low, MOSI changes with SCK falling, MISO is sampled at the clk_114
# edge that raises SCK).  Constrained for the fastest divider the SD spec
# allows, div = 2: clk_114 / 6 = 18.9 MHz (div 1 = 28.4 MHz is over the 25
# MHz of SPI mode; the firmware never sets div < 2).  The clock is defined at
# the pin, with the register's clock pin as its source, so it includes the
# clock-to-pin delay the card sees; sck_r itself stays a clk_114 data register
# for the shifter (no clock on its Q, cf. cfide's sck_pin in sd_card.xdc).
#
# The card (SD Physical Layer spec, default speed): input setup / hold 5 ns /
# 5 ns around SCK rising; output delay at most 14 ns after SCK falling, hold
# >= 0.  Board traces (a few cm) are inside those margins.
#   CMD / DAT3 (outputs): launched by clk_114 registers at the edge that drops
#     SCK (or, CS, with SCK idle low and >= 3 cycles before the next rise),
#     sampled by the card at the next SCK rise, 3 clk_114 cycles later
#     (setup multicycle 3); they next change at the following SCK fall, 3
#     cycles after that rise: hold is checked against that launch (hold
#     multicycle 5 moves the hold launch to it).
#   DAT0 (input): launched by the card at SCK falling, sampled 3 clk_114
#     cycles later at the edge that raises SCK (setup multicycle 3, the hold
#     check back at the launch edge).
# sd_m_d1 / sd_m_d2 are constant 1.
# Card detect: asynchronous, through sdcard_spi's two-flop synchroniser and a
# 9 ms debounce.
set sdc_spi_cells [get_cells -quiet -hierarchical -filter {NAME =~ *sdc_spi/*}]
if {[llength $sdc_spi_cells] != 0} {
    set sdc_sck_reg [get_cells -quiet -hierarchical -filter {NAME =~ *sdc_spi/sck_r_reg}]
    set sdc_missing {}
    foreach {sdc_what sdc_obj} [list \
            *sdc_spi/sck_r_reg $sdc_sck_reg \
            *sdc_spi/cd_s1_reg [get_cells -quiet -hierarchical -filter {NAME =~ *sdc_spi/cd_s1_reg}] \
            *sdc_spi/cd_s2_reg [get_cells -quiet -hierarchical -filter {NAME =~ *sdc_spi/cd_s2_reg}] \
            {port sd_m_clk}  [get_ports -quiet sd_m_clk] \
            {port sd_m_cmd}  [get_ports -quiet sd_m_cmd] \
            {port sd_m_d3}   [get_ports -quiet sd_m_d3] \
            {port sd_m_d0}   [get_ports -quiet sd_m_d0] \
            {port sd_m_cdet} [get_ports -quiet sd_m_cdet]] {
        if {[llength $sdc_obj] != 1} { lappend sdc_missing "$sdc_what ([llength $sdc_obj] found, 1 expected)" }
    }
    if {[llength $sdc_missing]} {
        # stop the run: see the header (batch: exit, else an ERROR)
        set sdc_msg "sd_card_engine.tcl: the SD card engine is in the netlist ([llength $sdc_spi_cells] cells under *sdc_spi/) but its constraints cannot be applied: [join $sdc_missing {; }]. Fix the names in this file (the engine's pins would otherwise go unconstrained)."
        if {[info exists ::rdi::mode] && $::rdi::mode eq "batch"} { puts "ERROR: $sdc_msg"; flush stdout; exit 1 }
        set_msg_config -id {Common 17-1548} -string {sd_card_engine.tcl} -new_severity ERROR
        error $sdc_msg
    }
    create_generated_clock -name sdc_sck -source [get_pins $sdc_sck_reg/C] -divide_by 6 [get_ports sd_m_clk]
    set_output_delay -clock sdc_sck -max  5.0 [get_ports {sd_m_cmd sd_m_d3}]
    set_output_delay -clock sdc_sck -min -5.0 [get_ports {sd_m_cmd sd_m_d3}]
    set_multicycle_path -setup -start 3 -from [get_clocks clk_114] -to [get_ports {sd_m_cmd sd_m_d3}]
    set_multicycle_path -hold  -start 5 -from [get_clocks clk_114] -to [get_ports {sd_m_cmd sd_m_d3}]
    set_input_delay -clock sdc_sck -clock_fall -max 14.0 [get_ports sd_m_d0]
    set_input_delay -clock sdc_sck -clock_fall -min  0.0 [get_ports sd_m_d0]
    set_multicycle_path -setup -end 3 -from [get_ports sd_m_d0] -to [get_clocks clk_114]
    set_multicycle_path -hold  -end 2 -from [get_ports sd_m_d0] -to [get_clocks clk_114]
    set_false_path -from [get_ports sd_m_cdet]
    set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *sdc_spi/cd_s1_reg || NAME =~ *sdc_spi/cd_s2_reg}]
    puts "sd_card_engine.tcl: SD card engine constraints ($sdc_sck_reg)"
} else {
    # no engine: the card on cfide's SPI, as before (card data in is
    # resampled by the SPI logic; CMD / DAT3 slow serial outputs)
    set_false_path -from [get_ports sd_m_d0]
    set_false_path -to [get_ports {sd_m_cmd sd_m_d3}]
    puts "sd_card_engine.tcl: no SD card engine, the card on cfide's SPI"
}
# <<< sdc_io

# The SD card engine's Gayle bridge (rtl/minimig/sdcard_gayle.v) crosses
# between clk_114 and dll_28.  The two are phase-aligned MMCM siblings,
# timed as related clocks under wizard.xdc's 1:4 multicycles; every crossing
# is a two-flop synchroniser of a toggle or of a Gray count, or a word held
# longer than those multicycles allow (sdcard_gayle.v, "Timing constraints").
# The one exception: the 3-bit Gray count q_gray can step on two consecutive
# clk_114 edges (a one-cycle g_req), so its bits must reach s_gray1 within
# one clk_114 period of each other, or s_gray1 could take a mix of two codes
# that are not neighbours.  The 1:4 multicycle would allow 4 periods: bound
# the datapath to one (it overrides the multicycle).
# >>> sdc_bridge
set sdc_bridge_cells [get_cells -quiet -hierarchical -filter {NAME =~ *SDCGAYLE1/*}]
if {[llength $sdc_bridge_cells] != 0} {
    set sdc_gray_q [get_cells -quiet -hierarchical -filter {NAME =~ *SDCGAYLE1/q_gray_reg*}]
    set sdc_gray_s [get_cells -quiet -hierarchical -filter {NAME =~ *SDCGAYLE1/s_gray1_reg*}]
    if {[llength $sdc_gray_q] != 3 || [llength $sdc_gray_s] != 3} {
        set sdc_msg "sd_card_engine.tcl: the SD card engine's Gayle bridge is in the netlist ([llength $sdc_bridge_cells] cells under *SDCGAYLE1/) but q_gray / s_gray1 match [llength $sdc_gray_q] / [llength $sdc_gray_s] cells, 3 / 3 expected. Fix the names in this file (the Gray count would otherwise go unbounded)."
        if {[info exists ::rdi::mode] && $::rdi::mode eq "batch"} { puts "ERROR: $sdc_msg"; flush stdout; exit 1 }
        set_msg_config -id {Common 17-1548} -string {sd_card_engine.tcl} -new_severity ERROR
        error $sdc_msg
    }
    set_max_delay -datapath_only 8.815 -from $sdc_gray_q -to $sdc_gray_s
    puts "sd_card_engine.tcl: SD card engine bridge bound (q_gray -> s_gray1)"
}
# <<< sdc_bridge
