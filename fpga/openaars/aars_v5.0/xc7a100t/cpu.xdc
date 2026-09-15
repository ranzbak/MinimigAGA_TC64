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
# It has since come BACK, for the walker and the line-fill router both, with
# the premise made TRUE in RTL rather than asserted: rtl/soc/TG68K.vhd gates
# both routers on `bus_step`, which skips exactly that one edge in three.  See
# the bus-router block at the end of the clk_114 -> clk_38 section.
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

# The memory side: everything that takes cpuAddr/cpustate and states the
# "address stable one cycle before the chip select" contract in its header.
# ddr3_fastram is in this list since stage D3 -- it was missed before, and its
# cpu_cache_new instance wants the same rule sdram_ctrl's does
# (ddr3_fastram.v:20).  minimig is here for the chipset side.
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

# THE NEXT-EDGE SAMPLERS: single-cycle, by name, overriding the two above.
#
# The derivation above rests on "the copy that matters at edge T+3 is the one
# captured at T+2".  That was true while clkena was decided combinationally at
# T+3.  Since the D3 fix clkena is a REGISTER decided at T+2 (rtl/soc/TG68K.vhd,
# clkena_r), and the copies that matter to THAT decision are the ones captured
# at T+1 -- one clk_114 period after the kernel's address moved.  Under a
# blanket -end 2 those captures are not timed at all: the tool is told they
# may take 17.63 ns, the design consumes them after 8.815 ns, and whether the
# bitstream works is decided by where the placer happened to put things.
# Measured on the routed d3fixc checkpoint the worst of them,
# bus16/addr_out_reg[26] -> sdram/cpu_cache/cpu_cacheline_match_reg, took
# 7.394 ns -- inside one period, by 1.0 ns, by luck.  These are exactly the
# registers whose value at T+1 the T+2 decision reads
# (findings/ap68040/sdd-d3/task-d3stable-report.md has the enumeration):
#
#   sel_ram_d, sel_ddr_d, sel_undecoded_d      the wrapper's decode copies
#   sdram/cpu_cache/cpu_cacheline_match         cpu_cache_new.v:257, the
#   ddr3_fastram_i/cpu_cache/cpu_cacheline_match  line-buffer hit compare
#
# and with them the registers that were "KNOWN LOOSE" here before: akiko_req
# and akiko_wr (gated by slower(2), one cycle earlier than slower(1)), and
# both bus routers, which sample wk_req/wk_addr/wk_wdat/wk_we, fl_req/fl_addr
# and the kernel's busstate on the very next edge -- a router that starts one
# edge after the kernel raised its request copies the kernel's address into
# wk_busaddr/fl_busaddr on that edge, single-cycle.  Every one of these is now
# what it physically is: one clk_114 period from the kernel.  Cell-scoped
# exceptions take priority over the clock-scoped pair above, so this is an
# override, not a conflict; report_exceptions shows both.
#
# -hold 0 keeps the hold check on the coincident launch edge, as -end 1 did.
set cpu_next_edge [get_cells -quiet -hier -filter "(NAME =~ $cpu_wrapper/sel_ram_d_reg* || \
                                                  NAME =~ $cpu_wrapper/sel_ddr_d_reg* || \
                                                  NAME =~ $cpu_wrapper/sel_undecoded_d_reg* || \
                                                  NAME =~ $cpu_wrapper/akiko_req_reg* || \
                                                  NAME =~ $cpu_wrapper/akiko_wr_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_st_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_active_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_bstate_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_busaddr_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_wdat16_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_ack_reg* || \
                                                  NAME =~ $cpu_wrapper/wk_berr_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_st_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_busy_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_active_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_bstate_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_busaddr_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_word_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_ack_reg* || \
                                                  NAME =~ $cpu_wrapper/fl_err_reg* || \
                                                  NAME =~ openaars_virtual_top/sdram/cpu_cache/cpu_cacheline_match_reg* || \
                                                  NAME =~ openaars_virtual_top/g_ddr3_fastram.ddr3_fastram_i/cpu_cache/cpu_cacheline_match_reg*) && ($tg68_seq)"]
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
# `clkena` itself, `datatg68`, `bus_ready`, `mem_ready`, the walker's and the
# fill router's acknowledges and payloads are all produced on the FREE clk_114
# clock and can rise on the edge immediately before a clk_38 one -- that is the
# whole point of the handshake, that the core is released as soon as memory
# answers rather than on the next slot of a cadence.
#
# Leaving the default is not a compromise for those: it is 8.815 ns, which is
# exactly the requirement they meet today (nothing in this file ever relaxed a
# path INTO the kernel, including the clkena net that fans out to 7,391 kernel
# clock-enable pins).  The absence of a rule here is the derivation's answer,
# not an omission -- for everything except the walker router, below.

