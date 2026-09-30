# Branch target buffer in IF: plan

Status: **in progress** (2026-09-30). Paul: "Can you implement branch target buffer?"
Core branch: `btb`, off `copyback` 0f94652. Switch: `AP040_BTB` (core parameter `BTB`), default 0.

## Why

Board, 2026-09-30: `stage_cb1` with copyback on the Zorro III boards gives xSysInfo **1.04x** an A4000/040 at 25 MHz (34,192 Dhrystones), at 37.8 MHz: about **0.69 of a 68040 per clock**.

SoC Dhrystone profile (copyback, 11,101 clocks per run): the biggest loss after retiring is **redirect-to-retire, 26.5 %**. About 1,400 redirects per run: ID 987, EA-fetch 286, EA-calc 121.

ID redirects for every Bcc/BRA/BSR/DBcc (it guesses taken) and for an RTS the return-address stack predicts. IF has fetched the words after the branch by then. The target fetch goes out in the clock ID emits the branch, and ID sees the target's first word two clocks later. A BTB lets IF fetch the target in the clock after it fetched the branch, so the target's words follow the branch's in the queue with no gap.

Expected: most of ID's 987 redirects hidden, about 2 clocks each: roughly **-10 to -15 %** clocks on Dhrystone.

## Design

**What IF predicts: exactly what ID would redirect on**, one stage earlier. The BTB learns from ID's redirects for Bcc, BRA, BSR and DBcc: the targets are PC-relative constants. RTS stays with the return-address stack in ID, and EA-calc's and EA-fetch's redirects are unchanged. A predicted Bcc is still resolved by EA-fetch, as today.

**Entry**, keyed by the fetch that brought the branch's last word:
- the fetch address `fa[31:1]` and the S bit of the stream (the full key: no aliasing);
- `slot`: the branch's last word is the first (0) or the second (1) word of that fetch;
- the target.

Direct-mapped, 16 entries (index `fa[4:1]`), in flops.

**IF.**
- **Lookup** on `fpc`, the sequential fetch address, not on a redirect's address (timing: `redirect_pc` does not reach the BTB).
- **On a hit:** the fetch goes out as usual; the next fetch address is the target (not `fa + 4`); the answer keeps only the words up to `slot`; the last kept word is marked.
- **One prediction at a time:** no lookup while a marked word is queued or in flight (`m_v`).
- **When ID takes the marked word,** the queue's PC jumps to the target (`qpc <= m_tgt`).
- **Two code ranges for the self-modifying-code check:** `[qpc, m_end)` before the jump and `[m_tgt, fpc)` after it. Today's single range `[q_lo, q_hi)` would be wrong across the jump.

**ID** sees a marked word with the queue (`q_m0/q_m1`) and the prediction's target.
- **Right prediction:** the instruction it emits ends on the marked word and is a branch it redirects on, with the same target. Then ID does not redirect; everything else is as today (the RAS push for BSR, the prediction for EA-fetch).
- **Marked word ends the instruction, but ID disagrees:** not a branch, or another target. ID redirects to what it would have done (target, or `next_pc`) and fixes the entry (writes the right target, or invalidates it).
- **Marked word inside an instruction** (the words after it are the target's, so the instruction is wrong): ID drops the gathered words and redirects IF to the instruction's first word (`g_pc`). The entry is invalidated, so the refetch does not hit it again.
- **Learning:** an ID redirect for Bcc/BRA/BSR/DBcc that was not predicted writes the entry. The key is the fetch that brought the branch's last word: `fa = pc_last - 2*s`, where IF marks each queued word with `s`, "the second word of its fetch".

**Clearing the whole BTB:** reset; CINV/CPUSH of the instruction cache (68040 code changes need one, and AmigaOS's CacheClearU after LoadSeg does it); the self-modifying-code refetch (`wb_smc`); PFLUSH and MOVEC to TC/URP/SRP/ITT (the logical-to-physical mapping of code changes).

## Stages

1. **Tests first.** A pipe_asm program `btb.s`, on the bus bench, with `.exp`:
   - tight loops (DBcc, Bcc backward, BRA);
   - BSR/RTS chains;
   - branches at each word position of a fetch;
   - BRA.W and BRA.L whose last word crosses a fetch;
   - a branch whose target is itself;
   - code rewritten after CINVA (stale entry cleared);
   - overlapping instruction streams (a jump into the middle of an instruction: the same bytes decoded two ways, so a marked word lands inside an instruction);
   - self-modifying code on the branch;
   - an interrupt and a trace during predicted loops;
   - an access fault on a predicted target fetch.

   The compat programs and the differential fuzz run with `BTB = 1` against the reference; mutants for every rule above.
2. **IF and ID with the BTB**, behind `BTB`, default 0. With `BTB = 0` the suite must be identical to before, log for log. With `BTB = 1` everything must pass, plus the SoC Dhrystone.
3. **Board image;** I/O first, then xSysInfo.

## Risks

- **Timing:** the lookup is on `fpc` (a register), and a 16-entry compare feeds the next `fpc`. The flops are 16 x ~64 bits.
- **The queue's jump:** `qpc` and the SMC ranges are the parts that break silently; the overlapping-streams test and the SMC test aim at them.

## Result, 2026-10-01: correct, but no gain on Dhrystone; not shipped

- **Tests:** btb.s (ten cases) passes with and without the BTB on every bench; six mutants caught; full suite passes with BTB=1; with BTB=0 the 282 shared logs are identical; 40 differential fuzz seeds clean. Core 8f99f5b (branch `btb`).
- **btb.s itself:** 9-21 % fewer clocks.
- **SoC Dhrystone** (MMU on, stage 4, copyback): **11,101 -> 11,083 clocks per run (-0.2 %)**. ID redirects dropped from 987 to 583 and the redirect-to-retire clocks from 2,940 to 1,709, but almost none of that reached the total: those clocks overlapped with the back end's waits. The "26.5 % redirect-to-retire" bucket that motivated this plan counts clocks from a redirect to the next retire, not clocks the redirect alone costs.
- **Board image `stage_btb1` (copyback + BTB) fails timing:** clk_38 -0.374 ns, 185 endpoints (worst: EA-fetch's `eaf_o[cls]` to the BCU's `mem_addr`, 46 levels). Not loaded.
- **Decision:** the BTB stays in the core, `AP040_BTB` default 0; the board builds leave it off.
- **What limits Dhrystone per clock:** the back end. EA-fetch -> EX transit 19.9 %, data-read wait 14.9 %, EA-fetch other 9.7 %, store-hold 6.5 %.
