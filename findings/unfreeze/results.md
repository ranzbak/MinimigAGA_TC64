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
| `--mmu` | pass (uf1b, uf3b, uf3b2, ufx6 identical) | pass (uf4b: its FC-3 hits were the monitor's false positive; with the latch ufx1) | 0 |
| `--mmu`, caches off (MMU_CACR=0) | -- | pass (ufxr without the latch, ufx2 with it; FC-1b quiet) | 0 |
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
| `walk` (walker ack/berr without `AND bce_q`) | `--mmu` | survives (uf4mw2, ufx8) and is equivalent: the walker's answer is fresh when the MMU takes it, and the MMU ignores it in the request-low clock after (final review). |
| `--ackmutant` (existing: x_ack_r held) | `--ap040`, frozen | fails as before, and FC-2 now names it (7 double takes). |

## Final review (fresh reviewer) and what changed

**Walker: my "bug" was a monitor false positive (corrected).** The 30 FC-3 hits on `--mmu` (uf4b) came from
`ap040_mmu` deliberately dropping `walker_req` for one clock after each take and ignoring `walker_ack` there
(`walker_req = w_active && w_issued`, `walk_ack` needs `w_issued`). The pre-fix run completed every phase with
timestamps identical to the "fixed" one. The hang I described needs `clkena` low right after a walker answer,
which cannot happen, since `m_req` is idle for the whole walk. `wk_taken` was inert and has been removed. FC-3
now judges only `m_ack`. The `walk` mutant (walker answer without `bce_q`) survives and is equivalent.

**MMU pass latch (reviewer Critical 1).** `ap040_mmu` forwards a request combinationally (`m_req = pass_ok`,
`m_addr = pa_out`) and re-evaluates both every clock from TC, the TTRs and the ATC. A free core can commit a
MOVEC to TC or a TTR while its own access is in flight. Fix, in the submodule (lib/AP68040-pipelined 2c904dc,
branch `free-core-pass-latch`): `pass_hold` keeps the forwarded decision and physical address from admission
until `m_ack`, and blocks a fault or walk start meanwhile.
- Not reproduced at the bus: a new check, FC-1b (x_* unchanged from admission to the answering edge), stays
  quiet on every leg with and without the latch, including `--mmu` with the caches off (ufxr) and on (ufxr2).
- The latch does change one internal step: the free `--mmu` leg's phase 3 moves by 176 ns. That is the one
  place it kept a request, still inside the cache, that the MMU would have re-decided. Both versions pass.
- Neutral elsewhere: the SysInfo loop is 6,790 (off) / 5,845 (on) clocks, as before; the frozen legs and the
  other free legs have identical timestamps.

Also from the review: `FREECORE=0` in run.sh now means off, and the stale `sel_undecoded_d` wording in cpu.xdc
is fixed. Two points are documented, not changed:
- the core's stall watchdog (2^21 clocks, about 55 ms) is live now that the core is never frozen;
- a MOVEC VBR with a read in flight could mis-decode the NMI vector window for one clock.

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

## Board (Paul)

Loaded 2026-09-26 17:10 over JTAG: `build/stage_unfreeze_on`. Checklist: `hw-checklist.md`.

| | `stage_chip32_on` (frozen) | `stage_unfreeze_on` (free) | change |
|---|---|---|---|
| SysInfo SPEED (vs A4000/040 25 MHz) | 0.83x | **1.00x** | **+20 %** |
| SysInfo Dhrystones | 15,592 | **18,223** | **+16.9 %** |

The board gained more than the sim loop predicted (about 0.95x). Real code carries more store traffic than
SysInfo's register-heavy loop, and every store used to freeze the core. The remaining checklist items
(cputest, OSD reset under load, demos, RTG, idle) are pending.
