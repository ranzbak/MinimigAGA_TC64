# Clocks
create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]
create_clock -period 8.713 -name VIRTUAL_dll_114 -waveform {0.000 4.356}
create_clock -period 34.851 -name VIRTUAL_dll_28 -waveform {0.000 17.426}
create_clock -period 5.000 -name VIRTUAL_clk_200 -waveform {0.000 2.500}
create_clock -period 1115.248 -name VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0 -waveform {0.000 557.624}
create_clock -period 636.040 -name VIRTUAL_my_i2s_transmitter/max_sclk_OBUF -waveform {0.000 318.020}

# Generated clock
create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 73 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -divide_by 128 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
create_generated_clock -name clk_sdram -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1] -multiply_by 1 [get_pins dr_clk_OBUF_inst/O]

# Clock group
set_clock_groups -name async_generic -asynchronous -group [get_clocks -filter { NAME !~  "*VIRTUAL*" }] -group [get_clocks *VIRTUAL*]

#set_clock_groups -name async_generic -asynchronous -group [get_clocks [list clk_50 $clk_i2s $clk_sd [get_clocks -of_objects [get_pins $clk_hdmi]] [get_clocks -of_objects [get_pins clk_hdmi/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKFBOUT]] [get_clocks -of_objects [get_pins $clk_28]] [get_clocks -of_objects [get_pins $clk_114]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]]]] -group [get_clocks {VIRTUAL_clk_200 VIRTUAL_dll_28 VIRTUAL_dll_114 VIRTUAL_my_i2s_transmitter/max_sclk_OBUF VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0}]

# name PLL clocks
# CLK mapping
# CLK0 = dll_114
# CLK1 = pll_114 *SDRAM
# CLK2 = dll_28
set clk_114   "openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0"
set clk_sdram "openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1"
set clk_28    "openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2"
set clk_sd    "openaars_virtual_top/mycfide/sck_reg_n_0"
set clk_i2s   "my_i2s_transmitter/max_sclk_OBUF"
set clk_hdmi  "clk_hdmi/CLKOUT0"

# name SDRAM ports
set sdram_outputs [get_ports {dr_d[*] dr_a[*] dr_dqm[*] dr_we_n dr_cas_n dr_ras_n dr_cs_n dr_ba[*] dr_cke}]
set sdram_inputs  [get_ports {dr_d[*]}]

# input delay
set_input_delay -clock [get_clocks -of_objects [get_pins $clk_sdram]] -reference_pin [get_ports dr_clk] -max 6.4 $sdram_inputs
set_input_delay -clock [get_clocks -of_objects [get_pins $clk_sdram]] -reference_pin [get_ports dr_clk] -min 3.2 $sdram_inputs

#output delay
set_output_delay -clock [get_clocks -of_objects [get_pins $clk_sdram]] -reference_pin [get_ports dr_clk] -max  1.5 $sdram_outputs
set_output_delay -clock [get_clocks -of_objects [get_pins $clk_sdram]] -reference_pin [get_ports dr_clk] -min -0.8 $sdram_outputs

# Input delay
set async_ports_114_in [get_ports {sd_m_* sys_reset_in button_*}]
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay 0.300 $async_ports_114_in
set_input_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 0.400 $async_ports_114_in
set async_ports_28_in [get_ports {dv_scl dv_sda ps2_* sys_reset_in}]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.300 $async_ports_28_in
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.400 $async_ports_28_in
set_input_delay -clock [get_clocks VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0] -clock_fall -min -add_delay 0.500 [get_ports sd_m_d0]
set_input_delay -clock [get_clocks VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0] -clock_fall -max -add_delay 0.500 [get_ports sd_m_d0]
set_input_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -min -add_delay 0.500 [get_ports sys_reset_in]
set_input_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -max -add_delay 0.500 [get_ports sys_reset_in]

# Output delay
set async_ports_200_out [get_ports dv_*]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -0.400 $async_ports_200_out
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay 1.400 $async_ports_200_out
set async_ports_114_out [get_ports {led_* sd_m_*}]
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -5.000 $async_ports_114_out
set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 5.000 $async_ports_114_out
set async_ports_28_out [get_ports {dv_scl dv_sda js_* pmod_* ps2_* uart*}]
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay -5.00 $async_ports_28_out
set_output_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 5.00 $async_ports_28_out
set_output_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -min -add_delay -100.000 [get_ports max_*]
set_output_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -max -add_delay 100.000 [get_ports max_*]

# Multi cycle path
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins $clk_114]] -to [get_clocks -of_objects [get_pins $clk_28]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins $clk_114]] -to [get_clocks -of_objects [get_pins $clk_28]] 3


#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup 4
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -setup 4
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -hold 3
#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|memaddr*} -setup 3
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/memaddr*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -setup 3
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/memaddr*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -hold 2
#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|memaddr*} -to {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup 4
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/memaddr*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -to [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -setup 4
set_multicycle_path -start -from [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/memaddr*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -to [get_pins  -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" }  -of_objects [get_cells -hierarchical -filter { NAME =~  "*" } ]] -hold 3
#set_multicycle_path -from {TG68K:tg68k|addr[*]} -setup 3
set_multicycle_path -start -from [get_pins -filter { NAME =~  "*tg68k/addr_reg[*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -setup 3
set_multicycle_path -start -from [get_pins -filter { NAME =~  "*tg68k/addr_reg[*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -hold 2

#set_multicycle_path -from {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|dpram_256x32:dtram|altsyncram:altsyncram_component|*|q_a[*]} -to {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set_multicycle_path -from [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/dtram/gen_ram_256_32/mem_reg/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -to [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline_*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -setup 2
set_multicycle_path -from [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/dtram/gen_ram_256_32/mem_reg/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -to [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline_*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -hold 1
#set_multicycle_path -from {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|dpram_256x32:itram|altsyncram:altsyncram_component|*|q_a[*]} -to {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set_multicycle_path -from [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -to [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -setup 2
set_multicycle_path -from [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -to [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]] -hold 1
#set_multicycle_path -from [get_clocks $clk_28] -to [get_clocks $clk_114] -setup 4
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins $clk_28]] -to [get_clocks -of_objects [get_pins $clk_114]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins $clk_28]] -to [get_clocks -of_objects [get_pins $clk_114]] 3
#set_multicycle_path -from [get_clocks $clk_sdram] -to [get_clocks $clk_114] -setup 2
set_multicycle_path -setup -from [get_clocks clk_sdram] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 2



# False path
set_false_path -to [get_clocks -of_objects [get_pins $clk_hdmi]]
set_false_path -to [get_clocks $clk_sd]
set_false_path -from [get_clocks $clk_sd]
set_false_path -from [get_clocks $clk_i2s]
set_false_path -to [get_clocks $clk_i2s]
set_false_path -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
