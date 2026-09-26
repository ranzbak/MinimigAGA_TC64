# Free-running pipelined core: results

Plan: `findings/unfreeze/plan.md`. Branch `unfreeze` (off 5.0-040-pipelined). Sim: `sim/ddr3_cpu`, one leg
at a time, real `TG68K.vhd` + `sdram_ctrl` + DDR3 island. Written 2026-09-26.

## The number (SysInfo 4.4 SPEED loop, SoC bench, IE+DE, MMU off, 3 passes = 2,541 instructions)

| bucket | off (`si_uf3_off`) | on (`si_uf4_on`) | change |
|---|---:|---:|---:|
| **total clocks** | **6,790** | **5,845** | **-945 (-13.9 %)** |
| **CPI** | **2.672** | **2.300** | **1.16x** |
| frozen by a store (enable low, `m_*` busy) | 935 | 0 | -935 |
| frozen, other | 24 | 0 | -24 |
| retire | 2,541 | 2,541 | 0 |
| store-hold | 495 | 510 | +15 |
| EAF->EX transit | 1,270 | 1,270 | 0 |
| data-read wait | 619 | 619 | 0 |
| EA-fetch other | 405 | 404 | -1 |
| EA-calc/ID | 165 | 164 | -1 |
| queue-only | 206 | 205 | -1 |
| EX busy | 120 | 120 | 0 |

`off` is identical to the pre-change baseline `run_perf_si_ddr3_cur_9efe`, clock for clock.

**Where the frozen clocks went:** the free core turned 944 of the 959 frozen clocks into progress; store-hold
rose by only 15. What is left for the store buffer (upstream survey P2) is the store-hold (510) plus the
slow-path read wait (619, reads that miss the M14 fast path while a store is in flight): about 1,130 clocks,
19 % of the new total. The 68040 itself spends about 0 on both.

## Legs

| leg | off (generic 0) | on (FREECORE=1) | FC-4 (on) |
|---|---|---|---:|
| `--ap040` | pass (uf1a, uf3a identical) | pass (uf4a) | 0 |
| `--mmu` | pass (uf1b, uf3b, uf3b2 identical) | pass after the walker fix (uf4b2); FAILED before it (uf4b: FC-3 x30) | 0 |
| `--snoop` | pass (uf1c) | pass (uf4c) | 0 |
| `--ap040 --chipbus` | pass (uf1d) | pass (uf4d) | 0 |
| `--fcprog` | pass (uf2a, uf3c identical) | pass (uf4e) | 0 |
| `--fcprog --chipbus` | pass (uf2c, uf3d identical) | pass (uf4f) | 0 |
| `--snoop` DMA_OVERLAP=1 | -- | pass (uf4g) | 0 |
| `--ap040` CPU_RATIO=4 | -- | pass (uf4h) | 0 |

"identical" means every `program phase` timestamp equals the pre-change leg's, i.e. the generic's off state is
today's design. Legs uf4a/c/d/e/f/g/h ran before the walker fix. That fix changes only the walker handshake,
which only the `--mmu` leg exercises (the others run with translation off), and `--mmu` was re-run on the
fixed RTL.

## Mutants (`FREECORE=1 FCMUTANT=...`)

| mutant | leg | result |
|---|---|---|
| `ack` (adapter ack not qualified by `bce_q`) | `--fcprog --chipbus` | **survives: unobservable here.** FC-4 = 0 on every free leg, so a stale adapter level never met a waiting core at ratio 3: the adapter clears it on the next `clkena` edge, before the core's next request can be answered. The qualification stays as the guarantee. |
| `data` (read mux on the unqualified ack) | `--fcprog --chipbus` | **survives: unobservable here**, same evidence (FC-4 = 0). Kept. |
| `walk` (walker ack/berr without `AND NOT wk_taken`) | `--mmu` | **fails as required** (uf4mw3: FC-3 x30). |
| `walk`, first form (without `AND bce_q`) | `--mmu` | survives (uf4mw2), and is equivalent: before the take the level is fresh, and after it `wk_taken` masks it. The mutant was repointed at `wk_taken`. |
| `--ackmutant` (existing: x_ack_r held) | `--ap040`, frozen | fails as before, and FC-2 now names it (7 double takes). |

## The bug the free core exposed (fixed)

`--mmu` on the free core raised FC-3 30 times in phases 2-3, the cold-page U/M write-backs. A
discriminating FC-3 (uf4bd) showed it was the **walker's** answer, not the adapter's.

`WK_DONE` ends the walker handshake only when it *sees* `walker_req` low on a `clkena` edge, and it holds
`wk_ack` until then. The free MMU takes the answer one `clk_cpu` edge after it appears and drops its request.
Its one request-low cycle before the next descriptor can fall on an edge where `clkena` is low. The walker
then never sees it and stays in `WK_DONE`, and the MMU takes the old `wk_ack`/`wk_data` as the answer to the
next descriptor.

Fix (free mode only): `wk_taken` in `TG68K.vhd` records that the core took the answer, masks
`pc_wk_ack`/`pc_wk_berr` from then on, and lets `WK_DONE` end on it.

## Routed build (MMU + FPU, no ILA)

| | `stage_chip32_on` (= off, frozen) | `stage_unfreeze_on` (free) |
|---|---|---|
| clk_38 WNS | +0.648 | **+0.905** |
| clk_114 WNS | +0.765 | +0.560 |
| clk_114 -> clk_38 | +0.178 (11,994 endpoints) | **+0.490 (2,374 endpoints)** |
| failing endpoints | the 16 known SDRAM | the 16 known SDRAM (-0.657) |
| Slice LUTs | 46,041 | **45,519 (-522)** |
| md5 | 2d4bfb4f... | 079c8545f7b858f597da16d414fd68e8 |

The constant enable removes the core's clock-enable net (the clk_114 -> clk_38 endpoint count drops by about
9,600) and the logic behind it. No separate `stage_unfreeze_off` was built. The off state is proven
clock-identical to today in sim, so `stage_chip32_on` is the A/B baseline (ledger ruling).

## Board (Paul): pending

Loaded 2026-09-26 17:10 over JTAG: `build/stage_unfreeze_on`. Checklist: `hw-checklist.md`.
