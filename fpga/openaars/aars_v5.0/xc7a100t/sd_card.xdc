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
set_property PACKAGE_PIN F23 [get_ports sd_m_cdet]

set_property -dict {IOSTANDARD LVTTL SLEW SLOW } [get_ports {sd_m_clk sd_m_cmd sd_m_d1 sd_m_d2 sd_m_d3}]
set_property -dict {IOSTANDARD LVTTL } [get_ports {sd_m_d0 sd_m_cdet}]


# Port timing
set_false_path -from [get_ports sd_m_d0]