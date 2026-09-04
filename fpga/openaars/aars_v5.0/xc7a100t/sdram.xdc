#SDRAM
# AS4C16M16SA (16M x 16, CL3, burst 8)

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

###############################################################################
# Timing
#
# The SDRAM clock dr_clk is clk_sd_114 (amiga_clk MMCM CLKOUT1, 113.4375 MHz, -121.5 deg =
# -2.975 ns relative to clk_114) driven from its BUFG straight to the pin
# (minimig_virtual_top.v:274). Modelling it as a generated clock on the port includes the
# BUFG -> OBUF path, so both directions below are timed against the clock the SDRAM actually sees.
create_generated_clock -name clk_gen_sdram -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -divide_by 1 [get_ports dr_clk]

# Device timing, AS4C16M16SA-7 at CL3 (datasheet; check against the fitted speed grade):
#   tSU   1.5 ns   command/address/data setup to CK
#   tH    0.8 ns   command/address/data hold from CK
#   tAC3  5.4 ns   CK to data out (-6 grade: 5.0 ns)
#   tOH   2.5 ns   data hold from the next CK
# Board: ~60 mm traces, one way ~0.17 ns.
set sdram_tsu    1.5
set sdram_th     0.8
set sdram_tac    5.4
set sdram_toh    2.5
set sdram_tr_dly 0.17

set sdram_outputs [get_ports {dr_a[*] dr_ba[*] dr_d[*] dr_dqm[*] dr_cas_n dr_cs_n dr_ras_n dr_we_n dr_cke}]
set sdram_inputs  [get_ports {dr_d[*]}]

# Outputs: data must arrive tSU before, and stay tH after, the SDRAM's clock edge.
#   -max =  tSU + trace,  -min = -tH + trace
set_output_delay -clock [get_clocks clk_gen_sdram] -max [expr {$sdram_tsu + $sdram_tr_dly}] $sdram_outputs
set_output_delay -clock [get_clocks clk_gen_sdram] -min [expr {-$sdram_th + $sdram_tr_dly}] $sdram_outputs

# Inputs: read data appears tAC after the SDRAM's clock edge and holds tOH after the next one.
#   -max = tAC + trace,  -min = tOH + trace
set_input_delay -clock [get_clocks clk_gen_sdram] -max [expr {$sdram_tac + $sdram_tr_dly}] $sdram_inputs
set_input_delay -clock [get_clocks clk_gen_sdram] -min [expr {$sdram_toh + $sdram_tr_dly}] $sdram_inputs

# HEAD RTL captures read data in a fabric flop on clk_114. fix-12's dedicated capture clock
# (clk_sd_rd, IOB flop) was reverted: it met timing and passed simulation on all ports but did
# not run on hardware at ANY capture phase across the whole clock period - so the fault is not
# read-capture timing (findings/constraints/fix-12). Read path is one edge marginal at the slow
# corner, which matches the board's long-standing "boots after a few resets" behaviour.
set_multicycle_path -setup -end 2 -from $sdram_inputs -to [get_clocks clk_114]
set_multicycle_path -hold  -end 1 -from $sdram_inputs -to [get_clocks clk_114]
