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

## Stage 4 (SB_MMU): posting with translation on, 2026-09-29/30

Core `catchup` a47b11f (+ the window below). With the MMU on, a store to a page a synchronous store has proved postable is posted: the core keeps 4 logical pages (with FC); the MMU latches its verdict (TTR or ATC hit, writable, M set, not cache-inhibited) with the physical address; the wrapper adds a RAM window on that physical address.

**SoC Dhrystone, MMU on (MMUON=1, DTT0/ITT0), 10 runs:**

| build | clocks/run | store-hold |
|---|---:|---:|
| cu4 switches (no SB_MMU) | 13,092 | 32.2 % |
| + SB_MMU | 12,130 (-7.3 %) | 14.8 % |

**Board, and the SDRAM finding.**

| image | stage 4 window | result |
|---|---|---|
| `stage_cu6` | chip RAM, Zorro II, both Zorro III boards | **corrupt**: Workbench crashes 80000004, damaged icons, bad disk blocks, "wrong dir block" |
| `stage_cu6` + 832 firmware SPI_fast 2 (SD at ~11 MHz) | as cu6 | **still corrupt**: SD read timing ruled out |
| `stage_cu7` | none (SB_MMU = 0) | clean, xSysInfo 0.88 |
| `stage_cu8` | **the DDR3 board only** | **clean**: HDF stable, demos stable, **xSysInfo 1.01, 33,287 Dhrystones** (cu4: 0.88, 28,938; +15 %), without DDR3First |

- The core's stage 4 is right; posting into the SDRAM with translation on is what corrupts. Every simulation was clean: the full suite, the stage 4 mutants, 100+ differential fuzz seeds with SB_MMU (half with translation on) and 40 with random level-2 interrupts and a handler that stores to six pages (`GEN_IRQ=1`, more pages than the table holds).
- Stage 4's window is therefore the DDR3 board only (`ap040_pipe_tg68k_compat.v`, `mem_postok`). With translation off (boot, before SetPatch) the window still includes the SDRAM; cu4 and cu7 boot clean with it, but nothing heavy runs there.
- **Open: why posted stores into the SDRAM corrupt.** Leads: `sdram_ctrl` acknowledges a CPU write when it reaches the write buffer and nothing forwards it to a chipset read; `cpu_cache_new`'s line buffer is not snooped; the hardware-only chip RAM corruption that depended on the SDRAM phase an access completes on (memory: sdram-turbo-chip-coherency). Posting changes exactly that: CPU writes back to back and in the background. A bisect build posting to chip RAM only, or to the SDRAM fast RAM only, would split it.
- Side finding: fuzz seed 21 with `GEN_IRQ=1` fails the compat bench's interrupt-latency bound (a qualified request not taken within 16 instruction starts) with and without SB_MMU: a run of loads defers the interrupt. Pre-existing, not a corruption.
- SD timing, for the record: cfide samples MISO on the clk_114 edge that raises the SD clock, about 26 ns after the card's output edge at SPI_fast 1, over a false-pathed input (`sd_card.xdc`'s "/70 is the fastest it runs" is wrong: SPI_fast is /6). Marginal on paper, but not this bug.
