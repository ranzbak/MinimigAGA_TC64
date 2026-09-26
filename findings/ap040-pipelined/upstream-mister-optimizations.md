# apolkosnik's `ap040-pipelined` (MiSTer): what applies to our pipelined core

Written 2026-09-26 for Paul, from the backlog item in `SESSION-HANDOVER.md` ("Investigate apolkosnik's
optimized pipelined 040 core"). Read-only survey: nothing was adopted, built or run.

## Sources

- Theirs: https://github.com/apolkosnik/Minimig-AGA_MiSTer branch `ap040-pipelined`, tip **eefc5367**
  (2026-09-25), local clone `../minimig/Minimig-AGA_MiSTer`, remote `apol`. Design and measurements:
  `doc_AP040_PIPELINE_RESTRUCTURING_PLAN.md` (phases 0-8), `doc_AP040_PIPELINE_CACHES.md` (stages 0-F2),
  the 8 `perf baseline:` commits, `tests/ap040/perf/baseline.json`.
- Ours: `lib/AP68040-pipelined` @ 9efe490, `rtl/soc/TG68K.vhd`, `PLAN.md` (M11.2, M14, D1-D25).

## Three facts that shape everything below

1. **Same parent, two separate forks.** Both descend from nonarkitten's milestone 17. He imported it on
   2026-09-18 (26dd1961) and rebuilt it himself: his decode is 4,357 lines against our 1,674, and his
   ea_fetch is 4,339 against our 2,882. A patch will not carry across, so every item here is a
   **re-implementation**, and his tests are the part that ports most cheaply.
2. **None of his pipelined numbers come from hardware.** The pipelined core got its card wrapper on
   2026-09-25 (F2). Every figure is from simulation, either on his "core top" (an ideal one-cycle
   array) or his "bus16 top" (the MMU plus the 16-bit adapter), with fits for a Cyclone V at 25 ns. The
   board results in his log (Dhrystones 7,551 -> 8,559, PERFORMANCE.md) are for his **sequential**
   core.
3. **Our pipeline is already at or ahead of his on most per-instruction items.** We already have:
   - two words per clock into decode, from a six-word queue (our M1); this is his phase 8
   - static branch prediction and a four-step divider; these are his "perf 1"
   - MOVEM at one register per clock, matching the manual's formula; his phase 5 gets an
     eight-register MOVEM to 12/11 clocks
   - MOVE16 in 8 clocks against his 12
   - CLR that does not read memory
   - 143 of 145 cycle forms within manual+1 (M11)

   Our shortfall is on the **memory side** (M11.2), and that is also where his newest work is.

---

## PERFORMANCE

| # | What (his commit) | His measured gain | Ours today | Fit | Cost |
|---|---|---|---|---|---|
| P1 | **The core is not frozen during bus cycles.** The F2 wrapper (eefc5367) runs the pipelined core on its own tick and ignores `clkena_in`, because "this core stalls on its own"; the memory side runs every clock. | Not measured separately. It is a prerequisite for P2. | **No.** `TG68K.vhd:1806` `bus_release` gates `clkena_r`, and `ap040_pipe_tg68k_compat.v:177` has `ce_core = clkena_in`. So the core, MMU and cache stand still for every external access. M11.2 put that at 6.9 % of SoC time, and it makes our posted store "worth nothing on the board". The comment at `:160-176` says we re-gated because the adapter's ack stays high across our 5-of-16 duty-cycled enable. **His F2 fixes that same ack** (it is now taken once, in the clock after the enabled edge; see C9). | **High** | M-L: the wrapper, the adapter ack, the `cpu.xdc` multicycle island (T-section) and a random-CE bench (R1). Q12-class, so it needs your ruling. |
| P2 | **Four-entry store buffer** in the DMU (d06c1959). A write is accepted when there is room, not when the bus is free. Reads that go to the bus, line reads, table walks and CINV/CPUSH/PFLUSH/MOVEC-to-MMU wait for it to drain. | Dhrystone on the bus16 top **-14.3 %** cycles (437,103 -> 374,647), latency phase **-18.0 %**. t_fpu -1 to -2 %; everything else within 0.3 %. | One posted store (`POST_STORES=1`, `compat/ap040_cache.v:391`), which is useless while P1 stands. | **High, after P1** | M |
| P3 | **Copyback data cache** (1648a867, and f452fbb6 for its bus errors). It has dirty bits per longword and a push engine, and table searches go through the cache. | None stated. | Write-through only (`ap040_cache.v:8`). | **Medium-low.** Risks: our RTG fetcher reads the framebuffer straight from SDRAM, so a dirty line in fast RAM shows stale pixels unless P96's framebuffer page is CI/write-through. A snooped dirty line also loses its data (his own rule). | L |
| P4 | **Code in chip RAM is cacheable** because his I-cache is snooped by chipset writes (f7b0cc22). His FSM core's wrapper excluded it; the pipelined one does not. | None stated. | Our fast I-path bypasses chip-RAM fetches (`ap040_pipe_tg68k_compat.v:55`). | **Medium.** Helps games and demos that run from chip RAM. It needs the I-bank snoop proven first, plus a turbo-off style A/B on the demo set. | M |
| P5 | **MUL.L no longer holds EX** (7f10c247, phase 6C). The product goes straight to WB, and a reader waits one cycle. | Register MUL.L 3 -> 2 local cycles. | Not checked. We have `mul_busy`-style holds, so first read our cycle-checker row. | Medium. Rare in the SysInfo loop (one MULS.W per pass). | S |
| P6 | **Register bitfields sooner** (3e72b3fa phase 3, 3b93d2c9 6A): immediate offset/width taken at the sequencer's start, rotate straight into S2, and the extract and flag stages merged. | Register forms 9/10 -> **4/5**; memory -3; dynamic offset 8 -> 7. | Our `bf_uop` sequence has not been compared yet. | Medium. Blitter-less graphics code and some C compilers use BF*. | S-M |
| P7 | **FPU completion a cycle sooner** (a093729b, phase 6B): `fin` and the forced T0 flow are seen on entry to S_FIN; DISPATCH is skipped when the EA is not An's own. | FMOVE reg 9 -> 7, FADD 11 -> 9, **-1 on every F-line**. | Our `compat/ap040_fpu.v` is lifted from the same sequential FPU, so the same S_FIN cycle is likely there. Check it. | Medium-high for FPU workloads. Cheap. | S |
| P8 | **Operand-specific hazards** (3e72b3fa phase 1): `addr_hz` holds only the port whose address view is used; a load's destination and a store's data no longer wait; CHK's match is qualified by an actual write. | MOVE.L (A0),D1 repeated 3 -> 2 local; ALU -> store data 3 -> 2; passing CHK 2 -> 1. | Not checked. Our hazard logic is different code. | Medium | S-M |
| P9 | **A plain load leaves EA-fetch as its read goes out** (3bdc2de9, phase 5). | A load 2 -> 1 local cycle; two independent loads 4 -> 2; bus 5.5 -> 5.0. | Not checked. It brought a real bug with it (C7, MOVE <mem>,SR). | Medium | M |
| — | Already ours or not needed: phase 8 (two words into decode), perf 1 (prefetch stream, branch prediction, four-step divider), phase 5 MOVEM/MOVE16 streaming (ours is faster), phase 2 CLR without a read (Scc memory not checked), phase 4 EA-calc address stage (he says it "buys structure, not time"), his I/D caches and two-port MMU as designs (our M14 copies answer a hit in **1 clock**; his D-cache answers in 3). | | | n/a | |

## TIMING

His CPU closes at 25 ns (40-43 MHz) on a Cyclone V. Ours closes at 26.4 ns (clk_38), with +0.45 to
+0.64 ns in the FPU images. **We don't need timing work today.** These techniques matter as a package
**with** P1/P2, since freeing the core changes the paths.

| # | Technique (his commit) | His gain | Relevance to us |
|---|---|---|---|
| T1 | **The write snoop is registered.** membus snoops a write the cycle after accepting it. A fetch answered in the accept cycle is held (`a_dfr`) and answered next cycle, or refetched after the write (3b93d2c9). | bus16 38.5 -> 41.04 MHz, +0.635 ns | Our store-vs-fetch-queue snoop is combinational in EX (`ap040_pipe_core.v:761`, `ovl(exe_o.st_addr, …, if_q_lo, if_q_hi)`). A candidate if P2 lengthens that path. |
| T2 | **A combinational loop removed.** RMW waits on `wr_busy`, which came from `wren_b`, which came from EA-fetch's stalls, which came from EX. Verilator's UNOPTFLAT on `stall_self` flagged it, and Quartus synthesized it as a 17.7 ns LOOP (26 MHz). He replaced it with `wr_busy_w`, which assumes `wren_b` is set. | Loop gone | **Run `verilator --lint-only` on our core** (see R4). Our fork shares the milestone-17 stall structure. |
| T3 | **Address views read their own register, not EX's second forward.** The forward's mux carried the divider's high word (d1373fc6). | Part of 33.4 -> 35.8 MHz | Check our EA-fetch address views for the MULL/DIVL high word on the forward. |
| T4 | **The stack bank (A7 select) comes from `sr_base` and WB's commit, not EX's SR forward.** Asserted: any S/M change empties what is behind it (3b93d2c9). | Part of the +0.635 ns | Same question for our regfile's A7 bank select. |
| T5 | **The MUL.L product is kept off the forward mux** (P5). | core +1.228, bus16 +1.790 ns | Comes with P5. |
| T6 | **Wide fetch values are formed from registers** for the 0, 1 and 2 words taken, and the late take count only picks one. Before this, all 40 worst paths ran through `issued + taken` (-4.5 ns). | +4.5 ns recovered | The same shape as our M11.1 lesson (ab95926: "a smaller D is not a shorter path"). Worth reading before any IF change. |
| T7 | **The fast redirect decodes only Bcc.W, BSR.W and DBcc from the opcode.** The rest read held registers. | Took gather-start off the L1 read path | Useful if our redirect family (M11.1) returns. |
| T8 | **Translation from registers.** The DMU translates a latched request; the first draft translated in the request's own cycle and fit at -5.3 ns. I-cache: the request is registered, the set read next cycle, the compare after that ("port A's address arrives ~19.5 ns into the cycle"). | -5.3 -> +1.1 ns | This is the fallback if our 1-clock M14 hit copies ever become the critical path. It costs latency, so it is a last resort. |

## PRACTICAL (tests and tooling we can reuse)

| # | What | Why it matters to us | Cost |
|---|---|---|---|
| R1 | **A random clock enable plus slow memory mode** for the whole suite (`--ce-random --slow-l1`). It found his write-receipt bug (C9), the fetch overtaking a write, and t_exceptions 141. | Our enable is duty-cycled 5-of-16 and **we have no random-CE bench** (grep of `tb/`, `tests/`). It is a hard prerequisite for P1. | S-M |
| R2 | **Portable 68k test programs**, each run on both of his cores. Ours can run them the same way: `t_agu.s` (tests 1-115: every producer straight ahead of its consumer, the adjacencies a gather used to hide), `t_fault_edges.s` (1-68), `t_smc_mmu.s`, `t_moves_alt.s`, `t_walk_order.s`, `t_snoop.s`, `t_cinv_moves.s`, and **`dhry`** (PLAN.md M11 notes that we have no Dhrystone). | The cheapest way to find the bugs in the COMPATIBILITY table. | S-M |
| R3 | **A perf runner with a baseline gate** (`run_pipe_perf.py`, 79 cases, `baseline.json`, `--check` fails any case that got slower). It also counts the instructions that took the fast path, so a silently dead optimization fails. | Our cycle checker (145 forms) plus `perf_probe.vh` cover similar ground, but have no regression gate. | S |
| R4 | **Verilator lint**, which found T2. | One command, possibly one real loop. | S |
| R5 | **Focused benches**: `wrreceipt_bus16` (stores under 4 CE schedules), `wronly_bus16` (read-sensitive window), `dblfault_bus16`, `pushdep`, `fpufault_bus16`, `busredirect` phase 6, `dmuport`. | Templates. They need our top instantiated. | M |
| R6 | A boot bench that checks the **RESET instruction**: the line is low for 128 core cycles, and CIA writes follow its release (eefc5367). | Checked by nothing on our side either. | S |

## COMPATIBILITY (bugs he found or behaviour he fixed; our status)

"Check" means the bug is plausible in our fork and has not been verified. R2/R5 are the way to settle
each one.

| # | Issue (his commit) | Ours |
|---|---|---|
| C1 | **MOVES to alternate spaces (FC 0/3/4/7) must be untranslated**: no ATC, no table search, no protection, cache-inhibited (M68040UM 3.2 Table 3-2). FC 2/6 goes out as a data access in 1/5 (0262c909). Both his cores used to translate every FC, as WinUAE does. | **Divergent.** `compat/ap040_mmu.v:177` (`a_super = c_fc[2]`) and `:380` (`m_fc = c_fc`) translate every FC. Under our authority order the UM text wins, so this should become a divergences row. Rare in AmigaOS; matters for MMU tools. S-M. |
| C2 | **A bus error on a posted write or push becomes a format $7 access error** at a later boundary, with WB1 filled (UM 8.4.6; f452fbb6). | **Divergent by decision** (D13: `post_err` is fatal). Low priority for AmigaOS. |
| C3 | **Double fault**: a refused frame write, or a faulted vector read, must halt rather than retry or use junk as the handler. An IPL 7 must not wake the halt (476cc5d3). | Probably fine: `P_HALT` covers `aerr_dbl`/`wf_dbl`/odd vector 2/3 (`ap040_ea_fetch.v:2471,2856`). **Check** with his dblfault bench whether IPL 7 wakes it. |
| C4 | **A push behind its A7 producer**: BSR.S, JSR (An) or PEA (An) in EA-fetch while MOVEA/SUBQ/LEA/EXG to A7 is in EX stacked below the old A7 (df2f6f24). | **Check** (pushdep bench / t_agu.s). |
| C5 | **An access fault on an FPU transfer left the FPU sequencer running**, so the $7 frame went partly to the operand (86f69b53: `fp_clear |= aerr_now`). | **Check**: our FPU is lifted from the same sequential FPU (fpufault bench). |
| C6 | **A faulted MOVEM beat left its read outstanding.** Because `rvalid` is a level, the vector read and the handler's loads were written into the faulted beat's register until the next flush (phase 4 notes). | **Check** (t_fault_edges.s 38-45). |
| C7 | **MOVE <mem>,SR/CCR wrote SR from a stale operand** once loads were pipelined (phase 5). | Not applicable unless we port P9. Then it is mandatory. |
| C8 | **A fetch overtook a buffered write**, so a store into the next instruction ran the old one (a3e99024 on the L1, d1373fc6 on membus: t_integer 192, t_exceptions 141). | Likely fine: IF has `redirect_hold` ("a store into the code is still on its way"), and D10. Becomes **relevant again with P2**: a store buffer must hold fetches of covered words. |
| C9 | **The adapter's ack is re-taken under a divided enable**: it stayed up until the next enabled edge, and a free-running bus controller took it as the ack of the next transaction, with old data. Now taken once (eefc5367). The **write receipt** (86f69b53) covers the same class: a write forwarded while CPU ce was low freed `wr_busy` for a clock nobody saw, and random ce doubled stores. | **This is exactly why we re-gated** (`ap040_pipe_tg68k_compat.v:160-176`, t_integer 67 runaway). Taking both fixes is the core of P1. |
| C10 | **The prefetch window snooped the physical write address against logical fetch addresses** (2e93677d). | Fine: we compare logical `exe_o.st_addr` with the logical queue range (`ap040_pipe_core.v:761`). |
| C11 | **With TC.E clear, the MMU's instruction peek gave the stale ATC entry's caching mode**, so ROM and IO would have been cached at boot (f7b0cc22). | Probably fine: our IFP step 1 applies the window formula directly when TC.E=0. Check if we port P4. |
| C12 | **PROG_WORDS counted fetched words** (phase 8). | Our own 2^31 freeze, cc65d93, found independently. |

---

## Direction (Paul, 2026-09-26): cycles per instruction first

The core stays at clk_38 = clk_114/3. Routed fmax is about 38.8 MHz, and the clk_114 -> clk_38
acknowledge crossing has +0.18 ns (stage_chip32_on). The next clock target is clk_114/2 = 57 MHz, which
lets us drop the synchronization cycles with the memory logic. In-between ratios are not pursued.
Until the core can close at 57 MHz, the work is **CPI**. The TIMING table is kept for that later step.
Each CPI change reports its clk_38 slack, so that no new long path pushes 57 MHz further away.

## Shortlist (my ranking by expected gain over cost; your call on each)

1. **R1 + R4 now**: the random-CE / slow-memory bench and Verilator lint. They are cheap, they can
   only find bugs, and R1 is a prerequisite for #2.
2. **P1 + C9**: stop freezing the core during external accesses, using his adapter-ack and
   write-receipt fixes. It recovers the ~7 % frozen time M11.2 measured and unlocks #3. It touches
   `TG68K.vhd` and the `cpu.xdc` multicycle island, so it is Q12-class and needs your ruling. Do it as
   its own branch with a board A/B.
3. **P2**: a 4-entry store buffer, after #2. His Dhrystone -14 to -18 % is the largest measured gain on
   his branch, and our M11.2 breakdown (store hold + frozen, ~9 %) agrees with where it would land.
4. **R2**: port t_agu / t_fault_edges / t_moves_alt / dhry and settle C3-C6. Then **C1** (alternate-space
   MOVES per the UM), as a divergences row plus a fix.
5. **P7 + P5 + P6**: the one-cycle FPU completion, staged MUL.L and register bitfield shortcuts. Each
   is small and local. Check our current cycle rows first; skip any where we already match.

Deferred, with reasons: P3 copyback (RTG/DMA risk, large), P4 chip-RAM code caching (needs the I-bank
snoop proven and a demo A/B), P8/P9 (compare our hazard logic first; P9 carries C7 with it). T1-T8
travel with whatever feature moves the path. Every gain above is his simulation number on his tops;
only a routed build and a board A/B on ours decides.
