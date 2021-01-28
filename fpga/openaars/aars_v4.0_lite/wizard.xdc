

#

#set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks VIRTUAL_DDR_clk] 2

# We don't care

# Address registry

# dll114 to dll28

set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 3
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3
#set _xlnx_shared_i0 [get_cells -hierarchical -regexp .*openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
#set_multicycle_path -setup -start -from $_xlnx_shared_i0 4
#set_multicycle_path -hold -start -from $_xlnx_shared_i0 3
set_clock_groups -name main_clocks -asynchronous -group [get_clocks [list VIRTUAL_DDR_clk [get_clocks -of_objects [get_pins clk_hdmi/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]]]] -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]


create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -divide_by 8 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -divide_by 8 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
create_clock -period 8.767 -name VIRTUAL_dll_114 -waveform {-3.562 0.822}
create_clock -period 5.000 -name VIRTUAL_clk_200 -waveform {0.000 2.500}
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports {dr_a[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports {dr_a[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -1.600 [get_ports {dv_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay -0.600 [get_ports {dv_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -1.600 [get_ports dr_we_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay -0.600 [get_ports dr_we_n]
set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks VIRTUAL_DDR_clk] 10.000
set _xlnx_shared_i0 [get_pins -hierarchical -regexp .*tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -from $_xlnx_shared_i0 -to $_xlnx_shared_i0 4
set_multicycle_path -hold -from $_xlnx_shared_i0 -to $_xlnx_shared_i0 3
set_false_path -from [get_clocks openaars_virtual_top/mycfide/sck_reg_0] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks openaars_virtual_top/mycfide/sck_reg_0]
set _xlnx_shared_i1 [get_pins -hierarchical -regexp .*tg68k/addr_reg.*]
set _xlnx_shared_i2 [get_pins -hierarchical -regexp .*openaars_virtual_top/sdram.*]
set_multicycle_path -setup -from $_xlnx_shared_i1 -to $_xlnx_shared_i2 3
set_multicycle_path -hold -from $_xlnx_shared_i1 -to $_xlnx_shared_i2 2
set_false_path -from [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -to [get_clocks VIRTUAL_clk_200]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks openaars_virtual_top/mycfide/sck_reg_0]
set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks my_i2s_transmitter/max_sclk_OBUF]

create_clock -period 8.767 -name VIRTUAL_dll_114_1 -waveform {-3.562 0.822}
set_input_delay -clock [get_clocks VIRTUAL_dll_114_1] -min -add_delay -1.000 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_dll_114_1] -max -add_delay 2.000 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -2.000 [get_ports dv_clk]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay -1.000 [get_ports dv_clk]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -2.000 [get_ports dv_de]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay -1.000 [get_ports dv_de]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -2.000 [get_ports dv_hsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay -1.000 [get_ports dv_hsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -2.000 [get_ports dv_vsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay -1.000 [get_ports dv_vsync]



create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 4 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list openaars_virtual_top/amiga_clk/amiga_clk_i/c0]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 8 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {vga_r[0]} {vga_r[1]} {vga_r[2]} {vga_r[3]} {vga_r[4]} {vga_r[5]} {vga_r[6]} {vga_r[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 8 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {vga_g[0]} {vga_g[1]} {vga_g[2]} {vga_g[3]} {vga_g[4]} {vga_g[5]} {vga_g[6]} {vga_g[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 8 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {vga_b[0]} {vga_b[1]} {vga_b[2]} {vga_b[3]} {vga_b[4]} {vga_b[5]} {vga_b[6]} {vga_b[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 1 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list max_i2s_OBUF]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 1 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list max_lrclk_OBUF]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 1 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list max_sclk_OBUF]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 1 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list reset_n]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 1 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list sd_clk]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 1 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list sd_cs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 1 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list sd_miso]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 1 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list sd_mosi]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 1 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list vga_cs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 1 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list vga_hs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 1 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list vga_pixel]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 1 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list vga_selcs]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list vga_vs]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_114]
