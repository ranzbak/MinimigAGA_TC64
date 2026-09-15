# Cross-cutting timing exceptions: things that belong to no single interface.
# Every exception here states the design fact that makes it legal.
# Interface-specific timing lives in the interface's own xdc (sdram.xdc, adv7511_video.xdc,
# i2s.xdc, sd_card.xdc, ...); CPU exceptions in cpu.xdc; clocks in clocks.xdc.

# Slow serial outputs (I2C, joystick SPI, I2S, SD card): no external timing requirement.
set_false_path -to [get_ports {io_scl io_sda js_cs js_mosi js_sck max_i2s max_lrclk sd_m_cmd sd_m_d3}]

###############################################################################
# Chipset (dll_28) <-> system (clk_114): phase-aligned 1:4 siblings from one MMCM.
#
# dll_28 -> clk_114 (slow to fast): data launched on the 28 MHz edge is stable for 4 fast
# cycles; relax the CAPTURE edge (-end on both, so the hold check stays on the launch edge).
set_multicycle_path -setup -end 4 -from [get_clocks dll_28] -to [get_clocks clk_114]
set_multicycle_path -hold  -end 3 -from [get_clocks dll_28] -to [get_clocks clk_114]
# clk_114 -> dll_28 (fast to slow): consumers sample on the 28 MHz edge; relax the LAUNCH edge.
set_multicycle_path -setup -start 4 -from [get_clocks clk_114] -to [get_clocks dll_28]
set_multicycle_path -hold  -start 3 -from [get_clocks clk_114] -to [get_clocks dll_28]

# Direct flip-flop to flip-flop crossings between dll_28 and clk_114 whose consumer samples on
# every cycle (edge detectors, enables, configuration bits latched into the CPU island). The
# clock-to-clock rules above must not relax these; they are single-cycle and short. Cell-scoped
# exceptions take precedence over the clock-scoped ones. (Vivado TIMING-46 list.)
# (Written out explicitly: Vivado silently drops foreach/if in an XDC at implementation.)
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/amiga_clk/clk7_en_reg_reg}] -to [get_cells -quiet {openaars_virtual_top/sdram/clk7_enD_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/amiga_clk/clk7_en_reg_reg}] -to [get_cells -quiet {openaars_virtual_top/sdram/clk7_enD_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/aud_tick_reg}] -to [get_cells -quiet {openaars_virtual_top/aud_tick_d_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/aud_tick_reg}] -to [get_cells -quiet {openaars_virtual_top/aud_tick_d_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/hostcpu/hw_req_reg}] -to [get_cells -quiet {openaars_virtual_top/mycfide/i2c_master.my_i2c_mmio/_req_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/hostcpu/hw_req_reg}] -to [get_cells -quiet {openaars_virtual_top/mycfide/i2c_master.my_i2c_mmio/_req_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/hostcpu/wr_reg}] -to [get_cells -quiet {openaars_virtual_top/mycfide/i2c_master.my_i2c_mmio/_wr_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/hostcpu/wr_reg}] -to [get_cells -quiet {openaars_virtual_top/mycfide/i2c_master.my_i2c_mmio/_wr_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[0]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z2ram_ena_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[0]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z2ram_ena_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[1]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram_ena_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[1]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram_ena_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[2]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram2_ena_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[2]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram2_ena_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[3]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram3_ena_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/minimig/autoconfig/board_configured_reg[3]}] -to [get_cells -quiet {openaars_virtual_top/tg68k/z3ram3_ena_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/tg68k/lds2_reg}] -to [get_cells -quiet {openaars_virtual_top/minimig/CPU1/l_lds2_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/tg68k/lds2_reg}] -to [get_cells -quiet {openaars_virtual_top/minimig/CPU1/l_lds2_reg}]
set_multicycle_path -setup 1 -from [get_cells -quiet {openaars_virtual_top/tg68k/uds2_reg}] -to [get_cells -quiet {openaars_virtual_top/minimig/CPU1/l_uds2_reg}]
set_multicycle_path -hold  0 -from [get_cells -quiet {openaars_virtual_top/tg68k/uds2_reg}] -to [get_cells -quiet {openaars_virtual_top/minimig/CPU1/l_uds2_reg}]

###############################################################################
# Minimig / SDRAM domains <-> HDMI domain (clk_148).
#
# The domains are unrelated in phase; every crossing is a synchroniser or a toggle handshake.
# Bound the data paths to one destination period so the synchronisers are placed tightly, but
# do not mask them (a false path would let placement stretch them arbitrarily).
set_max_delay -datapath_only 6.734 -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]
set_max_delay -datapath_only 8.815 -from [get_clocks clk_148] -to [get_clocks {dll_28 clk_114 clk_sd_114}]

###############################################################################
# Placement
create_pblock sdram_controller
add_cells_to_pblock [get_pblocks sdram_controller] [get_cells -quiet [list openaars_virtual_top/sdram]]
resize_pblock [get_pblocks sdram_controller] -add {SLICE_X52Y51:SLICE_X89Y99}
resize_pblock [get_pblocks sdram_controller] -add {DSP48_X1Y22:DSP48_X2Y39}
resize_pblock [get_pblocks sdram_controller] -add {RAMB18_X1Y22:RAMB18_X3Y39}
resize_pblock [get_pblocks sdram_controller] -add {RAMB36_X1Y11:RAMB36_X3Y19}
