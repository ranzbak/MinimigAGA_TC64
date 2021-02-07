#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# SD-Card interface
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVTTL SLEW SLOW} [get_ports sd_m_clk]
set_property PACKAGE_PIN Y26 [get_ports sd_m_cmd]
set_property IOSTANDARD LVTTL [get_ports sd_m_cmd]
set_property PULLUP true [get_ports sd_m_cmd]
set_property SLEW SLOW [get_ports sd_m_cmd]
set_property PACKAGE_PIN Y21 [get_ports sd_m_d0]
set_property IOSTANDARD LVTTL [get_ports sd_m_d0]
set_property PULLUP true [get_ports sd_m_d0]
set_property PACKAGE_PIN AC24 [get_ports sd_m_d1]
set_property IOSTANDARD LVTTL [get_ports sd_m_d1]
set_property PULLUP true [get_ports sd_m_d1]
set_property SLEW SLOW [get_ports sd_m_d1]
set_property PACKAGE_PIN AB24 [get_ports sd_m_d2]
set_property IOSTANDARD LVTTL [get_ports sd_m_d2]
set_property PULLUP true [get_ports sd_m_d2]
set_property SLEW SLOW [get_ports sd_m_d2]
set_property PACKAGE_PIN W25 [get_ports sd_m_d3]
set_property IOSTANDARD LVTTL [get_ports sd_m_d3]
set_property PULLUP true [get_ports sd_m_d3]
set_property SLEW SLOW [get_ports sd_m_d3]

set_property PACKAGE_PIN AA25 [get_ports sd_m_cdet]
set_property IOSTANDARD LVTTL [get_ports sd_m_cdet]

# Port timing












