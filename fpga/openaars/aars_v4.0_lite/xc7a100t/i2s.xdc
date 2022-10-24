# I2S audio interface MAX9850
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVTTL} [get_ports max_sclk]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVTTL} [get_ports max_lrclk]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVTTL} [get_ports max_i2s]

# I2S channel ADV7511
# No ADV7511 Sound on this board
# set_property -dict {PACKAGE_PIN J21  IOSTANDARD LVTTL} [ get_ports dv_sclk]
# set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVTTL} [ get_ports dv_lrclk]
# set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVTTL} [ get_ports {dv_i2s[0]}]
# set_property -dict {PACKAGE_PIN H21 IOSTANDARD LVTTL} [ get_ports {dv_i2s[1]}]

# Timing constraints
# TODO check invalid path
# set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks my_i2s_transmitter/max_sclk_OBUF]
















