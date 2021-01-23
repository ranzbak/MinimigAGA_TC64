#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# Time constraints
create_clock -period 8.889 -name VIRTUAL_ADV_clk -waveform {0.000 4.444}
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -min -add_delay -1.000 [get_ports -regexp {dv_(clk|de|hsync|vsync|d\[[0-9]?[0-9]\])}]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk] -max -add_delay 0.700 [get_ports -regexp {dv_(clk|de|hsync|vsync|d\[[0-9]?[0-9]\])}]

create_clock -period 35.556 -name VIRTUAL_ADV_clk28m -waveform {0.000 17.778}
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk28m] -min -add_delay -0.800 [get_ports -regexp dv_(sda|sdl|cecclk)]
set_output_delay -clock [get_clocks VIRTUAL_ADV_clk28m] -max -add_delay 1.800 [get_ports -regexp dv_(sda|scl|cecclk)]

# I2C INTERFACE
set_property -dict {PACKAGE_PIN T25 IOSTANDARD LVTTL} [get_ports dv_sda]
set_property -dict {PACKAGE_PIN V21 IOSTANDARD LVTTL} [get_ports dv_scl]

# CLOCK AND ENABLE SIGNALS
set_property -dict {PACKAGE_PIN M26 IOSTANDARD LVTTL} [get_ports dv_de]
set_property -dict {PACKAGE_PIN L23 IOSTANDARD LVTTL DRIVE 8} [get_ports dv_clk]

# SYNC SIGNALS
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVTTL} [get_ports dv_hsync]
set_property -dict {PACKAGE_PIN K23 IOSTANDARD LVTTL} [get_ports dv_vsync]

# 12-bit DDR data channel
set_property -dict {PACKAGE_PIN T24 IOSTANDARD LVTTL} [get_ports {dv_d[11]}]
set_property -dict {PACKAGE_PIN R25 IOSTANDARD LVTTL} [get_ports {dv_d[10]}]
set_property -dict {PACKAGE_PIN P25 IOSTANDARD LVTTL} [get_ports {dv_d[9]}]
set_property -dict {PACKAGE_PIN P23 IOSTANDARD LVTTL} [get_ports {dv_d[8]}]
set_property -dict {PACKAGE_PIN P24 IOSTANDARD LVTTL} [get_ports {dv_d[7]}]
set_property -dict {PACKAGE_PIN N21 IOSTANDARD LVTTL} [get_ports {dv_d[6]}]
set_property -dict {PACKAGE_PIN N22 IOSTANDARD LVTTL} [get_ports {dv_d[5]}]
set_property -dict {PACKAGE_PIN M24 IOSTANDARD LVTTL} [get_ports {dv_d[4]}]
set_property -dict {PACKAGE_PIN M25 IOSTANDARD LVTTL} [get_ports {dv_d[3]}]
set_property -dict {PACKAGE_PIN R26 IOSTANDARD LVTTL} [get_ports {dv_d[2]}]
set_property -dict {PACKAGE_PIN P26 IOSTANDARD LVTTL} [get_ports {dv_d[1]}]
set_property -dict {PACKAGE_PIN N26 IOSTANDARD LVTTL} [get_ports {dv_d[0]}]

# ADV CEC clock
set_property -dict {PACKAGE_PIN W23 IOSTANDARD LVTTL} [get_ports dv_cecclk]

set_max_delay -from [get_pins -hierarchical -regexp {.*my_pal_to_ddr/_i_pal.*_reg.*/C$.*}] -to [get_pins -hierarchical -regexp {.*my_pal_to_ddr/__i_pal_.*_reg.*/D$.*}] 1.500











