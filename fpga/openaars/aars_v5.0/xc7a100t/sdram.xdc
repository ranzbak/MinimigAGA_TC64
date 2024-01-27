#SDRAM
# AS4C16M16SA

## Address ##
set_property -dict {PACKAGE_PIN J1 IOB TRUE} [get_ports {dr_a[0]}]
set_property -dict {PACKAGE_PIN M5 IOB TRUE} [get_ports {dr_a[1]}]
set_property -dict {PACKAGE_PIN T3 IOB TRUE} [get_ports {dr_a[2]}]
set_property -dict {PACKAGE_PIN P6 IOB TRUE} [get_ports {dr_a[3]}]
set_property -dict {PACKAGE_PIN T4 IOB TRUE} [get_ports {dr_a[4]}]
set_property -dict {PACKAGE_PIN M6 IOB TRUE} [get_ports {dr_a[5]}]
set_property -dict {PACKAGE_PIN K1 IOB TRUE} [get_ports {dr_a[6]}]
set_property -dict {PACKAGE_PIN R3 IOB TRUE} [get_ports {dr_a[7]}]
set_property -dict {PACKAGE_PIN M4 IOB TRUE} [get_ports {dr_a[8]}]
set_property -dict {PACKAGE_PIN L5 IOB TRUE} [get_ports {dr_a[9]}]
set_property -dict {PACKAGE_PIN P3 IOB TRUE} [get_ports {dr_a[10]}]
set_property -dict {PACKAGE_PIN N2 IOB TRUE} [get_ports {dr_a[11]}]
set_property -dict {PACKAGE_PIN M2 IOB TRUE} [get_ports {dr_a[12]}]

## DATA ##
set_property -dict {PACKAGE_PIN C2 IOB TRUE} [get_ports {dr_d[0]}]
set_property -dict {PACKAGE_PIN D4 IOB TRUE} [get_ports {dr_d[1]}]
set_property -dict {PACKAGE_PIN D5 IOB TRUE} [get_ports {dr_d[2]}]
set_property -dict {PACKAGE_PIN B1 IOB TRUE} [get_ports {dr_d[3]}]
set_property -dict {PACKAGE_PIN D1 IOB TRUE} [get_ports {dr_d[4]}]
set_property -dict {PACKAGE_PIN E2 IOB TRUE} [get_ports {dr_d[5]}]
set_property -dict {PACKAGE_PIN F4 IOB TRUE} [get_ports {dr_d[6]}]
set_property -dict {PACKAGE_PIN G1 IOB TRUE} [get_ports {dr_d[7]}]
set_property -dict {PACKAGE_PIN G2 IOB TRUE} [get_ports {dr_d[8]}]
set_property -dict {PACKAGE_PIN G4 IOB TRUE} [get_ports {dr_d[9]}]
set_property -dict {PACKAGE_PIN F2 IOB TRUE} [get_ports {dr_d[10]}]
set_property -dict {PACKAGE_PIN E1 IOB TRUE} [get_ports {dr_d[11]}]
set_property -dict {PACKAGE_PIN C1 IOB TRUE} [get_ports {dr_d[12]}]
set_property -dict {PACKAGE_PIN E5 IOB TRUE} [get_ports {dr_d[13]}]
set_property -dict {PACKAGE_PIN B2 IOB TRUE} [get_ports {dr_d[14]}]
set_property -dict {PACKAGE_PIN A3 IOB TRUE} [get_ports {dr_d[15]}]

## BANK ##
set_property -dict {PACKAGE_PIN K5 IOB TRUE} [get_ports {dr_ba[0]}]
set_property -dict {PACKAGE_PIN L4 IOB TRUE} [get_ports {dr_ba[1]}]

## CONTROL ##
set_property -dict {PACKAGE_PIN N3 IOB TRUE} [get_ports dr_cs_n]

set_property -dict {PACKAGE_PIN H4 IOB TRUE} [get_ports {dr_dqm[0]}]
set_property -dict {PACKAGE_PIN J4 IOB TRUE} [get_ports {dr_dqm[1]}]

set_property -dict {PACKAGE_PIN L2 IOB TRUE} [get_ports dr_ras_n]
set_property -dict {PACKAGE_PIN G9 IOB TRUE} [get_ports dr_cas_n]
set_property -dict {PACKAGE_PIN H1 IOB TRUE} [get_ports dr_we_n]
set_property -dict {PACKAGE_PIN H9} [get_ports dr_cke]
set_property -dict {PACKAGE_PIN H2} [get_ports dr_clk]

set_property -dict {IOSTANDARD LVTTL DRIVE 12 SLEW FAST} [get_ports dr_*]

# Define SDRAM input clock

# Input clocks
# A safe amount of phase shift is at least the output hold time of your far-end device,
# plus your best-case (fastest) calculated round-trip flight time, entered as your set_output_delay -min value (entered as a negative number for hold time.)
# output hold time sdram = 2.5 ns
# 60mm trace length = 0.7ns 6ns/meter * 0.06m *2
# Phase shift SDRAM = 3.2 ns

# Timing


# Data sampling is edge aligned

# name SDRAM ports


# input delay
# set_input_delay -clock $input_clock -reference_pin [get_ports dr_clk] -max $skew_bre $sdram_inputs
# set_input_delay -clock $input_clock -reference_pin [get_ports dr_clk] -max $skew_bre $sdram_inputs
set_input_delay -clock [get_clocks clk_114] -max 1.500 [get_ports [get_ports {dr_d[*]}]]
set_input_delay -clock [get_clocks clk_114] -min -0.800 [get_ports [get_ports {dr_d[*]}]]



# Output Delay Constraints
# Clock pin
set_output_delay -clock [get_clocks clk_114] -max 1.500 [get_ports [get_ports dr_clk]]
set_output_delay -clock [get_clocks clk_114] -min -0.800 [get_ports [get_ports dr_clk]]

# report_timing -to [get_ports $sdram_clk] -max_paths 20 -nworst 1 -delay_type min_max -name sys_sync_rise_out -file sys_sync_rise_out.txt;

# Output pins
set_output_delay -clock [get_clocks clk_114] -max 1.500 [get_ports [get_ports {{dr_d[*]} {dr_a[*]} dr_cs_n {dr_ba[*]} dr_dqm dr_ras_n dr_cas_n dr_we_n dr_cke}]]
set_output_delay -clock [get_clocks clk_114] -min -0.800 [get_ports [get_ports {{dr_d[*]} {dr_a[*]} dr_cs_n {dr_ba[*]} dr_dqm dr_ras_n dr_cas_n dr_we_n dr_cke}]]

# Adjust data window for SDRAM reads by 1 cycle
# set_multicycle_path -setup -from clk_sd_114 -to [get_clocks clk_114] 2
# set_multicycle_path -hold -from clk_sd_114 -to [get_clocks clk_114] 2

# TODO: check if correct - don't care for dr_clk
set_false_path -from [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -to [get_ports dr_clk]