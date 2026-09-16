# Stage E0 + E1 — results

Running record for [2026-09-15-e0-e1-plan.md](2026-09-15-e0-e1-plan.md), branch
`stage-e`. Newest entries at the bottom of each section.

## Task 1 — the bench runs the shipping gate (commit 7d51f59)

The REALSDRAM bench instantiated the wrapper with `cpu_phase_gate_dly` at its
VHDL default of 0: the gate as first built, not the shipping value. Now it
passes `CPU_PHASE_GATE_DLY` (default 3).

REALSDRAM leg at the default: program PASS, DMA window 3964 writes, 0 wrong,
`2 passed, 0 failed`.

## Task 2 — placement monitor

`sim/ddr3_cpu/placement_monitor.vh` bins every rising chip-RAM acknowledge by
SDRAM round phase, with the counter reset on `ena7WR_real`, the same way
`dbg_phist` does on hardware. A leg fails when more than 1 % of at least 1000
acknowledges land outside {2, 6, 10, 14, 13}.

### Gate delay 0 (must fail) — FAILED as required, but not on the hardware's phases

Run `e1dly0`: exit 1, program PASS, DMA 3960 writes 0 wrong, placement FAIL
(1448 of 1938 off the grid).

| ph16 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bench, gate 0, registered enables | 14 | **349** | 0 | 0 | 7 | **421** | 15 | 0 | 7 | **572** | 0 | 72 | 6 | **475** | 0 | 0 |
| hardware, r3 gate as built (d3phist_r3) | 21 | 3 | 0 | **585** | 5 | 15 | 2 | **439** | 13 | 6 | 0 | **495** | 3 | **510** | 4 | **355** |
| hardware, r3 gate delay 3 (clean) | 3 | 0 | **4371** | 29 | 8 | 0 | **4671** | 7 | 8 | 0 | **3840** | 25 | 6 | **5772** | **3891** | 9 |

The bench lands gate-0 acknowledges on **1/5/9/13**, where the hardware lands them
on **3/7/11/15**: the same four-step pattern, shifted by two. Consequences:
- The mutant failed only because three of its four bins are off the grid. Its
  fourth bin sits on 13, which the monitor counts as allowed, so this failure
  proves less than it appears to.
- At gate 3 the bench can be expected off the hardware grid too, so a gate-3
  verdict on this bench would not mean what the monitor claims.

### Cause found: a bench-only register on the SDRAM enables

- **Hardware** (`rtl/soc/minimig_virtual_top.v`): `tg68_ena28` and `tg68_ena7WR`
  are wires from `sdram_ctrl`'s outputs (`.enaWRreg (tg68_ena28)`) straight into
  the wrapper's `clkena_in` and `ena7WRreg`. `ramready` is `tg68_cpuena`, also a
  wire.
- **Bench before the fix** (`sim/ddr3_cpu/ddr3_cpu_tb.sv`): under REALSDRAM,
  `ena28 <= enaWR_real`, `ena7RDreg <= ena7RD_real` and
  `ena7WRreg <= ena7WR_real` sat in a clocked `always` block. Those registers
  were written to model `sdram_ctrl` when the bench did not compile it. The
  REALSDRAM path (ba323b9, 2026-09-13) fed the real controller's outputs —
  already `output reg` — through them, adding a flip-flop the hardware does not
  have. Since D3 the phase gate opens on `clkena_in`, so the extra clk moves
  where chip-RAM accesses start. The file-header note that the AP68040 leg
  "does not read clkena_in at all" went stale when the gate was added.
- One extra register predicts a one-step shift; the observed shift is two
  (equivalently minus two, since the pattern repeats every four). So the
  register is at least part of the difference, not yet proven to be all of it.
  The reruns on the corrected bench decide.

**Fix (uncommitted until the reruns report):** under REALSDRAM the wrapper's
`clkena_in`, `ena7RDreg` and `ena7WRreg` take `enaWR_real` / `ena7RD_real` /
`ena7WR_real` through wires (`w_ena28`, `w_ena7RDreg`, `w_ena7WRreg`). The
registered cadence path is unchanged when the bench models the controller.
`xvlog` analysis: 0 errors with and without REALSDRAM.

