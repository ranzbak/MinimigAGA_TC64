# CPU timing exceptions.  Two cores, and since stage D3 two different stories.
#
# TG68K (rtl/tg68k/TG68KdotC_Kernel.vhd inside rtl/soc/TG68K.vhd)
#   The kernel is clocked by clk_114 and advances only when clkena is high. The SDRAM controller
#   pulses clkena once per 4 clk_114 cycles (enaWRreg, 28.36 MHz) and the wrapper gates it further
#   on bus readiness. Every kernel register therefore holds its value for at least 4 clk_114
#   cycles, so kernel -> kernel and kernel -> wrapper paths get 4 cycles' worth (the numbers below
#   are 3, deliberately tighter; see the island block).  That is a MULTICYCLE story and it is
#   unchanged.
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
# If the CPU core is replaced, only the "Who the CPU is" block below changes.
# The wrapper set includes Akiko (CLUT block RAM and C2P), which the kernel writes on clkena.
#
# Multicycle form: for the TG68K both ends are clk_114, so -start (move the launch edge) is used
# and hold is always setup - 1.  For the AP68040 the two ends are different clocks and the form
# follows wizard.xdc's: -end on a slow -> fast path (relax the capture edge, keep the hold check
# on the launch edge), -start on fast -> slow.
#
# The TG68K block below matches nothing in an AP68040 build and everything scoped to it carries
# -quiet for that reason; so does the AP68040 phase marker, which does not exist in a TG68K one.
# The check that the exceptions actually landed is report_exceptions, not the absence of
# warnings -- and report_exceptions on an AP68040 build must show NONE on the core, which is
# this stage's stated exit criterion.

# Endpoint filter: flip-flops, distributed RAM (the register file is RAM32X1D) and block RAM
# (Akiko CLUT). IS_SEQUENTIAL alone misses the RAM primitives.
set tg68_seq {IS_SEQUENTIAL || PRIMITIVE_TYPE =~ "DMEM.*" || PRIMITIVE_TYPE =~ "BMEM.*"}

#-----------------------------------------------------------------------------
# Who the CPU is.  Everything below is written against these three lists, so a
# core swap changes only this block (findings/ap68040/plan-v2-with-ddr3.md,
# step 0.3).  A pattern that matches nothing simply contributes nothing, so one
# file serves both the TG68K and the AP68040 build.
#-----------------------------------------------------------------------------
set cpu_wrapper openaars_virtual_top/tg68k

# The kernel instance inside that wrapper, per core.  Only one of the two is
# elaborated (TG68K.vhd's cpu_core generic picks the generate branch), so the
# other pattern simply matches nothing and one file serves both builds.
# Note the generate label in each: Vivado names a VHDL if-generate instance
# "<label>.<instance>", so making the kernel a generate MOVED it in the
# netlist.  That is what silently emptied these sets the first time -- ten
# "No valid object(s) found" criticals and no CPU exceptions in the bitstream.
#   g_tg68k.pf68K_Kernel_inst  TG68KdotC_Kernel (rtl/tg68k)
#   g_ap040.ap040              ap040_tg68k_compat (lib/AP68040)
set cpu_kernel_tg68k $cpu_wrapper/g_tg68k.pf68K_Kernel_inst
set cpu_kernel_ap040 $cpu_wrapper/g_ap040.ap040

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
# clk_38 period.  For wk_active it is false: the walker router advances on
# clkena, clkena is a bus handshake now, and wk_active can therefore change on
# any clk_114 edge.  It keeps single-cycle timing, like every other wrapper
# register.
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

# Written out longhand: an XDC file is not general Tcl, and Vivado rejects
# foreach ("Command 'foreach' is not supported in the xdc constraint file",
# Designutils 20-1307).  Building these strings in a loop cost a build: the
# variables were left unset and all ten exceptions below were silently dropped.
set cpu_not_kernel "NAME !~ $cpu_kernel_tg68k/* && NAME !~ $cpu_kernel_ap040/*"

# Only the TG68K kernel needs a cell list now.  The AP68040's rules are all
# clock-scoped, which is the whole point of stage D3: there is nothing left to
# name, because the island is a clock domain instead of an exception.  The set
# is empty in an AP040 build, so everything written against it carries -quiet.
set tg68_kernel  [get_cells -quiet -hier -filter "NAME =~ $cpu_kernel_tg68k/* && ($tg68_seq)"]

set tg68_wrap   [get_cells -hier -filter "NAME =~ $cpu_wrapper/* && ($cpu_not_kernel) && ($tg68_seq)"]

# The memory side: everything that takes cpuAddr/cpustate and states the
# "address stable one cycle before the chip select" contract in its header.
# ddr3_fastram is in this list since stage D3 -- it was missed before, and its
# cpu_cache_new instance wants the same rule sdram_ctrl's does
# (ddr3_fastram.v:20).  minimig is here for the chipset side.
set tg68_mem    [get_cells -hier -filter "(NAME =~ openaars_virtual_top/sdram/* || \
                                           NAME =~ openaars_virtual_top/minimig/* || \
                                           NAME =~ openaars_virtual_top/g_ddr3_fastram.ddr3_fastram_i/*) && ($tg68_seq)"]

