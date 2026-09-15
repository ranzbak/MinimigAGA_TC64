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

### Pending

- Gate delay 0 and 3 on the corrected bench (`e1fix0`, `e1fix3`). Pass
  criterion for E1: gate 0 lands mainly on 3/7/11/15 and fails; gate 3 lands
  on 2/6/10/14 (+13) and passes; both bench histograms match the hardware rows
  above bin for bin in where the peaks are.
- Address-guard cross-check (plan Task 2 Step 4).
- DMA overlap leg at gate 3 (plan Task 2 Step 5).
