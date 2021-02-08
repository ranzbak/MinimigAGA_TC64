

create_clock -period 5.000 -name VIRTUAL_clk_200 -waveform {0.000 2.500}
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -0.500 [get_ports {dv_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay 1.100 [get_ports {dv_d[*]}]

connect_debug_port u_ila_0/probe0 [get_nets [list {openaars_virtual_top/mycfide/sd_cs[0]} {openaars_virtual_top/mycfide/sd_cs[1]} {openaars_virtual_top/mycfide/sd_cs[2]} {openaars_virtual_top/mycfide/sd_cs[3]} {openaars_virtual_top/mycfide/sd_cs[4]} {openaars_virtual_top/mycfide/sd_cs[5]} {openaars_virtual_top/mycfide/sd_cs[6]} {openaars_virtual_top/mycfide/sd_cs[7]}]]
connect_debug_port u_ila_0/probe1 [get_nets [list {openaars_virtual_top/mycfide/q[0]} {openaars_virtual_top/mycfide/q[1]} {openaars_virtual_top/mycfide/q[2]} {openaars_virtual_top/mycfide/q[3]} {openaars_virtual_top/mycfide/q[4]} {openaars_virtual_top/mycfide/q[5]} {openaars_virtual_top/mycfide/q[6]} {openaars_virtual_top/mycfide/q[7]} {openaars_virtual_top/mycfide/q[8]} {openaars_virtual_top/mycfide/q[9]} {openaars_virtual_top/mycfide/q[10]} {openaars_virtual_top/mycfide/q[11]} {openaars_virtual_top/mycfide/q[12]} {openaars_virtual_top/mycfide/q[13]} {openaars_virtual_top/mycfide/q[14]} {openaars_virtual_top/mycfide/q[15]}]]
connect_debug_port u_ila_0/probe2 [get_nets [list {openaars_virtual_top/mycfide/sd_in_shift[0]} {openaars_virtual_top/mycfide/sd_in_shift[1]} {openaars_virtual_top/mycfide/sd_in_shift[2]} {openaars_virtual_top/mycfide/sd_in_shift[3]} {openaars_virtual_top/mycfide/sd_in_shift[4]} {openaars_virtual_top/mycfide/sd_in_shift[5]} {openaars_virtual_top/mycfide/sd_in_shift[6]} {openaars_virtual_top/mycfide/sd_in_shift[7]} {openaars_virtual_top/mycfide/sd_in_shift[8]} {openaars_virtual_top/mycfide/sd_in_shift[9]} {openaars_virtual_top/mycfide/sd_in_shift[10]} {openaars_virtual_top/mycfide/sd_in_shift[11]} {openaars_virtual_top/mycfide/sd_in_shift[12]} {openaars_virtual_top/mycfide/sd_in_shift[13]} {openaars_virtual_top/mycfide/sd_in_shift[14]} {openaars_virtual_top/mycfide/sd_in_shift[15]}]]
connect_debug_port u_ila_0/probe3 [get_nets [list {openaars_virtual_top/mycfide/d[0]} {openaars_virtual_top/mycfide/d[1]} {openaars_virtual_top/mycfide/d[2]} {openaars_virtual_top/mycfide/d[3]} {openaars_virtual_top/mycfide/d[4]} {openaars_virtual_top/mycfide/d[5]} {openaars_virtual_top/mycfide/d[6]} {openaars_virtual_top/mycfide/d[7]} {openaars_virtual_top/mycfide/d[8]} {openaars_virtual_top/mycfide/d[9]} {openaars_virtual_top/mycfide/d[10]} {openaars_virtual_top/mycfide/d[11]} {openaars_virtual_top/mycfide/d[12]} {openaars_virtual_top/mycfide/d[13]} {openaars_virtual_top/mycfide/d[14]} {openaars_virtual_top/mycfide/d[15]}]]
connect_debug_port u_ila_0/probe4 [get_nets [list {openaars_virtual_top/mycfide/addr[2]} {openaars_virtual_top/mycfide/addr[3]} {openaars_virtual_top/mycfide/addr[4]} {openaars_virtual_top/mycfide/addr[5]} {openaars_virtual_top/mycfide/addr[6]} {openaars_virtual_top/mycfide/addr[7]} {openaars_virtual_top/mycfide/addr[8]} {openaars_virtual_top/mycfide/addr[9]} {openaars_virtual_top/mycfide/addr[10]} {openaars_virtual_top/mycfide/addr[11]} {openaars_virtual_top/mycfide/addr[12]} {openaars_virtual_top/mycfide/addr[13]} {openaars_virtual_top/mycfide/addr[14]} {openaars_virtual_top/mycfide/addr[15]} {openaars_virtual_top/mycfide/addr[16]} {openaars_virtual_top/mycfide/addr[17]} {openaars_virtual_top/mycfide/addr[18]} {openaars_virtual_top/mycfide/addr[19]} {openaars_virtual_top/mycfide/addr[20]} {openaars_virtual_top/mycfide/addr[21]} {openaars_virtual_top/mycfide/addr[22]} {openaars_virtual_top/mycfide/addr[23]} {openaars_virtual_top/mycfide/addr[24]} {openaars_virtual_top/mycfide/addr[25]} {openaars_virtual_top/mycfide/addr[26]} {openaars_virtual_top/mycfide/addr[27]} {openaars_virtual_top/mycfide/addr[28]} {openaars_virtual_top/mycfide/addr[29]} {openaars_virtual_top/mycfide/addr[30]} {openaars_virtual_top/mycfide/addr[31]}]]
connect_debug_port u_ila_0/probe5 [get_nets [list openaars_virtual_top/mycfide/ack]]
connect_debug_port u_ila_0/probe6 [get_nets [list openaars_virtual_top/mycfide/sd_clk]]
connect_debug_port u_ila_0/probe7 [get_nets [list openaars_virtual_top/mycfide/sd_di]]
connect_debug_port u_ila_0/probe8 [get_nets [list openaars_virtual_top/mycfide/sd_di_in]]
connect_debug_port u_ila_0/probe9 [get_nets [list openaars_virtual_top/mycfide/sd_dimm]]
connect_debug_port u_ila_0/probe10 [get_nets [list openaars_virtual_top/mycfide/sd_do]]
connect_debug_port u_ila_0/probe11 [get_nets [list openaars_virtual_top/mycfide/SPI_select]]
connect_debug_port u_ila_0/probe13 [get_nets [list openaars_virtual_top/mycfide/wr]]
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_clock_groups -asynchronous -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0] -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]]
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 3
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -group [get_clocks VIRTUAL_clk_200]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3

