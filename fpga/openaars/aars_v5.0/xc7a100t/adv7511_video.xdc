#
# Paul Honig 2020
#
# I/O Board
# Open AARS board V2
#
# Core board
# QMTech Artix-7XC7A100T Core Board

# I2C INTERFACE
set_property -dict {PACKAGE_PIN W23 IOSTANDARD LVTTL} [get_ports io_sda]
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVTTL} [get_ports io_scl]

# CLOCK AND ENABLE SIGNALS
set_property -dict {PACKAGE_PIN M26 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_de]
set_property -dict {PACKAGE_PIN L23 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_clk]

# SYNC SIGNALS
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVTTL} [get_ports dv_hsync]
set_property -dict {PACKAGE_PIN K23 IOSTANDARD LVTTL} [get_ports dv_vsync]

# 12-bit DDR data channel
set_property -dict {PACKAGE_PIN T24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[11]}]
set_property -dict {PACKAGE_PIN R25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[10]}]
set_property -dict {PACKAGE_PIN P25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[9]}]
set_property -dict {PACKAGE_PIN P23 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[8]}]
set_property -dict {PACKAGE_PIN P24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[7]}]
set_property -dict {PACKAGE_PIN N21 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[6]}]
set_property -dict {PACKAGE_PIN N22 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[5]}]
set_property -dict {PACKAGE_PIN M24 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[4]}]
set_property -dict {PACKAGE_PIN M25 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[3]}]
set_property -dict {PACKAGE_PIN R26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[2]}]
set_property -dict {PACKAGE_PIN P26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[1]}]
set_property -dict {PACKAGE_PIN N26 IOSTANDARD LVTTL SLEW FAST} [get_ports {dv_d[0]}]

# ADV CEC clock
set_property -dict {PACKAGE_PIN AA25 IOSTANDARD LVTTL} [get_ports dv_cecclk]

# ADV interrupt
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVTTL} [get_ports dv_int]

###############################################################################
# Timing

# Asynchronous inputs: interrupt and I2C are resynchronised in the RTL.
set_false_path -from [get_ports dv_int]
set_false_path -from [get_ports {io_scl io_sda}]
# CEC reference clock output: no timing relationship to anything.
set_false_path -to [get_ports dv_cecclk]

# ADV7511 12-bit DDR bus: dv_clk (74.25 MHz) and the data/sync/DE lines all leave adv_ddr.v from
# registers on clk_148. The clock is NOT forwarded through an ODDR but through an ordinary
# flip-flop (clk_pixel_out), and a generated clock cannot propagate through a flip-flop's D->Q
# (Vivado TIMING-36: "no edge propagation"), so the interface cannot be timed against dv_clk
# until adv_ddr forwards it with an ODDR (findings/constraints/fix-03). Until then:
#   - the registers are packed into the IOBs below, so clock and data reach the pins with the
#     same OLOGIC + OBUF delay (matched to a few hundred ps instead of the 8 ns fabric skew the
#     data bits had), which is what the ADV7511's edge-aligned DDR input needs;
#   - the group is false-pathed HERE, explicitly, rather than masked behind a clock group.
# ADV7511 input requirement for reference (previous constraint set): tsu 0.7 ns, th 1.0 ns.
set dv_data [get_ports {dv_d[*] dv_de dv_hsync dv_vsync}]
set_false_path -to $dv_data
set_false_path -to [get_ports dv_clk]

# Pack the output registers into the IOBs: the data/sync/DE flops and the forwarded pixel clock
# all leave adv_ddr on the same clk_148 edge, and only from the IOB do they reach the pins with
# matched, minimal delay (from the fabric the route alone was 8 ns on dv_d[3]).
set_property IOB TRUE [get_cells -hier -filter {NAME =~ "my_pal_to_ddr/myadr_ddr/data_out_reg[*]" || NAME =~ "my_pal_to_ddr/myadr_ddr/de_out_reg" || NAME =~ "my_pal_to_ddr/myadr_ddr/hsync_out_reg" || NAME =~ "my_pal_to_ddr/myadr_ddr/vsync_out_reg" || NAME =~ "my_pal_to_ddr/myadr_ddr/clk_pixel_out_reg"}]
