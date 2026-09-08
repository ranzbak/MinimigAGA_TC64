# CPU timing exceptions - TG68K (rtl/tg68k/TG68KdotC_Kernel.vhd inside rtl/soc/TG68K.vhd)
#
# The kernel is clocked by clk_114 but advances only when clkena is high. The SDRAM controller
# pulses clkena once per 4 clk_114 cycles (enaWRreg, 28.36 MHz) and the wrapper (TG68K.vhd:457)
# gates it further on bus readiness. Every kernel register therefore holds its value for at
# least 4 clk_114 cycles, so:
#   kernel -> kernel and kernel -> wrapper paths get 4 cycles.
#
# Kernel outputs (address, data, bus state) are sampled every cycle by the SDRAM controller and
# the chipset interface, but only used once they are stable; the controller requires the address
# one cycle before chip-select (sdram_ctrl.v:186), so those paths get 3 cycles, as the original
# memaddr rule did.
#
# The destination sets are explicit cell lists so that the exceptions can never land on a
# consumer that samples every cycle (a direct FF->FF with CE tied high, Vivado TIMING-46).
# If the CPU core is replaced, only the "Who the CPU is" block below changes.
# The wrapper set includes Akiko (CLUT block RAM and C2P), which the kernel writes on clkena.
#
# Multicycle form: same clock on both ends, so -start (move the launch edge) is used
# throughout; hold is always setup - 1.

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

# Registers inside the kernel that advance on the FREE-RUNNING clock rather
# than on clkena, and therefore keep honest single-cycle timing.  Relaxing
# these would be wrong, not merely generous.
#
#   core_stall_watchdog  ap040_bus_timeout, a 21-bit counter with no enable at
#                        all: it exists to notice a clkena wedge, so a wedge
#                        must not be able to stop it (ap040_tg68k_compat.v:14-28)
#   walker_wr_d / wsnp_* the walker-write snoop edge detector in the same file
#                        (:293-305), also ungated
#
# NOT AUDITED EXHAUSTIVELY YET: these two are the blocks read out of the source
# at step 0.3.  Stage A3 must re-check against the elaborated netlist -- look
# for TIMING-46 and for CE pins tied high inside the kernel set -- because a
# register that samples every cycle and receives a 4-cycle exception is exactly
# the class of bug findings/constraints/fix-04 was about.
#
# Written out longhand: an XDC file is not general Tcl, and Vivado rejects
# foreach ("Command 'foreach' is not supported in the xdc constraint file",
# Designutils 20-1307).  Building these strings in a loop cost a build: the
# variables were left unset and all ten exceptions below were silently dropped.
set cpu_is_kernel  "NAME =~ $cpu_kernel_tg68k/* || NAME =~ $cpu_kernel_ap040/*"
set cpu_not_kernel "NAME !~ $cpu_kernel_tg68k/* && NAME !~ $cpu_kernel_ap040/*"
# Registers inside the core that do NOT advance on the clock enable.  A
# multicycle exception on one of these is simply false: it updates every
# clock, so the tool would check a single-cycle path against the island's
# budget and report slack that does not exist.  This is the TIMING-46 class
# fix-04 was about, and the list is no longer guesswork -- it comes from
# reading every always @(posedge clk) in lib/AP68040/rtl for its enable guard
# (2026-09-08):
#
#   core_stall_watchdog   ap040_bus_timeout, counts on the free clock by design
#   walker_wr_d, wsnp_*   the compat top's walker-write snoop, free-running
#   l_row, l_tag, l_ld    ap040_mmu.v:163, the ATC lookup pipe, no ce at all
#                         -- measured 6.237 ns
#   *_snooped             ap040_cache.v:253, "set free-running -- the snoop is"
#
# All of them meet single-cycle timing today; the point is that from here on
# the tool checks that instead of taking it on trust.
set cpu_not_free   "NAME !~ *core_stall_watchdog/* && NAME !~ *walker_wr_d* && NAME !~ *wsnp_pend* && NAME !~ *wsnp_addr* && \
                    NAME !~ *mmu/l_row_reg* && NAME !~ *mmu/l_tag_reg* && NAME !~ *mmu/l_ld_reg* && \
                    NAME !~ *_snooped_reg*"

