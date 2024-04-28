# Slower IO clocks
set_false_path -to [get_ports {io_scl io_sda js_cs js_mosi js_sck max_i2s max_lrclk sd_m_cmd sd_m_d3}]

# CPU constraints
set _xlnx_shared_i0 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set _xlnx_shared_i1 [all_registers]
set_multicycle_path -setup -start -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 4
set_multicycle_path -hold -start -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 3

set _xlnx_shared_i2 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/memaddr.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i2 -to $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from $_xlnx_shared_i2 -to $_xlnx_shared_i1 2

set_multicycle_path -setup -start -from [get_cells openaars_virtual_top/tg68k/addr*] -to $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from [get_cells openaars_virtual_top/tg68k/addr*] -to $_xlnx_shared_i1 2

# # Dram to cache line constraints
# Incorrect
set_multicycle_path -from [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/dtram/.*] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cacheline_.*] -setup 2
set_multicycle_path -from [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/dtram/.*] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cacheline_.*] -hold 1

# From 28 -> 114 MHz four cycles in the 114 network
set_multicycle_path -setup -from [get_clocks dll_28] -to [get_clocks clk_114] 4
set_multicycle_path -hold -from [get_clocks dll_28] -to [get_clocks clk_114] 3

# The returning signals from SDRAM can take 2 cycles
set_multicycle_path -setup -from [get_clocks clk_sd_114] -to [get_clocks clk_114] 2

# Neither in nor out of the C2P requires single-cycle speed
set _xlnx_shared_i3 [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -start -from [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/rdptr.*] -to $_xlnx_shared_i3 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/rdptr.*] -to $_xlnx_shared_i3 2
set _xlnx_shared_i4 [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/buf_reg.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i4 -to $_xlnx_shared_i3 2
set_multicycle_path -hold -start -from $_xlnx_shared_i4 -to $_xlnx_shared_i3 2



# All datapaths from the Minimig core to the HDMI output module use double flip flop transitions
# set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_false_path -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]

set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3

set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 1.800
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2


create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]

set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114, dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114 dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]

create_pblock sdram_controller
add_cells_to_pblock [get_pblocks sdram_controller] [get_cells -quiet [list openaars_virtual_top/sdram]]
resize_pblock [get_pblocks sdram_controller] -add {SLICE_X52Y51:SLICE_X89Y99}
resize_pblock [get_pblocks sdram_controller] -add {DSP48_X1Y22:DSP48_X2Y39}
resize_pblock [get_pblocks sdram_controller] -add {RAMB18_X1Y22:RAMB18_X3Y39}
resize_pblock [get_pblocks sdram_controller] -add {RAMB36_X1Y11:RAMB36_X3Y19}
