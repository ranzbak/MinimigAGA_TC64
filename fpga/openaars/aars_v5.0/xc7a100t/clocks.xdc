
# Clocks

# Main input clock
create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]

# External clocks
create_clock -period 6.734 -name VIRTUAL_clk_148 -waveform {0.000 3.367}

# Clock oscillator
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVTTL} [get_ports clk_50]


# Rename the amiga_clk output pins
create_generated_clock -name clk_114 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]
create_generated_clock -name clk_sd_114 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]
create_generated_clock -name dll_28 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]

# Make SDRAM clock independent of the main clock
set_clock_groups -name sdram_async -asynchronous -group [get_clocks clk_114] -group [get_clocks clk_sd_114]

# Indicate that the sck from the SD card is not a synchronous clock

# 100MHz LVDS clock input
create_clock -period 10.000 -name clk_100_p -waveform {0.000 5.000} [get_ports clk_100_p]
# create_clock -period 10.000 -name clk_100 -waveform {0.000 5.000} [get_ports {clk_100_p}] # 100 MHz

# I/O standard and package pin constraints (combined)
set_property -dict {PACKAGE_PIN U21} [get_ports clk_100_p]
set_property -dict {PACKAGE_PIN V21} [get_ports clk_100_n]
set_input_jitter clk_100_p 0.002

# Differential pair constraints
# set_property -dict {IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports {clk_100_p clk_100_n}]
set_property -dict {IOSTANDARD LVTTL}  [get_ports {clk_100_p clk_100_n}]

# Set the input clock jitter
set_input_jitter clk_100_p 0.002

# Rename the hdmi clock outputs
create_generated_clock -name clk_148 -master_clock [get_clocks clk_50] [get_pins clk_hdmi/CLKOUT0]
set_clock_groups -asynchronous -group [get_clocks clk_148] -group [get_clocks VIRTUAL_clk_148]

