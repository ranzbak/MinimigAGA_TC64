#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# UART 0 interface
set_property -dict {PACKAGE_PIN AB24 IOSTANDARD LVTTL} [get_ports uart0_txd]
set_property -dict {PACKAGE_PIN W25 IOSTANDARD LVTTL} [get_ports uart0_rxd]
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVTTL} [get_ports uart0_cts]
set_property -dict {PACKAGE_PIN Y26 IOSTANDARD LVTTL} [get_ports uart0_rts]

# UART 1 interface, model has no RTS/CTS
set_property -dict {PACKAGE_PIN Y25 IOSTANDARD LVTTL} [get_ports uart1_txd]
set_property -dict {PACKAGE_PIN AC24 IOSTANDARD LVTTL} [get_ports uart1_rxd]
# set_property -dict {PACKAGE_PIN V23 IOSTANDARD LVTTL} [get_ports uart1_cts]
# set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVTTL} [get_ports uart1_rts]

# Don't care about the timing
set_false_path -from [get_ports {uart0_rxd uart0_cts uart1_rxd uart1_cts}]
set_false_path -to [get_ports {uart0_txd uart0_rts uart1_txd uart1_rts}]