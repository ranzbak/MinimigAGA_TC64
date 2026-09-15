# Clocks
#
# Board oscillator: 50 MHz on U22 (QMTech core board Y1).
create_clock -period 20.000 -name clk_50 -waveform {0.000 10.000} [get_ports clk_50]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVTTL} [get_ports clk_50]

# amiga_clk MMCM (rtl/clock/amiga_clk_xilinx.v): VCO = 50 x 45.375 / 2 = 1134.375 MHz
#   CLKOUT0 /10 -> clk_114     113.4375 MHz            system, SDRAM controller, CPU
#   CLKOUT1 /10 -> clk_sd_114  113.4375 MHz, -121.5 deg forwarded to the SDRAM as dr_clk (sdram.xdc)
#   CLKOUT2 /40 -> dll_28       28.359375 MHz           Amiga chipset
#   CLKOUT3 /30 -> clk_38       37.812500 MHz           the AP68040 CPU island
# These are renames of the auto-derived MMCM clocks; ratio and phase come from the MMCM attributes.
#
# clk_38 is 1134.375 / 30 = 37.8125 MHz EXACTLY, i.e. clk_114 / 3 with no phase
# shift, so every clk_38 edge coincides with a clk_114 one.  It clocks the
# AP68040 kernel and nothing else (rtl/soc/TG68K.vhd, port clk_cpu).  The
# crossings between it and
# clk_114 are SYNCHRONOUS and are timed as such -- see cpu.xdc, and do not put
# the two in an asynchronous clock group.
set amiga_mmcm openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main
create_generated_clock -name clk_114    [get_pins $amiga_mmcm/CLKOUT0]
create_generated_clock -name clk_sd_114 [get_pins $amiga_mmcm/CLKOUT1]
create_generated_clock -name dll_28     [get_pins $amiga_mmcm/CLKOUT2]
create_generated_clock -name clk_38     [get_pins $amiga_mmcm/CLKOUT3]

# HDMI MMCM (rtl/soc/minimig_openaars_top.v clk_hdmi): 50 x 37.125 / 2 / 6.25 = 148.5 MHz
#   clk_148 is the ADV7511 DDR data clock; the 74.25 MHz pixel clock is a fabric divider of it.
create_generated_clock -name clk_148 [get_pins clk_hdmi/CLKOUT0]

# Clock domain relationships
#   clk_114 / clk_sd_114 / dll_28 / clk_38 are phase-aligned siblings: timed synchronously,
#   with the multicycle rules in wizard.xdc (dll_28, 1:4) and cpu.xdc (clk_38, 1:3) where the
#   design samples at the slower rate.
#   clk_148 shares only the 50 MHz reference with them; every crossing goes through
#   synchronisers and is bounded with set_max_delay -datapath_only in wizard.xdc rather than
#   masked with a false path.

# The DDR3 island has its own PLL (rtl/ddr3/ddr3_pll.v) off this same clk_50;
# its four generated clocks and the asynchronous clock group against the Minimig
# clocks above are declared in ddr3.xdc.
