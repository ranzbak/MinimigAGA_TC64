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
# Header pin 30, the clock's neighbour on the core-board header (pin 29); not connected on the IO
# board. Held low (strongest LVTTL drive) as a return path next to the clock.
set_property -dict {PACKAGE_PIN L22 IOSTANDARD LVTTL DRIVE 24} [get_ports dv_clk_gnd]

# SYNC SIGNALS
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_hsync]
set_property -dict {PACKAGE_PIN K23 IOSTANDARD LVTTL SLEW FAST} [get_ports dv_vsync]

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

# ADV7511 12-bit DDR bus (2026-10-10).  dv_clk (74.25 MHz) and the data, DE and sync lines all
# leave adv_ddr.v from its pad registers (pad_*), one per pin, in the pins' OLOGIC: clock and data
# leave on the same clk_148 rising edge (DE half a period later, on the falling edge), so the bus is
# edge-aligned and every clock edge at the ADV7511 latches the word launched one clk_148 period
# earlier.  Measured on stage_combo5_x0 (the same arrangement, with Vivado's own register copies):
# dv_clk 9.21 / 3.74 ns after the clk_148 edge (slow / fast corner), dv_d within 0.04 ns of it.
#
# ADV7511 input timing (Hardware User's Guide Rev D, AC specifications): setup tVSU 1.0 ns, hold
# tVHLD 0.7 ns, measured at 0.9 V, both moved by the clock delay in register 0xBA[7:5] (-1.2 ..
# +1.6 ns, 0.4 ns steps; the same on both edges while 0xD0[7] = 0).  The ADV7511 needs the data
# stable from (d - tVSU) to (d + tVHLD) around each dv_clk edge at its pin, d = the 0xBA delay.
# dv_adv_delay MUST match what the firmware writes (fw/ctrl_832/adv7511.h ADV_CLKDELAY_DEFAULT,
# -0.8 ns; the OSD HDMI page can change it at run time -- these numbers then no longer hold).
# Board skew: the IO board's traces give the clock the shortest (17.2 mm) and the data 17.6 - 27.0
# mm, syncs 32 - 34 mm (about 6 ps/mm); the core board's lengths are unknown.  dv_board_skew is
# allowed in both directions.
set dv_tsu        1.0
set dv_th         0.7
set dv_adv_delay -0.8
set dv_board_skew 0.1

# The forwarded clock: clk_148 / 2 out of pad_clk_reg, then the pin itself, so the clock's own
# OLOGIC -> OBUF -> pad delay is part of every check (the generated clock's source is the
# register's clock pin, the clk_148 divider form; not the D input, which TIMING-36 rejects).
create_generated_clock -name dv_clk_reg -source [get_pins my_pal_to_ddr/myadr_ddr/pad_clk_reg/C] \
    -divide_by 2 [get_pins my_pal_to_ddr/myadr_ddr/pad_clk_reg/Q]
create_generated_clock -name dv_clk_pin -source [get_pins my_pal_to_ddr/myadr_ddr/pad_clk_reg/Q] \
    -multiply_by 1 [get_ports dv_clk]

# Every data/DE/sync pin against both dv_clk edges (DDR).  Setup: a word launched at a clk_148
# edge is latched by the next dv_clk edge; hold: it must not change before (d + tVHLD) after the
# clock edge launched with it.
set dv_data [get_ports {dv_d[*] dv_de dv_hsync dv_vsync}]
set dv_omax [expr {$dv_tsu - $dv_adv_delay + $dv_board_skew}]
set dv_omin [expr {-($dv_th + $dv_adv_delay + $dv_board_skew)}]
set_output_delay -clock dv_clk_pin -max $dv_omax $dv_data
set_output_delay -clock dv_clk_pin -min $dv_omin $dv_data
set_output_delay -clock dv_clk_pin -clock_fall -max $dv_omax $dv_data -add_delay
set_output_delay -clock dv_clk_pin -clock_fall -min $dv_omin $dv_data -add_delay
set_false_path -to [get_ports dv_clk_gnd]

# The pad registers carry IOB = "TRUE" and DONT_TOUCH in adv_ddr.v; this makes the IOB placement
# explicit here too.  The internal clk_pixel_out / de_out / hsync_out / vsync_out registers are
# not pad registers any more and are not named here.
set_property IOB TRUE [get_cells -hier -filter {NAME =~ "my_pal_to_ddr/myadr_ddr/pad_*_reg*"}]