### Gate delay 3 on the registered feed (`e1dly3`)

Exit 1, program PASS, DMA 3964 writes 0 wrong, placement FAIL (1946 of 1972 off
the grid).

| ph16 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bench, gate 0, registered enables | 14 | **349** | 0 | 0 | 7 | **421** | 15 | 0 | 7 | **572** | 0 | 72 | 6 | **475** | 0 | 0 |
| bench, gate 3, registered enables | **427** | 0 | 0 | 13 | **467** | 49 | 0 | 8 | **452** | 0 | 0 | 78 | **441** | 26 | 0 | 11 |

- **The gate works in simulation as designed:** three more cycles of opening delay
  move every peak three phases later (1/5/9/13 → 0/4/8/12).
- **Prediction for the corrected bench, written before its runs report:** one
  register fewer moves every peak one phase EARLIER, putting gate 0 on 0/4/8/12
  and gate 3 on 3/7/11/15. The hardware has gate 0 on 3/7/11/15 and gate 3 on
  2/6/10/14. If that holds, the register was not the whole difference, and the
  bench would still sit one phase off the hardware.
- **Second candidate, in the monitor rather than the design:** `dbg_phist` bins
  `ramready AND sel_ram_d`. `sel_ram_d` is the registered address decode and
  stays high across consecutive chip-RAM accesses. The monitor bins
  `ramready_real AND !ramcs_n`, and `ramcs` drops between accesses. When the
  acknowledge stays high across a select gap, the two formulas bin on different
  cycles. Changed only after the corrected-bench runs, so each run varies one
  thing.

### Corrected bench (direct enables): prediction confirmed, still one phase off

Runs `e1fix0` and `e1fix3` after the fix. Both: program PASS, DMA 0 wrong
(3964 / 3958 writes), placement FAIL.

| ph16 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bench fixed, gate 0 | **427** | 0 | 0 | 13 | **467** | 49 | 0 | 8 | **452** | 0 | 0 | 78 | **441** | 26 | 0 | 11 |
| bench fixed, gate 3 | 0 | 0 | 11 | **563** | 30 | 0 | 7 | **457** | 0 | 0 | 7 | **422** | 0 | 23 | 16 | **417** |
| hardware, gate as built (0) | 21 | 3 | 0 | **585** | 5 | 15 | 2 | **439** | 13 | 6 | 0 | **495** | 3 | **510** | 4 | **355** |
| hardware, gate 3 (clean) | 3 | 0 | **4371** | 29 | 8 | 0 | **4671** | 7 | 8 | 0 | **3840** | 25 | 6 | **5772** | **3891** | 9 |

- The prediction written before these runs held exactly. Removing the register
  moved every peak one phase earlier: gate 0 onto 0/4/8/12, gate 3 onto
  3/7/11/15. The fixed bench's gate 0 is bin-for-bin the old bench's gate 3
  (427/467/452/441): one register fewer plus three more cycles of opening delay
  lands on the same phases.
- **The fixed bench still sits one phase LATER than the hardware**: its gate 3
  lands where the hardware's gate 0 lands. So the monitor fails the shipping
  gate the hardware runs clean with. E1 Task 2 is not done, and E4a stays
  blocked on it.
- Also unlike the hardware, the bench shows no gate-independent peak on 13 at
  gate 3 (23 against 5772).
- Next suspect is the measurement, not the design: the monitor bins
  `ramready_real AND !ramcs_n`, `dbg_phist` bins `ramready AND sel_ram_d`. Test:
  make the monitor use a registered address decode like `sel_ram_d`, rerun
  gate 3.

### Monitor made to bin exactly like `dbg_phist`

