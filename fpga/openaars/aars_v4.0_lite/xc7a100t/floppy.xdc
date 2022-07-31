# Floppy drive physical interface pins
# Input is all open drain

# Disk read data (input)
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVTTL} [get_ports EXP_DKRD]

# Select Disk side (0=Upper, 1=Lower) (output)
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVTTL} [get_ports EXP_SIDE]

# Drive Head position over track 0 (input)
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVTTL} [get_ports EXP_TRK0]
# Disk Ready (input)
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVTTL} [get_ports EXP_RDY]

# OC = Open Collector

# Select drive 1 (OC)
set_property -dict {PACKAGE_PIN R12 IOSTANDARD LVTTL} [get_ports EXP_SEL0]
# Select Head direction (0=inner, 1=outer) (output)
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVTTL} [get_ports EXP_DIR]
# Disk removed from drive (lanched low)
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVTTL} [get_ports EXP_CHNG]
# Disk write enable (OC) (output)
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVTTL} [get_ports EXP_DKWEB]
# Select drive 1 (OC)
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVTTL} [get_ports EXP_SEL1]
# Step to Head-Pulse, First low, then high (output)
set_property -dict {PACKAGE_PIN T13 IOSTANDARD LVTTL} [get_ports EXP_STEP]
# Disk index pulse (OC) (Input)
set_property -dict {PACKAGE_PIN P13 IOSTANDARD LVTTL} [get_ports EXP_INDEX]
# Disk write data (output)
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVTTL} [get_ports EXP_DKWDB]









