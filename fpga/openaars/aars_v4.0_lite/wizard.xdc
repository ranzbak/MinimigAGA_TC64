


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
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 3
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -group [get_clocks VIRTUAL_clk_200]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3

set_max_delay -datapath_only -from [get_pins my_pal_to_ddr/_i_pal_*/C] -to [get_pins my_pal_to_ddr/__i_pal_*/D] 1.000




create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 100 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
create_clock -period 8.713 -name VIRTUAL_dll_114 -waveform {0.000 4.356}
create_clock -period 34.851 -name VIRTUAL_dll_28 -waveform {0.000 17.426}
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay 1.300 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.100 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.500 [get_ports js_miso]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports js_miso]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.500 [get_ports ps2_clk1]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports ps2_clk1]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.500 [get_ports ps2_clk2]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports ps2_clk2]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.500 [get_ports ps2_data1]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports ps2_data1]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.500 [get_ports ps2_data2]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports ps2_data2]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports dr_*]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 1.500 [get_ports dr_*]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay -0.500 [get_ports -filter { NAME =~  "*js_*" && DIRECTION == "OUT" }]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports -filter { NAME =~  "*js_*" && DIRECTION == "OUT" }]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay -0.500 [get_ports -filter { NAME =~  "*ps2*" && DIRECTION != "IN" } -of_objects [get_nets -hierarchical -filter { NAME =~  "*" }]]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports -filter { NAME =~  "*ps*" && DIRECTION != "IN" }]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.500 [get_ports -filter { NAME =~  "*sd_m*" && DIRECTION != "IN" }]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 0.500 [get_ports -filter { NAME =~  "*sd_m*" && DIRECTION != "IN" }]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay -0.500 [get_ports uart3_txd]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.500 [get_ports uart3_txd]
set_clock_groups -asynchronous -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0] -group [get_clocks VIRTUAL_dll_114]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks VIRTUAL_clk_200]
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -group [get_clocks VIRTUAL_dll_114]
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -group [get_clocks VIRTUAL_dll_114]
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -group [get_clocks VIRTUAL_dll_28]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]




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
connect_debug_port u_ila_0/clk [get_nets [list openaars_virtual_top/amiga_clk/amiga_clk_i/c0]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 12 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {openaars_virtual_top/minimig/kbd/kbd1/preceive[0]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[1]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[2]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[3]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[4]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[5]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[6]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[7]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[8]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[9]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[10]} {openaars_virtual_top/minimig/kbd/kbd1/preceive[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 8 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {openaars_virtual_top/minimig/AMBER1/red_in[0]} {openaars_virtual_top/minimig/AMBER1/red_in[1]} {openaars_virtual_top/minimig/AMBER1/red_in[2]} {openaars_virtual_top/minimig/AMBER1/red_in[3]} {openaars_virtual_top/minimig/AMBER1/red_in[4]} {openaars_virtual_top/minimig/AMBER1/red_in[5]} {openaars_virtual_top/minimig/AMBER1/red_in[6]} {openaars_virtual_top/minimig/AMBER1/red_in[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 8 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {openaars_virtual_top/red[0]} {openaars_virtual_top/red[1]} {openaars_virtual_top/red[2]} {openaars_virtual_top/red[3]} {openaars_virtual_top/red[4]} {openaars_virtual_top/red[5]} {openaars_virtual_top/red[6]} {openaars_virtual_top/red[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 7 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {openaars_virtual_top/tg68_cpustate[0]} {openaars_virtual_top/tg68_cpustate[1]} {openaars_virtual_top/tg68_cpustate[2]} {openaars_virtual_top/tg68_cpustate[3]} {openaars_virtual_top/tg68_cpustate[4]} {openaars_virtual_top/tg68_cpustate[5]} {openaars_virtual_top/tg68_cpustate[6]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 3 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {openaars_virtual_top/minimig/kbd/kbd1/kstate[0]} {openaars_virtual_top/minimig/kbd/kbd1/kstate[1]} {openaars_virtual_top/minimig/kbd/kbd1/kstate[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 8 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {vga_r[0]} {vga_r[1]} {vga_r[2]} {vga_r[3]} {vga_r[4]} {vga_r[5]} {vga_r[6]} {vga_r[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 1 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list openaars_virtual_top/minimig/_cpu_reset_in]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 1 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list amiga_reset_n]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 1 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/clk7_en]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 1 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/keystrobe]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 1 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/prready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 1 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/ps2kclk_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 1 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/ps2kclk_o]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 1 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/ps2kdat_i]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 1 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/ps2kdat_o]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list openaars_virtual_top/minimig/kbd/kbd1/reset]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe16]
set_property port_width 1 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list openaars_virtual_top/rtg_16bit]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list openaars_virtual_top/rtg_clut]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe18]
set_property port_width 1 [get_debug_ports u_ila_0/probe18]
connect_debug_port u_ila_0/probe18 [get_nets [list openaars_virtual_top/rtg_ena]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe19]
set_property port_width 1 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list openaars_virtual_top/rtg_ena_mm]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe20]
set_property port_width 1 [get_debug_ports u_ila_0/probe20]
connect_debug_port u_ila_0/probe20 [get_nets [list vga_cs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe21]
set_property port_width 1 [get_debug_ports u_ila_0/probe21]
connect_debug_port u_ila_0/probe21 [get_nets [list vga_hs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe22]
set_property port_width 1 [get_debug_ports u_ila_0/probe22]
connect_debug_port u_ila_0/probe22 [get_nets [list vga_pixel]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe23]
set_property port_width 1 [get_debug_ports u_ila_0/probe23]
connect_debug_port u_ila_0/probe23 [get_nets [list vga_selcs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe24]
set_property port_width 1 [get_debug_ports u_ila_0/probe24]
connect_debug_port u_ila_0/probe24 [get_nets [list vga_vs]]
create_debug_core u_ila_1 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_1]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_1]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
connect_debug_port u_ila_1/clk [get_nets [list openaars_virtual_top/amiga_clk/amiga_clk_i/c1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe0]
set_property port_width 1 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 [get_nets [list openaars_virtual_top/minimig/sys_reset]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets dv_cecclk_OBUF]
