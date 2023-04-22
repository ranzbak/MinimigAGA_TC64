#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# buttons
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVTTL} [get_ports button_osd_in]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVTTL} [get_ports button_user_in]
set_property -dict {PACKAGE_PIN Y25 IOSTANDARD LVTTL} [get_ports button_reset_n_in]

# Time constraints
set_false_path -from [get_ports button_osd_in]
set_false_path -from [get_ports button_user_in]
set_false_path -from [get_ports button_reset_n_in]