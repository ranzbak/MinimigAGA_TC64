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

Both: `DDR3 CPU TB: 2 passed, 0 failed`.

## Board (chipbw, KB/s; PAL)

| image | Turbo chip | Turbo kick | MMU (68040.library) | chip rd.l | chip wr.l | chip rd.w | chip wr.w | rom rd.l |
|---|---|---|---|---|---|---|---|---|
