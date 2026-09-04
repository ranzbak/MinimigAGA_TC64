# SDRAM read path — simulation results

> **Caveat added 2026-09-04:** the "fast" corner used for the runs below was an
> estimate (clock-forwarding path only 1.5 ns faster than slow). Vivado's routed
> min/max delays show a 6 ns spread. The conclusion (one word late at the slow corner,
> needs its own capture clock) stands; the *phase* derived here (+3.5 ns) does not — see
> [fix-12](fix-12-sdram-read-capture-clock.md) "Implemented". The bench now takes its
> corners from Vivado's report.

Testbench: [sim/sdram_timing/](../../sim/sdram_timing/) (`sdram_timing_tb.v`,
`run.sh`). Logs: [sim-logs/](sim-logs/). Companion to
[sdram-read-path.md](sdram-read-path.md), which derived the same conclusion
from the static report; this run confirms it dynamically with the vendor model.

## Setup

* `rtl/sdram/sdram_ctrl.v` unmodified, `clk7_en` at 1/16, CL3 BL8 mode register
  loaded by the controller's own init sequence.
* Alliance `AS4C16M16SA` model, `-7` grade (tAC3 = 5.4 ns, tOH = 2.5 ns) and
  `-6` grade (tAC3 = 5.0 ns).
* FPGA/board delays as transport delays, from the Vivado routed report
  (slow) and an estimated fast corner — table in
  [sim/sdram_timing/README.md](../../sim/sdram_timing/README.md).
* Stimulus: eight chipset writes then one chipset read burst at an 8-aligned
  column. The controller's own `chipRD` / `chip48` outputs are compared with the
  written pattern `A000, A111 … A777`.

## Result

```
                         chipRD   chip48                 word 0 lands on edge
slow, sg7 (worst)        ZZZZ     A000 A111 A222         ph9   <- one word late
slow, sg6                ZZZZ     A000 A111 A222         ph9   <- one word late
fast, sg7                A000     A111 A222 A333         ph8   <- correct
fast, sg6                A000     A111 A222 A333         ph8   <- correct
expected                 A000     A111 A222 A333         ph8   (RTL comment table: "ph9 read0")
```

At the slow corner **every chipset read returns the burst shifted by one
word**: `chipRD` samples an undriven bus and `chip48` receives words 0–2 instead
of 1–3. At the fast corner the same RTL is correct. Nothing in the controller
changes between the two runs — only the physical delays.

## Why: the sample edge straddles the data transition

Per-edge detail from the logs, showing the value at `sdata_reg/D` and its
setup / hold margin at the as-built sample point (`posedge clk_114`):

```
slow sg7                              fast sg7
 ph   D value  setup   hold            ph   D value  setup   hold
  8   zzzz    391.8    1.12  <- word0   8   a000     1.49    7.33  <- word0
  9   a000      7.70   1.12  arrives    9   a111     1.49    7.33
 10   a111      7.70   1.12  1.12 ns   10   a222     1.49    7.33
 ...                         AFTER     ...
                             the edge
```

Slow corner: word 0 arrives **1.12 ns after** the ph8 edge (0.72 ns with the
faster part), so that edge captures Hi-Z and the word is taken one edge later.
Fast corner: word 0 arrives **1.49 ns before** the ph8 edge and is captured
correctly, but the *next* word arrives only 1.5 ns after that — 1.49 ns of
setup on an interface that Vivado reported at −1.3 ns for the slow case.

The two corners sit 2.6 ns apart around the same edge. Real silicon at real
temperature lives somewhere between them: near the crossover a board will see
mixed words and metastable samples; either side of it, a clean but
*temperature-dependent* off-by-one. This is the mechanism behind "SDRAM works
cold, flaky warm", and behind the phase-tuning history in `amiga_clk_xilinx.v`
(−146.25° → −144° → −121.5°): each value moved the crossover, none removed it.

Vivado's −1.295 ns ([fix 1](fix-01-sdram-delay-formulas.md)) is the same 1.1 ns
plus flop setup. The static analysis and the dynamic simulation agree.

## The write side is fine

The model's `$setuphold` checks on `Cs_n`/`Ras_n`/`Cas_n`/`We_n`/`Addr`/`Dq`
raised no violation at either corner, and the written data was received
correctly (`WRITE : … Data = 40960` = `A000` etc. in every log). This matches
the +0.672 ns Vivado gives the output side. The phase is right for writes; it
is only the read capture that has no independent adjustment.

## Proposed fix, measured

Same logs, the two alternative sample points evaluated on the identical
waveform:

| Sample point | Corner | word 0 edge | worst setup | worst hold | verdict |
|---|---|---|---|---|---|
| as built, `posedge clk_114` | slow sg7 | **ph9** | 7.70 | 1.12 | wrong word |
| | fast sg7 | ph8 | 1.49 | 4.42 (word 7) | correct, thin |
| **+3.5 ns capture clock** | slow sg7 | ph8 | 2.38 | 3.54 (word 7) | ok |
| | slow sg6 | ph8 | 2.78 | 3.54 | ok |
| | fast sg7 | ph8 | 4.99 | 0.93 (word 7) | ok |
| | fast sg6 | ph8 | 5.39 | 0.93 | ok |
| negedge (+4.4 ns) | slow sg7 | ph8 | 3.29 | 2.63 | ok |
| | fast sg7 | ph8 | 5.90 | **0.02** (word 7) | **HD!** |

The dedicated +3.5 ns capture clock puts word 0 on **the same edge at every
corner and both speed grades**, with ≥ 2.4 ns setup and ≥ 0.9 ns hold. The
limiting case is the last word of the burst at the fast corner, where the SDRAM
releases the bus tHZ after the auto-precharge edge; +3.2 ns would balance that
slightly better (≈ 2.1 ns setup slow / 1.2 ns hold fast). Either is a derived,
defensible number.

The negedge shortcut works at the slow corner and fails on word 7 at the fast
corner — fine as a one-build diagnostic on a board that currently fails warm,
not as the fix.

## What this means for the constraint

Once the capture clock exists, the read constraint becomes single-cycle and
honest — the second half of
[sdram-read-path.md § Fix](sdram-read-path.md#fix-a-dedicated-read-capture-clock).
The `-setup 2` multicycle was fitted to a report, not to the design; the
simulation shows it describes the *slow-corner* behaviour (data one edge late)
while the RTL's phase table describes the *fast-corner* behaviour (data on
time). Neither is wrong; the hardware simply does both.

## Reproduce

```bash
cd sim/sdram_timing
./run.sh slow sg7 && ./run.sh fast sg7
```

About one second each.
