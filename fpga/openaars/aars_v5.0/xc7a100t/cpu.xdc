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
#   pf68K_Kernel_inst  TG68KdotC_Kernel (rtl/tg68k)
#   g_ap040.ap040      ap040_tg68k_compat (lib/AP68040)
set cpu_kernel_tg68k $cpu_wrapper/pf68K_Kernel_inst
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
set cpu_not_free   "NAME !~ *core_stall_watchdog/* && NAME !~ *walker_wr_d* && NAME !~ *wsnp_pend* && NAME !~ *wsnp_addr*"

set tg68_kernel [get_cells -hier -filter "($cpu_is_kernel) && ($cpu_not_free) && ($tg68_seq)"]
set tg68_wrap   [get_cells -hier -filter "NAME =~ $cpu_wrapper/* && ($cpu_not_kernel) && ($tg68_seq)"]
set tg68_mem    [get_cells -hier -filter "(NAME =~ openaars_virtual_top/sdram/* || NAME =~ openaars_virtual_top/minimig/*) && ($tg68_seq)"]

# Kernel island
set_multicycle_path -setup -start 4 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -hold  -start 3 -from $tg68_kernel -to $tg68_kernel
set_multicycle_path -setup -start 4 -from $tg68_kernel -to $tg68_wrap
set_multicycle_path -hold  -start 3 -from $tg68_kernel -to $tg68_wrap

# Kernel outputs to the memory side (SDRAM controller, cache, chipset interface)
set_multicycle_path -setup -start 3 -from $tg68_kernel -to $tg68_mem
set_multicycle_path -hold  -start 2 -from $tg68_kernel -to $tg68_mem

# Wrapper address registers feeding the memory side: same 3-cycle stability as the kernel address.
set_multicycle_path -setup -start 3 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 2 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem

# Akiko C2P: neither direction requires single-cycle speed (data consumed on clkena).
set c2p_rdptr [get_cells -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/rdptr_reg* && ($tg68_seq)"]
set c2p_buf   [get_cells -hier -filter "NAME =~ $cpu_wrapper/myakiko/c2p.myc2p/buf_reg* && ($tg68_seq)"]
set_multicycle_path -setup -start 2 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -setup -start 2 -from $c2p_buf   -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_buf   -to $tg68_kernel
