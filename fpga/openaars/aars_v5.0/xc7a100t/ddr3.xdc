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

# The island shares only the 50 MHz reference with the Minimig clock tree.  The
# only things that cross are the asynchronous board reset, which enters through
# the island's own reset synchroniser (ddr3_top.v), and the Zorro-III fast RAM
# handshake below, which is a toggle handshake bounded with
# set_max_delay -datapath_only -- that survives this clock group.
set_clock_groups -asynchronous \
  -group {clk_ddr100 clk_ddr400 clk_ddr200 clk_ddr400_90} \
  -group {clk_114 dll_28 clk_sd_114 clk_148 clk_50}

#-----------------------------------------------------------------------------
# Zorro-III fast RAM clock domain crossing
#-----------------------------------------------------------------------------
# rtl/ddr3/ddr3_cdc.v, instantiated as `cdc` inside rtl/ddr3/ddr3_fastram.v
# (itself instantiated as g_ddr3_fastram.ddr3_fastram_i inside
# minimig_virtual_top).  The module header states the invariant these
# constraints depend on: the payload registers on each side are only written
# while the two toggles agree, i.e. while the far side is idle, so they are
# stable for the whole round trip through both two-flop synchronisers.  Only
# the toggles are synchronised; the buses are quasi-static.
#
# Therefore the buses must NOT be timed edge-to-edge, but their skew must stay
# well inside one destination clock period, which is what -datapath_only does.
# 8 ns is comfortably under both periods (8.815 ns on clk_114, 10 ns on
# clk_ddr100) and is trivially met by any placement.
#
# NO CONTROL FLOW HERE.  Vivado's XDC reader rejects `if` / `foreach` -- and it
# does so in IMPLEMENTATION as well as synthesis ("CRITICAL WARNING:
# [Designutils 20-1307] Command 'if' is not supported in the xdc constraint
# file"), silently dropping the guarded constraint.  So these are unconditional.
#
# Consequence for the fallback build (minimig_openaars_top.v HAVEDDR3 = 0):
# the cells below do not exist, and set_max_delay with an empty -from is a hard
# ERROR ([Vivado 12-4739] "No valid object(s) found"), not a warning.  Synthesis
# is unaffected -- implementation-specific constraints are deferred, not
# evaluated -- so the fallback SYNTHESISES fine; a fallback IMPLEMENTATION must
# disable this file, e.g.
#   set_property is_enabled false [get_files .../ddr3.xdc]
# or comment out the four exceptions below.
#
# Precedence note: set_clock_groups above has higher precedence than
# set_max_delay -datapath_only (UG903), so on the clk_114 <-> clk_ddr100 pair
# the group is what actually makes the paths unconstrained and these four
# appear as overridden.  They are kept because they state the real requirement
# -- bounded skew, not "don't care" -- and they become the operative constraint
# the moment the clock group is narrowed.  Check with
#   report_exceptions            (they must be listed)
#   report_exceptions -ignored   (none of them may say "Non-existent path")
# Verified on the routed checkpoint of the first stage-B build: both are listed
# with max_dpo=8 and status "Totally overridden path by CG" (the clock group),
# and neither appears in the -ignored report.  Because they are overridden they
# do not change placement or routing.
set_max_delay -datapath_only -to [get_clocks clk_ddr100] 8.000 -from [get_cells -hier -filter { \
    NAME =~ "*ddr3_fastram_i/cdc/req_rd_r_reg"   || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wr_r_reg*"  || \
    NAME =~ "*ddr3_fastram_i/cdc/req_adr_r_reg*" || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wd_r_reg*"}]
set_max_delay -datapath_only -to [get_clocks clk_114] 8.000 -from [get_cells -hier -filter { \
    NAME =~ "*ddr3_fastram_i/cdc/rdata_r_reg*"}]
# The two optional set_false_path lines from the module header are deliberately
# NOT here.  The toggles are already covered by ASYNC_REG plus the asynchronous
# clock group, and opt_design absorbs req_sync_reg[0] / ack_sync_reg[0] into the
# following flop, so a constraint naming them would become "non-existent" the
# moment anyone re-reads this file on a placed or routed checkpoint.
