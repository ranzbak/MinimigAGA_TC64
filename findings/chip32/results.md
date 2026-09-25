# 32-bit chip cycles -- results

Plan: findings/chip32/plan.md.  Base commit: 1b00f48 (findings/ap040-pipelined: handover for the end of the 09-24/25 session), branch chip32.

## chipbw unit test (vamos)

`findings/chip32/tools/test_chipbw.sh`: PASS (four chip result lines, 27 CIA-B TOD reads in hi/mid/lo order, ROM test reads $F80000).
A mutant (TOD mid read replaced by lo, ROM region moved to $F00000) fails it.

## sim/chip32 (minimig side: bridge + gary + bank mapper + SRAM bridge + real sdram_ctrl + SDRAM model)

`sim/chip32/run.sh` (Task 2, no RTL change):

    CHIP32 slots per CPU access: 0:0 1:1079 2:0 3+:0
    CHIP32 TB: 2083 checks, 0 errors
    CHIP32 TB: PASS
    mut_word2: failed as required (30 FAIL lines)
    mut_nowr2: failed as required (30 FAIL lines)

Every CPU access, wide or narrow, read or write, with or without DMA, took exactly one chip slot.
Wide reads of chip RAM and ROM (incl. overlay), wide writes, the stale-word-2 cases (T6a DMA write, T6b CPU word write)
and DMA in the slot right after the CPU's (T5b) all correct.  CPU access period ~564 ns (4 ena7 ticks) in the SDRAM trace.

## Simulation (sim/ddr3_cpu, --chipbus: chip RAM over the 7 MHz chipset bus)

| leg | CHIP32 | wide / narrow chipset cycles | phase 7 at | phase 8 at | $finish at |
|---|---|---|---|---|---|
| reference core, c32base | (none) | n/a | 956299682 ps | 1110738482 ps | 1134415572 ps |
| pipelined core, c32base | (none) | n/a | 985636002 ps | 1157281682 ps | 1180958772 ps |
| reference core, c32red (CHIP32PH, wrapper before the change) | 1 (no logic yet) | 0 / 1784 | 967300802 ps | 1427232242 ps | |
| reference core, c32 | 1 | 1049 / 83, 0 bad | 728379042 ps | 1090710802 ps | |
| pipelined core, c32 | 1 | 1019 / 117, 0 bad | 688041602 ps | 1026960722 ps | |
| reference core, c32off (NOCHIP32) | 0 | 0 / 1784 | 967300802 ps | 1427232242 ps | |

- Phase 1 -> 7 (the program before CHIP32PH): reference 690.1 -> 458.5 us (1.51x), pipelined 724.5 -> 423.4 us (1.71x).
- CHIP32PH to phase 8: 460 -> 362 us (reference).
- NOCHIP32 is BIT-IDENTICAL to the wrapper before the change (every phase timestamp and the 1784 narrow cycles).
  The c32red timestamps are +11.0 us against c32base at every phase because the bench preloads the (larger)
  program over the chip port before releasing the CPU; the intervals are identical.
- --c32mutant --chipbus: mutant failed as required (garbled fetches, stall at phase 0).
- --ap040 (Turbo chip on): 2 passed, 0 failed, 0 wide cycles.
- --mmu --chipbus: DROPPED (plan Task 3 leg 6).  Stalls in phase 1 (the table build) with CHIP32 (3924 wide, 76 narrow,
  0 bad) and with NOCHIP32 (4197 narrow) alike, at the 120k-cycle MMU watchdog and also at 300k: over the chipset bus the
  phase outlasts both the watchdog and the 4 ms TIMEOUT.  Pre-existing, a bench limit, not this change.

Both: `DDR3 CPU TB: 2 passed, 0 failed`.

## Images (Task 4, from the working tree = commits of Tasks 3+4)

| image | CHIP32 | MMU/FPU | LUTs | clk_38 | clk_114 | clk_148 | failing | md5 |
|---|---|---|---|---|---|---|---|---|
| build/stage_chip32_on | 1 | 1/1 | 45,519 | +0.648 | +0.765 | +0.796 | the known 16 clk_gen_sdram->clk_114 (-0.544) | 2d4bfb4f... |
| build/stage_chip32_off | 0 | 1/1 | 45,477 | +0.061 | +0.194 | +0.411 | the known 16 (-0.544) | dfbb4308... |
| build/stage_chip32_on_nofpu | 1 | 0/0 | 31,679 | +0.155 | +0.654 | +0.502 | the known 16 (-0.496) | |
| build/stage_chip32_off_nofpu | 0 | 0/0 | 31,620 | +0.025 | +0.523 | +0.805 | the known 16 | |

The LUT difference (+42 / +59) is the CHIP32 route: the generic reaches the wrapper through both tops.
Board A/B: use the MMU+FPU pair (the board's current image, m14f_fpu, is MMU+FPU).

## Board (chipbw, KB/s; PAL)

| image | Turbo chip | Turbo kick | MMU (68040.library) | chip rd.l | chip wr.l | chip rd.w | chip wr.w | rom rd.l |
|---|---|---|---|---|---|---|---|---|