set_property MARK_DEBUG true [get_nets pmod_9_OBUF]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list clk_200_BUFG]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 2 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {my_pal_to_ddr/myupsample/r_cur_read_buf[0]} {my_pal_to_ddr/myupsample/r_cur_read_buf[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 12 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {my_pal_to_ddr/myupsample/r_h_pos_0[0]} {my_pal_to_ddr/myupsample/r_h_pos_0[1]} {my_pal_to_ddr/myupsample/r_h_pos_0[2]} {my_pal_to_ddr/myupsample/r_h_pos_0[3]} {my_pal_to_ddr/myupsample/r_h_pos_0[4]} {my_pal_to_ddr/myupsample/r_h_pos_0[5]} {my_pal_to_ddr/myupsample/r_h_pos_0[6]} {my_pal_to_ddr/myupsample/r_h_pos_0[7]} {my_pal_to_ddr/myupsample/r_h_pos_0[8]} {my_pal_to_ddr/myupsample/r_h_pos_0[9]} {my_pal_to_ddr/myupsample/r_h_pos_0[10]} {my_pal_to_ddr/myupsample/r_h_pos_0[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 2 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {my_pal_to_ddr/myupsample/r_cur_write_buf[0]} {my_pal_to_ddr/myupsample/r_cur_write_buf[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 8 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[0]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[1]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[2]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[3]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[4]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[5]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[6]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdo_reg[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 8 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[0]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[1]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[2]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[3]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[4]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[5]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[6]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/sdi_reg[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 3 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {openaars_virtual_top/minimig/USERIO1/osd1/spi0/bit_cnt[0]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/bit_cnt[1]} {openaars_virtual_top/minimig/USERIO1/osd1/spi0/bit_cnt[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 1 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list pmod_9_OBUF]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 1 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list my_pal_to_ddr/myupsample/r_pal_hsync_]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 1 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list my_pal_to_ddr/myupsample/r_pal_vsync_]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 1 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list openaars_virtual_top/mycfide/spi_wait]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 1 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list vga_vs]]
set_max_delay -datapath_only -from [get_pins my_pal_to_ddr/_i_pal_*/C] -to [get_pins my_pal_to_ddr/__i_pal_*/D] 1.000
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_200_BUFG]
