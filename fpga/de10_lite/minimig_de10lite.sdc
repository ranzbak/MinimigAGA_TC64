
# time information
set_time_format -unit ns -decimal_places 3


#create clocks
create_clock -name pll_in_clk -period 20 [get_ports {MAX10_CLK1_50}]

# name PLL clocks
set pll_sdram "virtual_top|amiga_clk|amiga_clk_i|altpll_component|auto_generated|pll1|clk[0]"
set clk_114   "virtual_top|amiga_clk|amiga_clk_i|altpll_component|auto_generated|pll1|clk[1]"
set clk_28    "virtual_top|amiga_clk|amiga_clk_i|altpll_component|auto_generated|pll1|clk[2]"

# pll clocks
derive_pll_clocks


# generated clocks

create_generated_clock -name clk_sdram -source [get_pins {virtual_top|amiga_clk|amiga_clk_i|altpll_component|auto_generated|pll1|clk[0]}] [get_ports {DRAM_CLK}]
create_generated_clock -name spiclk -source [get_pins {virtual_top|amiga_clk|amiga_clk_i|altpll_component|auto_generated|pll1|clk[2]}] -divide_by 2 [get_registers {minimig_virtual_top:virtual_top|cfide:mycfide|sck_pin}]

# name SDRAM ports
set sdram_outputs [get_ports {DRAM_ADDR[*] DRAM_LDQM DRAM_UDQM DRAM_WE_N DRAM_CAS_N DRAM_RAS_N DRAM_CS_N DRAM_BA[*] DRAM_CKE}]
set sdram_dqoutputs [get_ports {DRAM_DQ[*]}]
set sdram_inputs  [get_ports {DRAM_DQ[*]}]


# clock groups



# clock uncertainty
derive_clock_uncertainty


# input delay
set_input_delay -clock clk_sdram -max 6.0 $sdram_inputs
set_input_delay -clock clk_sdram -min 4.0 $sdram_inputs

set_input_delay -clock $clk_114 .5 [get_ports {ARDUINO_IO[*]}]
set_input_delay -clock $clk_114 .5 [get_ports {GPIO[*]}]
set_input_delay -clock $clk_114 .5 [get_ports {KEY[*]}]

set_input_delay -clock $clk_114 .5 [get_ports {altera_reserved_tdi}]
set_input_delay -clock $clk_114 .5 [get_ports {altera_reserved_tms}]

#output delay
#set_output_delay -clock $clk_sdram -max  1.5 [get_ports DRAM_CLK]
#set_output_delay -clock $clk_sdram -min -0.8 [get_ports DRAM_CLK]
set_output_delay -clock clk_sdram -max  1.5 $sdram_outputs
set_output_delay -clock clk_sdram -max  1.5 $sdram_dqoutputs
set_output_delay -clock clk_sdram -min -0.8 $sdram_outputs
set_output_delay -clock clk_sdram -min -0.8 $sdram_dqoutputs

set_output_delay -clock $clk_114 .5 [get_ports {ARDUINO_IO[*]}]
set_output_delay -clock $clk_114 .5 [get_ports {GPIO[*]}]
set_output_delay -clock $clk_114 .5 [get_ports {VGA_R[*]}]
set_output_delay -clock $clk_114 .5 [get_ports {VGA_G[*]}]
set_output_delay -clock $clk_114 .5 [get_ports {VGA_B[*]}]
set_output_delay -clock $clk_114 .5 [get_ports {VGA_*S}]
set_output_delay -clock $clk_114 .5 [get_ports {LEDR[*]}]

set_output_delay -clock $clk_114 .5 [get_ports {altera_reserved_tdo}]

# false paths


# multicycle paths

#set_multicycle_path -from {virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup 4
#set_multicycle_path -from {virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -hold 3

set_multicycle_path -from {minimig_virtual_top:virtual_top|EightThirtyTwo_Bridge:hostcpu|eightthirtytwo_cpu:my832|*} -to {minimig_virtual_top:virtual_top|EightThirtyTwo_Bridge:hostcpu|eightthirtytwo_cpu:my832|eightthirtytwo_alu:alu|mulresult[*]} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|EightThirtyTwo_Bridge:hostcpu|eightthirtytwo_cpu:my832|*} -to {minimig_virtual_top:virtual_top|EightThirtyTwo_Bridge:hostcpu|eightthirtytwo_cpu:my832|eightthirtytwo_alu:alu|mulresult[*]} -hold -end 2

