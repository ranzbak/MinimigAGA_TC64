#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# I2C INTERFACE
set_property -dict {PACKAGE_PIN W23 IOSTANDARD LVTTL} [get_ports io_sda]
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVTTL} [get_ports io_scl]

# CLOCK AND ENABLE SIGNALS
set_property -dict {PACKAGE_PIN M26 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_de]
# set_property -dict {PACKAGE_PIN L23 IOSTANDARD LVTTL DRIVE 8} [get_ports dv_clk]
set_property -dict {PACKAGE_PIN L23 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_clk]


# SYNC SIGNALS
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVTTL} [get_ports dv_hsync]
set_property -dict {PACKAGE_PIN K23 IOSTANDARD LVTTL} [get_ports dv_vsync]

# 12-bit DDR data channel
set_property -dict {PACKAGE_PIN T24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[11]}]
set_property -dict {PACKAGE_PIN R25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[10]}]
set_property -dict {PACKAGE_PIN P25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[9]}]
set_property -dict {PACKAGE_PIN P23 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[8]}]
set_property -dict {PACKAGE_PIN P24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[7]}]
set_property -dict {PACKAGE_PIN N21 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[6]}]
set_property -dict {PACKAGE_PIN N22 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[5]}]
set_property -dict {PACKAGE_PIN M24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[4]}]
set_property -dict {PACKAGE_PIN M25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[3]}]
set_property -dict {PACKAGE_PIN R26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[2]}]
set_property -dict {PACKAGE_PIN P26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[1]}]
set_property -dict {PACKAGE_PIN N26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[0]}]

# ADV CEC clock
set_property -dict {PACKAGE_PIN AA25 IOSTANDARD LVTTL} [get_ports dv_cecclk]

# ADV interrupt
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVTTL} [get_ports dv_int]

# Set timing constraints
set_false_path -from [get_ports dv_int]


# TODO: review output delay settings
# set_output_delay -clock [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -min -add_delay -0.700 [get_ports -filter { NAME =~  "*dv_*" && DIRECTION == "OUT" }]
# set_output_delay -clock [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -max -add_delay 1.000 [get_ports -filter { NAME =~  "*dv_*" && DIRECTION == "OUT" }]


# Setup an Asynchronous clock group as destination
#create_clock -period 6.739 -name fw_clk_148 -waveform {0.000 3.370}
# set_clock_groups -asynchronous -group [get_clocks {clk_148 }] -group [get_clocks {fw_clk_148 }]]

# Output Delay Constraint

# set_output_delay -clock fw_clk_148 -max 4+1.5  $dv_out_ports;
# set_output_delay -clock fw_clk_148 -min 3-0.8 $dv_out_ports;

set_false_path -from [get_ports {io_scl io_sda}]

# Set output delays for the high speed ADV7511 ports
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -1.000 [get_ports {{dv_d[*]} dv_clk dv_de dv_hsync dv_vsync dv_vsync}]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 0.700 [get_ports {{dv_d[*]} dv_clk dv_de dv_hsync dv_vsync dv_vsync}]