# Stage E2 — results

Running record for [2026-09-15-e2-plan.md](2026-09-15-e2-plan.md), branch
`stage-e`. Each task appends one row from `tools/complexity_report.sh` and the
bench legs it ran.

## Complexity budget

"Code" counts exclude blank lines and full-line comments.

- **Posted-write paths** now counts both paths the spec §2 table names: the
  040's `POST_STORES`, and `cpu_cache_new`'s write buffer, which acknowledges a
  write before the SDRAM write is issued (`cpu_cache_new.v:318–327`). E4a's
  rows printed 1 and undercounted by that second path; the hardware did not
  change.
- **RAM width conversions** is `32-16-32` while `sdram_ctrl` still has the
  16-bit CPU port that the bus16 adapter feeds, and 0 once it takes the unit
  port.
- **Handshake signals** counts which of the spec §2 enable/handshake signals
  (`clkena_r`, `slower`, `bus_step`, `bus_fresh`, `cpu_phase_ok`, `datatg68_r`,
  `mem_ready`, `cpu_bus_settled`) are still in the wrapper. `datatg68_r` is
  counted although nothing reads it (see e4a-results.md, "`datatg68_r` never
  reached the AP68040"); E2 Task 1 deletes it.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes | RAM width conversions | handshake signals |
|---|---|---|---|---|---|---|---|---|---|---|---|
| d3_stable | 2138 | 1029 | 727 | 591 | 2 | 6 | 1 | 15 | dbg_phist dbg_snoop | 32-16-32 | 8 |
| stage-e 971119d (hardware = `stage_ap040_e4a`) | 1934 | 917 | 695 | 587 | 2 | 0 | 0 | 0 | dbg_phist dbg_rtg | 32-16-32 | 8 |

The `e4a` tag waits for Paul's hardware test; 971119d differs from the
`stage_ap040_e4a` build sources only in `sim/`, `tools/` and `findings/`.

## Tasks

### Task 0 — complexity report columns

Two columns added and the posted-write count corrected, as above. Both rows
taken with the new script: `d3_stable` from a scratch `git archive` of the three
files it reads.
