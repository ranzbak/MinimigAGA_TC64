# Fix 9 — Ports with no delay constraint and no exception

**Severity: Low · Effect: 2 input ports and 3 output ports are timed against
nothing**

## Evidence

From `check_timing` in the routed timing summary:

```
5. checking no_input_delay (15)
    2 input ports with no input delay specified.                  (HIGH)
   13 input ports with no input delay but user has a false path.  (MEDIUM)

6. checking no_output_delay (26)
    3 ports with no output delay specified.                       (HIGH)
   21 ports with no output delay but user has a false path.       (MEDIUM)
    2 ports with no output delay but with a timing clock on it.   (LOW)
```

The MEDIUM entries are deliberate — `set_false_path` on the slow interfaces
(PS/2, UART, RTC, LEDs, buttons, joystick, I²C). The two LOW entries are
`dr_clk` and `max_sclk`, which carry generated clocks. The **HIGH** entries are
the ones nobody decided about.

## Verified — the guess below was wrong

`check_timing -verbose` on the April-2024 checkpoint
([vivado-reports/04_check_timing.rpt](vivado-reports/04_check_timing.rpt)):

```
2 input ports with no input delay specified. (HIGH)
    uart0_cts
    uart0_rxd
3 ports with no output delay specified. (HIGH)
    uart0_rts
    uart0_txd
    uart1_txd
```

Not the SD card pins. The working-tree `uart.xdc:23-24` already false-paths all
five, so on a fresh build the HIGH counts should read 0 — confirm after the next
implementation run. The SD card and `dv_cecclk` discussion below stands as a
review of *intent*, not as a report of missing constraints.

## Likely candidates

The SD card interface is only partly covered. `wizard.xdc:2` false-paths two of
its pins:

```tcl
set_false_path -to [get_ports {io_scl io_sda js_cs js_mosi js_sck max_i2s max_lrclk sd_m_cmd sd_m_d3}]
```

and `sd_card.xdc:25` covers one input:

```tcl
set_false_path -from [get_ports sd_m_d0]
```

Not covered anywhere:

| Port | Direction | Declared at |
|---|---|---|
| `sd_m_clk` | output | `minimig_openaars_top.v` SD block |
| `sd_m_d1` | output | same |
| `sd_m_d2` | same | same |
| `sd_m_cdet` | input | same |
| `dv_cecclk` | output | `adv7511_video.xdc:41` has the pin, nothing else |

That is five candidates for the five HIGH entries, but do not guess — get the
exact list from the tool.

## Get the exact list

```tcl
open_run impl_1
check_timing -verbose -override_defaults {no_input_delay no_output_delay} -file ct.rpt
```

The verbose form names every port in each bucket.

## Fix

For each HIGH port, make a decision and record it:

**Genuinely asynchronous or don't-care** (card-detect, a CEC reference clock):

```tcl
set_false_path -from [get_ports sd_m_cdet]
set_false_path -to   [get_ports dv_cecclk]
```

**Real synchronous interface** (the SD/MMC data and clock): constrain it
properly. `sd_m_clk` is a forwarded clock, so it deserves the same treatment as
`dr_clk`:

```tcl
create_generated_clock -name sd_clk_out -source [get_pins <driver>/C] -divide_by <N> [get_ports sd_m_clk]

set sd_data [get_ports {sd_m_cmd sd_m_d1 sd_m_d2 sd_m_d3}]
set_output_delay -clock sd_clk_out -max <tsu+trace> -add_delay $sd_data
set_output_delay -clock sd_clk_out -min <-th+trace> -add_delay $sd_data
set_input_delay  -clock sd_clk_out -max <tac+trace> -add_delay [get_ports sd_m_d0]
set_input_delay  -clock sd_clk_out -min <toh+trace> -add_delay [get_ports sd_m_d0]
```

The SD interface here runs slowly, so a false path is defensible. What is not
defensible is the current state: some pins of one interface false-pathed, others
left silent, with no comment saying which was intended.

## The wider point

`set_false_path` on an I/O port is a decision, and it should read like one.
Grouping them by interface with a one-line justification makes the next audit
cheap:

```tcl
# PS/2 is bit-banged at ~15 kHz and resynchronised in the core - async by design
set_false_path -from [get_ports ps2_*]
set_false_path -to   [get_ports ps2_*]
```

Most of the tree already does this. The SD card block and `dv_cecclk` are the
gaps.

## Verify

```tcl
check_timing -verbose -override_defaults {no_input_delay no_output_delay}
```

Both HIGH counts should read 0. MEDIUM counts staying non-zero is fine — that is
the false-path bucket, and it is intentional.
