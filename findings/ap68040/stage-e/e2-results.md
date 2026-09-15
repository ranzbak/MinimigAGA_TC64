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

### Task 2 — port sweep in `sim/sdram_coherency` (on today's 16-bit port)

New in `sdram_coherency_tb.v`: `cpu_write_bs` (a word cycle with explicit byte
selects), `cpu_access` (a B/W/L request at a byte address, split onto the
16-bit port exactly as `ap040_bus16_adapter.v` splits it), and `port_sweep`,
run by the CPU sequencer through a mailbox (the bench's one-owner-per-port
rule). For each size at each of the 16 offsets of one line, in a CPU-only
window (`W_SWP`, word address $010000): write a pattern unique to (size,
offset, byte), read it back with the same size, then read the eight
surrounding bytes one at a time against a golden copy. 3 × 16 × 9 = 432 checks.
`+sweep` runs it before the rounds; `+sweepmut` makes single-byte reads take
the wrong half of the word. Without either plusarg the bench is unchanged.

| leg | result |
|---|---|
| `./run.sh fast sg7 +nobg +sweep +rounds=1` | **port sweep: 432 checked, 0 failed** (the one other failure is the known "C2P line buffer primed", 1 of 1 round) |
| `./run.sh fast sg7 +nobg +sweepmut +rounds=1` | **416 of 432 failed**: the check has teeth. The 16 that pass are the read-backs of W and L at the eight even offsets, which are whole-word cycles with no single-byte read for the mutant to corrupt |
| `./run.sh fast sg7 +nobg +rounds=50` | 52 errors, 0 timeouts; every category = E4a reference (line buffer 50, longword 2) |
| `./run.sh fast sg7 +rounds=50` | 14 errors, 0 timeouts; every category = E4a reference (P2C 4 late 0 lost, longword 10, 3552 background reads 0 failed) |

The sweep is the test Task 3's unit port must pass unchanged (with
`cpu_access` switched to the unit split table).
