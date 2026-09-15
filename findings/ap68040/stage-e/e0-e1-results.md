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

### `sim/sdram_coherency` reference for E4a: first attempt incomplete

Both legs (`fast sg7 +nobg`, `fast sg7`) hit a 15-minute `timeout` (exit 124)
before printing a summary, so they are not a reference. The partial output shows
the two known defects on unmodified RTL: `C2P linebuf` (line buffer not
invalidated by snoops, `CL_SNOOP` off) and `P2C LATE` (posted-write lateness).
Rerunning both with `+rounds=50` to completion.

### Pending

- Gate delay 0 and 3 on the corrected bench (`e1fix0`, `e1fix3`). Pass
  criterion for E1: gate 0 lands mainly on 3/7/11/15 and fails; gate 3 lands
  on 2/6/10/14 (+13) and passes; both bench histograms match the hardware rows
  above bin for bin in where the peaks are.
- Address-guard cross-check (plan Task 2 Step 4).
- DMA overlap leg at gate 3 (plan Task 2 Step 5).
