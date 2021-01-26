

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
