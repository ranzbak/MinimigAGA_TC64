# Fix 4 — Blanket TG68K multicycles land on single-cycle paths

**Severity: Medium · File: `fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:5-15,
30-35` · Effect: 11 direct flip-flop-to-flip-flop connections are given 4 cycles
of setup budget they do not have**

## Evidence

`wizard.xdc:4-15`:

```tcl
# CPU constraints
set _xlnx_shared_i0 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*]
set _xlnx_shared_i1 [all_registers]
set_multicycle_path -setup -start -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 4
set_multicycle_path -hold -start -from $_xlnx_shared_i0 -to $_xlnx_shared_i1 3

set _xlnx_shared_i2 [get_pins -hier -regexp openaars_virtual_top/tg68k/pf68K_Kernel_inst/memaddr.*]
set_multicycle_path -setup -start -from $_xlnx_shared_i2 -to $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from $_xlnx_shared_i2 -to $_xlnx_shared_i1 2

set_multicycle_path -setup -start -from [get_cells openaars_virtual_top/tg68k/addr*] -to $_xlnx_shared_i1 3
set_multicycle_path -hold -start -from [get_cells openaars_virtual_top/tg68k/addr*] -to $_xlnx_shared_i1 2
```

Vivado on the scale of it:

```
XDCB-1#2  Runtime intensive exceptions
  -from = expands to 46580 design objects.
  -to   = expands to 11933 design objects.
  set_multicycle_path -setup -start -from [get_pins -hier -regexp
    openaars_virtual_top/tg68k/pf68K_Kernel_inst/.*] -to [all_registers] 4
```

`XDCB-1` fires **10 times** across this file.

## Why `[all_registers]` is the problem

Three separate consequences:

**1. It ignores each endpoint's clock relationship.** `[all_registers]` spans
`clk_114`, `dll_28`, `clk_sd_114` and `clk_148`. A single `-start 4` cannot be
correct for all of them — `-start` is the fast→slow recipe (see
[fix-02-dll28-hold-multicycle.md](fix-02-dll28-hold-multicycle.md)), and many of
these endpoints are same-clock or slow→fast.

**2. It outranks the carefully written clock-to-clock exceptions.** In SDC,
exceptions scoped to pins and cells beat exceptions scoped to clocks. So for any
path originating in the TG68K kernel, the correct `clk_114 → dll_28` pair at
`wizard.xdc:43-44` is silently overridden by this blanket rule.

**3. It hits paths that genuinely need one cycle.** Vivado names 11 of them:

```
TIMING-46#1   amiga_clk/clk7_en_reg_reg/Q            -> sdram/clk7_enD_reg/D
TIMING-46#2   aud_tick_reg/Q                          -> aud_tick_d_reg/D
TIMING-46#3   hostcpu/hw_req_reg/Q                    -> mycfide/i2c_master.my_i2c_mmio/_req_reg/D
TIMING-46#4   hostcpu/wr_reg/Q                        -> mycfide/i2c_master.my_i2c_mmio/_wr_reg/D
TIMING-46#5   minimig/autoconfig/board_configured_reg[0]/Q -> tg68k/z2ram_ena_reg/D
TIMING-46#6-8 board_configured_reg[1..3]/Q            -> tg68k/z3ram*_ena_reg/D
TIMING-46#9   minimig/cpu_config_reg_reg[0]/Q         -> tg68k/pf68K_Kernel_inst/use_VBR_Stackframe_reg/D
TIMING-46#10  tg68k/lds2_reg/Q                        -> minimig/CPU1/l_lds2_reg/D
TIMING-46#11  tg68k/uds2_reg/Q                        -> minimig/CPU1/l_uds2_reg/D
```

Each carries the same message:

```
One or more multicycle paths are defined between registers <A>/Q and <B>/D with
a direct connection and the CE pins connected to VCC. This may result in an
inaccurate path requirement.
```

"CE tied to VCC" is the key phrase. A multicycle path asserts that the data only
changes every N cycles. That assertion is normally enforced by a clock enable.
With CE tied high, the register updates every cycle and the assertion is simply
false — the tool is being told it may take 4 cycles on a path that has 1.