Two RTL facts decide how to mirror the hardware's formula in the bench:
- `cpu_cache_new` clears `cpu_cache_ack` only with a registered
  `if (!cpu_cs) cpu_cache_ack <= 0` (`cpu_cache_new.v:589`), so `ramready`
  stays high for one clk after the chip select falls.
- The wrapper's `ramaddr` (the bench's `tg68_cad`) follows `cpuaddr`
  combinationally with no select gating (`TG68K.vhd:860-866`), and bits 25:21
  are all zero only for $000000-$1FFFFF.

So the monitor now uses the same three registers as `dbg_phist`:

| register | hardware (`TG68K.vhd`) | monitor before | monitor now |
|---|---|---|---|
| select | `sel_ram_d <= sel_ram` | — | `pm_sel_d <= (tg68_cad[25:21] == 0)` |
| acknowledge | `ph_ack_r <= ramready AND sel_ram_d` | `ramready_real && !ramcs_n` | `ramready_real && pm_sel_d` |
| chip flag | `ph_chip_r <= sel_chipram` | `!ramcs_n && chip decode` | chip decode |

`xvlog` clean. Gate 3 (`e1pm3`) runs first: on 2/6/10/14 (+13) the remaining
phase difference was the measurement; still on 3/7/11/15 it is real, and the
work stops for a report.

### Result with the `dbg_phist`-equivalent monitor: the offset is not the measurement

Runs `e1pm3`, `e1pm0`. Both: program PASS, DMA 0 wrong, placement FAIL.

| ph16 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bench, `dbg_phist` formula, gate 3 (13163) | 603 | 702 | 734 | **1302** | 576 | 563 | 664 | **1285** | 830 | 718 | 624 | **1323** | 921 | 651 | 571 | **1096** |
| bench, `dbg_phist` formula, gate 0 (13161) | **1193** | 746 | 679 | 732 | **1211** | 699 | 620 | 657 | **1231** | 729 | 655 | 716 | **1229** | 796 | 644 | 624 |
| hardware, gate 3 (22640) | 3 | 0 | **4371** | 29 | 8 | 0 | **4671** | 7 | 8 | 0 | **3840** | 25 | 6 | **5772** | **3891** | 9 |

- The peaks did not move: gate 3 still peaks on 3/7/11/15, gate 0 on 0/4/8/12.
  **The bench's one-phase-late placement is real, not an artefact of binning.**
- Binned without the chip select, the bench shows about seven times as many
  acknowledge edges, spread over every phase (roughly 600–900 per bin). The
  hardware capture, with the same formula, has no such floor (~0.4 % off its
  peaks). So the bench's acknowledge activity differs from the board's in more
  than the offset, and simulation alone cannot say which detail is right.
- What does agree: moving the gate from 0 to 3 shifts the peaks by exactly
  three phases, on the bench and on the hardware alike.
- **Consequence:** as specified, the bench cannot check the absolute placement
  rule (2/6/10/14 at the shipping gate). E1 Task 2 stops here for Paul's decision.

### Decision (Paul, 2026-09-15): calibrate and move on

Chosen over "find the offset first" and "drop the absolute check".

- **Monitor:** back to the select-gated formula (`ramready_real && !ramcs_n`),
  whose peaks are sharp. The `dbg_phist` formula is recorded above as tried.
- **Grid:** acknowledges are judged against the hardware grid 2/6/10/14 (+13),
  shifted by `PLACEMENT_OFFSET` = 1 (bench phase = hardware phase + 1). Two
  measured anchors back that value: gate 3 bench 3/7/11/15 vs board 2/6/10/14,
  gate 0 bench 0/4/8/12 vs board 3/7/11/15.
- **Limit:** `PLACEMENT_STRAY_PPM` = 100000 (10 %). On the bench, 94 of 1953
  shipping-gate acknowledges (4.8 %) fall off the shifted grid, against 0.4 % on
  the board. The delay-0 mutant lands ~94 % off, so 10 % separates the two with
  a wide margin on both sides.
- **E4a proves each removal by identical histograms** before and after, which
  does not depend on the offset.
