#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# PS/2 port 1 (keyboard)
set_property PACKAGE_PIN E23 [get_ports ps2_clk1]
set_property PACKAGE_PIN F22 [get_ports ps2_data1]

# PS/2 port 2 (Mouse)
set_property PACKAGE_PIN G22 [get_ports ps2_clk2]
set_property PACKAGE_PIN J25 [get_ports ps2_data2]

# Set the port properties for all PS2 pins
set_property IOSTANDARD LVTTL [get_ports ps2_clk1]
set_property IOSTANDARD LVTTL [get_ports ps2_clk2]
set_property IOSTANDARD LVTTL [get_ports ps2_data1]
set_property IOSTANDARD LVTTL [get_ports ps2_data2]
set_property SLEW SLOW [get_ports ps2_clk1]
set_property SLEW SLOW [get_ports ps2_clk2]
set_property SLEW SLOW [get_ports ps2_data1]
set_property SLEW SLOW [get_ports ps2_data2]
set_property PULLUP true [get_ports ps2_clk1]
set_property PULLUP true [get_ports ps2_clk2]
set_property PULLUP true [get_ports ps2_data1]
set_property PULLUP true [get_ports ps2_data2]


# Set timing constraints
set_false_path -from [get_ports ps2_*]
set_false_path -to [get_ports ps2_*]



