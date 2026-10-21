# Dhrystone on the RISC-V host CPU (Task 13)

`fw/dhrystone_rv`, xPack gcc 15.2.0-1, `-march=rv32imc_zicsr_zifencei`, 100 runs
per measurement.  DMIPS/MHz = 1e8 / (cycles x 1757).  x832 = 714,342 / cycles
(the 832 at WS=3, tiny-cores.md).  Cycles are `clk_114` between the bench's
`=== TIME 1` and `=== TIME 2` stamps (the loop only; no printing inside).

## Result

| Run | cycles / 100 runs | DMIPS/MHz | x 832 | Gate (<= 142,868) |
|---|---:|---:|---:|---|
| L1 `-O2`, WS=3 ROMWS=1 | **168,386** | 0.338 | 4.24 | **FAIL** (+17.9 %) |
| L1 `-Os`, WS=3 ROMWS=1 | 273,408 | 0.208 | 2.61 | not gated |
| L2 `-O2`, real bridge + hostcache + cfide, SLAT 8 SJIT 0 | 253,428 | 0.225 | 2.82 | recorded only |
| reference: 832, WS=3 | 714,342 | 0.080 | 1.00 | |
| reference: tiny-cores VexRiscv IMC + 4 KB I$ | 101,087 | 0.563 | 7.07 | its bus did not register the CPU block |
| gate | 142,868 | 0.398 | 5.00 | |

The first of the 100 runs also fills the I$ (80 refills, whole program).  From
a 200-run measurement the steady state is 167,400 cycles per 100 runs (4.27x),
so the cold start is 1,000 cycles (0.6 %).

L1 wait-state sweep, `-O2` (ROMWS=1; memory costs 1 + WS cycles per access):

| WS | 0 | 1 | 3 | 8 |
|---|---:|---:|---:|---:|
| cycles / 100 runs | 127,779 | 141,248 | 168,386 | 250,231 |
| x 832 | 5.59 | 5.06 | 4.24 | 2.85 |

`-Os` at WS 0 / 1 / 8: 225,520 / 241,483 / 364,717.

## Gate missed: where the cycles go (Phase 7 item, not tuned here)

`RV_HOSTCPU_STATS` counts the whole run; the difference of the 100-run and the
200-run image gives the counts for 100 more passes:

- I$ refills: 0 (the whole program fits the 4 KB I$ after the first run);
- dBus accesses: 11,700 reads + 7,200 writes = 18,900 per 100 runs (189 per run);
- cycles with a bus request in flight: 90,700 = 4.80 per access.  The bench
  memory answers in 1 + WS = 4 cycles, so `rv_hostcpu` adds **0.80 cycle per
  access** (registered request, read data one cycle after ack) = 15,100 cycles
  per 100 runs = 9 % of the total;
- the other 77,700 cycles are the core running without a bus request.

WS sensitivity: 15,300 cycles per WS step, 0.81 cycles per access and step (the
writes overlap the pipeline in part).  Without the 0.80 cycle per access the run
would still be about 153,000 (4.7x): the gate needs the data-access cost
(189 accesses per run, mostly stack) to drop as well, e.g. by a D$ or by moving
the hot data on chip.  At WS=1 it is met (5.06x).

L2 at SLAT 8: 253,428.  An SDRAM line fill is 8 halfword beats after SLAT 8;
the 189 accesses per run go through hostcache (data) and the I$ fills over the
same path.  There were 1,429 SDRAM reads for the whole run (every access that
misses the hostcache).

## Dhrystone's own result checks

`dhry_1.c` compares 21 values after the loop (`Int_Glob`, `Bool_Glob`, ...,
`Arr_2_Glob[8][7] == Number_Of_Runs + 10`, the strings) and prints
`Error <name> is <x> but should be <y>` on a mismatch.  Every run printed
`Result checks: 21 compared, 0 wrong` and no line containing "should be"; the
run scripts fail on either (`sim/rv_l1/run.sh dhry`, `sim/host_bridge/run.sh dhry`).

## Differences from the brief

- **No TX-ready poll.**  The brief and the Global Constraints named bit 8 of a
  16-bit read at 0xFFFFFFF0 as TX ready.  `rtl/host/cfide.vhd` has no such bit,
  and a UART read is never acked at all: cfide acks an rs232/SPI access only
  with `IOcpuena`, and its support state machine sets `IOcpuena` for the UART
  only on a write, so a read leaves the bridge waiting for an ack that never
  comes and the CPU deadlocks.  (This text first said the read returns the SPI
  data register; that was wrong, corrected after the final review.)  The L1
  model used to return 0x0100 (so a poll worked in L1); the L2 run with a
  poll hung in the first character (SDRAM-resident firmware, 40 M cycles, 2 hw
  accesses).  The L1 model now fails any UART read (`=== FAIL uart read`, test
  `uart_read`), and the Global Constraints and the plan are corrected.
  `hw.c` writes the byte without polling: cfide does not ack a UART write while
  `txbusy`, so no character is lost (as the 832 firmware).
- TIMER: `timecnt[23:8]` counts every `aud_tick` (643 clk_28 = 44.1 kHz), so
  one count is 256 x 643 / 28.359375 MHz = 5.804 ms.  The 832 Dhrystone's
  `2 * TIMER` as "milliseconds" does not match that; `hw_ms()` uses 5.804 ms.
  Board numbers have 5.8 ms resolution on a run of seconds.

## Commands

    make -C fw/dhrystone_rv
    bash sim/rv_l1/run.sh dhry                      # RUNTAG=t13 above; WS=0/1/8 as RUNTAG=t13w<WS>
    RUNTAG=t13 bash sim/host_bridge/run.sh dhry     # xsim, about 1 minute
