# CPU timing exceptions.  (The TG68K core and its clk_114 multicycle island were
# removed in Stage E4a; tag d3_stable has them.)
#
# AP68040 (lib/AP68040, the g_ap040 branch)
#   Since stage D3 the kernel is on its OWN CLOCK, clk_38 = 37.8125 MHz = clk_114 / 3, phase
#   aligned, from the same MMCM (clocks.xdc).  Its enable is a bus handshake and no longer a duty
#   cycle -- it is high on every clk_38 edge except while a bus request is outstanding -- so
#   "every kernel register holds for at least N clk_114 cycles" is FALSE and every multicycle
#   exception that rested on it is gone.  What replaces it is the clock period itself: a
#   kernel -> kernel path is one clk_38 period, 26.45 ns, which is exactly what the old -start 3
#   island bought, and the tool derives it rather than being told.
#
#   The kernel's crossings to and from clk_114 are SYNCHRONOUS 1:3, not a CDC.  They are modelled
#   on the 1:4 dll_28 idiom in wizard.xdc:14-18 and derived below, one direction at a time.
#
# Kernel outputs (address, data, bus state) are sampled every cycle by the SDRAM controller, the
# DDR3 fast RAM and the chipset interface, but only used once they are stable; both controllers
# require the address one cycle before chip-select (sdram_ctrl.v:226, ddr3_fastram.v:20), so
# those paths get one cycle less than the island.
#
# The destination sets are explicit cell lists so that the exceptions can never land on a
# consumer that samples every cycle (a direct FF->FF with CE tied high, Vivado TIMING-46).
#
# Multicycle form: across clk_38 and clk_114 the form follows wizard.xdc's: -end on a slow ->
# fast path (relax the capture edge, keep the hold check on the launch edge), -start on fast ->
# slow.  On a same-clock path (the wrapper address rule at the bottom) -start is used and hold
# is setup - 1.
#
# The check that the exceptions actually landed is report_exceptions, not the absence of
# warnings -- and report_exceptions must show NONE on the core, which is stage D3's stated exit
# criterion.

# Endpoint filter: flip-flops, distributed RAM (the register file is RAM32X1D) and block RAM
# (Akiko CLUT). IS_SEQUENTIAL alone misses the RAM primitives.
set tg68_seq {IS_SEQUENTIAL || PRIMITIVE_TYPE =~ "DMEM.*" || PRIMITIVE_TYPE =~ "BMEM.*"}

#-----------------------------------------------------------------------------
# Who the CPU is: the wrapper instance.  The AP68040's own rules are clock-scoped
# (see below), so no kernel cell list is needed.  The kernel itself sits at
# $cpu_wrapper/g_ap040.ap040: Vivado names a VHDL if-generate instance
# "<label>.<instance>", which is why TG68K.vhd keeps g_ap040 as a generate --
# moving it once silently emptied these sets (ten "No valid object(s) found"
# criticals and no CPU exceptions in the bitstream).
#-----------------------------------------------------------------------------
set cpu_wrapper openaars_virtual_top/tg68k

# THE FREE-RUNNING REGISTERS INSIDE THE AP68040, AND WHY THEY ARE NO LONGER
# EXCLUDED FROM ANYTHING.
#
# These are the registers in the core that have no clock enable and advance on
# every clock:
#
#   core_stall_watchdog   ap040_bus_timeout, a 21-bit counter with no enable at
#                         all: it exists to notice a clkena wedge, so a wedge
#                         must not be able to stop it
#                         (ap040_tg68k_compat.v:14-28)
#   walker_wr_d, wsnp_*   the compat top's walker-write snoop edge detector in
#                         the same file (:293-305), also ungated
#   l_row, l_tag, l_ld    ap040_mmu.v:165-167, the ATC lookup pipe, no ce at all
#   *_snooped             ap040_cache.v:345 (st_snooped), :376 (fill_snooped,
#                         look_snooped), "set free-running -- the snoop is"
#   ipl_s*, irq_*, nmi_*  the interrupt sampler, ap040_core.v:150ff
#
# Until stage D3 they had to be excluded from the kernel island by name,
# because the island gave every kernel register three clk_114 cycles and these
# ones really do change on every clock -- the TIMING-46 class that
# findings/constraints/fix-04 was about, applied to thousands of cells instead
# of four.  THE EXCLUSION IS NOW EMPTY OF PURPOSE: the kernel is a clock
# domain, not an exception, so a free-running register and an enabled one are
# both checked against one clk_38 period and both answers are true.  The list
# is kept as documentation of what these registers are, and the filter that
# used it is gone.
#
# One consequence worth recording.  `atc_ram -> g_cache.cache/{look,st}_snooped_reg`
# failed setup by roughly -0.3 to -0.6 ns in EVERY AP040 build measured so far,
# including the pre-D3 baseline, and was the WNS-defining path on clk_114.  It
# is entirely inside the kernel, so it is now a clk_38 -> clk_38 path with
# 26.45 ns instead of 8.815 ns and should stop being a violation without the
# RTL change that was on the deferred list for it.  That is a prediction to
# check against the first D3 build, not a claim.
#
# The other thing that dies with the duty cycle is the "ce-aligned" pair.  It
# said that l_row/l_tag/l_ld and the wrapper's wk_active have no clock enable
# but only ever change just after one, so their consumers have the enable
# period minus one cycle -- two, not one.  For l_* that is now simply the
# clk_38 period.  For wk_active the claim as written was false -- the walker
# router has transitions that fire on a clk_114 edge of their own, so it could
# change on the edge before the kernel samples -- and deleting it was right.
# It came back once, for the walker and the line-fill router, with the premise
# made true in RTL (`bus_step`), and went again in Stage E2: the fill router is
# deleted and the walker is a clk_38 master on the kernel's own enable.
#
# Kept because the finding cost a day and is still true: ipl_s* was NEVER in
# the exclusion list, and that was a decision.  The cone from the interrupt
# sampler into the sequencer is physically single-cycle -- 15 levels, 9.86 ns
# of which 80 % routing, against 8.815 ns -- it cannot be placed out of trouble
# and it cannot be pipelined.  Splitting it was tried on 2026-09-08 and the
# core's own t_exceptions test 150 rejected it, because what must be immediate
# is the MASK: the request is asserted while masked, settles, and then a
# "move.w #$2000,sr" has to take it at that very boundary.  On clk_38 the same
# cone has 26.45 ns and the question does not arise; if the island clock is
# ever raised, this is the path that decides how far.

