# DDR3 - QMTech XC7A100T core board, 256 MB MT41K128M16 (x16, 2 Gbit), all bank 16.
#
# Pin locations are a mechanical conversion of the vendor file
#   QMTECH_XC7A75T-100T-200T_Core_Board/Software_XC7A100T/DDR3.ucf
# (identical to the pin list in that board's MIG example, mig.prj), with one
# change: the IOSTANDARD is SSTL15 / DIFF_SSTL15, not the vendor's SSTL135.
# Bank 16 VCCO on this board is 1.5 V, so 1.35 V signalling is not what the
# bank can drive; the vendor file mis-states the rail.
#
# There are 47 DDR3 pins, not 48: the module strap CS# low on the PCB, so the
# controller's ddr3_cs_n has no package pin.  Both the vendor UCF and the
# vendor MIG project omit it as well.
#
# rtl/ddr3/ddr3_dfi_phy.v (vendored, lib/core_ddr3_controller) hard-codes
# IOSTANDARD("SSTL135") / ("DIFF_SSTL135") in its 19 OBUF / OBUFDS / IOBUFDS
# instances.  An IOSTANDARD set here overrides the instance parameter, so the
# RTL is left untouched; synthesis/implementation emits a mismatch warning and
# the routed checkpoint must be checked to confirm this file won
# (report_property [get_ports {ddr3_dq[0]}] -> IOSTANDARD SSTL15).
#
# SLEW FAST and IN_TERM UNTUNED_SPLIT_50 follow the upstream reference design
# (core_ddr3_controller examples/arty_a7/arty_revb.xdc) and the vendor MIG
# output: the split-50 input termination is on DQ and both halves of DQS only.

# Row / column address A[13:0]
set_property -dict {PACKAGE_PIN E17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[0]}]
set_property -dict {PACKAGE_PIN G17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[1]}]
set_property -dict {PACKAGE_PIN F17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[2]}]
set_property -dict {PACKAGE_PIN C17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[3]}]
set_property -dict {PACKAGE_PIN G16  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[4]}]
set_property -dict {PACKAGE_PIN D16  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[5]}]
set_property -dict {PACKAGE_PIN H16  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[6]}]
set_property -dict {PACKAGE_PIN E16  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[7]}]
set_property -dict {PACKAGE_PIN H14  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[8]}]
set_property -dict {PACKAGE_PIN F15  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[9]}]
set_property -dict {PACKAGE_PIN F20  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[10]}]
set_property -dict {PACKAGE_PIN H15  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[11]}]
set_property -dict {PACKAGE_PIN C18  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[12]}]
set_property -dict {PACKAGE_PIN G15  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_addr[13]}]

# Bank address BA[2:0]
set_property -dict {PACKAGE_PIN B17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_ba[0]}]
set_property -dict {PACKAGE_PIN D18  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_ba[1]}]
set_property -dict {PACKAGE_PIN A17  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_ba[2]}]

# RAS#
set_property -dict {PACKAGE_PIN A19  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_ras_n]

# CAS#
set_property -dict {PACKAGE_PIN B19  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_cas_n]

# WE#
set_property -dict {PACKAGE_PIN A18  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_we_n]

# CKE (clock enable)
set_property -dict {PACKAGE_PIN E18  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_cke]

# ODT (on-die termination)
set_property -dict {PACKAGE_PIN G19  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_odt]

# RESET#
set_property -dict {PACKAGE_PIN H17  IOSTANDARD SSTL15      SLEW FAST} [get_ports ddr3_reset_n]

# CK differential clock, P
set_property -dict {PACKAGE_PIN F18  IOSTANDARD DIFF_SSTL15 SLEW FAST} [get_ports ddr3_ck_p]

# CK differential clock, N
set_property -dict {PACKAGE_PIN F19  IOSTANDARD DIFF_SSTL15 SLEW FAST} [get_ports ddr3_ck_n]

# DM, one data mask per byte lane
set_property -dict {PACKAGE_PIN A22  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_dm[0]}]
set_property -dict {PACKAGE_PIN C22  IOSTANDARD SSTL15      SLEW FAST} [get_ports {ddr3_dm[1]}]

# DQ data bus
set_property -dict {PACKAGE_PIN D21  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[0]}]
set_property -dict {PACKAGE_PIN C21  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[1]}]
set_property -dict {PACKAGE_PIN B22  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[2]}]
set_property -dict {PACKAGE_PIN B21  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[3]}]
set_property -dict {PACKAGE_PIN D19  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[4]}]
set_property -dict {PACKAGE_PIN E20  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[5]}]
set_property -dict {PACKAGE_PIN C19  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[6]}]
set_property -dict {PACKAGE_PIN D20  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[7]}]
set_property -dict {PACKAGE_PIN C23  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[8]}]
set_property -dict {PACKAGE_PIN D23  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[9]}]
set_property -dict {PACKAGE_PIN B24  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[10]}]
set_property -dict {PACKAGE_PIN B25  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[11]}]
set_property -dict {PACKAGE_PIN C24  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[12]}]
set_property -dict {PACKAGE_PIN C26  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[13]}]
set_property -dict {PACKAGE_PIN A25  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[14]}]
set_property -dict {PACKAGE_PIN B26  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dq[15]}]

