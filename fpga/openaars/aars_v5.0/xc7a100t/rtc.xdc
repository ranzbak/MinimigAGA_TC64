
#
# Paul Honig 2023
#
# I/O Board
# Open AARS board V5
#
# Core board
# QMTech Artix-7XC7A100T Core Board


# Real time clock SPI pins
# PCF2123TS SPI RTC IC
set_property -dict {PACKAGE_PIN P1} [get_ports rtc_int_n]
set_property -dict {PACKAGE_PIN R1} [get_ports rtc_spi_ce]
set_property -dict {PACKAGE_PIN U2} [get_ports rtc_spi_clk]
set_property -dict {PACKAGE_PIN R2} [get_ports rtc_spi_cmd]
set_property -dict {PACKAGE_PIN T2} [get_ports rtc_spi_data0]
# Can be configured to be 32.768, 16.384, 8.192 kHz
set_property -dict {PACKAGE_PIN U1} [get_ports rtc_clkout]


set_property -dict {IOSTANDARD LVTTL SLEW SLOW} [get_ports rtc_*]

# For this low speed SPI interface we don't care about timing.
set_false_path -to [get_ports {rtc_*}]
set_false_path -from [get_ports {rtc_*}]