# Write every set out longhand: an XDC file is not general Tcl, and Vivado
# rejects foreach ("Command 'foreach' is not supported in the xdc constraint
# file", Designutils 20-1307).  Building strings in a loop once cost a build: the
# variables were left unset and ten exceptions were silently dropped.

# The memory side.  Since Stage E2 the two controllers take the unit port from
# ap040_ram_seq registers on clk_114, so only the wrapper's own chipset address
# rule at the bottom still uses this set; the controllers stay in it because
# that rule is scoped by destination.  minimig is here for the chipset side.
set tg68_mem    [get_cells -hier -filter "(NAME =~ openaars_virtual_top/sdram/* || \
                                           NAME =~ openaars_virtual_top/minimig/* || \
                                           NAME =~ openaars_virtual_top/g_ddr3_fastram.ddr3_fastram_i/*) && ($tg68_seq)"]

#=============================================================================
# AP68040: the clk_38 island.  Stage D3.
#=============================================================================
#
# THERE ARE NO MULTICYCLE EXCEPTIONS ON THIS CORE, and that is the stage's
# stated exit criterion.  kernel -> kernel is one clk_38 period because the
# kernel is one clock domain; what is left to say is only what the two
# crossings to clk_114 are worth, and both are derived here rather than copied.
#
# The 1:3 geometry.  clk_114 edges every 8.815 ns; clk_38 edges on every third
# one, so the two coincide every 26.445 ns.  Between two coincident edges there
# are clk_114 edges at +1 and +2.
#
#---------------------------------------------------------------------------
# clk_38 -> clk_114 (the CPU island's outputs).  TWO clk_114 cycles, 17.63 ns.
#---------------------------------------------------------------------------
# Derived, not copied from the 1:4 dll_28 pair (which would give three).  The
# question a multicycle answers is "how long after the launch edge is this
# value first LOOKED AT", and the answer here is set by the enable gap:
#
#   the kernel advances at clk_38 edge T and at the earliest again at T+3
#   (three clk_114 periods later).  Its address, bus state, byte selects and
#   write data change at T.
#
#   Everything on the clk_114 side that feeds an answer BACK to the kernel is
#   registered, and the copy that matters at edge T+3 is the one captured at
#   T+2 -- so its input has to be settled at T+2, two clk_114 periods after T.
#   sel_undecoded_d is the sharpest case: it is bus_ready all by itself, so a
#   decode that has not settled by T+2 releases the core at T+3 with $FFFF.
#
#   The memory side (Stage E2).  The master channel x_* is clk_38 and changes
#   only at T.  The sequencers that take it to the controllers (ap040_ram_seq
#   x2, the Akiko sequencer) see it through q_req, which is masked on edges T
#   (clkena_r) and T+1 (x_fresh), so the first edge that latches an access is
#   T+2: settled at T+2 again.  The controllers themselves see only the
#   sequencers' clk_114 registers.
#
#   And the 7 MHz chipset state machine, which is why rtl/soc/TG68K.vhd grew
#   cpu_bus_settled in stage D3.  ena7WRreg lands on phase 14 of a sixteen
#   phase round, 16 and 3 are coprime, so without a guard it could latch the
#   kernel's outputs one clk_114 cycle after they moved.  cpu_bus_settled is
#   slower(1), so the earliest start is edge T+3: settled at T+2, once more.
#
# Hence two, uniformly -- one cycle TIGHTER than the old -start 3 island and
# than the dll_28 idiom, and the same 17.63 ns the old kernel -> memory rule
# always used.  -end on both, so the hold check stays on the coincident launch
# edge, exactly as wizard.xdc:14-18 does it.
set_multicycle_path -setup -end 2 -from [get_clocks clk_38] -to [get_clocks clk_114]
set_multicycle_path -hold  -end 1 -from [get_clocks clk_38] -to [get_clocks clk_114]