#---------------------------------------------------------------------------
# ... except the two bus routers, which are now stable by construction.
#---------------------------------------------------------------------------
# THE ONE EXCEPTION INTO THE ISLAND, AND WHY IT IS NOT THE MISTAKE ABOVE.
#
# `wk_active`/`wk_busaddr` and `fl_active`/`fl_busaddr` select the bus-side
# address mux in rtl/soc/TG68K.vhd, and that mux is the head of the longest
# combinational chain in the design:
#
#   cpuaddr -> sel_kickram -> cache_inhibit -> sdram_ctrl -> cpu_cache_new's
#   cpu_cacheline_valid -> cpu_ack -> cpuena -> ramready -> mem_ready ->
#   bus_ready -> clkena -> the kernel
#
# -- out of the wrapper, across the die into a memory controller, through its
# cache-hit logic and all the way back into the CPU island (and the same round
# trip again through ddr3_fastram's own cpu_cache_new).  Driven from the
# kernel's addrtg68 that chain is clk_38 -> clk_38 and has 26.45 ns.  Driven
# from these registers it is clk_114 -> clk_38 and has 8.815 ns, and it
# measured 8.24 ns in build/stage_ap040_d3.  Measured on those two routed
# checkpoints, wk_active, wk_busaddr and fl_busaddr are, in that order, the
# startpoint of EVERY clk_114 -> clk_38 path with less than 0.3 ns of slack:
# 3987 of the 4000 worst, then all of the next 3000, then all of the rest down
# to 0.107 ns.  This one pair of routers is the crossing's whole problem, and
# the intermittent AN_MemCorrupt Guru is what a mis-captured clkena or a
# mis-captured ATC entry looks like from Exec.
#
# Before stage D3 the walker half was covered: cpu.xdc had `$cpu_ce_aligned`,
# a -setup -start 2 on `wk_active` worth 17.63 ns, and stage D3 deleted it --
# on the correct ground that its premise ("every transition of wk_active is
# triggered by a ce-aligned event") is false once the kernel has its own clock.
# It is false in five specific places, all of them waits on something the
# memory side produces:
#
#   * WK_IDLE -> WK_HI is gated on fl_busy, which the line-fill router drops on
#     whatever clk_114 edge its eighth word lands on;
#   * the sel_undecoded abort in WK_HI and WK_LO fires on the first edge in the
#     state, one edge after the state was entered;
#   * WK_GAP -> WK_LO is gated on bus_ready falling;
#   * FL_SEL -> FL_GAP is gated on mem_ready rising and FL_GAP -> FL_SEL on it
#     falling -- twice per word, eight words per line.
#
# So the premise was MADE true instead of asserted: `bus_step` gates both
# router processes, and bus_step is `NOT cpu_ph`.  cpu_ph is the phase marker's
# middle register, high in (T+1,T+2) when the kernel's edges are at T and T+3,
# so an edge that samples cpu_ph = '1' IS edge T+2 -- the one clk_114 edge
# before the kernel samples -- and that edge alone is skipped.  Every register
# in both routers therefore holds its value across (T+1,T+2) and (T+2,T+3),
# which is exactly and only what -setup -start 2 asserts.  Nothing is lost by
# skipping an edge: every condition either router waits on is a level held
# until consumed, with the single exception of `clkena`, which is high in
# (T+2,T+3) and is therefore only ever sampled at edge T+3, where the routers
# run.  The derivation is written out at the walker process itself in
# rtl/soc/TG68K.vhd; IF THAT GATE IS EVER REMOVED, THIS EXCEPTION MUST GO WITH
# IT.
#
# Two is the maximum and three would be false: both routers still run at edge
# T+1, so a value launched at T can be gone by T+1.
#
# Scoped `-to [get_clocks clk_38]` and no further.  The same registers also
# feed sdram_ctrl and ddr3_fastram, which sample cpuAddr unconditionally on
# every clk_114 edge; those paths keep the single-cycle rule they have always
# had.  And nothing here touches `clkena`'s own cone from `bus_ready`, which
# stays 8.815 ns, nor `datatg68`, which is genuinely single-cycle: cpu_cache_new
# sets `cpu_dat_r <= sdr_dat_r` and `cpu_cache_ack <= 1'b1` in the SAME
# statement block in CPU_SM_FILL1 (rtl/sdram/cpu_cache_new.v), on whichever
# clk_114 edge the SDRAM burst's first word lands on -- which can be the edge
# before a clk_38 one.  A -setup 2 on the read data would be exactly the kind
# of claim that is true in the abstract and false in effect.
#
# -hold -start 1 keeps the hold check where it was: verified on the routed
# checkpoint, the hold requirement for these paths is still 0.000 ns
# (clk_38 rise@0 - clk_114 rise@0), the coincident-edge check, with the same
# 0.128 ns of slack it had before the exception.
set bus_routers [get_cells -quiet -hier -filter "(NAME =~ $cpu_wrapper/wk_st_reg* || \
                                               NAME =~ $cpu_wrapper/wk_active_reg* || \
                                               NAME =~ $cpu_wrapper/wk_bstate_reg* || \
                                               NAME =~ $cpu_wrapper/wk_busaddr_reg* || \
                                               NAME =~ $cpu_wrapper/wk_wdat16_reg* || \
                                               NAME =~ $cpu_wrapper/wk_data_reg* || \
                                               NAME =~ $cpu_wrapper/wk_ack_reg* || \
                                               NAME =~ $cpu_wrapper/wk_berr_reg* || \
                                               NAME =~ $cpu_wrapper/fl_st_reg* || \
                                               NAME =~ $cpu_wrapper/fl_busy_reg* || \
                                               NAME =~ $cpu_wrapper/fl_active_reg* || \
                                               NAME =~ $cpu_wrapper/fl_bstate_reg* || \
                                               NAME =~ $cpu_wrapper/fl_busaddr_reg* || \
                                               NAME =~ $cpu_wrapper/fl_word_reg* || \
                                               NAME =~ $cpu_wrapper/fl_line_reg* || \
                                               NAME =~ $cpu_wrapper/fl_ack_reg* || \
                                               NAME =~ $cpu_wrapper/fl_err_reg*) && ($tg68_seq)"]
set_multicycle_path -quiet -setup -start 2 -from $bus_routers -to [get_clocks clk_38]
set_multicycle_path -quiet -hold  -start 1 -from $bus_routers -to [get_clocks clk_38]

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