The `hostcpu → i2c_mmio` pair in `#3` and `#4` is worth a look given commit
ae11724 ("fix I2C mmio core").

## Fix

Replace the blanket destination with the specific paths that really are
multi-cycle. Two workable approaches:

**A. Enumerate the destinations.**

```tcl
set tg68k_slow_dests [get_cells -hier -regexp {openaars_virtual_top/(sdram|minimig/CPU1)/.*}]
set_multicycle_path -setup -start -from $_xlnx_shared_i0 -to $tg68k_slow_dests 4
set_multicycle_path -hold  -start -from $_xlnx_shared_i0 -to $tg68k_slow_dests 3
```

**B. Scope by clock, then subtract the exceptions.** Keep a clock-to-clock
multicycle for the genuinely quarter-rate crossings and add explicit
single-cycle exceptions for the direct connections Vivado listed:

```tcl
set_multicycle_path -setup -start -from $_xlnx_shared_i0 -to [get_clocks clk_114] 4
set_multicycle_path -hold  -start -from $_xlnx_shared_i0 -to [get_clocks clk_114] 3

# These are direct FF->FF with CE tied high: one cycle, no exception
set_multicycle_path -setup -from [get_cells openaars_virtual_top/tg68k/lds2_reg] \
                           -to   [get_cells openaars_virtual_top/minimig/CPU1/l_lds2_reg] 1
# ... and the rest of the TIMING-46 list
```

Either way, the goal is that `report_methodology` returns zero `TIMING-46` and
zero `XDCB-1`.

## Same pattern at `wizard.xdc:30-35`

The C2P exceptions use `-hold -start 2` alongside `-setup -start 2`. The hold
companion should be `N-1`, i.e. `1`:

```tcl
set_multicycle_path -setup -start -from ...rdptr.* -to $_xlnx_shared_i3 2
set_multicycle_path -hold  -start -from ...rdptr.* -to $_xlnx_shared_i3 2   ;# should be 1
set_multicycle_path -setup -start -from $_xlnx_shared_i4 -to $_xlnx_shared_i3 2
set_multicycle_path -hold  -start -from $_xlnx_shared_i4 -to $_xlnx_shared_i3 2   ;# should be 1
```

## And the self-flagged one

`wizard.xdc:17-20`:

```tcl
# # Dram to cache line constraints
# Incorrect
set_multicycle_path -from [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/dtram/.*] -to ... -setup 2
set_multicycle_path -from ... -hold 1
```

A comment reading `# Incorrect` sits directly above two live constraints. Either
fix them or delete them — leaving a known-wrong exception in place means every
future reader has to re-derive whether it matters.

## Verify

```tcl
report_methodology -file meth.rpt      ;# TIMING-46 and XDCB-1 counts should be 0
report_exceptions -ignored             ;# nothing from the CPU rules should be overriding clock rules
```

Expect some paths that previously passed to start failing. Those are real.

## Verified in Vivado (2026-09-04)

Two things, one in each direction.

**The kernel genuinely needs the multicycle.** Worst kernel→kernel path
([20_tg68k_kernel_to_kernel.rpt](vivado-reports/20_tg68k_kernel_to_kernel.rpt)):
19.376 ns data path, 30 logic levels, 74 % routing, against a 26.446 ns
(3-cycle) requirement. 2.2× the clock period — single-cycle is not an option.

**The `TIMING-46` pairs are wrongly constrained but not currently failing.**
All four checked ([21_timing46_pairs.rpt](vivado-reports/21_timing46_pairs.rpt))
carry 1.7–2.3 ns against a 35.3 ns requirement and would pass single-cycle. Fix
the scoping for correctness and for the `XDCB-1` runtime, not because a
violation is hiding there today. One of the family,
`board_configured_reg[3] → z3ram3_ena_reg`, does show up in the
[fix 2](fix-02-dll28-hold-multicycle.md) hold violations — through the
`dll_28 → clk_114` rule.
