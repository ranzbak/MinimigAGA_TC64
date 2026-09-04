#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# SD-Card interface
set_property PACKAGE_PIN D26 [get_ports sd_m_clk]
set_property PACKAGE_PIN E25 [get_ports sd_m_cmd]
set_property PACKAGE_PIN E26 [get_ports sd_m_d0]
set_property PACKAGE_PIN D25 [get_ports sd_m_d1]
set_property PACKAGE_PIN H26 [get_ports sd_m_d2]
set_property PACKAGE_PIN G26 [get_ports sd_m_d3]

# Low when card is inserted, otherwise high

set_property -dict {IOSTANDARD LVTTL SLEW SLOW} [get_ports {sd_m_clk sd_m_cmd sd_m_d1 sd_m_d2 sd_m_d3}]
set_property -dict {IOSTANDARD LVTTL} [get_ports {sd_m_d0 sd_m_cdet}]


# Port timing
# Card data in is resampled by the SPI logic; no input timing requirement.
set_false_path -from [get_ports sd_m_d0]
# sd_m_cmd / sd_m_d3 are false-pathed with the other slow serial outputs in wizard.xdc.

# The SPI bit clock is a flip-flop toggled by the cfide state machine (rtl/host/cfide.vhd sck),
# driven from clk_114; /70 is the fastest it runs. The generated clock exists so that the
# registers clocked by it have a clock. Its crossings with clk_114/dll_28 are inside cfide and
# by construction many cycles apart, hence the asynchronous group.
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114 dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]