# Catching up with the 68040: loads and branches

Status: **in progress** (2026-09-28).
- Paul: "Let's try to catch up with the 040 and make a plan and implement loads and branches."
- Core branch `catchup`, off `store-buffer` f87241a.

## Why

The pipelined core runs at 37.8 MHz and reaches SysInfo 1.00, the speed of an A4000/040 at 25 MHz. The real 68040 therefore needs about 2/3 of our clocks per instruction: CPI about 1.5, against our 2.26-2.38 on the SPEED loop.

A per-instruction trace shows where the clocks go:
- Tools: `tb/perf/tb_trace_compat.v` and `tb/perf/trace_gaps.py`.
- Run: the compat perf bench on `siloop_compat.s`, 3 wait profiles, 10,167 instructions.
- Measure: each instruction's lost clocks = its gap to the previous retirement, minus 1.
- Result: 12,726 lost clocks, 1.25 per instruction.

| cause | lost | share | what happens |
|---|---:|---:|---|
| `rts` waits for its return address | ~4,700 | 37 % | `bsr` just pushed it. The push is a store still in WB or in the FIFO, so the `rts` read goes the slow way and waits for it to reach memory: 8.1 clocks per `rts`. |
| refill after `rts` | ~1,900 | 15 % | EA-fetch redirects only once the return address arrives, then IF, ID and EA-calc refill: 4 clocks at every return target. |
| fast-read latency | 2,400 | 19 % | A fast read is looked up in the clock after issue, then answered through the BCU's `rd_ack` register a clock later: 2 clocks where the 68040 takes 1. |
| taken `bsr`/`bra`/`bcc` | 1,600 | 12.5 % | ID guesses taken and redirects IF, and the fetch starts again 2 stages back: 5 clocks per `bsr`. |
| rest | ~2,100 | 16 % | DIV (real 68040 DIVS.W: 27 clocks), small stalls. |

The first four together are about 70 % of the loss. Removing them brings the loop to CPI ≈ 1.5.

Paul runs with the MMU on (68040.library), so every step must work with translation on.

## Steps

Each step ends with the full suite (bus legs, compat legs, `PIPE_STORE_BUF=1`), its own programs and mutants, the trace and perf measurement, and routed clk_38 timing. The board comes after step 2 and again at the end.

### 1. Store-to-load forwarding (loads; the `rts` wait)

A read is answered from the youngest older store that fully covers it, instead of waiting for that store to reach memory.

Sources:
- WB's store (registered);
- the store FIFO's entries (registered; the youngest match wins).

Not from EX: its data is ALU output (timing). A read that overlaps EX's store waits as today.

A read may forward only if the location is RAM:
- MMU off: the store's window verdict (`st_post`'s RAM window);
- MMU on: the wrapper's view of the read, from the data read path's translation copy (`dfp_tok`, `!dfp_tci`, `da_win`), without the tag hit.

In both cases the read and the store use the same FC (data space), and neither is locked. A partial overlap or a straddle goes the slow way.

A forwarded read never faults. That is fine: the store to the same address has passed, or will pass, the same check. If the store faults, the reading instruction is younger and is squashed.

Expected: most of the 4,700.

### 2. Return-address stack (branches; the refill after `rts`)

An 8-entry stack in ID:
- BSR and JSR push their return address;
- RTS pops it, and ID redirects IF to the popped address, as it does for a guessed-taken Bcc. The micro-op carries the prediction.

EA-fetch compares the real return address with the prediction:
- equal: no redirect;
- different: it redirects as today.

A wrong-path push or pop only costs a misprediction.

RTR, RTD and RTE are not predicted. The first four steps leave SMC and exception entry to the existing redirects.

Expected: most of the 1,900.

### 3. Taken branches redirected from IF (branches)

IF pre-decodes BRA/BSR/Bcc with an 8- or 16-bit displacement in the word it has just fetched. It redirects the next fetch to the target itself, ID's guess one stage early, instead of waiting for ID.

Timing: the worst clk_38 path already ends at IF's fetch PC (+0.012 ns). The target adder and the redirect must therefore come from IF's registered queue word, never from the fetch answer.

Expected: 2-3 of the 5 clocks per taken branch.

### 4. Fast-read latency (loads)

EA-fetch takes the fast read's data in the lookup-answer clock, bypassing the BCU's `rd_ack` register. This saves 1 clock per fast read.

Timing: `dfp_hit` then reaches EA-fetch's dispatch combinationally. Try it; register a part of the chain if it doesn't fit. If it can't close, drop it.

Expected: up to 2,400.

## Measuring

- **Fast:** the compat perf bench and the trace (iverilog, 5 minutes), in the table above.
- **Real:** the SoC bench (`run_ddr3_perf.sh`, FREECORE=1, STOREBUF=1).
- **Board:** SysInfo with the MMU on (the normal boot).

## Log

SysInfo loop, compat perf bench, profile 0 (8,076 clocks, CPI 2.383 before):

| step | commit | clocks | CPI |
|---|---|---:|---:|
| 1 forwarding | af3e3a7 | 6,930 | 2.045 |
| 2 RAS | ebb0901 | 6,230 | 1.838 |

- 2026-09-28: plan written.
- **Step 1.** The first cut compared only WB and the FIFO, and gained nothing: the RTS read issues early, while the BSR is still in EX. EX's BSR/JSR push was added as a source; its data is EX's input register, so there is no ALU path.
- **Step 2.** EA-fetch redirects fell from 654 to 6.
- **Mutants.**
  - Caught: fwd_oldest, fwd_ex_any, fwd_ex_late, fwd_partial, fwd_partial_fifo, ras_nocheck.
  - Not observable: the FC compare, because the bench's memory is not FC-split.
- **What is left** (trace, lost clocks after each):
  - a taken BSR/BRA: 1.9-2.0;
  - an RTS: 1.1, now ID's redirect;
  - a fast read: its 2-clock latency, for example `move.l 4(a0)` right after `lea` loses 3.0.
- **Board, 2026-09-28** (`stage_cu2`: STORE_BUF=1 FWD=1 RAS=1, normal boot with the MMU on): SysInfo **1.25**, **23.96 MIPS**, against 1.00 and 19.03 on `stage_sb2`. That is +26 %, as the SoC bench predicted (-25 % clocks).
- **Dhrystone** (xSysInfo's, `tb/perf/dhry`; board after step 2: 22,185 = 0.67 of an A4000/040's 32,809). Its profile differs from SysInfo's loop: CPI 4.2 on the old core. The causes:
  - loads refused by ANY store in EX/WB;
  - misaligned accesses bypassing the cache (68000-compiled: 2-aligned globals, a 62-byte stack frame);
  - string-loop branches;
  - store bandwidth: every store writes through.

  Compat perf bench, 20 runs, profile 0:

  | build | clocks |
  |---|---:|
  | old core | 38,493 |
  | FWD+RAS | 35,220 |
  | +PRECISE (store buffer stage 3) | 28,042 |
  | +forwarding at any alignment | 27,802 |
  | +MISPLIT | **26,559 (-31 %)** |

  Mutants mis_word, pre_no_wb, pre_no_ans and pre_lo_only are caught. The all-switches suite passes, apart from one checker bug (fixed, be119bc). `build/stage_cu3` (all five switches) has clk_38 at +0.068 ns.
- **Next.** The board test after step 2 (`build/stage_cu2`), then steps 3 and 4. Step 3 is probably a branch target buffer in IF, because pre-decoding IF's queue gains nothing over ID. Step 4 has the timing risk.