# The interrupt sampler (ipl_s*, irq_*, nmi_*, ap040_core.v:151) is NOT in that
# list, and that is a decision rather than an oversight.  It free-runs, so the
# cone from it into the sequencer is physically single-cycle: 15 levels, 9.86 ns
# of which 80 % routing, against 8.815 ns.  It cannot be placed out of trouble
# and it cannot be pipelined -- splitting it was tried on 2026-09-08 and the
# core's own t_exceptions test 150 rejected it, because what must be immediate
# is the MASK: the request is asserted while masked, settles, and then a
# "move.w #$2000,sr" has to take it at that very boundary.  That path launches
# from sr, a ce-gated register, and keeps the island's normal treatment.
#
# What the exception says for the ipl side is that the LEVEL may take longer
# than one clock to settle.  It may: the level is asynchronous and level-held,
# so if it changes less than a path delay before an enable edge the sequencer
# reads the old value and takes the interrupt at the next boundary instead --
# which is indistinguishable from the request having arrived a fraction later.
# A multicycle exception costs no latency; it only stops the tool checking an
# asynchronous arrival against a deadline it was never required to meet.
#
# The snoop flags are the opposite case and stay excluded: a late snoop is a
# stale cache line, not a deferred interrupt.  They meet single-cycle today.

# ... but "no clock enable" is not the same as "changes every cycle".  A flop
# clocked every cycle whose INPUT only moves just after an enable edge has an
# output that only moves just after an enable edge too, so what follows it has
# the enable period minus one cycle -- two, not one, and not the island's
# three.  Two of the groups above are exactly that, and constraining them
# single-cycle is as wrong as constraining them at three, just in the safe
# direction (measured: 9.8 ns and 9.1 ns of real path, against 8.7 ns at one
# cycle and 17.63 ns at two):
#
#   l_row/l_tag/l_ld  ap040_mmu.v:163, loaded from a_row/a_tag, which come
#                     from c_addr -- and the core drives mem_addr from
#                     task issue_ifetch, called under "else if (ce)"
#   wk_active         the walker router in TG68K.vhd; every transition is
#                     triggered by a ce-aligned event (walker_req, which the
#                     MMU registers under ce, or a clkena completion)
#
# ipl_s* stays single-cycle: it samples an asynchronous input and really can
# change on any clock.  That one needs RTL, not a constraint.
set cpu_ce_aligned [get_cells -quiet -hier -filter "(NAME =~ $cpu_wrapper/wk_active_reg* || \
                                                    NAME =~ $cpu_kernel_ap040/mmu/l_row_reg* || \
                                                    NAME =~ $cpu_kernel_ap040/mmu/l_tag_reg* || \
                                                    NAME =~ $cpu_kernel_ap040/mmu/l_ld_reg*) && ($tg68_seq)"]
set_multicycle_path -setup -start 2 -from $cpu_ce_aligned
set_multicycle_path -hold  -start 1 -from $cpu_ce_aligned

set tg68_kernel [get_cells -hier -filter "($cpu_is_kernel) && ($cpu_not_free) && ($tg68_seq)"]
set tg68_wrap   [get_cells -hier -filter "NAME =~ $cpu_wrapper/* && ($cpu_not_kernel) && ($tg68_seq)"]
set tg68_mem    [get_cells -hier -filter "(NAME =~ openaars_virtual_top/sdram/* || NAME =~ openaars_virtual_top/minimig/*) && ($tg68_seq)"]

# Kernel island.
#
# The CPU's clock enable is enaWRreg, pulsed on five of the sixteen SDRAM
# phases (2, 5, 8, 11, 14 -- sdram_ctrl.v), spacing 3-3-3-3-4.  A multicycle
# exception has to cover the MINIMUM spacing, so these are 3 and not 4: every
# kernel register holds for at least 3 cycles, 26.45 ns.  It was 4 (35.26 ns)
# while the enable was on four phases; findings/ap68040/performance.md option
# 1a made the change, and the AP68040's worst path is 21.0 ns standalone, so
# the budget is met with about 5 ns to spare before congestion.
set_multicycle_path -setup -start 3 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -hold  -start 2 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -setup -start 3 -from $tg68_kernel -to $tg68_wrap
set_multicycle_path -hold  -start 2 -from $tg68_kernel -to $tg68_wrap

# Kernel outputs to the memory side (SDRAM controller, cache, chipset
# interface): one cycle less than the island, because sdram_ctrl wants the
# address stable a cycle before the chip select.  2 cycles = 17.63 ns.
set_multicycle_path -setup -start 2 -from $tg68_kernel -to $tg68_mem
set_multicycle_path -hold  -start 1 -from $tg68_kernel -to $tg68_mem

# Wrapper address registers feeding the memory side: same rule as the kernel address.
set_multicycle_path -setup -start 2 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 1 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem

# Akiko C2P: neither direction requires single-cycle speed (data consumed on clkena).
set c2p_rdptr [get_cells -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/rdptr_reg* && ($tg68_seq)"]
set c2p_buf   [get_cells -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/buf_reg* && ($tg68_seq)"]
set_multicycle_path -setup -start 2 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -setup -start 2 -from $c2p_buf   -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_buf   -to $tg68_kernel
