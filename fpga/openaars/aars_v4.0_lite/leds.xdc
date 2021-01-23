#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# Core board LED
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVTTL} [get_ports led_core]

# LEDS
set_property -dict {PACKAGE_PIN J21 IOSTANDARD LVTTL} [get_ports led_hdisk]
set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVTTL} [get_ports led_user]
set_property -dict {PACKAGE_PIN K26 IOSTANDARD LVTTL} [get_ports led_power]
set_property -dict {PACKAGE_PIN K25 IOSTANDARD LVTTL} [get_ports led_fdisk]

# We don't care for the LED timing
set_false_path -through [get_ports led_*]






































































