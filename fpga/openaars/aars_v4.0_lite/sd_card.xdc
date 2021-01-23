#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# SD-Card interface
set_property PACKAGE_PIN W21 [get_ports sd_m_clk]
set_property IOSTANDARD LVTTL [get_ports sd_m_clk]
set_property PULLUP true [get_ports sd_m_clk]
set_property SLEW SLOW [get_ports sd_m_clk]
set_property PACKAGE_PIN Y26 [get_ports sd_m_cmd]
set_property IOSTANDARD LVTTL [get_ports sd_m_cmd]
set_property PULLUP true [get_ports sd_m_cmd]
set_property SLEW SLOW [get_ports sd_m_cmd]
set_property PACKAGE_PIN Y21 [get_ports {sd_m_d[0]}]
set_property IOSTANDARD LVTTL [get_ports {sd_m_d[0]}]
set_property PULLUP true [get_ports {sd_m_d[0]}]
set_property SLEW SLOW [get_ports {sd_m_d[0]}]
set_property PACKAGE_PIN AC24 [get_ports {sd_m_d[1]}]
set_property IOSTANDARD LVTTL [get_ports {sd_m_d[1]}]
set_property PULLUP true [get_ports {sd_m_d[1]}]
set_property SLEW SLOW [get_ports {sd_m_d[1]}]
set_property PACKAGE_PIN AB24 [get_ports {sd_m_d[2]}]
set_property IOSTANDARD LVTTL [get_ports {sd_m_d[2]}]
set_property PULLUP true [get_ports {sd_m_d[2]}]
set_property SLEW SLOW [get_ports {sd_m_d[2]}]
set_property PACKAGE_PIN W25 [get_ports {sd_m_d[3]}]
set_property IOSTANDARD LVTTL [get_ports {sd_m_d[3]}]
set_property PULLUP true [get_ports {sd_m_d[3]}]
set_property SLEW SLOW [get_ports {sd_m_d[3]}]
set_property PACKAGE_PIN AA25 [get_ports sd_m_cdet]
set_property IOSTANDARD LVTTL [get_ports sd_m_cdet]
set_property PULLUP true [get_ports sd_m_cdet]

# Port timing

set_input_delay -clock [get_clocks VIRTUAL_ADV_clk] -min -add_delay -5.000 [get_ports {sd_m_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_ADV_clk] -max -add_delay 5.000 [get_ports {sd_m_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -min -add_delay -5.000 [get_ports {sd_m_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -max -add_delay 5.000 [get_ports {sd_m_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -min -add_delay -5.000 [get_ports sd_m_clk]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -max -add_delay 5.000 [get_ports sd_m_clk]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -min -add_delay -5.000 [get_ports sd_m_cmd]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -max -add_delay 5.000 [get_ports sd_m_cmd]