#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V4
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# PMOD interface
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVTTL} [get_ports pmod_12]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVTTL} [get_ports pmod_1]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVTTL} [get_ports pmod_11]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVTTL} [get_ports pmod_2]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVTTL} [get_ports pmod_9]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVTTL} [get_ports pmod_10]

# U255	P1	34		Right	PMOD_12
# U256	R1	34		Left	PMOD_1
# U257	R2	34		Right	PMOD_11
# U258	T2	34		Left	PMOD_2
# U259	U1	34		Right	PMOD_9
# U260	U2	34		Left	PMOD_10









