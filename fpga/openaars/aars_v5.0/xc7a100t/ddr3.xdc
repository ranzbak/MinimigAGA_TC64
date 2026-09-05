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

# The island shares only the 50 MHz reference with the Minimig clock tree, and
# only two things actually cross between the two: the asynchronous board reset,
# and the Zorro-III fast RAM handshake of rtl/ddr3/ddr3_cdc.v.  Both are
# constrained explicitly below.
#
# clk_ddr400 / clk_ddr400_90 / clk_ddr200 are in the asynchronous group because
# they have NO fabric crossings whatsoever: 400 MHz and 400 MHz@90 exist only
# inside ddr3_dfi_phy, where they are the OSERDESE2/ISERDESE2 bit clocks and
# clock nothing but those primitives and their IOB flops, and 200 MHz drives
# only the PHY's IDELAYCTRL (REFCLK_FREQUENCY 200).  No register in the Minimig
# clock tree can be reached from them, so grouping them away costs nothing.
#
# clk_ddr100 is deliberately NOT in the group any more.  It is the one island
# clock with fabric crossings, and set_clock_groups outranks set_max_delay
# (UG903 "Constraints precedence"), so while it was in the group every single
# clk_114 <-> clk_ddr100 path was simply UNCONSTRAINED: the bus bounds below
# used to be reported by report_exceptions as "Totally overridden path by CG"
# and neither the placer nor the router ever saw them.  The island's own BIST
# passes over the full 256 MB, so the memory and the PHY are sound; the CDC is
# the one piece of the fast-RAM path that neither the simulation nor static
# timing was covering.  With clk_ddr100 out of the group, every path in and out
# of it is timed and each is given the exception it actually needs, below.
#
# What that leaves timed and unexcepted: clk_ddr100 against clk_ddr400 /
# clk_ddr400_90 / clk_ddr200 (PLL siblings, timed before this change too --
# clocks inside a single -group stay mutually timed -- and the PHY's
# CLK/CLKDIV relationships depend on it), and clk_ddr100 against clk_50, its
# own PLL reference, which clocks no fabric register in this design.
set_clock_groups -asynchronous \
  -group {clk_ddr400 clk_ddr200 clk_ddr400_90} \
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
# Every cell name below was read out of the synthesised netlist of this exact
# build (get_cells -hier on the post-synthesis design), not guessed.  The two
# synchroniser first stages carry ASYNC_REG = "TRUE" in the RTL, so opt_design
# neither merges them into the second stage nor pulls them into an SRL; the
# -to lists nevertheless match BOTH stages of each synchroniser, so that the
# exception still has a valid endpoint and still covers the real crossing even
# if a future tool version does absorb a stage.
#
# All patterns end in a bare `*` rather than `[*]`: -filter =~ is a Tcl
# `string match`, in which [...] is a character class, so "..._reg[*]" would
# match "..._reg" followed by one literal asterisk and find nothing.
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
# or comment out the exceptions below.
#
# Check every rule here with
#   report_exceptions            (all of them must be listed, none of them may
#                                 say "Totally overridden path by CG")
#   report_exceptions -ignored   (none of them may say "Non-existent path")
# tools/vivado/build_ila.tcl writes both reports.

# --- 1. request payload, clk_114 -> clk_ddr100 -------------------------------
# req_rd_r / req_wr_r / req_adr_r / req_wd_r are written only in the cycle the
# source flips req_tgl, and not touched again until the response comes back.
# The destination cannot look at them until req_tgl has crossed its own two-flop
# synchroniser, so they have been stable for at least two clk_ddr100 edges by
# then and edge-to-edge timing is meaningless.  What DOES matter is that the
# 177 bits arrive within one destination period of each other, otherwise the
# island would latch a half-old address or a torn write payload -- exactly the
# kind of corruption the Amiga is showing.  -datapath_only drops the clock
# skew/uncertainty term and keeps the pure combinational bound, and 10.000 ns
# is one clk_ddr100 period.
set_max_delay -datapath_only 10.000 -to [get_clocks clk_ddr100] -from [get_cells -hier -filter { \
    NAME =~ "*ddr3_fastram_i/cdc/req_rd_r_reg"   || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wr_r_reg*"  || \
    NAME =~ "*ddr3_fastram_i/cdc/req_adr_r_reg*" || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wd_r_reg*"}]

