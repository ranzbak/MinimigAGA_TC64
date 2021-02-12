# Main clock
create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]
create_clock -period 5.000 -name VIRTUAL_clk_200 -waveform {0.000 2.500}

# Generated clocks
create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -divide_by 73 [get_pins my_i2s_transmitter/sclk_reg/Q]
#create_generated_clock -name clk_sdram -source [get_ports *dr_clk*] -multiply_by 1 -add -master_clock pll_114 [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]

# Clock groups
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -group [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]


# false paths
set_false_path -from [get_clocks my_i2s_transmitter/max_sclk_OBUF]
set_false_path -to [get_clocks my_i2s_transmitter/max_sclk_OBUF]
set_false_path -from [list [get_ports pmod_*] [get_ports *sd_m_*] [get_ports *button*] [get_ports *reset*] [get_ports *dv_s*]]

# Input delay
set_input_delay -clock [get_clocks clk_sdram] -max 3.000 [get_ports -filter { NAME =~  "*dr*" && DIRECTION == "INOUT" } -of_objects [get_nets -hierarchical -filter { NAME =~  "*" }]]
set_input_delay -clock [get_clocks clk_sdram] -min 2.000 [get_ports -filter { NAME =~  "*dr*" && DIRECTION == "INOUT" } -of_objects [get_nets -hierarchical -filter { NAME =~  "*" }]]

# Output delay
set_output_delay -clock [get_clocks *sdram*] -max 1.500 [get_ports -filter { NAME =~  "*dr_*" && DIRECTION != "IN" }]
set_output_delay -clock [get_clocks *sdram*] -min -0.800 [get_ports -filter { NAME =~  "*dr_*" && DIRECTION != "IN" }]
#set_output_delay -clock [get_clocks *sdram*] -min -add_delay 3.000 [get_ports -filter { NAME =~  "*dr_clk*" && DIRECTION != "IN" }]
#set_output_delay -clock [get_clocks *sdram*] -max -add_delay 2.000 [get_ports -filter { NAME =~  "*dr_clk*" && DIRECTION != "IN" }]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -0.500 [get_ports -filter { NAME =~  "*dv_*" && DIRECTION == "OUT" }]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay 1.100 [get_ports -filter { NAME =~  "*dv_*" && DIRECTION == "OUT" }]

# Max delay
#set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2.500
#set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2.500
#set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2.500


# Multi cycle paths
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 3
set_multicycle_path -setup -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] 3
set _xlnx_shared_i0 [get_pins -filter { NAME =~  "*openaars_virtual_top/tg68k/pf68K_Kernel_inst/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set _xlnx_shared_i1 [list [get_pins -filter { NAME =~  "*openaars_virtual_top/tg68k/pf68K_Kernel_inst/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]]
set_multicycle_path -setup -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 4
set_multicycle_path -hold -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 3

set _xlnx_shared_i2 [get_pins -filter { NAME =~  "*openaars_virtual_top/tg68k/addr_reg[*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -start -from $_xlnx_shared_i2 3
set_multicycle_path -hold -start -from $_xlnx_shared_i2 2

set_multicycle_path -setup -start -reset_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -reset_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3


set _xlnx_shared_i3 [get_pins -filter { NAME =~  "*openaars_virtual_top/hostcpu/my832/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set _xlnx_shared_i4 [get_pins -filter { NAME =~  "*openaars_virtual_top/hostcpu/my832/alu/mulresult_reg[*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -end -from $_xlnx_shared_i3 -to $_xlnx_shared_i4 2
set_multicycle_path -hold -end -from $_xlnx_shared_i3 -to $_xlnx_shared_i4 2







