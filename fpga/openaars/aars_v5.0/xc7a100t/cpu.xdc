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
# If the CPU core is replaced, only the three set definitions below change.
# The wrapper set includes Akiko (CLUT block RAM and C2P), which the kernel writes on clkena.
#
# Multicycle form: same clock on both ends, so -start (move the launch edge) is used
# throughout; hold is always setup - 1.

# Endpoint filter: flip-flops, distributed RAM (the register file is RAM32X1D) and block RAM
# (Akiko CLUT). IS_SEQUENTIAL alone misses the RAM primitives.
set tg68_seq {IS_SEQUENTIAL || PRIMITIVE_TYPE =~ "DMEM.*" || PRIMITIVE_TYPE =~ "BMEM.*"}
set tg68_kernel [get_cells -hier -filter "NAME =~ openaars_virtual_top/tg68k/pf68K_Kernel_inst/* && ($tg68_seq)"]
set tg68_wrap   [get_cells -hier -filter "NAME =~ openaars_virtual_top/tg68k/* && NAME !~ openaars_virtual_top/tg68k/pf68K_Kernel_inst/* && ($tg68_seq)"]
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
set_multicycle_path -setup -start 3 -from [get_cells -quiet -hier -filter "NAME =~ openaars_virtual_top/tg68k/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 2 -from [get_cells -quiet -hier -filter "NAME =~ openaars_virtual_top/tg68k/addr* && ($tg68_seq)"] -to $tg68_mem

# Akiko C2P: neither direction requires single-cycle speed (data consumed on clkena).
set c2p_rdptr [get_cells -hier -filter "NAME =~ openaars_virtual_top/tg68k/myakiko/c2p.myc2p/rdptr_reg* && ($tg68_seq)"]
set c2p_buf   [get_cells -hier -filter "NAME =~ openaars_virtual_top/tg68k/myakiko/c2p.myc2p/buf_reg* && ($tg68_seq)"]
set_multicycle_path -setup -start 2 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_rdptr -to $tg68_kernel
set_multicycle_path -setup -start 2 -from $c2p_buf   -to $tg68_kernel
set_multicycle_path -hold  -start 1 -from $c2p_buf   -to $tg68_kernel
