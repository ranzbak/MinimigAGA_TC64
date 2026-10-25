#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# SD-Card interface
# The lines between the sdc_pins markers are also read on their own by the SD
# card engine's size and timing check (tools/vivado/ooc_sdcard/run.tcl, io
# mode): keep them free of other names.
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

# <<< sdc_pins

# Port timing: in sd_card_engine.tcl, an unmanaged Tcl constraint file (XDC has
# no "if"): the SD card engine's SCK / CMD / DAT0 / DAT3 / card-detect timing
# and its Gayle bridge bound when the build has the engine (SD_ENGINE = 1),
# else today's false paths for the card on cfide's SPI.

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
