# Slower IO clocks
set_false_path -to [get_ports {io_scl io_sda js_cs js_mosi js_sck max_i2s max_lrclk sd_m_cmd sd_m_d3}]

# CPU constraints
set _xlnx_shared_i0 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i0 4
set_multicycle_path -hold -start -from $_xlnx_shared_i0 3
set _xlnx_shared_i1 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/memaddr.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from $_xlnx_shared_i1 2

set_multicycle_path -setup -from $_xlnx_shared_i1 -to $_xlnx_shared_i1 4
set_multicycle_path -hold -from $_xlnx_shared_i1 -to $_xlnx_shared_i1 3

set_multicycle_path -setup -start -from [get_cells openaars_virtual_top/tg68k/addr*] 3
set_multicycle_path -hold -start -from [get_cells openaars_virtual_top/tg68k/addr*] 2

# # Dram to cache line constraints
# Incorrect
set_multicycle_path -setup -from [get_pins -hier -regexp {openaars_virtual_top/sdram/cpu_cache/[id]dram[01]/.*}] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/cpu_cacheline_.*] 2
set_multicycle_path -hold -from [get_pins -hier -regexp {openaars_virtual_top/sdram/cpu_cache/[id]dram[01]/.*}] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/cpu_cacheline_.*] 1

# From 28 -> 114 MHz four cycles in the 114 network
set_multicycle_path -setup -from [get_clocks dll_28] -to [get_clocks clk_114] 4
# set_multicycle_path -hold -end -from [get_clocks dll_28] -to [get_clocks clk_114] 3
set_multicycle_path -hold -from [get_clocks dll_28] -to [get_clocks clk_114] 3

# The returning synals from SDRAM can take 2 cycles
set_multicycle_path -setup -from [get_clocks clk_sd_114] -to [get_clocks clk_114] 2

# Neither in nor out of the C2P requires single-cycle speed
set _xlnx_shared_i2 [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set_multicycle_path -setup -start -from [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/rdptr.*] -to $_xlnx_shared_i2 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/rdptr.*] -to $_xlnx_shared_i2 2
set _xlnx_shared_i3 [get_pins -hier -regexp -nocase openaars_virtual_top/tg68k/myakiko/c2p.myc2p/buf_reg.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i3 -to $_xlnx_shared_i2 2
set_multicycle_path -hold -start -from $_xlnx_shared_i3 -to $_xlnx_shared_i2 2

# Likewise RTG and audio address have 8 cycles of downtime between bursts
# set _xlnx_shared_i8 [get_pins -hier -regexp -nocase openaars_virtual_top/sdram/.*]
# set_multicycle_path -reset_path -setup -end -from [get_pins -hier -regexp -nocase {openaars_virtual_top/myvs/address_high_reg\[.*\]}] -to $_xlnx_shared_i8 2
# set_multicycle_path -reset_path -hold -end -from [get_pins -hier -regexp -nocase {openaars_virtual_top/myvs/address_high_reg\[.*\]}] -to $_xlnx_shared_i8 2


# set_multicycle_path -reset_path -setup -end -from [get_pins -hier -regexp -nocase openaars_virtual_top/myvs/outptr.*] -to $_xlnx_shared_i8 2
# set_multicycle_path -reset_path -hold -end -from [get_pins -hier -regexp -nocase openaars_virtual_top/myvs/outptr.*] -to $_xlnx_shared_i8 2

# set_multicycle_path -reset_path -setup -end -from [get_pins -hier -regexp -nocase openaars_virtual_top/myaudiostream/.*] -to $_xlnx_shared_i8 2
# set_multicycle_path -reset_path -setup -end -from [get_pins -hier -regexp -nocase openaars_virtual_top/myaudiostream/.*] -to $_xlnx_shared_i8 2

# SPI is slow in comparison, so we don't care about the timing
# TODO : Check invalid rule
#set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]

# set_multicycle_path -reset -setup  -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
# set_multicycle_path -reset -hold   -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3


# All datapaths from the Minimig core to the HDMI output module use double flip flop transitions
# set_false_path -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_false_path -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]

# set_max_delay -datapath_only -from [get_pins {*my_pal_to_ddr/my*0hzupsample/s_pal_hsync_reg[1]/C*}] -to [get_pins *my_pal_to_ddr/my*0hzupsample/r_pal_hpos_in_reg/D*] 6.756
# set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 6.756
# set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 6.756

set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3

set_max_delay -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 1.800
set_multicycle_path -setup -start -from [get_ports {dr_d[*]}] -to [get_cells openaars_virtual_top/sdram/sdata_reg*] 2
set_multicycle_path -hold -start -from [get_ports {dr_d[*]}] -to [get_cells openaars_virtual_top/sdram/sdata_reg*] 2
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2


create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 70 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]

set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114, dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114 dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]


# Timing fix to signals to the SDRAM
# TODO find a better way to do this
set_max_delay -from openaars_virtual_top/sdram/sdata_oe_reg/C 9.700




set_property PULLTYPE PULLUP [get_ports sd_m_cdet]
set_property PULLTYPE PULLUP [get_ports sd_m_clk]
set_property PULLTYPE PULLUP [get_ports sd_m_cmd]
set_property -dict {PACKAGE_PIN F23 IOSTANDARD LVTTL} [get_ports sd_m_cdet]
set_false_path -from [get_ports sd_m_d0]