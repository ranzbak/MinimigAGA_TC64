#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# UART interface
set_property -dict {PACKAGE_PIN AB26 IOSTANDARD LVTTL} [get_ports uart3_rxd]
set_property -dict {PACKAGE_PIN AC26 IOSTANDARD LVTTL} [get_ports uart3_txd]

# Don't care about the timing
set_false_path -through [get_ports uart3_*]
































