#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# PS/2 port 1 (keyboard)
set_property -dict {PACKAGE_PIN D26 IOSTANDARD LVTTL SLEW SLOW} [get_ports ps2_clk1]
set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVTTL SLEW SLOW} [get_ports ps2_data1]

# PS/2 port 2 (Mouse)
set_property -dict {PACKAGE_PIN E26 IOSTANDARD LVTTL SLEW SLOW} [get_ports ps2_clk2]
set_property -dict {PACKAGE_PIN E25 IOSTANDARD LVTTL SLEW SLOW} [get_ports ps2_data2]









































































