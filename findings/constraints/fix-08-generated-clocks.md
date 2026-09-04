# Fix 8 — Generated clocks that model gated, data-driven toggles

**Severity: Low · Files: `wizard.xdc:50-51`, `clocks.xdc:15-17` · Effect: four of
the eight `TIMING-47` warnings, plus a fragile clock model**

## Part 1 — SPI clocks declared as fixed dividers

`wizard.xdc:50-51`:

```tcl
create_generated_clock -name my_i2s_transmitter/max_sclk_OBUF -source [get_pins .../CLKOUT0] -divide_by 70 [get_pins my_i2s_transmitter/sclk_reg/Q]
create_generated_clock -name openaars_virtual_top/mycfide/sck_reg_n_0 -source [get_pins .../CLKOUT0] -divide_by 70 [get_pins openaars_virtual_top/mycfide/sck_reg/Q]
```

Both declare a clean divide-by-70 off `clk_114`, giving 1.621 MHz in the Clock
Summary. Neither register is a divider.

`cfide.vhd:461-468` — `sck` is a state-machine output, gated on a shift counter:

```vhdl
                        IF sck = '0' THEN
                            IF shiftcnt(12 downto 0) /= "0000000000000" THEN
                                sck <= '1';
                            END IF;
                            shiftcnt <= shiftcnt - 1;
                        ELSE
                            sck         <= '0';
```

It stops between transfers and its rate depends on the state machine, not on a
fixed ratio. The `-divide_by 70` is an approximation that happens to bound the
worst case.

Consequence — four of the eight `TIMING-47` warnings:

```
TIMING-47#1  clock group between synchronous clocks clk_114 and .../sck_reg_n_0
TIMING-47#3  ... dll_28 and .../sck_reg_n_0
TIMING-47#4  ... .../sck_reg_n_0 and clk_114
TIMING-47#5  ... .../sck_reg_n_0 and dll_28
```

and three rows in the User Ignored Path Table.

Real risk is low — these are slow, non-critical interfaces. But the model is a
fiction and it costs four warnings that mask the ones that matter.

**Better:** drop the generated clocks and the `async_mycfide` group, and
constrain the SPI outputs with a plain maximum delay instead:

```tcl
set_max_delay -datapath_only -from [get_cells openaars_virtual_top/mycfide/sck_reg] \
  -to [get_ports {sd_m_cmd sd_m_clk}] 20.0
```

That expresses the real requirement — "get there within a fraction of an SPI bit
time" — without inventing a clock.

## Part 2 — MMCM clock renames without `-source`

`clocks.xdc:14-24`:

```tcl
create_generated_clock -name clk_114 -master_clock [get_clocks clk_50] [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]
create_generated_clock -name clk_sd_114 -master_clock [get_clocks clk_50] [get_pins .../CLKOUT1]
create_generated_clock -name dll_28 -master_clock [get_clocks clk_50] [get_pins .../CLKOUT2]
...
create_generated_clock -name clk_148 -master_clock [get_clocks clk_50] [get_pins clk_hdmi/CLKOUT0]
```

These give `-master_clock` but no `-source`, and no `-multiply_by` /
`-divide_by`. The documented form pairs `-source` with the MMCM's `CLKIN1` pin.

It worked out — the Clock Summary shows the correct values:

```
clk_114     {0.000 4.408}    8.815    113.438
clk_sd_114  {-2.975 1.433}   8.815    113.438      <-- -121.5 deg phase preserved
dll_28      {0.000 17.631}   35.262    28.359
clk_148     {0.000 3.367}     6.734   148.500
```

so Vivado inferred the ratios and the phase from the MMCM settings. But the form
is fragile: it overrides the auto-derived clock rather than renaming it, and a
future MMCM edit (a changed `CLKOUTn_DIVIDE_F`, a phase shift) may not propagate.

Two safer options:

**A. Add `-source`:**

```tcl
create_generated_clock -name clk_114 \
  -source [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKIN1] \
  -master_clock [get_clocks clk_50] \
  [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]
```

**B. Drop the renames entirely** and reference the auto-derived clocks by object:

```tcl
set clk_114 [get_clocks -of_objects [get_pins openaars_virtual_top/amiga_clk/amiga_clk_i/clk_main/CLKOUT0]]
```

Option B is what the rest of `wizard.xdc` already does in places (lines 43-47),
which is why the same clock is referred to two different ways in the same file.
Pick one style.

## Part 3 — feedback nets promoted to clocks

The Clock Summary lists:

```
clk_fb_main    {0.000 20.000}   40.000   25.000
clk_fb_main_1  {0.000 20.000}   40.000   25.000
```

These are the two MMCM `CLKFBOUT`/`CLKFBIN` nets. They appear in the
Unconstrained Path Table. Harmless, but they add noise to every report. If they
bother you, they can be excluded from analysis; otherwise leave them.

## Verify

```tcl
report_clocks -file clocks.rpt
report_methodology                 ;# TIMING-47 should drop from 8 to at most 1
```
