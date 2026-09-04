# I2S audio interface MAX9850
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVTTL} [get_ports max_sclk]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVTTL} [get_ports max_lrclk]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVTTL} [get_ports max_i2s]

# I2S channel ADV7511
# No ADV7511 Sound on this board
# set_property -dict {PACKAGE_PIN J21  IOSTANDARD LVTTL} [ get_ports dv_sclk]
# set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVTTL} [ get_ports {dv_i2s[0]}]
# set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVTTL} [ get_ports {dv_i2s[0]}]
# set_property -dict {PACKAGE_PIN H21 IOSTANDARD LVTTL} [ get_ports {dv_i2s[1]}]

# Timing
# The I2S bit clock is a flip-flop divider inside i2s_tx (sclk_reg), driven from clk_114 with a
# data-dependent prescaler; /70 is the fastest it runs. The generated clock exists so that the
# logic clocked by it inside i2s_tx has a clock; the three pins carry no external timing
# requirement and are false-pathed in wizard.xdc together with the other slow serial outputs.
create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins my_i2s_transmitter/sclk_reg/Q]