# DQS differential strobe, P, one per byte lane
set_property -dict {PACKAGE_PIN B20  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dqs_p[0]}]
set_property -dict {PACKAGE_PIN A23  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dqs_p[1]}]

# DQS differential strobe, N, one per byte lane
set_property -dict {PACKAGE_PIN A20  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dqs_n[0]}]
set_property -dict {PACKAGE_PIN A24  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50} [get_ports {ddr3_dqs_n[1]}]

# SSTL15 inputs need a reference of VCCO/2.  Bank 16 has no external VREF pin
# routed on this board, so the bank's internal reference generator supplies it.
# (The vendor MIG project sets <InternalVref>1</InternalVref> for the same reason.)
set_property INTERNAL_VREF 0.75 [get_iobanks 16]

#-----------------------------------------------------------------------------
# Island clocks
#-----------------------------------------------------------------------------
# rtl/ddr3/ddr3_pll.v: PLLE2_BASE from clk_50 (declared in clocks.xdc),
# CLKFBOUT_MULT 24 / DIVCLK_DIVIDE 1 -> VCO 1200 MHz.
#   CLKOUT0 /12 = 100 MHz  controller + PHY fabric clock
#   CLKOUT1 /3  = 400 MHz  OSERDES/ISERDES bit clock
#   CLKOUT2 /6  = 200 MHz  IDELAYCTRL reference
#   CLKOUT3 /3  = 400 MHz at 90 deg, DQS strobe
# These are renames of the clocks Vivado derives from the PLL attributes; the
# ratios and the phase come from the primitive, not from this file.
set ddr3_pll ddr3_island/u_pll/u_plle2
create_generated_clock -name clk_ddr100    [get_pins $ddr3_pll/CLKOUT0]
create_generated_clock -name clk_ddr400    [get_pins $ddr3_pll/CLKOUT1]
create_generated_clock -name clk_ddr200    [get_pins $ddr3_pll/CLKOUT2]
create_generated_clock -name clk_ddr400_90 [get_pins $ddr3_pll/CLKOUT3]

# The island shares only the 50 MHz reference with the Minimig clock tree.  At
# this stage (stage A) nothing crosses between them except the asynchronous
# board reset, which enters through the island's own reset synchroniser
# (ddr3_top.v), so the two sets are unrelated for timing.  When the Zorro-III
# cache backend is connected (task 3) the crossing is a toggle handshake and is
# bounded with set_max_delay -datapath_only, which survives this clock group.
set_clock_groups -asynchronous \
  -group {clk_ddr100 clk_ddr400 clk_ddr200 clk_ddr400_90} \
  -group {clk_114 dll_28 clk_sd_114 clk_148 clk_50}

#-----------------------------------------------------------------------------
# DDR3 pin timing
#-----------------------------------------------------------------------------
# The upstream reference design for this controller
# (core_ddr3_controller examples/arty_a7/arty_revb.xdc, read in full) contains
# NO timing constraints on the DDR3 pins at all: only PACKAGE_PIN, IOSTANDARD,
# SLEW and IN_TERM, plus a create_clock on its 100 MHz board oscillator.  It
# relies on the default behaviour that unconstrained top-level ports are not
# reported.  Rather than depend on that, state it explicitly here.
#
# Why this is legal: none of these pins is timed by static timing analysis in
# the usual input/output-delay sense.
#   * Commands, address, CK, DM and write data leave through OSERDESE2 clocked
#     by clk_ddr400 / clk_ddr400_90.  Their relationship to the DRAM is set by
#     the serialiser phase and the board's matched routing, not by a fabric
#     setup/hold arc.
#   * Read data is captured by ISERDESE2 strobed by DQS through IDELAYE2, with
#     the tap value calibrated at run time (DQS_TAP_DELAY_INIT, then the BIST
#     sweep of rtl/ddr3/ddr3_bist.v).  A calibrated, source-synchronous capture
#     is not something set_input_delay can describe.
# Adding set_input_delay / set_output_delay here would produce failing paths
# that mean nothing and would hide the paths that do matter (the island's own
# clk_ddr100 / clk_ddr400 logic, which IS timed and must meet).
set ddr3_out_ports [get_ports {ddr3_addr[*] ddr3_ba[*] ddr3_ras_n ddr3_cas_n \
                               ddr3_we_n ddr3_cke ddr3_odt ddr3_reset_n \
                               ddr3_ck_p ddr3_ck_n ddr3_dm[*]}]
set ddr3_bidi_ports [get_ports {ddr3_dq[*] ddr3_dqs_p[*] ddr3_dqs_n[*]}]

set_false_path -to   $ddr3_out_ports
set_false_path -to   $ddr3_bidi_ports
set_false_path -from $ddr3_bidi_ports