- **Open, and a hard precondition for E2:** explain why the bench lands one
  phase late. That needs a hardware capture of the same acknowledge timing,
  because E2 rewrites exactly the port whose timing differs.

### Calibrated monitor: shipping gate passes, gate-0 mutant fails

Runs `e1cal3`, `e1cal0`, with the select-gated formula, `PLACEMENT_OFFSET` = 1 and
a 10 % stray limit. Program PASS and DMA 0 wrong in both.

| gate | exit | acknowledges off the calibrated grid | verdict |
|---|---|---|---|
| 3 (shipping) | 0, `2 passed, 0 failed` | 78 of 1953 (4.0 %) | PASS |
| 0 (mutant) | 1 | 1862 of 1972 (94.4 %) | FAIL, as required |

Both histograms match `e1fix3` and `e1fix0` bin for bin, which confirms the
formula went back exactly. Committed as E1 Task 2.

### DMA overlap leg at the shipping gate (`e1ovl`): two failures, neither in the design

`REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=10`: exit 1. Program PASS, DMA window 3670
writes, 0 wrong.

| ph16 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bench, overlap, gate 3 (2602) | 0 | 0 | 70 | **454** | 18 | 0 | 47 | **464** | 0 | 0 | 40 | **696** | 0 | 167 | 102 | **544** |

- **P2C "1 stale" is a bench judging error (bench trap 4 again).** The failing
  read got `xxxx` from byte $8012 while the CPU's FIRST write to it (0009) was
  landing: "before 0000 / after 0009". The probe marks a word written if a
  value is seen before OR after the read, then judges that same read against
  the shadow's initial 0000. The word is never preloaded, so undefined data is
  correct. Fix: judge a read only if the word was written before the read
  began.
- **Placement: 342 of 2602 off the calibrated grid (13.1 %, limit 10 %).** The
  peaks are still on bench 3/7/11/15. Under chipset contention the scatter grows
  to 167 on bench 13 and 157 on bench 2/6/10 (one phase early). The board stays
  at 0.4 % under Way Too Rude, so this is the bench diverging further under
  load, not the design.

### Decision (Paul, 2026-09-15): the busy leg must match a saved reference exactly

Chosen over "loosen the limit to 20 %" and "explain the spread first".

- **Quiet leg** (`REALSDRAM=1 ./run.sh --ap040`): keeps the calibrated
  pass/fail placement check. The gate-0 mutant proves it can fail.
- **Busy leg** (`REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=10`): the placement
  histogram is printed but no longer fails the run. After the P2C judging fix,
  its exact numbers (placement bins, DMA writes and wrong, P2C reads, changes
  and stale) are saved as a reference. Every E4a step must reproduce them
  identically. The runs use fixed random seeds and have come out identical run
  to run (e1fix0 equals e1dly3 bin for bin), so exact comparison is meaningful.
- **Bench fixes pending** until the guard-check and regression chain ends,
  because every leg compiles `ddr3_cpu_tb.sv`: the P2C probe judges a read only
  if the word was written before the read began, and under `DMA_OVERLAP`
  placement is reported, not judged.

## Task 2 Step 4 — address-guard cross-check

Monitor without the chip address guard (`pm_chip = !ramcs_n`), gate 3: 1953
acknowledges, 78 off the grid, **identical** to the guarded run `e1cal3`. The guard
removes nothing in this bench and stays as a cross-check.

## Task 3 — regression legs (2026-09-15, after commit ea947e0)

| leg | exit | verdict |
|---|---|---|
| `--ap040` | 0 | 2 passed, 0 failed |
| `--mmu` | 0 | 2 passed, 0 failed |
| `--ap040 --chipbus` | 1 | **FAIL: the 68k program never wrote the mailbox (timeout); DDR3 backdoor 64 wrong** |
| `--lwmutant` | 0 | mutant failed as required (2158 32-bit-write protocol violations) |
| `--mmumutant` | 0 | mutant failed as required (stall watchdog) |
| `--fillmutant` | 0 | mutant failed as required (undecoded Z3 hole read, BYTE load read-back) |
| `--snoopmutant` | 0 | mutant failed as required (14679 of 22021 snoops never reached the core) |

