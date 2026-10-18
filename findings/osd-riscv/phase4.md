# OSD host CPU migration, Phase 4 findings

## Measurements

### Task 1: failure edge of the real `userio_osd` reply (E_osd)

Bench `sim/spi_cdc/tb_spi_cdc.v` (xsim 2023.2, RTL of the tree at the time of the run, `git status rtl` clean), `osd` test only.
Reference first: `RUNTAG=p4t1ref bash sim/spi_cdc/run.sh` gave `=== PASS` in all seven (SCKDLY, C28DLY) pairs of the default grid (wall 2 min 24 s; the osd failures it prints are below OSD_MIN_GAP=40 and not counted).
Sweep: `RUNTAG=p4t1 XARGS="+SWEEP=1 +TESTS=8 +OSD_MIN_GAP=0 +REPS=10" bash sim/spi_cdc/run.sh` (wall 48 s, seed 1). Every even gap 2..80, 10 repetitions each, every failure counted. Each pair ends `=== FAIL` as expected with OSD_MIN_GAP=0.
`+GAP` adds a random 0..3 `clk_114` cycles per access (`jitter = $urandom % 4`), so the gap value in the table is the minimum; the real gap is gap..gap+3 and the edge is a band.

Failures out of 10 by gap (`clk_114` cycles; 2..22 fail 10/10 in all pairs, 34..80 fail 0/10 in all pairs):

| SCKDLY / C28DLY (ns) | 24 | 26 | 28 | 30 | 32 | 34 | largest failing gap | smallest gap, all larger pass |
|---|---|---|---|---|---|---|---|---|
| 0.5 / 0.2 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 0.2 / 0.5 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 1.5 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 4.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 0.3 / 4.0 | 9 | 9 | 7 | 0 | 0 | 0 | 28 | 30 |
| 8.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 9.5 / 0.3 | 9 | 9 | 8 | 7 | 3 | 0 | 32 | 34 |

**E_osd = 34** (smallest `+GAP` at which `osd` passes 10/10 in every pair, and at every larger gap up to 80). With the 0..3 jitter that is an effective gap of 34..37 cycles; in the pair 0.3 / 4.0 alone the edge is 30.
**Band:** the transition is gradual, not a cliff: failures are 10/10 up to gap 22, 7..10/10 at 24..28, and fall to 0..7/10 at 30 and 0..3/10 at 32. Treat gaps below 34 as unsafe, and 34..37 as the first fully passing band (no failure in 10 reps x 7 pairs at any gap >= 34, so the margin to the firmware's 40 is 3..6 cycles plus jitter).
Consistent with commit 1e135e7 (stale replies below ~32): the largest failing gap is 32, no failure at any gap >= 34 and none at >= 40, so the 40-cycle reply gap of the RV firmware measured in L2 (Phase 3) sits 6 cycles above E_osd. One seed only; a lower tail below 34 at other seeds is not excluded (default grid, REPS=3, saw 1/3 failures at gap 32 in three pairs, same as here).

## Shared defects

(none yet)
