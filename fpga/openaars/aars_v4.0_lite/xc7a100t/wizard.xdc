






create_pblock pblock_68k
add_cells_to_pblock [get_pblocks pblock_68k] [get_cells -quiet [list openaars_virtual_top/tg68k]]
resize_pblock [get_pblocks pblock_68k] -add {CLOCKREGION_X1Y2:CLOCKREGION_X1Y2}
create_pblock pblock_hostcpu
add_cells_to_pblock [get_pblocks pblock_hostcpu] [get_cells -quiet [list openaars_virtual_top/hostcpu]]
resize_pblock [get_pblocks pblock_hostcpu] -add {SLICE_X52Y50:SLICE_X89Y70}
resize_pblock [get_pblocks pblock_hostcpu] -add {DSP48_X1Y20:DSP48_X2Y27}
resize_pblock [get_pblocks pblock_hostcpu] -add {RAMB18_X1Y20:RAMB18_X3Y27}
resize_pblock [get_pblocks pblock_hostcpu] -add {RAMB36_X1Y10:RAMB36_X3Y13}
create_pblock pblock_sdram
add_cells_to_pblock [get_pblocks pblock_sdram] [get_cells -quiet [list openaars_virtual_top/sdram]]
resize_pblock [get_pblocks pblock_sdram] -add {SLICE_X52Y71:SLICE_X89Y98}
resize_pblock [get_pblocks pblock_sdram] -add {DSP48_X1Y30:DSP48_X2Y37}
resize_pblock [get_pblocks pblock_sdram] -add {RAMB18_X1Y30:RAMB18_X3Y37}
resize_pblock [get_pblocks pblock_sdram] -add {RAMB36_X1Y15:RAMB36_X3Y18}








# set_false_path -from [get_pins myReset/nresetLoc_reg/C] -to [get_pins {r_reset_28_sync_reg[0]/D}]




create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]

set _xlnx_shared_i0 [get_pins -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -hold -start -from $_xlnx_shared_i0 3
set_false_path -from [get_pins myReset/nresetLoc_reg/C] -to [get_pins {r_reset_28_sync_reg[0]/D}]
set _xlnx_shared_i1 [get_pins -hierarchical -regexp -nocase .*openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i1 4
set_multicycle_path -hold -from $_xlnx_shared_i1 3
set_false_path -from [get_pins -hierarchical -regexp {.*openaars_virtual_top/minimig/cpu_config_reg_reg\[.*\]/C.*}]
set _xlnx_shared_i2 [get_pins -hierarchical -regexp -nocase .*openaars_virtual_top/tg68k/pf68K_Kernel_inst/memaddr.*]
set _xlnx_shared_i3 [get_pins -hierarchical -regexp .*openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -from $_xlnx_shared_i2 -to $_xlnx_shared_i3 4
set _xlnx_shared_i4 [get_pins -hierarchical -regexp -nocase .*openaars_virtual_top/tg68k/addr.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i4 4
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 3
create_clock -period 8.773 -name VIRTUAL_dll_114 -waveform {0.000 4.386}

create_clock -period 6.739 -name VIRTUAL_clk_148 -waveform {0.000 3.370}

set_multicycle_path -hold -start -from $_xlnx_shared_i4 3
#set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]

set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 3

create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 32 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 16 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
create_clock -period 35.091 -name VIRTUAL_dll_28 -waveform {0.000 17.546}
create_clock -period 140.366 -name VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0 -waveform {0.000 70.183}
create_clock -period 140.366 -name VIRTUAL_my_i2s_transmitter/max_sclk_OBUF -waveform {0.000 70.183}

set_clock_groups -name design -asynchronous -group [get_clocks [list clk_50 clk_hdmi my_i2s_transmitter/max_sclk_OBUF openaars_virtual_top/mycfide/sck_reg_n_0 [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] [get_clocks -of_objects [get_pins clk_hdmi/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]]]] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0] -group [get_clocks VIRTUAL_clk_148] -group [get_clocks VIRTUAL_dll_28] -group [get_clocks VIRTUAL_dll_114] -group [get_clocks my_i2s_transmitter/max_sclk_OBUF]
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay 0.800 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 1.800 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports {dr_a[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports {dr_a[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports {dr_ba[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports {dr_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports {dr_dqm[*]}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports dr_cas_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports dr_cs_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports dr_ras_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -0.800 [get_ports dr_we_n]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 2.000 [get_ports dr_we_n]
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -0.700 [get_ports {dv_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 1.500 [get_ports {dv_d[*]}]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -0.700 [get_ports dv_clk]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 1.500 [get_ports dv_clk]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -clock_fall -min -add_delay -0.700 [get_ports dv_de]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -clock_fall -max -add_delay 1.500 [get_ports dv_de]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -0.700 [get_ports dv_hsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 1.500 [get_ports dv_hsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -0.700 [get_ports dv_vsync]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 1.500 [get_ports dv_vsync]


set_max_delay -datapath_only -from [get_pins {*my_pal_to_ddr/my*0hzupsample/s_pal_hsync_reg[1]/C*}] -to [get_pins *my_pal_to_ddr/my*0hzupsample/r_pal_hpos_in_reg/D*] 6.756
# set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 6.756
set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 6.756
set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 6.756

set_max_delay -datapath_only -from [get_ports -regexp button_.*] 37.714
set_max_delay -datapath_only -from [get_ports -regexp ps2_.*] 37.714
