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
create_generated_clock -name clk_sdram -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0] -multiply_by 1 [get_ports *dr_clk*]

# Clock group
set_clock_groups -name async_generic -asynchronous -group [get_clocks -filter { NAME !~  "*VIRTUAL*" }] -group [get_clocks *VIRTUAL*]

#set_clock_groups -name async_generic -asynchronous -group [get_clocks [list clk_50 $clk_i2s $clk_sd [get_clocks -of_objects [get_pins $clk_hdmi]] [get_clocks -of_objects [get_pins clk_hdmi/CLKFBOUT]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKFBOUT]] [get_clocks -of_objects [get_pins $clk_28]] [get_clocks -of_objects [get_pins $clk_114]] [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]]]] -group [get_clocks {VIRTUAL_clk_200 VIRTUAL_dll_28 VIRTUAL_dll_114 VIRTUAL_my_i2s_transmitter/max_sclk_OBUF VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0}]

# name PLL clocks
# CLK mapping
# CLK0 = dll_114
# CLK1 = pll_114 *SDRAM
# CLK2 = dll_28

# name SDRAM ports

# input delay
#set_input_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -reference_pin [get_ports dr_clk] -max 6.400 [get_ports {dr_d[*]}]
#set_input_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -reference_pin [get_ports dr_clk] -min 3.200 [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -max 6.000 [get_ports -filter { NAME =~  "*dr_*" && DIRECTION != "OUT" }]
set_input_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -min 3.600 [get_ports -filter { NAME =~  "*dr_*" && DIRECTION != "OUT" }]


#output delay
set_output_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -reference_pin [get_ports dr_clk] -max 1.500 [get_ports {{dr_d[*]} {dr_a[*]} {dr_dqm[*]} dr_we_n dr_cas_n dr_ras_n dr_cs_n {dr_ba[*]} dr_cke}]
set_output_delay -clock [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT1]] -reference_pin [get_ports dr_clk] -min -0.800 [get_ports {{dr_d[*]} {dr_a[*]} {dr_dqm[*]} dr_we_n dr_cas_n dr_ras_n dr_cs_n {dr_ba[*]} dr_cke}]

# Input delay
#set async_ports_114_in [get_ports {sd_m_* sys_reset_in button_*}]
#set_input_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay 0.300 $async_ports_114_in
#set_input_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 0.400 $async_ports_114_in
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay 0.300 [get_ports {dv_scl dv_sda ps2_* sys_reset_in}]
set_input_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 0.400 [get_ports {dv_scl dv_sda ps2_* sys_reset_in}]
set_input_delay -clock [get_clocks VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0] -clock_fall -min -add_delay 0.500 [get_ports sd_m_d0]
set_input_delay -clock [get_clocks VIRTUAL_openaars_virtual_top/mycfide/sck_reg_n_0] -clock_fall -max -add_delay 0.500 [get_ports sd_m_d0]
set_input_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -min -add_delay 0.500 [get_ports sys_reset_in]
set_input_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -max -add_delay 0.500 [get_ports sys_reset_in]

# Output delay
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -min -add_delay -0.400 [get_ports dv_*]
set_output_delay -clock [get_clocks VIRTUAL_clk_200] -max -add_delay 1.400 [get_ports dv_*]
#set async_ports_114_out [get_ports {led_* sd_m_*}]
#set_output_delay -clock [get_clocks VIRTUAL_dll_114] -min -add_delay -5.000 $async_ports_114_out
#set_output_delay -clock [get_clocks VIRTUAL_dll_114] -max -add_delay 5.000 $async_ports_114_out
#set async_ports_28_out [get_ports {dv_scl dv_sda js_* pmod_* ps2_* uart*}]
#set_output_delay -clock [get_clocks VIRTUAL_dll_28] -min -add_delay -5.00 $async_ports_28_out
#set_output_delay -clock [get_clocks VIRTUAL_dll_28] -max -add_delay 5.00 $async_ports_28_out
set_output_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -min -add_delay -100.000 [get_ports max_*]
set_output_delay -clock [get_clocks VIRTUAL_my_i2s_transmitter/max_sclk_OBUF] -clock_fall -max -add_delay 100.000 [get_ports max_*]

# Multi cycle path
set_multicycle_path -setup -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 4
set_multicycle_path -hold -start -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] 3