set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|*} -setup 4
set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|*} -hold 3
set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|memaddr*} -setup 3
set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|memaddr*} -hold 2
set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|memaddr*} -to {virtual_top|tg68k|pf68K_Kernel_inst|*} -setup 4
set_multicycle_path -from {virtual_top|tg68k|pf68K_Kernel_inst|memaddr*} -to {virtual_top|tg68k|pf68K_Kernel_inst|*} -hold 3
set_multicycle_path -from {virtual_top|tg68k|addr[*]} -setup 3
set_multicycle_path -from {virtual_top|tg68k|addr[*]} -hold 2

set_multicycle_path -from {virtual_top|sdram|cpu_cache|itram|*} -to {virtual_top|sdram|cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set_multicycle_path -from {virtual_top|sdram|cpu_cache|itram|*} -to {virtual_top|sdram|cpu_cache|cpu_cacheline_*[*][*]} -hold 1
set_multicycle_path -from {virtual_top|sdram|cpu_cache|dtram|*} -to {virtual_top|sdram|cpu_cache|cpu_cacheline_*[*][*]} -setup 2
set_multicycle_path -from {virtual_top|sdram|cpu_cache|dtram|*} -to {virtual_top|sdram|cpu_cache|cpu_cacheline_*[*][*]} -hold 1

set_multicycle_path -from [get_clocks $clk_28] -to [get_clocks $clk_114] -setup 4
set_multicycle_path -from [get_clocks $clk_28] -to [get_clocks $clk_114] -hold 3

# Move data window for SDRAM reads by 1 cycle
set_multicycle_path -from clk_sdram -to [get_clocks $clk_114] -setup 2

# Neither in nor out of the C2P requires single-cycle speed
set_multicycle_path -from {minimig_virtual_top:virtual_top|TG68K:tg68k|akiko:myakiko|cornerturn:myc2p|rdptr[*]} -to {minimig_virtual_top:virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|TG68K:tg68k|akiko:myakiko|cornerturn:myc2p|rdptr[*]} -to {minimig_virtual_top:virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -hold -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|TG68K:tg68k|akiko:myakiko|cornerturn:myc2p|buf[*][*]} -to {minimig_virtual_top:virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|TG68K:tg68k|akiko:myakiko|cornerturn:myc2p|buf[*][*]} -to {minimig_virtual_top:virtual_top|TG68K:tg68k|TG68KdotC_Kernel:pf68K_Kernel_inst|*} -hold -end 2

# Likewise RTG and audio address have 8 cycles of downtime between bursts
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myvs|address_high[*]} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myvs|address_high[*]} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -hold -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myvs|outptr[*]} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myvs|outptr[*]} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -hold -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myaudiostream|*} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -setup -end 2
set_multicycle_path -from {minimig_virtual_top:virtual_top|VideoStream:myaudiostream|*} -to {minimig_virtual_top:virtual_top|sdram_ctrl:sdram|*} -hold -end 2

# JTAG
#set ports [get_ports -nowarn {altera_reserved_tck}]
#if {[get_collection_size $ports] == 1} {
#  create_clock -name tck -period 100.000 [get_ports {altera_reserved_tck}]
#  set_clock_groups -exclusive -group altera_reserved_tck
#  set_output_delay -clock tck 20 [get_ports altera_reserved_tdo]
#  set_input_delay  -clock tck 20 [get_ports altera_reserved_tdi]
#  set_input_delay  -clock tck 20 [get_ports altera_reserved_tms]
#  set tck altera_reserved_tck
#  set tms altera_reserved_tms
#  set tdi altera_reserved_tdi
#  set tdo altera_reserved_tdo
#  set_false_path -from *                -to [get_ports $tdo]
#  set_false_path -from [get_ports $tms] -to *
#  set_false_path -from [get_ports $tdi] -to *
#}
