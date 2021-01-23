#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# Virtual ui_clk (200MHz)

# Virtual clk_sys (28MHz)

# Indicate the SPI path count to the Flash chip
# This uses 4 SPI lanes during programming
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

# Configuration bank voltage select
set_property CFGBVS VCCO [current_design]
# I/O voltage bank configuration
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Disable errors when finding unassigned pins

# Core board

# Clock oscillator
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVTTL} [get_ports clk_50mhz]
create_clock -period 20.000 -name clk_50mhz -add [get_ports clk_50mhz]

# Reset button
# Included here to be complete
#set_property PACKAGE_PIN AE16 [get_ports i_sw1_n]
#set_property IOSTANDARD LVCMOS33 [get_ports i_sw1_n]
# Reset button for the FPGA, removing the configuration

# Reset input button
set_property -dict {PACKAGE_PIN Y25 IOSTANDARD LVTTL} [get_ports sys_reset_in]

# Constrain input delay of the reset signal




















































