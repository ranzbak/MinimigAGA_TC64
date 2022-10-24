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

# Clocks

# Clock oscillator
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVTTL} [get_ports clk_50]

# Main input clock
create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]

# External clocks
create_clock -period 6.739 -name VIRTUAL_clk_148 -waveform {0.000 3.370}

# Rename the hdmi clock outputs
create_generated_clock -name clk_148 -master_clock [get_clocks clk_50] [get_pins clk_hdmi/CLKOUT0]
set_clock_groups -asynchronous -group [get_clocks clk_148] -group [get_clocks VIRTUAL_clk_148]

# Rename the amiga_clk output pins
create_generated_clock -name clk_114 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]
create_generated_clock -name clk_sd_114 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]
create_generated_clock -name dll_28 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]

# Make SDRAM clock independent of the main clock
set_clock_groups -name sdram_async -asynchronous -group [get_clocks clk_114] -group [get_clocks clk_sd_114]

# Indicate that the sck from the SD card is not a synchronous clock


