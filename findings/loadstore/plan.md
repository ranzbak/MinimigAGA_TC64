# Load/store path: closing the per-clock gap to the 68040

Status: **draft for Paul's review** (2026-10-02, written overnight; no RTL changed, no hardware touched).
Core: `lib/AP68040-pipelined` branch `cputest-fixes` bd77429. Shipping image `stage_cf3`:
STORE_BUF=1 FWD=1 RAS=1 PRECISE=1 SB_MMU=1, COPYBACK=0 BTB=0 MISPLIT=0, FREE_CORE=1, MMU and FPU on.
Scratch work (patched RTL copies, probes, logs): `/tmp/claude-1000/.../scratchpad/loadstore/` (see "Reproducing" at the end).

## 1. The gap

| | Dhrystones/s | MHz | per MHz | clocks per Dhrystone | instructions per Dhrystone | CPI |
|---|---:|---:|---:|---:|---:|---:|
| board, `stage_cf3` (xSysInfo, MMU on) | 33,287 | 37.8125 | 880 | 1,136 | ~466 | 2.44 |
| SoC bench, same switches (this plan's baseline) | (31,240 at 37.8125) | | 826 | 1,210 | 466 | 2.60 |
| real 68040 (xSysInfo's A4000/040 reference, 32,809 at 25 MHz) | 32,809 | 25 | 1,312 | 762 | 466 | 1.64 |

The SoC bench is 7 % slower than the board (its DDR3/TG68K model is a little pessimistic); it has tracked every
board change within a few percent (storebuf, catchup findings), so it is the measuring instrument here. The gap to
close is **about 450 clocks per Dhrystone run (1,210 -> 762), 0.96 CPI**. Loads and stores are where most of it is:
per run the SoC profile has 206 clocks of data-read wait, 199 of EA-fetch -> EX transit (which, as shown below, is the
same load-latency bubble seen one stage later), 178 of store hold, 88 of other EA-fetch holds.

## 2. Measured baseline (SoC bench, today's switches)

Command (bash, not zsh; one xsim at a time; a new tag each run):

```
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64 && R=$PWD && INT=$R PIPE_DIR=$R/lib/AP68040-pipelined \
FREECORE=1 STOREBUF=1 FWDRAS=1 PREMIS=1 SBMMU=1 MMUON=1 TINFO_SHIM=$HOME/lib/tinfo5 \
bash findings/ap040-pipelined/tests/perf/run_ddr3_dhry.sh ls_base1
```

Result (`sim/ddr3_cpu/run_perf_ls_base1`, 10 Dhrystone runs, MMU on through DTT0/ITT0, 53 minutes of xsim):

```
PERF ddr3_cpu: 12102 clocks, 4657 instructions (4798 micro-ops), CPI 2.599
PERF   frozen (enable low, m_* busy): store 0 (0.0%)  I-fill 0 (0.0%)  D-fill 0 (0.0%)  other 0 (0.0%)
PERF   retire 4798 (39.6%)  store-hold 1775 (14.7%)  EX busy 50 (0.4%)  EAF->EX transit 1991 (16.5%)
PERF   data-read wait 2056 (17.0%)  EA-fetch other 878 (7.3%)  EA-calc/ID 276 (2.3%)  queue-only 278 (2.3%)
PERF   empty: fetch on port 0 (0.0%)  fetch denied 0 (0.0%)  IF idle 0 (0.0%)
PERF   redirects: ID 987  EA-calc 121  EA-fetch 286  EX 0  SMC 0;  redirect-to-retire clocks 2873 (23.7%)
PERF   core port transfers: fetch 0  read 118  store 1209;  m_* channel: reads 92  writes 1210  line fills 20
PERF   core port (enabled clocks): request up 6107 (50.5%, 4.60 per transfer)  ack-clock gap 1327  idle 4668
DDR3 CPU TB: PASS  (68k program completed all phases)
```

Within 0.2 % of `run_perf_dh_mmu_s4` (12,130 clocks, 2026-09-30, before the cputest fixes). Per run: 1,210 clocks,
466 instructions (480 micro-ops), 121 stores, ~160 data reads of which only 12 go out on the port.

Load/store classification (a scratch probe, `ls_probe_ddr3.sv`, same window; the numbers below are from the
compat perf bench, 20 runs, profile 0, `tb_ls_compat.v`; the SoC numbers are in section 4's table):

```
reads issued 3210: early (from EA-calc) 3059, EA-fetch's own 151
answered: fast-path 2426  forwarded 581  slow (port) 203
lookups missing the fast path: store-quiet refused at issue 0, at answer 0, FIFO overlap 0, no cache hit/window 203
EA-fetch holding 8903 clocks: read pending 6705, other 2198
stores: posted 2368  synchronous 1;  WB store-hold 1973 clocks: FIFO full 1954, sync not done 19
```

So: 95 % of reads are issued early (from EA-calc, in the clock the instruction enters EA-fetch), 94 % are answered
without the port (fast path 76 %, forwarding 18 %), the PRECISE/FWD rules refuse nothing any more, and the 6 % slow
reads are all "no hit": they are **misaligned** (the -m68000 Dhrystone's 2-aligned longword globals at `$351a`,
`$3512`, and stack slots), which the fast path does not serve.

## 3. Where a load hit's clocks go today

A `move.l (a0),d0` whose operand hits the data cache, with the early read (the common case, 95 %):

| clock | IF/ID/EA-calc | EA-fetch | BCU slot / port | wrapper + cache (data read path) | EX | WB |
|---|---|---|---|---|---|---|
| A | EA-calc computes the EA; `early_v` | finishing the previous instruction (`st.fin`) | `rd_req` latched into the slot (`dq_v`), `lk_v` compares the FIFO/WB/EX stores (`sb_ovl`, `fw_ok` registered) | `dfp_req`: tag + 4 data-way BRAMs of the D-bank copy addressed; MMU's dfp translation copy registered (`dfp_pa`, `dfp_tok`) | prev-1 | prev-2 |
| B | next instruction in EA-calc; its early read is **blocked** (`use_early` needs `!rd_pend \|\| rd_ack`) | the load is in EA-fetch, `rd_pend`, waits (`eaf_stall`) | `d_rd_fast` = `dfp_look & dfp_q1 & st_quiet_a & dfp_hit & !sb_ovl`; at the edge: `rd_ack <= 1`, `rd_data <= dfp_data`, `dq_v <= 0` | `dfp_thit`: 4 x 22-bit tag compares on the BRAM outputs, valid bits, collision checks; `dfp_rdata` = way mux + `lw_extract` | prev | prev-1 |
| C | the next instruction's early read goes out now | `cap`: `rd_ack & rd_pend` -> `ops_done` -> `stepf` -> `st.disp`, `st.fin`; `eaf_o <= disp_x` | | | prev | prev |
| D | | next instruction | | | **the load executes** | |
| E | | | | | | **retires** |

EA-fetch holds the load for two clocks (B and C). The 68040 holds it for one ("one clock in the <ea> fetch stage for
each memory access", M68040UM 10.1; MOVE (An),Dn: 1 clock EA-fetch, 1 execute). The second clock is the BCU's
`rd_ack` register: the lookup answers in B, the pipeline sees it in C. `ap040_ea_calc.v`'s own comment says the early
read was meant to make a load cost EA-fetch one clock; the M14 read path (lookup in the clock after issue, answer
registered) made it two. Without the early read (5 %: the instruction after a Bcc/RTS/JMP, `redir_cls`) EA-fetch
issues the read itself and holds three clocks.

The perf probe shows the same bubble twice: in B it is "data-read wait" if nothing older is in EX/WB, and when the
pipeline is otherwise full the previous instruction retires in B, and the hole appears a clock later as
"EA-fetch -> EX transit" (the oldest instruction sits in `eaf_o` with nothing behind it in EX). Those two buckets
(16.4 % + 17.0 % on the SoC) are mostly this one clock, not two problems.

## 4. Ceiling experiments

Each is a mutation of a scratch copy of `rtl/` (never the checkout), run on the compat perf bench
(iverilog, `tb_ap040_pipe_compat.v` + `tb/perf/tb_perf_compat.v`, 20 runs, profile 0 = zero-wait 16-bit bus) and,
for the ones that matter, on the SoC bench (xsim, `PIPE_DIR` pointed at a tree whose `rtl/` is the scratch copy).

| experiment | what the scratch RTL does | compat enabled clocks (20 runs) | compat total | SoC clocks (10 runs) |
|---|---|---:|---:|---:|
| baseline | - | 23,472 | 27,802 | 12,102 |
| **ZL**: zero-latency answer | the BCU hands a fast-path or forwarded answer to EA-fetch in the lookup clock itself (`rd_ack` combinational in B), for every read | 22,227 (-5.3 %) | 26,557 (-4.5 %) | **11,543 (-4.6 %)** |
| **ZL2**: ZL for eligible loads only | as ZL, but only when the pending read is the operand load (T_SLD/T_DLD) of a plain instruction whose value only EX uses (not RTS/JMP/MOVEM/CAS/CHK/BF/DBcc/memory-indirect, not two-load instructions) -- the set step 1 below can actually dispatch early | 22,319 (-4.9 %) | 26,649 (-4.1 %) | **11,695 (-3.4 %)** |
| ZL + 8-entry store FIFO | `SB_N = 8` on top of ZL | 22,307 | 26,637 | - |
| ZL2 + 8-entry store FIFO | | - | - | running when this was written: `scratchpad/loadstore/soc_ls_zl2_sb8.log`, `sim/ddr3_cpu/run_perf_ls_zl2_sb8` |
| **ZL3**: ZL2 + slow reads pass non-overlapping posted stores | the BCU slot read goes out ahead of the FIFO when no entry shares a longword with it (`addr[11:2]`, first and last) | 21,346 (-9.1 %) | 25,676 (-7.6 %) | queued behind it: `soc_ls_zl3.log`, `run_perf_ls_zl3` |
| copyback (existing run `dh_cb1`, 2026-09-30, against that day's 12,130) | stores to the DDR3 window stay in the cache: the "stores cost the port nothing" ceiling | - | - | 11,101 (-8.5 %) |

SoC ZL profile (`run_perf_ls_zl1`): store-hold 1,775 -> 2,137, EAF->EX transit 1,991 -> 1,434, data-read wait
2,056 -> 2,134, EA-fetch other 878 -> 461; reads 1,631 per 10 runs: fast 1,241, forwarded 281, slow 108 (72 misaligned);
the 108 slow reads hold EA-fetch 1,763 clocks (894 waiting in the slot for the FIFO to drain, 869 on the port):
**16 clocks each, 15 % of the run**.

Reading the compat column with care: that bench's 16-bit bus makes a store cost 4.4 core-port clocks plus a frozen
drain (14.6 % of its clocks are "frozen, store"), so it is store-bound: ZL's 3,007 saved read clocks turn into only
1,245 fewer clocks, because WB's FIFO-full holds grow from 1,973 to 3,073 as stores arrive faster. A deeper FIFO does
not help there (the slow reads then wait for a longer drain). The SoC column is the real one.

Per-instruction trace (`tb/perf/tb_trace_compat.v` + `trace_gaps.py`, compat profile 0, 9,181 instructions,
14,297 lost clocks = 1.56 per instruction):

| cause | lost clocks | share | what it is |
|---|---:|---:|---|
| redirect-I | 4,599 | 32 % | ID's taken-branch / predicted-RTS redirects, ~2.4 clocks each: the string loops' `bne` + `addq.l #1,a1`. The BTB's domain; it measured -0.2 % on the SoC because these overlap the back-end waits below. Once the back end is faster they resurface. |
| fastread | 3,406 | 24 % | the one extra clock per fast-path/forwarded load (section 3) |
| slowread | 2,661 | 19 % | the misaligned globals (`add.l $351a.l,d0`: 34 clocks each on this bench), `movea.l $10(a7),a2` |
| other | 2,080 | 15 % | `movem.l d2-d4/a2,-(a7)` 24 clocks (a store burst filling the FIFO), `jsr`/`pea` 5 each |
| redirect-F / -C | 1,551 | 11 % | EA-fetch's not-taken Bcc corrections, EA-calc's JSR/JMP redirects |

## 5. Gap decomposition, per Dhrystone run (SoC, 1,210 clocks vs the 68040's 762)

From the baseline and the ZL run (which strips the hit latency and exposes what is under it):

| cause | clocks per run | how bounded |
|---|---:|---|
| retire (one per micro-op; the 68040 pays these too) | 480 | - |
| **load hit latency: the second EA-fetch clock** | 56 net (150 gross) | ZL: 12,102 -> 11,543. The gross saving on 152 fast/forwarded reads per run is ~150; 36 of it comes back as store holds (stores arrive faster at a port that is already 50 % busy) and the rest was overlapping other waits. ZL2 (the buildable subset): 11,695, -407 clocks = -41 per run (-3.4 %); store-hold 1,775 -> 2,128. |
| **slow reads (12 per run, 7 of them misaligned)** | 176 | 16 clocks each: 8.3 waiting in the BCU slot for the store FIFO to drain (`go_rd` needs `sb_cnt == 0`), 8 on the port (the cache bypasses a misaligned read; MMU, cache, `m_*` to the DDR3). Measured on the ZL run; present in the baseline as well. |
| **store port: WB holds on a full 4-entry FIFO** | 178 (214 after ZL) | 121 stores per run; `m_*` is busy 4.5 clocks per write (5,489 clocks for 1,210 writes), the cache's drain slot 3.5, the cache FSM only 1.5: **the limit is TG68K's write handshake, not the core or the cache**. A store waits for the drain slot 2,779 clocks per 10 runs. Copyback (stores never reach `m_*`): -103 per run. |
| EA-fetch other holds (MOVEM, LINK/UNLK/PEA sequences, held redirects) | 88 (46 after ZL) | multi-step sequences; the 68040 also takes 2-3 clocks for most of these |
| EX busy (MUL/DIV) | 5 | - |
| front end (ID/EA-calc transit, queue-only) | 56 | BTB (built, correct, -0.2 % today) |
| redirect refill hidden under the above | (287 counted, overlapped) | becomes visible as the back end speeds up |

The 68040 pays about 1.64 CPI on this code: 1 clock per instruction plus ~0.64 for its taken branches (2 clocks),
BSR/JSR/RTS (3/3/2+), MOVEM (1 + 1 per register), LINK/UNLK/PEA, and a second access for each misaligned operand.
Our 2.60 is that plus the three bold rows (about 410 clocks per run gross, overlapping). Removing them entirely would
give about 2.0 CPI; the rest is the front end and the multi-step sequences, which are not load/store work.

## 6. Steps

Each step: a parameter on the core and on `ap040_pipe_tg68k_compat` (default 0, `build_ap040.tcl` plumbing, SoC
bench define), tests that fail before and pass after, mutants, the full pipe suite with the switch off being
log-identical to today, the switch-on suite green, 100+ differential fuzz seeds, SoC Dhrystone, routed clk_38 slack,
then the board: I/O checks (HDF, SD FAT, file copies, demos) BEFORE any benchmark, as the MISPLIT and stage-4 lessons
require.

### Step 1: `AP040_LDX` -- a hitting load costs EA-fetch one clock (late-operand dispatch)

**Design.** EA-fetch dispatches an *eligible* load to EX at the end of the lookup clock (B in section 3) without
waiting for the answer; the operand is written into `eaf_o` from the data path's combinational result in that clock,
and EX checks in C whether the answer really was fast (the BCU's registered `rd_ack`, as today) and stalls if not.

- **Eligibility** (decoded from `eac_i`, registers): the pending read is the instruction's last read, tag T_SLD or
  T_DLD, the class is one of ALU/SCC/SHIFT/BIT/EXG/CCROP/MOVE2CCR/PACK/UNPK/MULDIV (not imm[0])/LINK/UNLK/PEA, not
  `vdep` (CHK, CHK2, DBcc, BF, CAS2, DIV), no memory-indirect pointer read, not MOVES (fcsel), not a locked read,
  not a two-load instruction (CMPM, ABCD/ADDX/SBCD/SUBX memory forms). This is exactly the ZL2 set, whose ceiling
  is measured. RTS/RTD/RTR, JMP/JSR indirect, MOVEM, CAS, TAS, exceptions, RTE, FPU keep today's two-clock path.
- **EA-fetch** (`ap040_ea_fetch.v`): a new dispatch arm in `stepf`'s P_START/P_OPS branch: `ops_done` is also
  satisfied when the only missing operand is an eligible read issued at least a clock ago (`rd_pend`, a flop) and
  `LDX` is on. `disp_x.a` (or `.b` for T_DLD) takes `rd_data_c`, the BCU's new combinational candidate
  (`rd_fwd ? fw_data : dfp_data`), and the micro-op carries `ldp` (load pending) and which operand. The departed read
  stays tracked in EA-fetch as `rdx_pend` beside its own `rd_pend`: answers arrive in issue order (the BCU never
  reorders reads, see below), so the first `rd_ack` after a dispatch belongs to the departed read. On that ack, if it
  was NOT the fast answer (the BCU says so with `rd_ack` a clock late), EA-fetch rewrites `eaf_o.a/.b` with the port's
  `rd_data` and raises `ld_got`; on a fast answer nothing is rewritten (the data was right in B). `use_early` admits
  the next instruction's early read in the dispatch clock: `(!rd_pend || rd_ack || ldx_disp)`, so two reads may be
  in flight (the departed one being answered, the new one entering the slot).
- **BCU** (`ap040_pipe_bcu.v`): (1) the slot's `rd_req` latch moves after the fast-answer clear and after `go_rd`,
  so a request in the same clock as an answer or a port issue is not lost (the ZL experiment needed exactly this);
  (2) a fast or forwarded answer is refused while a read is on the port (`mem_req && kind == K_RD`): the lookup result
  is dropped and the slot read goes to the port after the older one, which keeps answers in issue order (cost: only
  the read behind a miss, 6 % of reads on this code); (3) `rd_data_c` and `rd_fast_now` exported.
- **EX** (`ap040_execute.v`): `ex_stall = stall_in || md_wait || (x.ldp && !ld_have)`, `ld_have = rd_ack_q ||
  ld_got` (flops). Nothing else: the operand is already in `x.a`.
- **Faults on a departed read** (bus error, or an MMU fault on a miss with translation on): EA-fetch keeps the
  departed read's PC, address, size and FC (it has `rd_a_q/rd_sz_q/rd_fc_q` for one read today; a second set) and,
  on `rd_err` for it, drops EX's stalled micro-op (`eaf_valid <= 0`: EA-fetch owns that register and EX has
  committed nothing) and takes vector 2 with a format $7 frame from the saved record, restart model as today.
  A flush from WB (`wf_go`, a store fault, which already abandons EX's micro-op and this stage) drops both pending
  reads (`rd_drop` for each). EA-fetch's OWN redirect (a not-taken Bcc correction, RTS mismatch) flushes only the
  younger stages: it must drop its own early read as today (`eaf_redir_v` arm) and must NOT drop the departed read,
  which belongs to the older instruction in EX -- the two reads need separate drop bits.
- **What does not change:** PRECISE/FWD store-order rules (the next read's lookup in the dispatch clock sees the
  same EX/WB stores as today's dispatch-clock early read), interrupts (taken at P_START of the next instruction;
  the departed load completes in EX as any EX instruction), trace, forwarding of EX results into EA-fetch (EX stalled
  means EA-fetch stalled), the wrapper and the cache (untouched).

**Expected gain:** the ZL2 ceiling: compat -4.9 % of enabled clocks; **SoC -3.4 % (12,102 -> 11,695)**, of which
the store FIFO takes back 35 clocks per run (store-hold 178 -> 213): the clocks saved on loads let stores arrive
faster at a port that `m_*` already holds half the time. With steps 2/2b in, more of the gross ~150 per run shows. A miss behind a fast
answer costs one clock more than today (the rewrite into `eaf_o`), bounded by 12 port reads per run.

**Timing.** The point of the late-operand form over the plain ZL form is where the logic sits:
- The stall chain gets no cache logic. Plain ZL would put `dfp_thit` (BRAM output -> 4 x 22-bit compare -> way select
  -> window -> store-quiet) in front of `cap -> ops_done -> stepf -> st.fin -> eaf_stall -> ea_stall -> ID consume ->
  IF fetch PC`, about 8 levels on top of a chain that is already in the 40s; that is the BTB's 46-level failure
  shape (`eaf_o -> mem_addr`) and must not be built. In LDX the dispatch decision is `rd_pend` (flop) AND eligibility
  (flops): no deeper than today's `cap`.
- The data path `dtag_q/ddat_q* -> compare -> way mux -> lw_extract -> disp_x.a -> eaf_o.a` is about 12-15 levels
  into a flop and touches no control; it is the same logic that today ends in the BCU's `rd_data` flop, one mux
  deeper.
- EX: one OR term on `ex_stall`, whose head today is `wb_hold` (flops -> 2 levels). The ALU -> CCR -> Bcc -> redirect
  -> IF path (52 levels, +0.012 ns on `stage_sb2`) is untouched because the operand mux is at `eaf_o`'s input, not at
  the ALU's.
- Nothing lands on `eaf_o -> mem_addr` (the BTB build's worst path); the BCU's slot logic gains one priority term.
- Budget: the last builds had clk_38 slack +0.089 to +0.813 ns, so even a modest LUT growth is a risk; build at high
  effort and compare with `stage_cf3`'s failing-path list before the board.

**Tests (fail first, then pass).**
- New `tb/pipe_asm/ldx.s` + `.exp` on the L1 and bus benches: load-use pairs of every eligible class and size
  (`move/add/cmp/tst/and (an),dn`, `(d16,an)`, `(d8,an,xn)`, abs.l, byte/word/long, Dn and An destinations), a load
  feeding a Bcc in the next instruction, two loads back to back (the second's early read in the first's dispatch
  clock), a load then a store to the same address and the reverse (PRECISE/FWD still right), RMW (`add.l d0,(a0)`),
  `move.l (a0),(a1)`, LINK/UNLK/PEA, a load whose line misses (the +1 clock rewrite path), a misaligned load behind a
  hit (slow after fast), a miss then a hit (the in-order rule), bus error on a departed read (`$F140`-armed, format
  $7 frame checked word by word as `berr_read.s` does), an MMU fault on a departed read with translation on, an
  interrupt arriving in the dispatch clock, trace on, a WB store fault flushing a departed load, ineligible
  instructions unchanged (RTS/CAS/MOVEM/CHK/DBcc/memory-indirect), and the bench's read-sensitive register `$F180`
  read exactly once per load.
- Compat: `t_dcache_pipe.s`, `t_fwd_pipe.s`, `t_sbuf_pipe.s`, `t_earlydrop_pipe.s` (the early read down a wrong
  path must still be dropped, now also a departed one), `t_specread_pipe.s`, `t_sbmmu_pipe.s` with `LDX=1`.
- `tb/perf/fuzz/fuzz.sh` 200 seeds, half with translation on, `LDX=1` against the reference build.
- Mutants (a `tb/perf/ldx_mutants.sh` like `sb_mutants.sh`): dispatch without `rd_pend`; eligibility ignoring
  `vdep`; the BCU taking a fast answer with a read on the port; EX not stalling on a miss; the rewrite into the wrong
  operand; `rd_drop` not covering the departed read; the fault record not saved. Each must be caught by a named test.
- `LDX=0`: the whole suite log-identical to bd77429 (clocks and phases), as `STORE_BUF=2` was proved.
- SoC: `run_ddr3_dhry.sh` with a new `LDX` define (ddr3_cpu_tb.sv generic), and the `sim/ddr3_cpu` functional legs
  (`--ap040 --snoop --mmu --chipbus`), Kickstart legs trace-identical.

**Board.** Build `stage_ldx1` = `stage_cf3` + LDX=1 (high effort). I/O checks first (the stage_cu3/cu6 list:
HDF reads, SD FAT visible, programs start, file copy to and from HDF, demos), then xSysInfo with the MMU on, AIBB,
cputest `ct040_01_B-01`. Expect xSysInfo from 1.01 to about 1.045 of the A4000/040 if the SoC ceiling (-3.4 %) holds 1:1.

### Step 2: slow reads must not wait for the whole store FIFO (`AP040_RDPASS`)

A read that misses the fast path waits in the BCU slot until the FIFO is EMPTY (`go_rd` needs `sb_cnt == 0`), then
goes out behind every posted store: 8.3 clocks per slow read on the SoC, 894 clocks per 10 runs (7.4 %). The FIFO
overlap compare already exists for the fast path (`lk_hit`, `addr[11:2]` of first and last longword against each
entry's). The 68040 itself lets a read pass its store buffer when the addresses differ (M68040UM 7.7: writes are
pushed before a read only on a conflict or a serialising access).

**Design.** The same compare run continuously on the slot (`dq_a/dq_s` against `sb_lo/sb_hi`, 4 entries x 4 ten-bit
compares, flops in, flops out: it feeds `go_rd`, which is registered into `mem_req`). A slot read with no overlap
and no synchronous store pending (`!st_v && !older_st` as today) takes the port ahead of the FIFO
(`go_fifo` yields to it), when the read is a data-space read of RAM. The last condition needs the wrapper's RAM
verdict for the slot read: the data read path already computes `dfp_ram` for the lookup; register it with the slot
(`dq_ram`). I/O reads (chipset registers, CIAs, autoconfig) keep today's order: a posted RAM store followed by a
read of a chipset register must stay ordered, because software starts DMA that way (store the buffer, then poke the
register -- the register poke is a synchronous store and already waits, but the conservative rule costs nothing).
Locked reads (TAS/CAS) and reads with translation off outside the RAM window are unchanged. The order checker
(`tb_sb_check.v`: no port read may pass a retired store that overlaps it) is exactly the invariant that must still hold,
and it must gain the rule that a RAM read MAY pass a non-overlapping posted store.

**Ceiling:** the 894 slot-wait clocks (scratch variant `rtl_zl3`: ZL2 + this rule; compat 22,319 -> 21,346 enabled clocks, -4.4 % on top of
ZL2, slot wait 1,170 -> 586 there; SoC: queued, `scratchpad/loadstore/soc_ls_zl3.log`; expected to recover most of the 894 slot-wait clocks, -5 to -7 %). The scratch variant trips `tb_sb_check.v` on every pass
("port read went with a retired store unwritten"), which is the checker doing its job on today's rule; the programs
themselves pass. The step includes teaching the checker the new rule (a RAM read may pass a posted store it does not
overlap) so that an overlapping pass still fails.

**Timing.** The compare feeds `go_rd`/`go_fifo` -> `mem_req`/`mem_addr` (the BCU's own output flops). `mem_addr`
is the endpoint of the BTB build's failing path (`eaf_o[cls] -> mem_addr`, 46 levels): that path is EA-fetch's
dispatch mux into the slot, not the slot-to-port mux; the new term adds one priority level to the latter. Check the
routed report for `mem_addr`/`mem_req` endpoints before the board.

**Tests.** `sb_order.s` (RAM then I/O: the I/O read must still wait), `sb_raw.s` (a read behind an overlapping
posted store still drains), a new `rdpass.s`: a misaligned read behind 4 non-overlapping posted stores (must go first,
checker green), the same with an aliasing store (`addr[11:2]` equal in another page: must wait), a read of the bench's
I/O register behind posted stores (must wait), translation on with the slot read's page cache-inhibited (must wait).
Mutants: no overlap check; I/O not excluded; aliasing ignored. Fuzz (its order checker catches a passed overlap).

### Step 3: misaligned reads served by the data read path (`AP040_DFP_MIS`)

7 of the 12 slow reads per run are the -m68000 Dhrystone's 2-aligned longwords (`$351a.l`, stack slots). Today a
misaligned longword/word is refused by the data read path (`dfp_ok_q` demands alignment), bypasses the cache on the
port (the cache serves only `fits_long` reads) and goes to the DDR3: 8 clocks on the port after step 2 has removed
the slot wait. MISPLIT split them into aligned port pieces and was known-bad on the board (I/O corruption, cause
open), so it is not the route; serving them from the cache COPY touches no port traffic at all.

**Design.** A misaligned read inside one 4K page is looked up as two consecutive longwords on the D-bank copy: the
first lookup as today, the second in the next clock on the same `dfp_*` port (the copy's BRAMs have one read port;
EA-fetch holds the read as it holds a slow one), both tag compares must hit the same line or two resident lines, no
collision in either clock, and the wrapper assembles the operand from a 64-bit window (`lw_extract` generalised).
The answer is taken in the third clock, through the registered `rd_ack` as today (no LDX for these). Store-order
rules unchanged (`lwo`/`sb_ovl` already compare both longwords of a misaligned access). A line-crossing or
page-crossing read, or one whose second lookup collides, falls back to the port.

**Ceiling:** 72 misaligned reads per 10 runs x (8 - 3) clocks = ~360 clocks (3 %) after step 2; ~720 (6 %) if step 2
is not built. Below the 3 % line only with step 2 in: build it after steps 1-2 and only if the SoC profile still
shows the misaligned reads at >= 3 %.

**Timing.** All in the wrapper and the cache copy (clk_38, the `dfp_*` family, which has slack: it ends in the BCU's
`rd_data` flop). Nothing on the stall chain.

**Tests.** `misalign.s`, `misplit.s` (as a correctness reference, MISPLIT=0), `t_dcache_pipe.s` misaligned cases,
a new `dfpmis.s`: every misalignment at a line end, a page end (must fall back), a snoop between the two lookups
(must fall back), a store to the second longword in flight (PRECISE must refuse), a word at `$...FFF`. Fuzz with
`gen.py`'s misaligned operands.

### Step 2b (Paul's side): the `m_*` write handshake

The store FIFO fills because `m_*` takes 4.5 clk_38 per write: TG68K's `ap040_ram_seq.vhd` raises `ack` only when
the RAM controller has acknowledged the unit (`u_ack`), and `x_ack_r` is then shaped onto the 1:3 clkena grid. The
core and the cache are idle most of that time (cache FSM busy 1.5 clocks per store). A deeper drain in the cache or
a deeper FIFO cannot help (ZL + SB_N=8: no gain; `m_*` is single-outstanding). What would: acknowledging a RAM write
on acceptance into the controller's write buffer (posting at the SoC level), or a second outstanding write. Both are
in `TG68K.vhd`/`ap040_ram_seq.vhd`/the controllers, shared with the reference core and Paul's, and both touch the
posting-into-SDRAM corruption that is still open (findings/storebuf/results.md) -- this plan only records the
measurement and the bound (-103 clocks per run, the copyback figure, for taking stores off the critical path).

### Step 4: re-measure the front end

With steps 1-3 in, rerun the BTB (`BTB=1`, core 8f99f5b's logic is on `cputest-fixes`) on the SoC Dhrystone: its
redirect clocks were hidden under the back-end waits this plan removes. If it now pays more than 3 %, its timing
problem (`eaf_o -> mem_addr`, 46 levels) becomes worth solving; otherwise it stays off.

## 7. What NOT to do, and why

- **Copyback on the board.** -8.5 % on the SoC bench, but `stage_cb1` crashes on the board and the cause is open
  (findings/copyback). Nothing in this plan replaces it: the store-hold row stays until copyback is stable or the
  `m_*` write handshake changes (step 2b).
- **Posting into the SDRAM / chip RAM with the MMU on** (`mem_postok` stays the DDR3 window): the stage-4 corruption
  cause is open (findings/storebuf/results.md). None of the steps here widens that window.
- **MISPLIT**: known-bad on the board (`stage_cu3`); step 3 serves misaligned reads from the cache copy instead of
  splitting them on the port.
- **The plain ZL form** (combinational `rd_ack` from the cache into EA-fetch's `stepf`): it is only a ceiling
  experiment; it would put the cache's tag compare on the stall chain.
- **A deeper store FIFO on its own**: measured, no gain.
- **Changing `TG68K.vhd`/`ap040_ram_seq.vhd`** for store throughput: Paul's files, shared with the reference core,
  and Q12 (the early acknowledge) is deferred by Paul until the plan is done.
- **Dropping the FPU** to buy LUTs for timing: never, per Paul.

## 8. Risks and open questions for Paul

1. **Timing budget.** `stage_cf3`'s clk_38 slack was as low as +0.089 ns. Step 1 adds a flop set in EA-fetch, a
   term in EX's stall and a mux at `eaf_o`'s input; it should be neutral on the known worst paths, but the tool's
   placement spread is about 1 ns. If `stage_ldx1` fails timing, the first thing to cut is the fault record
   (eligibility restricted to reads that cannot fault: fast-path hits only, which is what pays anyway, with a miss
   behind an LDX dispatch replayed through today's path -- a design variant that costs the miss case a few clocks).
2. **The access-error frame for a departed read**: the format $7 frame is built from EA-fetch's saved record while
   the faulting instruction's micro-op is in EX. Is a restart-model fault on an instruction that has left EA-fetch
   acceptable to you, or should LDX be limited to fast-path hits (no fault possible) from the start?
3. **The store port is yours**: the measurement says `m_*` write latency (4.5 clocks, single outstanding) is what
   fills the FIFO; nothing on the core side moves it. Do you want the write acknowledge on acceptance (SoC-level
   posting) looked at, given the open SDRAM/chip-RAM posting corruption? Until then the store-hold stays at ~15 %.
4. **The board figure vs the SoC**: the board is 7 % faster than the bench on the same switches. If the ceilings
   translate 1:1, step 1 alone takes xSysInfo from 1.01 to about 1.045 (34,450 Dhrystones); the full plan to roughly
   1.15-1.20 of an A4000/040 (0.76-0.80 of a 68040 per clock). Matching the 68040 per clock also needs copyback
   working on the board and the front end (BTB), which are outside this plan.
5. **Order**: step 1 (the hit latency; core-only, no new traffic pattern), step 2 (reads passing the FIFO; BCU-only,
   a new ordering rule the checker enforces), step 3 only if its ceiling still clears 3 % after the first two.

## 9. Reproducing the measurements

- Compat bench, Dhrystone, shipping switches, with the load/store probe:
  `scratchpad/loadstore/mk_compat.sh <rtl dir> <out dir>` (bash; builds `tb_ap040_pipe_compat.v tb_sb_check.v
  perf/tb_perf_compat.v $EXTRA` with `-DSTORE_BUF=1 -DFWD=1 -DRAS=1 -DPRECISE=1 -DSB_MMU=1`), then
  `run_compat.sh <out dir>` (`+prog=tb/build/dhry.hex`). `EXTRA=tb_ls_compat.v` adds the classification lines.
- Trace: add `tb/perf/tb_trace_compat.v`, run with `+trace=trace.txt`, keep clocks <= 23,480 (profile 0),
  `python3 tb/perf/trace_gaps.py trace_p0.txt tb/perf/dhry/dhry.bin 0`.
- Scratch RTL variants: `rtl_zl` (BCU `rd_ack` combinational for fast/forwarded answers, slot latch reordered),
  `rtl_zl2` (+ `zl_elig` from EA-fetch), `rtl_zl_sb8` / `rtl_zl2_sb8` (SB_N = 8), `rtl_zl3` (ZL2 + the slot read
  passing non-overlapping FIFO entries). SoC runs use
  `run_ddr3_dhry_ls.sh` (the real script plus `ls_probe_ddr3.sv` as a third top) with `PIPE_DIR=scratchpad/loadstore/pipe_<variant>`.
- SoC work directories: `sim/ddr3_cpu/run_perf_ls_base1`, `run_perf_ls_zl1`, `run_perf_ls_zl2`, `run_perf_ls_zl2_sb8`,
  `run_perf_ls_zl3`.
- The Dhrystone harness does not check its results (it only times the runs), so a ceiling variant's correctness is
  shown by the order checker (`tb_sb_check.v`, clean on ZL and ZL2) and by the compat bench's `+dump` of `$3000-$3FFF`
  (Dhrystone's globals) being identical to the baseline's: checked for ZL2 (2,176 words, identical; both runs
  `ALL TESTS PASSED` with the order checker clean).

## 10. Step 1 as implemented (2026-10-02, overnight)

Core branch `cputest-fixes`, parameter `LDX` (core) / `AP040_LDX` (compat wrapper) / `ap040_ldx`
(TG68K.vhd, both top levels) / `LDX=` (build_ap040.tcl) / `LDXF` (sim/ddr3_cpu) / `PIPE_LDX` (suite), all 0.

Differences from section 6's design, each for a reason:

- **One read in flight.** The next instruction's early read is NOT admitted in the dispatch clock
  (`use_early` still waits for the real `rd_ack`). The BCU slot, its latch order and its answer order are
  untouched: a departed read that turns out slow keeps the slot, and a second request would overwrite it.
  Cost: back-to-back loads keep one clock between them (compat: early reads 3,059 -> 2,557). This is the
  "step 1b" left: admitting that read needs either a two-deep slot or the fast verdict, which is the cache's
  tag compare, on the early-read control path.
- **EX's own store does not hold the departed read.** A load whose micro-op also stores (MOVE mem,mem,
  ADDQ to memory) deadlocked on a slow read: `go_rd` waited for `older_st`, which saw EX's micro-op -- the
  load's own, younger than its read. The core now leaves EX out of `older_st` while `ldx_busy && !rd_ack`
  (only for the BCU's port release; every issue-time check is unchanged).
- **MUL/DIV start on a real operand.** `md_start` waits for `!ld_wait` (a MUL from memory dispatched before a
  slow answer multiplied the provisional operand: X in the bus legs, `ldx.s` case 9).
- **MOVE to SR is not eligible** (its redirect's S bit comes from the operand while EX could still be waiting);
  `ex_redirect` is also gated by `ld_wait`.
- **Access error on a departed read**: taken in front of whatever EA-fetch holds, through the existing
  `aerr_st` path with the load's PC (`ldx_pc`) and an ordinary read's SSW; EX's micro-op is dropped.
  `berr_read.s` (bus legs) covers it: its first case is an eligible `move.l (a0)+,d0`.

Tests: `tb/pipe_asm/ldx.s` (14 cases; in the bus legs every load takes the slow path, so the rewrite and the
error path are what runs there; the compat bench and the SoC bench take the fast path), the whole suite with
`PIPE_LDX=1` in the shipping configuration, differential fuzz (60 seeds + 40 with interrupts), Dhrystone's
memory dump identical with and without LDX, mutants (`scratchpad/ldxmut`). Results: see the commit.

Measured (compat profile 0, shipping switches): 27,802 -> 27,153 clocks (-2.3 %), enabled 23,472 -> 22,823
(-2.8 %), data-read wait 4,401 -> 1,306; the ZL2 ceiling was 22,319. SoC: see the commit.

## 11. Re-measurement 2026-10-02: where the clocks go after copyback (per instruction)

Paul: copyback and LDX gave less than promised (board 1.02 -> 1.07; the copyback plan had said -15 to -25 %).
The copyback estimate was made against stage_cu4 (synchronous stores with the MMU on); store buffer stage 4 had
already taken most of that gain before copyback was built, and the estimate was never redone.  So: measure first.

Tool: `findings/ap040-pipelined/tests/perf/insprobe_ddr3.sv` (a PROBE top for `run_ddr3_dhry.sh`) charges every clock
of the perf window, in perf_probe.vh's buckets, to the next instruction to retire; `insprobe_report.py <run dir>`
sums them per PC and per instruction with the ELF's function names.  Runs (SoC bench, FREECORE STOREBUF=1 FWDRAS
PREMIS SBMMU MMUON, core b5cfdf4): `m1_wt` (write-through), `m1_cb5` (CBACK=1 = the board image stage_cb5),
`m1_cb5ldx` (CBACK=1 LDX=1).

| | clocks per Dhrystone run | vs the 68040's 762 |
|---|---:|---:|
| write-through (cu9 switches) | 1,210 | 1.59x |
| copyback (stage_cb5) | 1,110 | 1.46x |
| copyback + LDX | 1,044 | 1.37x |

Where the 282 clocks per run of copyback + LDX go (measured; buckets overlap a little, the ZL lesson of section 4):

| cause | clocks/run | evidence | fix | where |
|---|---:|---|---|---|
| forward branches guessed taken | ~80 | ID guesses EVERY Bcc taken (ap040_decode.v "guess taken"); 26.4 forward not-taken per run, the next instruction then costs 5.0 clocks instead of ~2 (strcmp's `bne.b` to its exit: `addq.l #1,a1` 5 clocks).  Forward taken: 4/run. | static backward-taken / forward-not-taken: ~-80 +12 = **~-68 (-6.5 %)** | core, ID, small |
| slow reads (misaligned globals and stack longwords: m68k gcc aligns int to 2) | ~85 | 5 per run at ~19 clocks (`add.l $410030ea.l,d0` 23, `cmpi.b #$40,$410030dc.l` 18, `movea.l $14(a7),a0` 17); the cache refuses a misaligned read and sends it to DDR3.  The 68040 does two cache accesses (+1 clock). | step 3 (AP040_DFP_MIS) + step 2 (RDPASS): **~-80 (-8 %)** | core + cache read path |
| store holds | ~59 | store misses write through (no write-allocate), e.g. `jsr (a4)` 21 clocks of which 19 store-hold | write-allocate (copyback S3) or the m_* write ack: ~-40 | cache / TG68K |
| load-use and EA-fetch -> EX bubbles not yet covered | ~40 | `move.b (a1),d0` after `addq.l #1,a1` 3.0; EA-fetch -> EX transit | early cache read (from EA-calc) | core, timing risk |
| multi-step (MOVEM, LINK/UNLK, JSR) | ~20 | MOVEM 10.8 clocks for 3 regs | - | the 68040 pays most of these |

Not a loss: taken branches cost 2 clocks (1 + the refill bubble), as on the 68040 (2); a correctly guessed not-taken
branch costs 1 (68040: 3).  strcpy's loop is 4 clocks per byte, the same as the 68040's.

If every fix delivered its full bucket: 1,044 -> ~850 clocks per run, 1.12x the 68040's clocks (0.9 of a 68040 per
clock).  Section 4's ZL run showed buckets do not add up fully; each step gets measured on its own.

### 11.1 BTFN (2026-10-02): measured, then on the board

Core 3ec6ad1 (AP040_BTFN; build switch BTFN=1).  SoC Dhrystone with copyback: 11,101 -> 10,195 clocks
(-8.2 %; the estimate above was -6.5 %); ID redirects 987 -> 683, EA-fetch corrections 286 -> 62.  Board
(stage_cb6 = rc1 + BTFN): xSysInfo 1.07 -> **1.17**, 35,166 -> **38,580** Dhrystones (+9.7 %).  Stable with
CopyBack off; the crashes seen on cb6 during disk activity came with CopyBack on the SDRAM Zorro III board (the
coarse copyback window, findings/copyback), not from BTFN: the same disk work with CopyBack off held.

### 11.2 LDX on the board (2026-10-03)

stage_r01ldx = release 0.1 (BTFN, write-through) + LDX=1: clk_38 +0.175 ns. Suite 323 pass with exactly these
switches. SoC Dhrystone (BTFN, write-through): 11,054 -> 10,651 clocks (-3.6 %). Board: xSysInfo 1.10 -> **1.13**, 36,256 -> **37,316** Dhrystones (+2.9 %; the -4 % of section 10 was
measured without BTFN -- the two partly remove the same bubbles). Heavy demos ran without a crash (Paul).
