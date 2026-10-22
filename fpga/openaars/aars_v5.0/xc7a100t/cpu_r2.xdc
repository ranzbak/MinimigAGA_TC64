# CPU timing exceptions at clock ratio 2: the AP68040 `faster` core on clk_38 = clk_114 / 2
# = 56.72 MHz (TG68K.vhd ap040_faster = 1, cpu_clk_ratio = 2; amiga_clk_xilinx CPU_CLK_DIVIDE
# = 20).  tools/vivado/build_ap040.tcl uses this file INSTEAD of cpu.xdc for such a build.
# (The clock keeps its name, clk_38, so every other constraint and script still finds it.)
#
# cpu.xdc's one blanket exception, -setup -end 2 from clk_38 to clk_114, does NOT carry over.
# Its derivation rests on the kernel's edges being three clk_114 periods apart: everything on
# the clk_114 side that answers the kernel is decided at T+2 for the kernel edge at T+3, two
# periods after the launch at T.  At ratio 2 the kernel edges are T and T+2, cpu_ph is high in
# (T, T+1), and clkena_r -- with x_ack_r, x_rdata_r and datatg68_r beside it -- is decided at
# T+1 from x_req, the router's decode of x_addr, and the adapter's state, all launched at T.
# That is ONE clk_114 period.  Relaxing the crossing to two would let the tool place a path
# that is sampled before it settles.
#
# So there is no exception on the island's crossings at all: clk_38 -> clk_114 and
# clk_114 -> clk_38 are both the default single clk_114 period, 8.815 ns, derived by the tool
# from the two clocks' edges.  Every signal leaving the island toward the memory side is a
# register (the bridge's mem_* in rtl/soc/ap68040_minimig.sv, the 16-bit adapter's outputs),
# so the budget is decode and routing.
#
# (Paths that ARE two periods long -- q_req is masked on T and T+1, so the sequencers first
# latch x_* at T+2 -- are left at one period too: tighter than needed, never wrong.  Relax them
# by name only if they fail.)

# Endpoint filter: flip-flops, distributed RAM and block RAM.
set tg68_seq {IS_SEQUENTIAL || PRIMITIVE_TYPE =~ "DMEM.*" || PRIMITIVE_TYPE =~ "BMEM.*"}
set cpu_wrapper openaars_virtual_top/tg68k
set tg68_mem    [get_cells -hier -filter "(NAME =~ openaars_virtual_top/sdram/* || \
                                           NAME =~ openaars_virtual_top/minimig/* || \
                                           NAME =~ openaars_virtual_top/g_ddr3_fastram.ddr3_fastram_i/*) && ($tg68_seq)"]


# The phase marker, unchanged from cpu.xdc: cpu_tgl flips on every clk_38 edge and cpu_tgl_d
# must catch it on the very next clk_114 edge.  At ratio 2 that is the default anyway; kept so
# the rule survives if a blanket relaxation is ever added above.
set cpu_phase_src [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/*cpu_tgl_reg && ($tg68_seq)"]
set cpu_phase_dst [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/*cpu_tgl_d_reg && ($tg68_seq)"]
set_multicycle_path -quiet -setup 1 -from $cpu_phase_src -to $cpu_phase_dst
set_multicycle_path -quiet -hold  0 -from $cpu_phase_src -to $cpu_phase_dst

# Wrapper address registers feeding the memory side: unchanged from cpu.xdc and NOT ratio
# dependent.  `addr` is the 7 MHz chipset machine's address register (clk_114, loaded on
# ena7WRreg and held for the whole chip cycle), so the two-cycle rule is about that machine,
# not about the island.  (The first ratio-2 build left it out: 3 paths to sdram/sdaddr_reg and
# cpu_cache failed at -0.48 ns.)
set_multicycle_path -setup -start 2 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
set_multicycle_path -hold  -start 1 -from [get_cells -quiet -hier -filter "NAME =~ $cpu_wrapper/addr* && ($tg68_seq)"] -to $tg68_mem