### `--ap040 --chipbus` regression: hang with the shipping gate

- The run never reached program phase 1. The committed reference log reached
  phase 1 at 98.4 µs and finished at 941 µs; this one sat until the 2.5 ms
  timeout. A hang from the start, not a slow run.
- **Prime suspect: E1 Task 1 (7d51f59).** It passes `CPU_PHASE_GATE_DLY` (default
  3) to the wrapper in EVERY leg, not only REALSDRAM. Before it, the chipbus leg
  ran the VHDL default 0. Chipbus legs use the bench's own modelled enable
  cadence, so this may be a bench artefact, but it may also be real.
- **Hardware consequence to check:** the shipping image (gate delay 3) has not
  been booted with Turbo OFF on the board. Added to the D3 close-out test.
- Experiment running: the same leg with `CPU_PHASE_GATE_DLY=0` (`e1cb0`).
- The regression runs overwrote seven tracked reference logs in `sim/ddr3_cpu`.
  They were backed up to the session scratchpad and restored from HEAD, so the
  committed references are unchanged; the verdicts above are the record.

### Chipbus hang is NOT the gate; busy-leg reference saved

- **`--ap040 --chipbus` with `CPU_PHASE_GATE_DLY=0` hangs the same way** (`e1cb0`:
  mailbox timeout, never reaches program phase 1). The gate delay is not the
  cause, and today's testbench changes apply only under REALSDRAM/DMA_OVERLAP.
  The leg most likely broke earlier and was not rerun; on the board, Turbo-off
  boots worked on the gate-0 histogram builds. Being traced.
- **Busy-leg reference** (`e1ref`, patched testbench, shipping gate): exit 0,
  program PASS (phase 8 at 2.148 ms), DMA 3670 writes 0 wrong, **P2C 167 reads,
  0 stale** (the judging fix removed the false failure), placement 2602
  acknowledges with the same histogram as `e1ovl`, reported not judged.
  Saved as `sim/ddr3_cpu/ref/overlap_gate3.txt`.

### Tracing the chipbus hang

- The committed passing chipbus log was last written at f374e1b (09-11 00:04).
  The leg was not run again until 2026-09-15.
- Hang signature: the CPU is released at 64 µs, then no line fills, no adapter
  traffic, no bus errors, no SDRAM-port reads, and no program phase. It stops
  before the first instruction completes.
- On the board, Turbo-off boots worked on builds that already had the phase gate
  and the registered read data, so a bench interaction is the more likely cause.
- Suspects since f374e1b that can reach the chipset path: dcb0e1a (ratio-aware
  phase marker, changes when `clkena` fires), 4e05663 (the phase gate
  `cpu_phase_ok`), ba323b9 (read data registered with the grant `datatg68_r`),
  and the switch commits c08ef67 / 9cc855f / 7c72275 / 7d51f59 if a default
  changed behaviour. The AP68040 cache-guard bump and revert net to zero, and
  the bench commits of that period only touch REALSDRAM code.
- **Step 1 (running):** chipbus with `PREB1` wrapper copies that switch off the
  registered read data, the phase gate, or both.
- **Step 1 result:** all three hang the same way (mailbox timeout). Read data
  not registered (`cb_nodatareg`), phase gate off (`cb_nogate`), both off
  (`cb_both`). Neither ba323b9 nor 4e05663 is the cause.
- **Step 2:** a binary search over the 26 commits since f374e1b, each in its
  own worktree with its own bench (submodules unpacked from the local
  submodule repositories: lib/AP68040's x3-overlay commits exist only here, so
  `git submodule update` cannot fetch them). f374e1b passed with today's tools;
  0d4591b, c08ef67, 46f0b71 (d3_stable) and 4a0d2f6 passed; **ea947e0 is the
  first bad commit.**

### Chipbus hang: cause and fix — a testbench bug from E1 Task 2