# --- 2. response payload, clk_ddr100 -> clk_114 ------------------------------
# rdata_r is written on the same clk_ddr100 edge that flips ack_tgl, and the
# source cannot see that flip for two clk_ddr100 plus two clk_114 edges, so the
# same argument applies in the other direction.  8.815 ns is one clk_114 period
# (113.4375 MHz).
set_max_delay -datapath_only 8.815 -to [get_clocks clk_114] -from [get_cells -hier -filter { \
    NAME =~ "*ddr3_fastram_i/cdc/rdata_r_reg*"}]

# --- 3. the two toggle synchronisers ----------------------------------------
# These are the only bits that genuinely cross asynchronously, and they are the
# reason the buses may be treated as quasi-static.  Each is a single bit into an
# ASYNC_REG two-flop chain, so the correct constraint is not "don't care" but
# "bounded": the first stage may go metastable, and the budget for it to settle
# is whatever is left of the destination period after the wire delay.  Bounding
# the wire at one destination period and letting the placer keep the two stages
# in one slice is what makes the MTBF argument hold.
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hier -filter { NAME =~ "*ddr3_fastram_i/cdc/req_tgl_reg"}] \
    -to   [get_cells -hier -filter { NAME =~ "*ddr3_fastram_i/cdc/req_sync_reg*"}]
set_max_delay -datapath_only 8.815 \
    -from [get_cells -hier -filter { NAME =~ "*ddr3_fastram_i/cdc/ack_tgl_reg"}] \
    -to   [get_cells -hier -filter { NAME =~ "*ddr3_fastram_i/cdc/ack_sync_reg*"}]

# --- 4. init_done, clk_ddr100 -> clk_114 -------------------------------------
# ddr3_core's init_done_o (clk_ddr100) is sampled by ddr3_fastram's own
# ASYNC_REG two-flop init_sync, which then releases the cache reset through a
# 256-cycle settling counter (ddr_ready).  It is a level that goes high once
# after calibration and never changes again, so a metastable first stage costs
# at most one extra clk_114 cycle of reset; the crossing only needs bounding,
# not timing.  Same rule as 3, in the clk_ddr100 -> clk_114 direction, one
# clk_114 period.  This crossing was invisible while clk_ddr100 sat in the
# asynchronous group.
set_max_delay -datapath_only 8.815 -from [get_clocks clk_ddr100] \
    -to [get_cells -hier -filter { NAME =~ "*ddr3_fastram_i/init_sync_reg*"}]

# --- 5. board reset, dll_28 -> clk_ddr100 ------------------------------------
# gen_reset (myReset, clocked by clk_28 = dll_28) drives reset_n, which reaches
# the island only as ddr3_top's arst_w = ~reset_n | ~pll_locked, the
# ASYNCHRONOUS preset of its own four-stage reset synchroniser rst_sync_q.  That
# is an asynchronous assert with a synchronous, clk_ddr100-synchronised release,
# which is precisely the structure a recovery/removal check must not be applied
# to: the assert edge is intentionally unrelated to clk_ddr100, and the release
# is re-timed by rst_sync_q itself.  So this one is a genuine false path rather
# than a bounded one.  It too was invisible while clk_ddr100 was grouped away.
set_false_path -from [get_clocks dll_28] \
    -to [get_cells -hier -filter { NAME =~ "*ddr3_island/rst_sync_q_reg*"}]

#-----------------------------------------------------------------------------
# Reviewed CDC waivers
#-----------------------------------------------------------------------------
# report_cdc is a STRUCTURAL check: it looks for a two-flop chain with nothing
# in front of it and calls everything else unsafe.  It cannot see a handshake.
# The two structures below are safe for reasons that live in the protocol, not
# in the netlist, so they are recorded as reviewed waivers rather than left as
# noise that hides the next real finding.  Both were read off the routed
# checkpoint of this build (report_cdc -details), and the endpoint lists are
# derived, not hard-coded, so they follow the placer.
#
# Check with
#   report_cdc                (no Critical row for clk_114 <-> clk_ddr100)
#   report_cdc -show_waiver   (the waived rows, with these descriptions)
#   report_waivers

