# Store buffer: plan

Status: **draft for Paul's review** (2026-09-28). Core branch to be: `store-buffer` off `perf-fpu-mul`.

## Why

SysInfo loop on the SoC bench (findings/unfreeze/results.md): 5,845 clocks for 2,541 instructions, CPI 2.30.
Two buckets are about stores:

| bucket | clocks | cause |
|---|---:|---|
| store-hold | 510 | 164 stores x 3.1 clocks: the core's **synchronous** store handshake |
| data-read wait | 619 | 120 reads x ~5 clocks: a read that misses the fast path while a store is in flight waits for it |

The cache already posts stores (POST_STORES=1, one drain slot) and that is almost never the limit. So the buffer
belongs on the **core side, in the BCU**, not in the cache (where upstream put its buffer, d06c1959). Expected: store-
hold toward ~1 clock per store (about -350 clocks, -6 %), then part of the read wait (stage 2), together roughly
**-10 to -15 %** clocks on this loop.

## Design

- **Where:** the BCU's existing, unused POST=1 FIFO (`rtl/ap040_pipe_bcu.v:129-135, 226-231, 272`), 4 entries.
  Entries hold the logical address and FC; the MMU translates at drain. The MMU and cache stay as they are, and
  stores reach the cache in program order, so their snoop/merge rules do not change.
- **Mixed mode.** Every store is either *posted* (into the FIFO; WB is released while there is room) or *sync*
  (today's path, unchanged: it waits for the FIFO to empty, then goes out with its precise fault reporting). A
  registered `st_sync` bit from EX decides. **Sync** when any of:
  - the MMU is enabled (TC.E), until stage 4;
  - a DTTx match with W set;
  - the write of a locked read-modify-write (TAS/CAS);
  - MOVES to FC 0/3/4/7;
  - the address is outside the **RAM window**, which is chip RAM plus Zorro II/III fast RAM, the same windows
    as `da_win`. So chip registers, CIAs, autoconfig and ROM are always sync.
- **Faults.** A posted store cannot take an MMU fault. In RAM, the only possible bus error is the watchdog, so
  the access-error machinery (`wb_fault`, WB1, FSAVE, CT) is untouched. Two invariants keep it so:
  - Every access that can fault drains the FIFO first: slow reads and sync stores. An access-error frame is
    therefore always built with the FIFO empty.
  - Fast reads never fault.
- **Late bus error on a posted store:** it stays fatal, as a cache-posted one already is (D13). It is made
  *visible* (halt) instead of silently lost.
- **What waits for the drain.** Most of this is already wired through `sb_busy` and `older_busy`:
  - slow reads, IO reads and locked reads;
  - BCU fetches, so a refetch after self-modifying code can't overtake a buffered store;
  - serializing instructions: MOVEC (TC/TTR/CACR), CINV/CPUSH, PFLUSH/PTEST, RTE, STOP, RESET, TRAP and
    exceptions;
  - interrupts and trace;
  - NOP.

  Also wire the cache's `post_busy` into NOP's sync, a pre-existing gap.
- **Read-after-write:** a fast read (D-cache hit) whose address overlaps a valid FIFO entry (`addr[11:2]`, both
  longwords of a misaligned store) takes the slow path, which drains: never worse than today. Registered compares
  only (the fast path feeds `rd_ack`; timing). Forwarding from the FIFO is optional, stage 3.
- **Pre-existing hazard the buffer would expose more:** `dfp_thit` (`compat/ap040_cache.v:1136`) ignores a
  pending invalidate (`store_inv_lost`, `winv_pend`, C_WINV). The fix is to gate the fast path on those.
- **Not done:** 68040-style late reporting of buffered writes (WB1-WB3 in a format $7 frame). Three write-back
  slots can't hold four entries plus WB's store.

## Stages (each: pipe suite incl. bus legs, cache/mmu/irq legs, SoC legs, perf, routed clk_38 slack; board A/B last)

0. **Plumbing and tests.** Add:
   - a compat parameter, default off (it must be clock-identical to today);
   - a bus-order scoreboard in `tb_ap040_pipe_prog.v`, checking retired stores against memory-port writes in
     program order;
   - the new programs:
     - `sb_raw.s`: a store then a load at the same, overlapping and aliased addresses, all sizes, misaligned,
       and with the FIFO full;
     - `sb_order.s`: RAM stores, then an IO store and an IO read, with the order logged;
     - `sb_serialize.s`: stores, then MOVEC TC/DTT0/CACR, CINV, PFLUSH, RTE, STOP, RESET or TRAP; every store
       must be in memory before;
     - `sb_lateberr`;
   - perf counters: FIFO occupancy, full holds, and drain waits for reads, fetches and serializing
     instructions.
1. **BCU mixed mode.** With `st_sync` forced to 1 it must be clock-identical to today (the A/B proof). Then:
   - enable posting with TC.E=0 in the RAM window;
   - keep the fast path blunt (`st_quiet &= !sb_busy`);
   - measure store-hold.
2. **Fast-path overlap check,** plus the `dfp_thit` invalidate gate. Measure the read wait.
3. **Precise EX/WB address compares** in `st_quiet`. Optionally, forwarding from the FIFO.
4. **MMU-on posting.** A store is posted only on an ATC hit that is writable, with M set, the supervisor check
   passed, no page crossing, and a physical address in the RAM window. This needs a store ATC peek.

## Risks

- Late bus errors can now be lost across up to 5 stores. The RAM-only window contains this.
- Timing on the fast-read path. Keep every compare registered.
- Fetch starvation and extra interrupt latency behind a full FIFO.
- Back-to-back BCU issue stresses the one-low-clock rule and the receipt/ack qualification. Run the free-core
  monitors (FC-1..4) and mutants.
- MMU-on software gains nothing until stage 4. AmigaOS normally runs with the MMU off, but 68040.library and
  MuForce may turn it on.

## Decisions for Paul

1. Posting only in the RAM window, and MMU-on stores staying sync until stage 4: OK?
2. A late bus error on a posted store halts the machine visibly (D13 extended): OK?
3. Stop after stage 2 and measure on the board before deciding on 3 and 4?