- ea947e0 added the `w_ena28`/`w_ena7RDreg`/`w_ena7WRreg` wires (direct
  enables under REALSDRAM, the bench's cadence registers otherwise), but put
  the block **inside** the `` `ifdef REALSDRAM `` section that declares the
  real controller. Without REALSDRAM the `` `else `` branch was never compiled,
  so the wrapper's `clkena_in`, `ena7RDreg` and `ena7WRreg` ports connected to
  undeclared names, which elaborate (with `-relax`) as undriven implicit nets.
  The enables sat at Z, the CPU never advanced, and the leg timed out.
- Not the RTL, not the gate, not the registered read data: every leg without
  REALSDRAM was broken, and `--chipbus` was the only one in the regression.
- Fix: the wire block moved below the REALSDRAM section's `` `endif ``. The
  REALSDRAM code is textually unchanged.
- Verification (`e1nest`, `e1nestrs`):
  - `--ap040 --chipbus`: 2 passed; phases 1–8 at exactly the timestamps of the
    last good log (phase 1 98.397 µs … phase 8 937.021 µs).
  - `REALSDRAM=1 --ap040`: 2 passed, DMA 3958 writes 0 wrong, placement **1953
    acknowledges, 78 off** — identical to the `e1cal3` reference.
- On the board, Turbo-off boot of the shipping image is still a close-out
  check (Task 5), but nothing in this trace points at it.

### Task 3 regression, rerun on the fixed bench (`fixreg`, commit 8167cde)

Every leg without REALSDRAM ran with undriven enables from ea947e0 until the
fix, so the morning's table above is void as a baseline — its numbers differ
from these (e.g. `--lwmutant` 2158 violations then, 2021 now). This table is
the E4a starting point.

| leg | exit | verdict |
|---|---|---|
| `--ap040` | 0 | 2 passed, 0 failed (phase 8 at 1.677 ms) |
| `--mmu` | 0 | 2 passed, 0 failed (phase 8 at 707.9 µs) |
| `--ap040 --chipbus` (`e1nest`) | 0 | 2 passed, 0 failed (phase 8 at 937.0 µs) |
| `REALSDRAM=1 --ap040` (`e1nestrs`) | 0 | 2 passed; placement 1953 / 78 off, = `e1cal3` |
| `--lwmutant` | 0 | mutant failed as required (2021 32-bit-write protocol violations) |
| `--mmumutant` | 0 | mutant failed as required (stall watchdog) |
| `--fillmutant` | 0 | mutant failed as required (undecoded Z3 hole read, BYTE load read-back) |
| `--snoopmutant` | 0 | mutant failed as required (14890 of 22340 snoops never reached the core) |

### `sim/sdram_coherency` reference for E4a: first attempt incomplete

Both legs (`fast sg7 +nobg`, `fast sg7`) hit a 15-minute `timeout` (exit 124)
before printing a summary, so they are not a reference. The partial output shows
the two known defects on unmodified RTL: `C2P linebuf` (line buffer not
invalidated by snoops, `CL_SNOOP` off) and `P2C LATE` (posted-write lateness).
Rerunning both with `+rounds=50` to completion.

### Pending

- Regression green again with the chipbus fix, so E4a can start (Paul,
  2026-09-15: "Do E4a first"). E1 Task 4 (time-boxed reproduction) follows E4a.
- [Paul] Task 5: board test of `build/stage_ap040_d3stable_gd3`, including a
  Turbo-off boot. [Paul] Task 8: RTG capture.
- Done above: gate 0/3 on the corrected bench (calibrated), address-guard
  cross-check, DMA overlap leg (reference, not gate).

## Task 4 Step 1 — first attempt void: concurrent xsim legs corrupt each other (2026-09-16)

The plan's Step 1 pair (`DMA_OVERLAP=1 P7LOOPS=40 P2CBLOCK=32`, gate 3 versus
gate 0) was run overnight alongside other simulations. Both legs failed
identically at program phase 2 — `FAIL code 2 pattern read-back, BYTE load`,
DDR3 array wrong in 665 / 690 places, `X`/`Z` in the backdoor dump — with chip
RAM clean (`DMA window: 0 wrong`). Identical failures at both gates is not a
reproduction, so the settings were isolated:

| leg | conditions | result |
|---|---|---|
| `P7LOOPS=40`, no `P2CBLOCK` | with other sims running | same phase-2 DDR3 failure |
| `P7LOOPS=10 P2CBLOCK=32` | with other sims running | same |
| `P7LOOPS=40`, **no chipset agent at all** | with other sims running | same |
| `P7LOOPS=11` (one byte from the reference) | with other sims running | same |
| **the saved reference command itself** | with other sims running | **same** |
| **the saved reference command** | **alone, twice** | **PASS, bit-identical to `ref/overlap_gate3.txt`** |

The passing and failing runs use the same `prog.bin` (md5 equal), the same
xelab command line, and a tree with no tracked change; phase 1 and 2 timestamps
match and the runs diverge afterwards. So the inputs are identical and the
simulator diverged — `xelab` defaults to `-mt auto`, and thread partitioning
depends on what else the machine is doing. **Every `sim/ddr3_cpu` leg run
concurrently with another is void**, which is what `run.sh`'s header has always
said. Step 1 is being re-run serially; the E2 Task 1 legs that ran under load
are re-running too.

## Stage E step 2 — the bench's one-phase offset is the read/write mix (2026-09-16)

The calibration above ("bench one phase later than the board, cause unknown")
is explained. The placement monitor now also bins each chip-RAM acknowledge by
access type (commit 2c25042; report lines `  split ph NN : read N  write N`).
Bins are bench phases, counted the same way as before.

| run | gate | reads land on | writes land on |
|---|---|---|---|
| `s2`, quiet (`REALSDRAM=1 --ap040`) | 3 | 3/7/11/15 (563/457/422/417), +4 (30) | **2/6/10/14** (11/7/7/16), **+13** (23) |
| `s2ovl`, busy leg | 3 | 3/7/11/15 (454/464/696/544), +4 (18) | **2/6/10/14** (70/47/40/102), **+13** (167) |
| `s2g`, quiet (`--gatemutant`) | 0 | 0/4/8/12 (427/467/452/441), +5 (49), +11 (72) | **3/7/11/15** (13/8/6/11), **+13** (26) |
| `e1rep0`, overlap `P7LOOPS=40 P2CBLOCK=32` | 0 | 0/4/8/12 (321/321/283/291), +5 (13), +11 (19) | **3/7/11/15** (4/2/1/7), **+13** (8) |
| board `dbg_phist`, Way Too Rude | 3 | — | 2/6/10/14, +13 (all accesses) |
| board `dbg_phist`, Way Too Rude | 0 | — | 3/7/11/15, +13 (all accesses) |

- **Bench writes land exactly where the board's acknowledges land, at both
  gates, phase 13 included.** Reads land one phase after writes.
- The combined bench histogram was dominated by reads (the pattern program
  reads chip RAM far more than it writes it), so its peaks sat one phase after
  the board's. Way Too Rude on the board is write-heavy, so its histogram shows
  the write grid. Nothing is wrong in either; the bench models placement
  correctly. `PLACEMENT_OFFSET = 1` was a calibration to the read mix.
- **For the rule:** the D3 hardware histograms are dominated by writes, so
  what they showed is consistent with "a chip-RAM WRITE acknowledged on
  3/7/11/15 corrupts". Reads on 3/7/11/15 are the normal placement with the
  shipping gate.
- E2 judges reads and writes separately (plan D7) and drops the offset. A
  hardware confirmation remains possible but is no longer a precondition: a
  `dbg_phist` split by access type, or a capture under a read-heavy workload.
- Aside from the same work: the D3 read-data capture (ba323b9) never reached
  the AP68040 (e4a-results.md), so the read-data crossing is a live candidate
  for WHY that placement corrupts.
