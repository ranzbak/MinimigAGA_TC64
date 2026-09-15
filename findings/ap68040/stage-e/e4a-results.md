# Stage E4a — results

Running record for [2026-09-15-e4a-plan.md](2026-09-15-e4a-plan.md), branch
`stage-e`. Each task appends one row from `tools/complexity_report.sh` and the
bench legs it ran.

## Complexity budget

"Code" counts exclude blank lines and full-line comments. "Posted-write paths"
is the live count (the 040's `POST_STORES`), plus the controller's tied-off
`cpu_wr_sync` option while it still exists.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| d3_stable | 2138 | 1029 | 727 | 591 | 1+wsync-option | 6 | 1 | 15 | dbg_phist dbg_snoop |
| stage-e e6b1b90 (baseline) | 2142 | 1031 | 727 | 591 | 1+wsync-option | 6 | 1 | 15 | dbg_phist dbg_rtg dbg_snoop |

The +4 wrapper lines between `d3_stable` and the baseline are the E0 `dbg_rtg`
probe (commit 4a0d2f6).

## `sim/sdram_coherency` reference (before any removal)

Taken at commit 85cac1b with `./run.sh fast sg7 +nobg +rounds=50` and
`./run.sh fast sg7 +rounds=50`. Both runs print `wrsync 0, cl_snoop 0`, the
shipping settings. E4a Tasks 2 (`cpu_wr_sync`) and 3 (`CL_SNOOP`) must
reproduce these counts exactly. Neither option is enabled here, so removing
them must not move a single number.

| check | `+nobg` | default (background load) |
|---|---|---|
| C2P (chipset write → CPU read) | 50 checked, 0 failed | 50 checked, 0 failed |
| P2C (CPU write → chipset read) | 50 checked, 0 failed | 50 checked, 4 failed (4 late, 0 lost) |
| C2P line buffer primed | 50 checked, 50 failed | 50 checked, 0 failed |
| C2P two-way cache primed | 50 checked, 0 failed | 50 checked, 0 failed |
| P2C longword write | 100 checked, 2 failed | 100 checked, 10 failed |
| cache-inhibited (Kickstart) read | 50 checked, 0 failed | 50 checked, 0 failed |
| read across a `cacheline_clr` pulse | 50 checked, 0 failed | 50 checked, 0 failed |
| background CPU reads | 0 | 3552 checked, 0 failed |
| **total** | **52 errors, 0 timeouts** | **14 errors, 0 timeouts** |

The failures are the two defects this bench found on unmodified RTL: the line
buffer that snoops never invalidate, and CPU writes that land late. They are
the reference, not a regression. Without `+rounds=50` the default 15-minute
`timeout` cut both legs off before their summary.

## Tasks

(Task 1 onwards: legs run, results, and the row after the removal.)