#=============================================================================
# TG68K: the kernel island.  Unchanged by stage D3.
#=============================================================================
#
# The CPU's clock enable is enaWRreg, pulsed on FOUR of the sixteen SDRAM
# phases (2, 6, 10, 14, spacing 4-4-4-4), the single shared cadence in
# rtl/sdram/cpu_enable_cadence.v (used by both sdram_ctrl.v and
# sim/ddr3_cpu).  At four phases the minimum spacing is 4 cycles, 35.26 ns,
# which would allow -start 4 / -hold 3.  The values below are -start 3 /
# -hold 2 (26.45 ns) instead -- tighter than four phases needs.  That dates
# from a five-phase enable (spacing 3-3-3-3-4, findings/ap68040/performance.md
# option 1a, "D1") which was tried in RTL and reverted (it does not boot);
# a later bench-only five-phase experiment (findings/ap68040/plan-v2-with-ddr3.md,
# task 4) confirmed the "0111" hypothesis was not the boot fix and left the
# cadence at four phases for good.  The tighter -start 3 / -hold 2 values
# were kept deliberately rather than loosened back to -start 4 / -hold 3:
# a tighter-than-necessary exception only costs margin the design isn't
# using, never correctness.
set_multicycle_path -quiet -setup -start 3 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -quiet -hold  -start 2 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -quiet -setup -start 3 -from $tg68_kernel -to $tg68_wrap
set_multicycle_path -quiet -hold  -start 2 -from $tg68_kernel -to $tg68_wrap

# Kernel outputs to the memory side: one cycle less than the island, because
# the controllers want the address stable a cycle before the chip select.
# 2 cycles = 17.63 ns.
set_multicycle_path -quiet -setup -start 2 -from $tg68_kernel -to $tg68_mem
set_multicycle_path -quiet -hold  -start 1 -from $tg68_kernel -to $tg68_mem

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
#   The memory side lands on the same number from the other direction.  Both
#   controllers register cpuAddr unconditionally and compare the registered
#   copy on the cycle they act on the select (sdram_ctrl.v:226,240 and
#   ddr3_fastram.v:20,220), and `slower` -- reloaded by clkena, which is now a
#   one-cycle pulse on exactly the clk_114 edge the kernel advances on -- holds
#   ramcs and ddrcs off until the select can first open during (T+3,T+4).  The
#   compare that gates it was captured at T+3 from the address during
#   (T+2,T+3): settled at T+2 again.
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

# KNOWN LOOSE, recorded rather than tightened.  A few wrapper registers read a
# kernel output on the very NEXT clk_114 edge and so want one cycle, not two:
# akiko_req/akiko_wr (gated by slower(2), which opens one cycle earlier than
# slower(1) does), and the walker and line-fill routers, which test wk_req,
# fl_req and the kernel's busstate unguarded on every edge.  All of them were
# loose by TWO under the old -start 3 island and have never been near the
# critical path -- a 16-bit address compare and a two-bit state test.  Making
# them exact is an RTL change (another cpu_bus_settled term) and a second
# variable; stage D3 has one.

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
# `clkena` itself, `datatg68`, `bus_ready`, `mem_ready`, the walker's and the
# fill router's acknowledges and payloads are all produced on the FREE clk_114
# clock and can rise on the edge immediately before a clk_38 one -- that is the
# whole point of the handshake, that the core is released as soon as memory
# answers rather than on the next slot of a cadence.
#
# Leaving the default is not a compromise: it is 8.815 ns, which is exactly the
# requirement these same paths meet today (nothing in this file ever relaxed a
# path INTO the kernel, including the clkena net that fans out to 7,391 kernel
# clock-enable pins).  So this direction is unchanged by stage D3, and the
# absence of a rule here is the derivation's answer, not an omission.

#=============================================================================
# Wrapper and Akiko.  Unchanged.
#=============================================================================
# Wrapper address registers feeding the memory side: same rule as the kernel address.
set_multicycle_path -setup -start 2 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 1 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem

# Akiko C2P: neither direction requires single-cycle speed (data consumed on clkena).
# Scoped to the TG68K kernel: with the AP68040 the C2P result reaches the core
# only through the wrapper's own datatg68_c register, so there is no C2P ->
# kernel path to except, and a clk_114 -> clk_38 relaxation would be false for
# the reason given above.
set c2p_rdptr [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/rdptr_reg* && ($tg68_seq)"]
set c2p_buf   [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/buf_reg* && ($tg68_seq)"]
set_multicycle_path -quiet -setup -start 2 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -quiet -hold  -start 1 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -quiet -setup -start 2 -from $c2p_buf   -to $tg68_kernel
set_multicycle_path -quiet -hold  -start 1 -from $c2p_buf   -to $tg68_kernel