#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup 4
set _xlnx_shared_i0 [get_pins -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -start -from $_xlnx_shared_i0 4
set_multicycle_path -hold -start -from $_xlnx_shared_i0 3
#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|memaddr*} -setup 3
set _xlnx_shared_i1 [get_pins -filter { NAME =~  "*tg68k/pf68K_Kernel_inst/memaddr*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -start -from $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from $_xlnx_shared_i1 2
#set_multicycle_path -from {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|memaddr*} -to {TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup 4
set_multicycle_path -setup -start -from $_xlnx_shared_i1 -to $_xlnx_shared_i0 4
set_multicycle_path -hold -start -from $_xlnx_shared_i1 -to $_xlnx_shared_i0 3
#set_multicycle_path -from {TG68K:tg68k|addr[*]} -setup 3
set _xlnx_shared_i2 [get_pins -filter { NAME =~  "*tg68k/addr_reg[*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -start -from $_xlnx_shared_i2 3
set_multicycle_path -hold -start -from $_xlnx_shared_i2 2

#set_multicycle_path -from {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|dpram_256x32:dtram|altsyncram:altsyncram_component|*|q_a[*]} -to {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set _xlnx_shared_i3 [get_pins -filter { NAME =~  "*openaars_virtual_top/sdram/dtram/gen_ram_256_32/mem_reg/*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set _xlnx_shared_i4 [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline_*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -from $_xlnx_shared_i3 -to $_xlnx_shared_i4 2
set_multicycle_path -hold -from $_xlnx_shared_i3 -to $_xlnx_shared_i4 1
#set_multicycle_path -from {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|dpram_256x32:itram|altsyncram:altsyncram_component|*|q_a[*]} -to {sdram_ctrl:sdram|cpu_cache_new:cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set _xlnx_shared_i5 [get_pins [list openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CASCADEOUTA \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CASCADEOUTB \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DBITERR \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[31]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[30]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[29]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[28]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[27]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[26]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[25]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[24]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[23]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[22]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[21]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[20]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[19]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[18]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[17]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[16]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOADO[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[31]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[30]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[29]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[28]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[27]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[26]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[25]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[24]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[23]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[22]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[21]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[20]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[19]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[18]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[17]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[16]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOBDO[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPADOP[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPADOP[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPADOP[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPADOP[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPBDOP[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPBDOP[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPBDOP[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DOPBDOP[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ECCPARITY[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RDADDRECC[0]} \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/SBITERR \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRARDADDR[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ADDRBWRADDR[0]} \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CASCADEINA \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CASCADEINB \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CLKARDCLK \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/CLKBWRCLK \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[31]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[30]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[29]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[28]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[27]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[26]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[25]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[24]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[23]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[22]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[21]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[20]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[19]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[18]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[17]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[16]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIADI[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[31]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[30]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[29]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[28]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[27]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[26]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[25]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[24]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[23]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[22]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[21]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[20]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[19]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[18]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[17]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[16]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[15]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[14]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[13]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[12]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[11]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[10]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[9]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[8]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIBDI[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPADIP[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPADIP[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPADIP[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPADIP[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPBDIP[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPBDIP[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPBDIP[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/DIPBDIP[0]} \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ENARDEN \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/ENBWREN \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/INJECTDBITERR \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/INJECTSBITERR \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/REGCEAREGCE \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/REGCEB \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RSTRAMARSTRAM \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RSTRAMB \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RSTREGARSTREG \
          openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/RSTREGB \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEA[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEA[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEA[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEA[0]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[7]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[6]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[5]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[4]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[3]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[2]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[1]} \
          {openaars_virtual_top/sdram/itram/gen_ram_256_32/mem_reg/WEBWE[0]}]]
set _xlnx_shared_i6 [get_pins -filter { NAME =~  "*sdram/cpu_cache/cpu_cacheline*[*][*]*" } -of_objects [get_cells -hierarchical -filter { NAME =~  "*" }]]
set_multicycle_path -setup -from $_xlnx_shared_i5 -to $_xlnx_shared_i6 2
set_multicycle_path -hold -from $_xlnx_shared_i5 -to $_xlnx_shared_i6 1
#set_multicycle_path -from [get_clocks $clk_28] -to [get_clocks $clk_114] -setup 4
set_multicycle_path -setup -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 4
set_multicycle_path -hold -end -from [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT2]] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 3
#set_multicycle_path -from [get_clocks $clk_sdram] -to [get_clocks $clk_114] -setup 2
set_multicycle_path -setup -from [get_clocks clk_sdram] -to [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]] 2



# False path
set_false_path -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_false_path -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_false_path -from [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_false_path -from [get_clocks my_i2s_transmitter/max_sclk_OBUF]
set_false_path -to [get_clocks my_i2s_transmitter/max_sclk_OBUF]
set_false_path -to [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
