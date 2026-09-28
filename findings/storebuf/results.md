# Store buffer, stages 0-2: results

Plan: `findings/storebuf/plan.md`. Paul, 2026-09-28: "Do 0-2". That accepts the plan's three decisions:
- posting only in the RAM window, with MMU-on stores synchronous;
- a late bus error on a posted store halts the core visibly;
- stop after stage 2 for a board A/B.

Core branch `store-buffer` (lib/AP68040-pipelined), off main 56eb8e7:

| commit | what |
|---|---|
| 07515b4 | stages 0-1: `STORE_BUF`, the mixed BCU, the order checker, the tests |
| 1a62ab5 | stage 2: the fast path answers past non-overlapping posted stores; the cache invalidate gate |
| f87241a | fix: no fetch while WB holds a store it posts (the SMC refetch); checker: a faulted split store |

## What is built

The switch is `STORE_BUF`, on the core and on the wrapper (`AP040_STORE_BUF`):

| value | behaviour |
|---|---|
| 0 | synchronous stores only (default) |
| 1 | posting |
| 2 | the same hardware never posting |

It reaches the SoC through the TG68K generic `ap040_store_buf`, the top-level `AP040_STORE_BUF` parameter and `STORE_BUF=` for `build_ap040.tcl`.

**The post decision.** A store is posted if EX's registered verdict says:
- the address is in the RAM window: chip RAM or Z2/Z3 fast RAM, the same as `da_win`;
- it is not a locked RMW's write;
- it is not MOVES.

WB then also requires, from registers, that TC.E is 0 and that no DTTx has E and W set. Every other store stays synchronous, exactly as before. A synchronous store goes out only once the FIFO is empty.

**The FIFO.** It is the BCU's 4 entries.
- Slow reads, fetches, serialising instructions, interrupts and trace all wait for it: these were already wired through `sb_busy`.
- A fetch also waits while WB holds a store it is about to post. This was found by the suite: the SMC refetch.
- A fast read (the M14 data path) waits only for a posted store that overlaps it. The compare uses `addr[11:2]`, registered in the issue clock.

**Late bus error.** A bus error on a posted store is fatal: EA-fetch goes to `P_HALT` (`dbg_halted`, the debug flag).

**The cache.** `dfp_thit` is now gated on a pending invalidate (`store_inv_lost`, `winv_pend`, `C_WINV`). This follows the plan's pre-existing hazard. Its mutant survives: three targeted tests never reached the window. It is kept as a defensive change.

## Verification

- **Checker.** `tb/tb_sb_check.v` runs in every bus-mode and compat leg. Byte by byte, program order must equal bus order. No port read may go past a retired store that is still unwritten, and no fast read may overlap one.
- **New programs.**
  - `sb_raw`: sizes, overlap, misalignment, the FIFO full, RMW chains.
  - `sb_order`: RAM and I/O.
  - `sb_serialize`: 9 serialising instructions, as `syncpc`.
  - `sb_lateberr`: posting only.
  - `t_sbuf_pipe`, 8 cases: FIFO against the fast path, a line-crossing store, aliasing, snoop sweeps, MOVEC TC behind a posted store, PFLUSH and CPUSH.
- **Mode 2 = mode 0, clock for clock.** All 254 logs of the full suite have the same halt clocks and phase cycles as core main. The one failure, `t_mmu_pipe`, was the checker; it is fixed in f87241a.
- **Mutants** (`tb/perf/sb_mutants.sh`), 12 in total: 9 caught, 3 surviving.

  | mutant | result |
  |---|---|
  | rd_nodrain | caught |
  | ser_nodrain, ser_nodrain_tc | caught |
  | fifo_lifo | caught |
  | post_tc_on | caught |
  | no_halt | caught |
  | ovl_ignored, ovl_nohi | caught |
  | fetch_past_wb | caught |
  | sync_overtake | survives: equivalent, `go_fifo` wins the mux anyway |
  | fast_nodrain | survives: equivalent in stage 1 |
  | inv_gate | survives: see above |

- **Full suites on f87241a.**
  - `PIPE_STORE_BUF=1`: 271/271.
  - Default (0): 268/268, and the same clocks as core main in all 254 logs. The cache gate moved nothing.
  - Core main: 255/255.
- **Routed build** `build/stage_sb2` (STORE_BUF=1, MMU+FPU, high effort; bit md5 e021c086f33b5d747cd22c9435af1016): timing met.
  - clk_38: WNS +0.012 ns. The worst path is the existing EX ALU → CCR forward → branch → redirect → IF chain (52 levels), and no store-buffer logic is on it. `stage_perf1` had +0.353: placement variation.
  - clk_114: WNS +0.326 ns.
  - The clk_gen_sdram → clk_114 row is -0.544 ns, as on every image.
- SoC bench (`sim/ddr3_cpu`, real TG68K + SDRAM + DDR3, FREECORE=1, STOREBUF=1): passes (`2 passed, 0 failed`).

## Performance: SysInfo 4.4 SPEED loop, SoC bench, 3 passes, 2,541 instructions

| bucket | off (`si_sb0`) | stage 1 (`si_sb1`) | stage 2 + fix (`si_sb3`) |
|---|---:|---:|---:|
| **total clocks** | **5,835** | **5,744** | **5,744** |
| CPI | 2.296 | 2.260 | 2.260 |
| store-hold | 506 | 0 | 0 |
| data-read wait | 619 | 991 | 991 |
| redirect-to-retire | 706 | 593 | 593 |
| port reads | 120 | 126 | 126 |

**The gain is -1.6 %, not the plan's -10 to -15 %.**
- The store-hold is gone (-506 clocks).
- Most of that time moved into the read wait (+372). A read that misses the fast path now waits for the FIFO to drain, where it used to wait for the synchronous store.
- Stage 2 adds nothing on this loop. The compat perf bench shows why (`siloop_compat`, per iteration, reads classified at the lookup):

| reads | fast | missed: store in EX | missed: FIFO overlap | missed: other |
|---:|---:|---:|---:|---:|
| 701 | 532 | **160** | 9 | 0 |

The slow reads are almost all a load right behind a store that is still in EX when the read issues. `st_quiet` refuses the fast path for any store in EX/WB. Stage 3, precise EX/WB address compares, is exactly that case: 160 of the 169 slow reads. The FIFO itself causes only 9, true RAW overlaps. The compat bench agrees with the SoC: 8,196 → 8,076 clocks (-1.5 %).

## Open

- The board A/B (build `stage_sb2`, STORE_BUF=1) against the current image: SysInfo, AIBB, FPUFixTest, AuditTest, and Workbench use.
- Stage 3 (EX/WB compares) is where this loop's remaining read wait is. Paul decides after the board.
