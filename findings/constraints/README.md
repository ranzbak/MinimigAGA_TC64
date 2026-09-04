# Timing constraints — findings and fix index

Scope: `fpga/openaars/aars_v5.0/xc7a100t/*.xdc` (13 files, 471 lines), with
supporting evidence from `project_1/project_1.runs/impl_1/` reports.

## The one-line summary

The design reports `WNS = 0.833 ns` and "All user specified timing constraints
are met", but that number covers only the paths still being checked. Two whole
external interfaces are unconstrained or mis-constrained, and one clock-domain
hold check is switched off across 2701 endpoints.

**Verified 2026-09-04 in Vivado** ([verification-vivado.md](verification-vivado.md)):
applying fixes 1 and 2 in memory exposes **49 hold violations** on the
`dll_28 → clk_114` crossing (worst −0.340 ns, on the VGA RGB registers feeding
the HDMI upsampler) and a **−1.295 ns setup violation** on the SDRAM read path.
Fix 9's port list was wrong and has been corrected. A new fix 11 came out of the
CDC report. A vendor-model simulation ([sdram-sim-results.md](sdram-sim-results.md))
then showed the SDRAM read burst arriving **one word late at the slow corner and
on time at the fast corner** — a temperature-dependent off-by-one, not a margin.

## Fix index

| # | File | Severity | What it is |
|---|---|---|---|
| 1 | [fix-01-sdram-delay-formulas.md](fix-01-sdram-delay-formulas.md) | **High** | `-min`/`-max` swapped; setup ~3.0 ns optimistic on a 8.815 ns period |
| 2 | [fix-02-dll28-hold-multicycle.md](fix-02-dll28-hold-multicycle.md) | **High** | `dll_28 → clk_114` hold check disabled — 79 ns of fake slack |
| 3 | [fix-03-adv7511-output-unconstrained.md](fix-03-adv7511-output-unconstrained.md) | **High** | Every HDMI output delay masked by a clock group |
| 4 | [fix-04-tg68k-blanket-multicycle.md](fix-04-tg68k-blanket-multicycle.md) | Medium | 46580 × 11933 exception lands on single-cycle paths |
| 5 | [fix-05-cdc-false-path.md](fix-05-cdc-false-path.md) | Medium | False path kills the two constraints below it |
| 6 | [fix-06-missing-hold-companion.md](fix-06-missing-hold-companion.md) | Medium | `clk_sd_114 → clk_114` setup relaxed, hold not |
| 7 | [fix-07-duplicate-clock-group.md](fix-07-duplicate-clock-group.md) | Low | Comma inside braces; duplicated `-name` |
| 8 | [fix-08-generated-clocks.md](fix-08-generated-clocks.md) | Low | Fixed dividers declared on gated, data-driven toggles |
| 9 | [fix-09-unconstrained-ports.md](fix-09-unconstrained-ports.md) | Low | 2 inputs + 3 outputs with no delay and no exception |
| 10 | [fix-10-comment-drift.md](fix-10-comment-drift.md) | Cosmetic | Comments that contradict the values beside them |
| 11 | [fix-11-reset-into-clk148.md](fix-11-reset-into-clk148.md) | **High** | 28 MHz reset drives 148 `clk_148` endpoints unsynchronised (found during verification) |
| 12 | [fix-12-sdram-read-capture-clock.md](fix-12-sdram-read-capture-clock.md) | **High** | SDRAM read data lands one word late at the slow corner; dedicated capture clock (RTL + MMCM + XDC) — **implemented, +3.76 ns, bench OK** |
| — | [implementation-status.md](implementation-status.md) | — | **Fixes 1,2,4,5,6,7,10,12 (and 3/8/9 partially) implemented and verified — results, what is still open** |
| — | [verification-vivado.md](verification-vivado.md) | — | Every finding re-timed in Vivado 2023.2 — before/after numbers |
| — | [sdram-read-path.md](sdram-read-path.md) | — | Why the read side cannot be phase-tuned into reliability, and the dedicated-capture-clock fix |
| — | [sdram-sim-results.md](sdram-sim-results.md) | — | **Vendor-model simulation: read data lands one word late at the slow corner, correct at the fast corner** |
| — | [reference-reports.md](reference-reports.md) | — | Clock summary, slack tables, methodology violations |
| — | [vivado-reports/](vivado-reports/) | — | Raw reports and the Tcl scripts that produced them |
| — | [impl-reports/](impl-reports/), [impl-reports-fix12/](impl-reports-fix12/) | — | Routed-design reports of the constraint-only build and of the fix-12 build |

## Recommended order

1. **Fix 1** — SDRAM delay formulas. A 3 ns error on an 8.815 ns period is the
   most likely cause of real hardware flakiness, and commit ae11724 ("fix SDRAM
   timing") means this is live territory.
   **Then fix 12** — with honest numbers the read path fails, and the
   simulation shows why: it needs its own capture clock, not another phase
   value.
2. **Fix 2** — the `dll_28 → clk_114` hold multicycle. A 79 ns hold slack across
   an edge-aligned MMCM crossing is a check that is not running.
3. **Fix 3** — un-mask and rebuild the ADV7511 output constraints, ideally with
   an ODDR on `dv_clk`.
4. **Fix 11** — synchronise the reset into `clk_148`; it is one register and it
   removes 148 of the 365 CDC Criticals.
5. **Fix 4** — narrow the TG68K blanket multicycles off `[all_registers]`.
6. Fixes 5–10 are hygiene; do them together once the above close.

Do 1–3 **before** touching the RTL fixes in [../adv7511/](../adv7511/) — an
unconstrained output interface can produce symptoms that look exactly like the
RTL bugs documented there.

## What Vivado already told you

From `minimig_openaars_top_timing_summary_routed.rpt`, Report Methodology:

| Rule | Count | Covered by |
|---|---|---|
| `TIMING-47` False path / clock group between synchronous clocks | 8 | [fix 3](fix-03-adv7511-output-unconstrained.md), [fix 5](fix-05-cdc-false-path.md), [fix 8](fix-08-generated-clocks.md) |
| `TIMING-46` Multicycle path with tied CE pins | 11 | [fix 4](fix-04-tg68k-blanket-multicycle.md) |
| `XDCB-1` Runtime intensive exceptions | 10 | [fix 4](fix-04-tg68k-blanket-multicycle.md) |
| `TIMING-29` Inconsistent pair of multicycle paths | 1 | [fix 2](fix-02-dll28-hold-multicycle.md) |
| `XDCH-1` Hold option missing in multicycle path | 1 | [fix 6](fix-06-missing-hold-companion.md) |
| `TIMING-9` Unknown CDC logic | 1 | [fix 5](fix-05-cdc-false-path.md) |
| `TIMING-10` Missing property on synchronizer | 1 | [fix 5](fix-05-cdc-false-path.md) |

None of these is new. They have been in the report all along.
