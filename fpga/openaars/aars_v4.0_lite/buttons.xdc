#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# buttons
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVTTL} [get_ports button_osd]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVTTL} [get_ports button_user]
set_property -dict {PACKAGE_PIN Y25 IOSTANDARD LVTTL} [get_ports sys_reset_in]








