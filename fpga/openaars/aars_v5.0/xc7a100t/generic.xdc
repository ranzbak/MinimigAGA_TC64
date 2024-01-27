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