# THE NEXT-EDGE SAMPLERS: single-cycle, by name, overriding the two above.
#
# The derivation above rests on "the copy that matters at edge T+3 is the one
# captured at T+2".  Since the D3 fix clkena is a REGISTER decided at T+2
# (rtl/soc/TG68K.vhd, clkena_r), and a register whose T+1 copy feeds that
# decision is really one clk_114 period from the kernel.  Under a blanket -end
# 2 it would not be timed at all.
#
# Stage E2 emptied this list down to one.  sel_ram_d/sel_ddr_d, the two
# cpu_cache_new line-buffer compares and the bus routers are gone or no longer
# see the island (the controllers take ap040_ram_seq's registers, the walker is
# on clk_38), and akiko_req/akiko_wr are driven by the Akiko sequencer, which
# latches only through the masked q_req.  What remains:
#
#   sel_undecoded_d   the wrapper's registered decode of x_addr, in
#                     bus_ready16, and read by the clk_38 walker.  Its T+1
#                     copy is never what releases an access -- the adapter is
#                     idle then, and idle releases anyway -- but it is kept
#                     single-cycle rather than argued loose.
#
# -hold 0 keeps the hold check on the coincident launch edge, as -end 1 did.
set cpu_next_edge [get_cells -quiet -hier -filter "(NAME =~ $cpu_wrapper/sel_undecoded_d_reg*) && ($tg68_seq)"]
set_multicycle_path -quiet -setup 1 -from [get_clocks clk_38] -to $cpu_next_edge
set_multicycle_path -quiet -hold  0 -from [get_clocks clk_38] -to $cpu_next_edge

# The phase marker must NOT be relaxed at all.  cpu_tgl flips on every clk_38
# edge and cpu_tgl_d has to catch it on the very next clk_114 edge; that is
# what puts cpu_ph2 on the cycle before the following clk_38 edge, and makes
# clkena a one-cycle pulse aligned with the kernel's own advance
# (rtl/soc/TG68K.vhd, the g_ap040 phase marker).  Give it two cycles and the
# pulse is simply in the wrong place, and `slower`, the chipset machine and
# every chip select go with it.  Same shape as the direct FF->FF crossings
# listed in wizard.xdc.
set cpu_phase_src [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/*cpu_tgl_reg && ($tg68_seq)"]
set cpu_phase_dst [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/*cpu_tgl_d_reg && ($tg68_seq)"]
set_multicycle_path -quiet -setup 1 -from $cpu_phase_src -to $cpu_phase_dst
set_multicycle_path -quiet -hold  0 -from $cpu_phase_src -to $cpu_phase_dst

#---------------------------------------------------------------------------
# clk_114 -> clk_38 (the wrapper's answers).  NOT RELAXED, deliberately.
#---------------------------------------------------------------------------
# The symmetric rule -- -setup -start N / -hold -start N-1 -- would be false
# here, and this is the one place the 1:4 dll_28 idiom does not carry over at
# all.  It would assert that a clk_114 register feeding the island does not
# change in the clk_114 cycles just before the island samples, and the
# wrapper's answers do exactly that:
# `clkena` itself, and since Stage E2 the completion x_ack_r with its data
# x_rdata_r (and datatg68_r for the adapter), are all registered on the clk_114
# edge immediately before a clk_38 one -- that is the whole point of the
# handshake, that the core is released as soon as memory answers rather than
# on the next slot of a cadence.  Category 2 of plan-v2's D4: a pulse shaped
# to the destination edge, genuinely one clk_114 period.
#
# Leaving the default is not a compromise for those: it is 8.815 ns, which is
# exactly the requirement they meet today (nothing in this file ever relaxed a
# path INTO the kernel, including the clkena net that fans out to 7,391 kernel
# clock-enable pins).  The absence of a rule here is the derivation's answer,
# not an omission.

# Stage E2 deleted the one exception that used to follow here: a -setup -start
# 2 from the clk_114 walker and line-fill routers into the island, valid only
# because `bus_step` froze both routers on the edge before each kernel edge.
# The fill router is gone, the walker is on clk_38, and bus_step with them.

#=============================================================================
# Wrapper and Akiko.  Unchanged.
#=============================================================================
# Wrapper address registers feeding the memory side: same rule as the kernel address.
set_multicycle_path -setup -start 2 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 1 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem

# Akiko C2P: no exception.  With the AP68040 the C2P result reaches the core
# only through the wrapper's own datatg68_c register, so there is no C2P ->
# kernel path to relax, and a clk_114 -> clk_38 relaxation would be false for
# the reason given above.  (The TG68K-scoped C2P rules went with that core in
# Stage E4a.)