# --- W1. the request payload bus, clk_114 -> clk_ddr100 ----------------------
# 273 endpoints inside ddr3_core: CDC-1 ("1-bit unknown CDC circuitry", the
# address bits that reach clock-enable pins of the sequencer's registers),
# CDC-13 ("1-bit CDC path on a non-FD primitive", the 128 write-data bits that
# reach the write FIFO's distributed RAM) and CDC-10 ("combinational logic
# before a synchronizer", the address bits into u_seq/addr_q which happens to
# be two flops deep).  None of them is a synchroniser and none of them needs to
# be: the far side only looks at this bus while req_valid is high, which
# happens at least two clk_ddr100 edges after the source flipped req_tgl and
# stopped writing the bus (rule 3 above, and the CDC INVARIANT in
# rtl/ddr3/ddr3_cdc.v).  The skew across the 177 bits is what matters and rule
# 1 bounds it at one destination period.
set ddr3_cdc_payload_src [get_pins -of_objects [get_cells -hier -filter { \
    NAME =~ "*ddr3_fastram_i/cdc/req_rd_r_reg"   || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wr_r_reg*"  || \
    NAME =~ "*ddr3_fastram_i/cdc/req_adr_r_reg*" || \
    NAME =~ "*ddr3_fastram_i/cdc/req_wd_r_reg*"}] -filter {REF_PIN_NAME == C}]
set ddr3_cdc_core_dst [get_pins -of_objects [get_cells -hier -filter { \
    NAME =~ "ddr3_island/u_core/*"}] -filter {DIRECTION == IN}]
create_waiver -type CDC -id {CDC-1} \
    -from $ddr3_cdc_payload_src -to $ddr3_cdc_core_dst \
    -description {ddr3_cdc.v toggle handshake: the request payload is written only while the far side is idle and is read only while req_valid is high, at least two clk_ddr100 edges later; skew is bounded by set_max_delay -datapath_only 10.000 in ddr3.xdc rule 1.}
create_waiver -type CDC -id {CDC-10} \
    -from $ddr3_cdc_payload_src -to $ddr3_cdc_core_dst \
    -description {ddr3_cdc.v toggle handshake: ddr3_core/u_seq/addr_q is not a synchroniser, it is the sequencer's address register loaded from a bus that is stable for the whole request; see rule 1 and the CDC INVARIANT in rtl/ddr3/ddr3_cdc.v.}
create_waiver -type CDC -id {CDC-13} \
    -from $ddr3_cdc_payload_src -to $ddr3_cdc_core_dst \
    -description {ddr3_cdc.v toggle handshake: the 128 write-data bits land in ddr3_dfi_seq's write FIFO (distributed RAM), pushed on the cycle the core accepts the request, by which time the bus has been stable for several clk_ddr100 periods.}

# --- W2. the island reset, dll_28 -> clk_ddr100 ------------------------------
# CDC-10 on myReset/nresetLoc_reg -> ddr3_island/rst_sync_q[0]/PRE: the
# "combinational logic before a synchronizer" is ddr3_top.v's
# arst_w = ~reset_n | ~pll_locked, the two-input OR that every reset
# synchroniser with two asynchronous sources has to have.  Both inputs are
# static levels that change once at power-up, seconds apart, so the OR cannot
# glitch; and a glitch would only assert a reset that is released
# synchronously by the four-stage chain anyway.  Rule 5 above false-paths the
# recovery/removal check for the same reason.
create_waiver -type CDC -id {CDC-10} \
    -from [get_pins -of_objects [get_cells -hier -filter { \
              NAME =~ "*myReset/nresetLoc_reg"}] -filter {REF_PIN_NAME == C}] \
    -to   [get_pins -of_objects [get_cells -hier -filter { \
              NAME =~ "*ddr3_island/rst_sync_q_reg*"}] -filter {REF_PIN_NAME == PRE}] \
    -description {ddr3_top.v reset synchroniser: arst_w = ~reset_n | ~pll_locked is the mandatory OR of two asynchronous, static reset sources; the release is re-timed by the four-stage rst_sync_q chain on clk_ddr100.}
