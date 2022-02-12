






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








set_false_path -from [get_pins myReset/nresetLoc_reg/C] -to [get_pins {r_reset_sync_reg[0]/D}]


create_clock -period 13.477 -name clk_hdmi -waveform {0.000 6.739}
set_output_delay -clock [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -min -0.700 [get_ports {{dv_d[*]} dv_de dv_hsync dv_vsync}]
set_output_delay -clock [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -max 1.000 [get_ports {{dv_d[*]} dv_de dv_hsync dv_vsync}]



set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_xilinx_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_xilinx_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_xilinx_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_xilinx_i/clk_main/CLKOUT0]] 3

set_property IOSTANDARD SSTL135 [get_ports {ddr3_dm_o[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dm_o[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba_o[2]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba_o[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba_o[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[13]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[12]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[11]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[10]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[9]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[8]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[7]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[6]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[5]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[4]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[3]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[2]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr_o[0]}]
set_property IOSTANDARD SSTL135 [get_ports ddr3_cas_n_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_cke_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_cs_n_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_odt_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_ras_n_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_reset_n_o]
set_property IOSTANDARD SSTL135 [get_ports ddr3_we_n_o]
