#SDRAM

# Timing constraints
create_clock -period 8.889 -name VIRTUAL_DDR_clk -waveform {0.000 4.444}
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -0.800 [get_ports {dr_a[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 1.800 [get_ports {dr_a[*]}]
set_input_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay 0.600 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 1.800 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -min -add_delay -1.800 [get_ports dr_we_n]
set_output_delay -clock [get_clocks VIRTUAL_DDR_clk] -max -add_delay 0.600 [get_ports dr_we_n]


## Address ##
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[0]}]
set_property -dict {PACKAGE_PIN M5 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[1]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[2]}]
set_property -dict {PACKAGE_PIN P6 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[3]}]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[4]}]
set_property -dict {PACKAGE_PIN M6 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[5]}]
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[6]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[7]}]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[8]}]
set_property -dict {PACKAGE_PIN L5 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[9]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[10]}]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[11]}]
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_a[12]}]

## DATA ##
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[0]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[1]}]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[2]}]
set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[3]}]
set_property -dict {PACKAGE_PIN D1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[4]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[5]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[6]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[7]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[8]}]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[9]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[10]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[11]}]
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[12]}]
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[13]}]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[14]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_d[15]}]

## BANK ##
set_property -dict {PACKAGE_PIN K5 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_ba[0]}]
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_ba[1]}]

## CONTROL ##
set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_cs_n]

set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_dqm[0]}]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports {dr_dqm[1]}]

set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_ras_n]
set_property -dict {PACKAGE_PIN G9 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_cas_n]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_we_n]
set_property -dict {PACKAGE_PIN H9 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_cke]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_clk]
















