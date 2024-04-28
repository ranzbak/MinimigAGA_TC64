#SDRAM
# AS4C16M16SA

## Address ##
set_property -dict {PACKAGE_PIN J1} [get_ports {dr_a[0]}]
set_property -dict {PACKAGE_PIN M5} [get_ports {dr_a[1]}]
set_property -dict {PACKAGE_PIN T3} [get_ports {dr_a[2]}]
set_property -dict {PACKAGE_PIN P6} [get_ports {dr_a[3]}]
set_property -dict {PACKAGE_PIN T4} [get_ports {dr_a[4]}]
set_property -dict {PACKAGE_PIN M6} [get_ports {dr_a[5]}]
set_property -dict {PACKAGE_PIN K1} [get_ports {dr_a[6]}]
set_property -dict {PACKAGE_PIN R3} [get_ports {dr_a[7]}]
set_property -dict {PACKAGE_PIN M4} [get_ports {dr_a[8]}]
set_property -dict {PACKAGE_PIN L5} [get_ports {dr_a[9]}]
set_property -dict {PACKAGE_PIN P3} [get_ports {dr_a[10]}]
set_property -dict {PACKAGE_PIN N2} [get_ports {dr_a[11]}]
set_property -dict {PACKAGE_PIN M2} [get_ports {dr_a[12]}]

## DATA ##
set_property -dict {PACKAGE_PIN C2} [get_ports {dr_d[0]}]
set_property -dict {PACKAGE_PIN D4} [get_ports {dr_d[1]}]
set_property -dict {PACKAGE_PIN D5} [get_ports {dr_d[2]}]
set_property -dict {PACKAGE_PIN B1} [get_ports {dr_d[3]}]
set_property -dict {PACKAGE_PIN D1} [get_ports {dr_d[4]}]
set_property -dict {PACKAGE_PIN E2} [get_ports {dr_d[5]}]
set_property -dict {PACKAGE_PIN F4} [get_ports {dr_d[6]}]
set_property -dict {PACKAGE_PIN G1} [get_ports {dr_d[7]}]
set_property -dict {PACKAGE_PIN G2} [get_ports {dr_d[8]}]
set_property -dict {PACKAGE_PIN G4} [get_ports {dr_d[9]}]
set_property -dict {PACKAGE_PIN F2} [get_ports {dr_d[10]}]
set_property -dict {PACKAGE_PIN E1} [get_ports {dr_d[11]}]
set_property -dict {PACKAGE_PIN C1} [get_ports {dr_d[12]}]
set_property -dict {PACKAGE_PIN E5} [get_ports {dr_d[13]}]
set_property -dict {PACKAGE_PIN B2} [get_ports {dr_d[14]}]
set_property -dict {PACKAGE_PIN A3} [get_ports {dr_d[15]}]

## BANK ##
set_property -dict {PACKAGE_PIN K5} [get_ports {dr_ba[0]}]
set_property -dict {PACKAGE_PIN L4} [get_ports {dr_ba[1]}]

## CONTROL ##
set_property -dict {PACKAGE_PIN N3} [get_ports dr_cs_n]

set_property -dict {PACKAGE_PIN H4} [get_ports {dr_dqm[0]}]
set_property -dict {PACKAGE_PIN J4} [get_ports {dr_dqm[1]}]

set_property -dict {PACKAGE_PIN L2} [get_ports dr_ras_n]
set_property -dict {PACKAGE_PIN G9} [get_ports dr_cas_n]
set_property -dict {PACKAGE_PIN H1} [get_ports dr_we_n]
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

# External clock -146' offset
# create_clock -period 8.815 -name VIRTUAL_clk_114  -waveform {0.0 4.408}
create_generated_clock -name clk_gen_sdram -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -divide_by 1 [get_ports dr_clk]

# Received data from the SDRAM chip is received one clock cycle later
# set_multicycle_path -setup  -from [get_ports {dr_d[*]}] -to [get_cells openaars_virtual_top/sdram/sdata_reg*] 2
# set_multicycle_path -hold -from [get_ports {dr_d[*]}] -to [get_cells openaars_virtual_top/sdram/sdata_reg*] 2
set_multicycle_path -setup  -from [get_ports {dr_d[*]}] -to [get_clocks clk_114] 2
set_multicycle_path -hold -from [get_ports {dr_d[*]}] -to [get_clocks clk_114] 2

set sdram_outputs [get_ports {dr_a[*] dr_ba[*] dr_d[*] dr_dqm[*] dr_cas_n dr_cs_n dr_ras_n dr_we_n }]
set sdram_inputs  [get_ports {dr_d[*]}]

# SDRAM setup/hold
set sdram_tsu 1.5
set sdram_thd -0.8
# Trace delay min/max
set sdram_tr_dly 0.17

set sdram_dly_max [expr {$sdram_tr_dly - $sdram_tsu}]
set sdram_dly_min [expr {$sdram_tr_dly + $sdram_tsu}]

set_output_delay -clock [get_clocks clk_gen_sdram] -min -add_delay $sdram_dly_min $sdram_outputs
set_output_delay -clock [get_clocks clk_gen_sdram] -max -add_delay $sdram_dly_max $sdram_outputs

set sdram_toh_min 2.5
set sdram_toh_max 3.0
set sdram_dly_in_max [expr {$sdram_toh_min + $sdram_tr_dly}]
set sdram_dly_in_min [expr {$sdram_toh_max + $sdram_tr_dly}]
set_input_delay -clock [get_clocks clk_sd_114] -min -add_delay $sdram_dly_in_max [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks clk_sd_114] -max -add_delay $sdram_dly_in_min [get_ports {dr_d[*]}]