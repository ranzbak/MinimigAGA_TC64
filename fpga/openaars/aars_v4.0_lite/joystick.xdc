# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board
#
# Joystick layout [5:0]
# fire2[5],
# fire[4],
# up[3],
# down[2],
# left[1],
# right[0]

# Joystick SPI interface to the MCP23S17 I/O extender
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVTTL} [get_ports js_mosi]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVTTL} [get_ports js_miso]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVTTL} [get_ports js_cs]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVTTL} [get_ports js_sck]
# Interrupt
set_property -dict {PACKAGE_PIN A2 IOSTANDARD LVTTL} [get_ports js_inta]

# Constrain timing on the Joystick port




























