#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# SD-Card interface
# The lines between "# >>> sdc_pins" and "# <<< sdc_pins", and those of the
# sdc_bridge block, are also read on their own by the SD card engine's size
# and timing check (tools/vivado/ooc_sdcard/run.tcl, io and ooc modes): keep
# them free of other cells' names.
# >>> sdc_pins
set_property PACKAGE_PIN D26 [get_ports sd_m_clk]
set_property PACKAGE_PIN E25 [get_ports sd_m_cmd]
set_property PACKAGE_PIN E26 [get_ports sd_m_d0]
set_property PACKAGE_PIN D25 [get_ports sd_m_d1]
set_property PACKAGE_PIN H26 [get_ports sd_m_d2]
set_property PACKAGE_PIN G26 [get_ports sd_m_d3]

# Card detect: low when a card is inserted, otherwise high (10k pull-up, 100 nF
# on the board).  F23 is in bank 15, whose VCCO is 3.3 V (bank 15 carries the
# LVTTL buttons and LEDs, buttons.xdc G20, leds.xdc H22): LVTTL.
set_property PACKAGE_PIN F23 [get_ports sd_m_cdet]

set_property -dict {IOSTANDARD LVTTL SLEW SLOW} [get_ports {sd_m_clk sd_m_cmd sd_m_d1 sd_m_d2 sd_m_d3}]
set_property -dict {IOSTANDARD LVTTL} [get_ports {sd_m_d0 sd_m_cdet}]


# Port timing: the SD card engine (rtl/host/sdcard_spi.v, SD_ENGINE = 1 in
# minimig_openaars_top.v) owns SCK, CMD (MOSI), DAT0 (MISO) and DAT3 (CS).
#
# SCK is sdcard_spi's sck_r register, clk_114 / (2 * (div + 1)) in SPI mode 0
# (idles low, MOSI changes with SCK falling, MISO is sampled at the clk_114
# edge that raises SCK).  Constrained for the fastest divider the SD spec
# allows, div = 2: clk_114 / 6 = 18.9 MHz (div 1 = 28.4 MHz is over the 25
# MHz of SPI mode; the firmware never sets div < 2).  The clock is defined at
# the pin, with the register's clock pin as its source, so it includes the
# clock-to-pin delay the card sees; sck_r itself stays a clk_114 data register
# for the shifter (no clock on its Q, cf. cfide's sck_pin in the comment below).
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
set sdc_sck_reg [get_cells -hierarchical -filter {NAME =~ *sdc_spi/sck_r_reg}]
create_generated_clock -name sdc_sck -source [get_pins $sdc_sck_reg/C] -divide_by 6 [get_ports sd_m_clk]
set_output_delay -clock sdc_sck -max  5.0 [get_ports {sd_m_cmd sd_m_d3}]
set_output_delay -clock sdc_sck -min -5.0 [get_ports {sd_m_cmd sd_m_d3}]
set_multicycle_path -setup -start 3 -from [get_clocks clk_114] -to [get_ports {sd_m_cmd sd_m_d3}]
set_multicycle_path -hold  -start 5 -from [get_clocks clk_114] -to [get_ports {sd_m_cmd sd_m_d3}]
set_input_delay -clock sdc_sck -clock_fall -max 14.0 [get_ports sd_m_d0]
set_input_delay -clock sdc_sck -clock_fall -min  0.0 [get_ports sd_m_d0]
set_multicycle_path -setup -end 3 -from [get_ports sd_m_d0] -to [get_clocks clk_114]
set_multicycle_path -hold  -end 2 -from [get_ports sd_m_d0] -to [get_clocks clk_114]
# sd_m_d1 / sd_m_d2 are constant 1.

# Card detect: asynchronous, through sdcard_spi's two-flop synchroniser and a
# 9 ms debounce.
set_false_path -from [get_ports sd_m_cdet]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *sdc_spi/cd_s1_reg || NAME =~ *sdc_spi/cd_s2_reg}]
# <<< sdc_pins

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
set_max_delay -datapath_only 8.815 \
    -from [get_cells -hierarchical -filter {NAME =~ *SDCGAYLE1/q_gray_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *SDCGAYLE1/s_gray1_reg*}]
# <<< sdc_bridge

# The SPI bit clock.  rtl/host/cfide.vhd's sck_pin is a flip-flop in clk_114,
# toggled by the SPI master every (2*speed + 1) clk_114 cycles (+2 while the SD
# card is selected, for the sd_ack handshake); SPI_SCK = NOT sck_pin clocks
# every SPI slave in the Minimig (paula_floppy, userio_osd_spi), and the card
# in builds without the SD card engine (SD_ENGINE = 0, not this board's).
# The firmware's fastest setting is SPI_fast() = speed 1: a half period of 3
# clk_114 cycles, so clk_114 / 6.  Defined as that, with the source it really
# has, so the clock is related to clk_114/dll_28 and intra-SPI paths are timed
# against the real half period (26.4 ns, not the 308 ns of the old /70).
#
# The SPI master's own state machine reads cfide's other copy, sck, as data:
# those paths are plain clk_114 paths now.  (Before, the clock sat on the one
# register that did both, so they were launched by this clock and went untimed
# with the old asynchronous group -- rows 1-32 of report_cdc -from it.)
create_generated_clock -name spi_sck -source [get_pins openaars_virtual_top/mycfide/sck_pin_reg/C] -divide_by 6 [get_pins openaars_virtual_top/mycfide/sck_pin_reg/Q]

# The crossings between spi_sck and the system clocks.  None of them is a
# single-cycle path in the protocol, but each needs its data to arrive in a
# bounded time, which the old asynchronous group never checked:
#  - MOSI and the chip selects (cfide, clk_114) change on the opposite sck edge
#    to the one that samples them, at least 3 clk_114 cycles away;
#  - MISO (slave -> cfide sd_in_shift) is sampled 3 clk_114 cycles after the
#    sck edge that launched it, so it needs datapath + sck routing < 26 ns;
#  - received words (rx_data, out, cmd, rx_cnt, tx_cnt...) are read in dll_28
#    only after their flag (spi_rx_flag, spi_tx_flag, new_byte) has been
#    through a two-stage clk7 synchroniser, >= 70 ns later, and are stable
#    for a whole word (byte) after that;
#  - paula's reply words (spi_tx_data) are loaded at a word's first sck edge,
#    hundreds of ns after the handshake that moved them.  (The OSD's reply
#    byte has the same structure but is only right if the host leaves ~350 ns
#    between bytes -- a protocol matter, sim/spi_cdc; no bound changes it.)
#  - rx_flag / tx_flag / rx clear their sck-side flags asynchronously, long
#    after the flag was set and long before the next word can set it again.
# So bound every crossing to two clk_114 periods of datapath (17.63 ns): that
# keeps MISO inside its 26.4 ns with the sck routing delay (~1.5 ns in the
# routed builds) and is far tighter than the handshakes need, without making
# the placer chase the long reply-mux paths (one period left 0.4 ns of slack
# on the halt -> spi_sdo_reg path in the combo build).  Hold is left alone:
# which side of a coincident edge a value lands on does not matter to any of
# them (sim/spi_cdc runs both orders and an sck a whole clk_114 period late).
# clk_38 only reaches spi_sck through Paula's reset (CPU reset -> the flags'
# asynchronous clears).
set spi_sys_clocks [get_clocks {clk_114 dll_28 clk_38}]
set_max_delay -datapath_only -from [get_clocks spi_sck] -to $spi_sys_clocks 17.630
set_max_delay -datapath_only -from $spi_sys_clocks -to [get_clocks spi_sck] 17.630
