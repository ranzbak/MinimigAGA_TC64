# Task 3 report -- route the AP68040 line-fill channel

**Status: DONE_WITH_CONCERNS.** All eight legs behave as required, the channel
carries 82 of 87 line fills, the phase times move consistently and by an amount
that reproduces exactly from the fill counts. Two things the brief could not
know changed the shape of the work and are the concerns: **the bench had never
enabled the 040's internal caches, so before this task it had never taken a
cache line fill at all**, and the brief's stated word order for `fill_data` is
the opposite of what the core wants. Both are evidenced below.

---

## 1. The fill handshake contract, as found in the code

Read before designing, from three independent places that agree.

### 1.1 The ports and the promise

`lib/AP68040/rtl/ap040_cache.v:93-108` -- the header comment *is* the contract:

```verilog
// Line-fill channel (A1).  When fill_ok says the line's physical
// address is served by a controller with a fill port, a miss raises
// fill_req with the line address and takes the whole line as one
// 128-bit payload -- longword at line offset 0 in [127:96], offset
// 12 in [31:0] -- under fill_ack, a LEVEL held until fill_req drops
// (the walker bridge's discipline: one toggle each way, payload
// stable until observed).  fill_err, held the same way, abandons the
// fill as m_err abandons an adapter fill.
input             fill_ok,
output reg        fill_req,
output     [31:4] fill_addr,
input     [127:0] fill_data,
input             fill_ack,
input             fill_err,
```

### 1.2 What the FSM actually does with them

| question | answer | evidence |
|---|---|---|
| when is `fill_req` raised? | in `C_LOOK`, on a miss, only when `FILL_CHANNEL != 0 && fill_ok`, and only after any posted store has drained (`dr_active` is checked first) | `ap040_cache.v:858-862` |
| is `fill_ack` a level or a pulse? | **a level, and it must be held until `fill_req` drops.** `C_FILLC` is inside `else if (ce)`, and `ce` here is `clkena_in` (the wrapper's duty-cycled enable, re-gated in submodule commit `c5d5cc3`). A pulse between enables is simply not seen. This is the same rule task 1 §2/§5 established for the bus16 adapter's `mem_ack` | `ap040_cache.v:867-885`, and the `else if (ce)` at `:591` |
| must `fill_data` be stable? | yes, in the cycle `fill_ack` is sampled: `fill_line <= fill_data` happens in that same cycle. Holding it until `fill_req` drops is the safe reading and is what the wrapper does | `ap040_cache.v:879-883` |
| does `fill_req` drop by itself? | yes -- `fill_req <= 0` in the accepting cycle, so the wrapper must watch for that to release its own ack | `ap040_cache.v:874, 880` |
| what does `fill_err` do? | **a bus error, not a fallback.** `fill_req <= 0; err_hold <= 1; cst <= C_FERR`. `C_FERR` invalidates the victim row through port B (`fill_err_inv`, `:516`, `:526`) and `err_hold` stops the still-asserted core request being re-accepted; the core faults. There is no retry over the adapter | `ap040_cache.v:874-878`, `C_FERR` at `:810` |
| word order inside `fill_data` | `fill_beat` drains `[127:96]` first at `r_beat == 0`, and `r_beat` counts up from 0 with `cd_widx = {r_bank, r_row, r_beat}` -- so **`[127:96]` is the longword at line offset 0** and `[31:0]` the one at offset 12 | `ap040_cache.v:416-419`, `:550-556` |
| how `fill_ok` is built | `(fill_ena_zorro & (cache_win & ~cache_chip \| cache_allow_all)) \| (fill_ena_chip & cache_chip)` -- so with `fill_ena_zorro = 1` and `fill_ena_chip = 0` the core asks only for Zorro-window lines, never chip ones | `ap040_tg68k_compat.v:413-414` |

### 1.3 The reference integration confirms the same word order

The author's own bridge assembles the controller's four ascending longword
beats with a left shift, offset 0 first:

```verilog
if (m_active && m_strb) m_line <= {m_line[95:0], m_dat};   // ap040_fill_cdc.v:144
m_resp_data <= m_strb ? {m_line[95:0], m_dat} : m_line;    // ap040_fill_cdc.v:148
```

After four beats the first one is in `[127:96]`. And `ddram_ctrl.v` on
`apol/ap040x3` feeds it `fill_dat <= {ram_dout[15:0], ram_dout[31:16]}` with the
comment "Longwords come out in 68k byte order" -- so the payload is 68k byte
order throughout, MS byte at the lowest address, exactly as the bus16 adapter
builds a longword (`rshift <= {rshift[15:0], data_in[15:0]}`,
`ap040_bus16_adapter.v:173`, first word = lower address = high half).

### 1.4 Where this contradicts the brief, and why I went with the code

The brief's ruling 2 says to assemble the 128 bits "in cpu_cache_new's word
order (see the ddr3_fastram.v header: word k at bits `[16k+15:16k]`, k = byte
offset/2)". **That is the opposite order to the one the cache requires.**
`ddr3_fastram.v:47-60` does say exactly that, but it is describing how
`ddr3_fastram` and `cpu_cache_new` pack a line *on the DDR3 side*, which the
fill router never touches: the router reads through the ordinary 16-bit CPU
port and never sees a 128-bit DDR3 word. In the cache's order the 16-bit word
at line offset `2k` belongs at bits `[127-16k : 112-16k]`, i.e. word `k` at
position `7-k` -- the reverse of the brief's parenthetical.

I did not stop to ask because the disagreement is settled by the code in three
places that agree with each other (`ap040_cache.v`'s header, its `fill_beat`
mux, and `ap040_fill_cdc.v`'s own assembly, which is the author's), and because
the brief itself asks for a mutant on exactly this: **`--fillmutant` implements
the brief's order and fails on the first fill** (section 4, leg 6). If the
brief's order had been right, that leg would have passed and this one would
have failed -- so the question is answered by measurement, not by my reading.

---

## 2. The design

### 2.1 Shape

`rtl/soc/TG68K.vhd:1163-1285` (comment block from `:1163`, process from `:1198`), a five-state FSM placed immediately after the
stage-B walker router and built as its twin: it borrows the wrapper's own
memory path through the same mux, so a fill word is indistinguishable from a
CPU data read to the decode, to `sdram_ctrl`, to `ddr3_fastram` and to the
7 MHz chipset FSM. No CDC (`ap040_fill_cdc.v` is deliberately not
instantiated -- one clock domain here, the same ruling as `ap040_walker_cdc`),
no new port on any controller, no change to `ddr3_fastram`'s CPU port.

| state | what it does |
|---|---|
| `FL_IDLE` | ack/err low, bus released. Starts when `fl_req = '1' AND wk_req = '0' AND wk_st = WK_IDLE AND state = "01"`: takes the bus (`fl_active`), puts the line address out with `fl_bstate` still `"01"` (select idle), word counter to 0 |
| `FL_DEC` | one cycle later the address has been on `cpuaddr` for a whole cycle. Checks the combinational decode `fl_ok`; if nothing answers there, release the bus and raise `fl_err`. Otherwise `fl_bstate <= "10"` and the select opens |
| `FL_SEL` | waits for `mem_ready`. On it: shift `datatg68` into `fl_line`, close the select (`fl_bstate <= "01"`), and either advance the word counter and the address, or (word 7) release the bus and raise `fl_ack` |
| `FL_GAP` | waits for `mem_ready` to fall -- the walker's `WK_GAP` rule, and for the same reason: `cpu_cache_new` clears `cpu_cache_ack` only when the select goes away (`cpu_cache_new.v:537`), so without it the next word completes on the previous one's stale level. Doubles as the next word's address setup cycle |
| `FL_DONE` | holds `fl_ack`/`fl_err` until `fl_req` drops, then clears `fl_busy` and goes idle |

### 2.2 How it drives the port, and the port contract

Per word: **address out with the select idle -> one idle cycle -> select
active -> ack -> select closed -> wait for the ack to clear.** Both controllers'
headers state the same rule -- "cpuAddr must be stable ONE CYCLE BEFORE
cpustate[2] goes low" (`sdram_ctrl.v:226`, `ddr3_fastram.v:20`) -- because each
registers `cpuAddr` into `cpuAddr_r` and it is `cpuAddr_r`, not the live
address, that addresses the memory on a miss. The router meets it exactly:
`fl_busaddr` changes at edge N (in `FL_SEL`, together with closing the select),
`FL_GAP` covers cycle N, and `fl_bstate <= "10"` lands at edge N+1, so
`cpuAddr_r` in cycle N+1 already holds the new address.

**Ruling 2 said "with the chip select held". I did not do that, deliberately.**
`cpu_cache_new` cannot serve back-to-back words that way: `cpu_cache_ack` is
cleared only by `!cpu_cs` (`cpu_cache_new.v:537`) and `cpu_dat_r` is a
free-running register that follows `cpu_adr` a cycle behind (`:294`), so with
the select held the acknowledge latches high and stops meaning anything, and
the only way to read the line would be an undocumented fixed pipeline that
also breaks the address/select contract of ruling 3 -- and the assertion ruling
3 asks for. The bench's SDRAM model agrees and needed no change: it clears
`ramready` on `ramcs_n` and sets it on the next `!ramcs_n` cycle
(`ddr3_cpu_tb.sv:508-590`), one word per select assertion, exactly the shape
the router drives. Rulings 2 and 3 are in conflict on this point; I followed 3,
because it is the one the controllers' own headers state and the one the bench
can check. The cost is measured in section 5 and the faster (contract-breaking)
alternative is written up there too.

### 2.3 Word order and ack semantics

```vhdl
fl_line   <= fl_line(111 downto 0) & datatg68;     -- TG68K.vhd:1252
```

Offset 0 first, shifted in from the right: after eight words the word at line
offset 0 is in `[127:112]` and the one at offset 14 in `[15:0]`, which is the
cache's layout of section 1.2 and bit for bit what `ap040_fill_cdc.v:144` does
with the controller's four longword beats.

`fl_ack` and `fl_err` are **levels held until `fl_req` drops** (`FL_DONE`), for
the reason task 1 §5 measured on `mem_ack`: the core consumes them under `ce`,
and `ce` here is a five-of-sixteen enable. `fl_line` is not touched while the
ack is up -- the FSM sits in `FL_DONE` -- so the payload is stable until
observed, which is the CDC bridge's other promise.

### 2.4 An address that decodes to nothing is auto-completed, not faulted

**This section as first written was wrong, and the review caught it. What
follows is the corrected design; the fix round at the end of this report has
the RED/GREEN evidence.**

`fl_ok` (`TG68K.vhd:610`) is `sel_ddr OR sel_z2ram OR sel_z3ram_sdram`: a Zorro
window that a RAM controller actually answers. It is **much narrower than the
core's cacheable Zorro windows**, and the first version of this report claimed
that did not matter because "the core should never ask for such an address".
That claim was false. `cache_z3_base0` is compared against `mm_addr[31:27]` --
a **128 MB** window, `$40000000-$47FFFFFF` -- and `cache_z3_base1` against
`mm_addr[31:28]`, a **256 MB** one (`ap040_tg68k_compat.v:397-401`), around
boards that are 16 or 32 MB. A cacheable read of a hole inside either -- past
the end of the DDR3 board, or where board 1 would sit if it were fitted -- is
ordinary reachable traffic, and the core raises `fill_req` for it.

Answering that with `fill_err` contradicted this SoC's own stated policy, four
lines above the port map that raised it: *"The SoC never raises a bus error:
undecoded 32-bit space is auto-completed with `$FFFF` by `sel_undecoded`"*
(`TG68K.vhd:773-775`). On the adapter path the same eight reads auto-complete;
the channel had made the same address fault.

So `FL_DEC`'s `fl_ok = '0'` arm is an **auto-complete** arm: the line is
answered as 128 bits of ones and acknowledged, with no bus transfer at all
(the bus is released in the same cycle). That is bit for bit what the eight
adapter reads it replaces returned. `fl_err` stays wired, and is now never
raised; the bench FAILs if it ever is.

Widening `fl_ok` to cover the whole cacheable window is **not** the
alternative -- it would hand the fill to a controller that cannot decode the
address.

What the wrong version actually did, measured (fix round, RED): the cache took
`C_FERR`, and the machine did not merely Guru -- **it stopped**. The bench's
68k program timed out at phase 7 with no fault reported, because `err_hold`
waits for the core to withdraw a request the core has no reason to withdraw.

`cpustate(6)` stays 0 (`longword_pair <= '0' WHEN use_ap040`, untouched) and
the router never sets it: every word is a plain 16-bit data read (ruling 7).

### 2.5 Walker ordering

Mutually exclusive by construction, with the walker given priority so the two
cannot both start in the same cycle:

* the walker's `WK_IDLE` now reads `IF wk_req = '1' AND fl_busy = '0'`;
* the fill's `FL_IDLE` requires `wk_req = '0' AND wk_st = WK_IDLE`.

A fill can therefore only start in a cycle where `wk_req` is low, which is
exactly the cycle the walker cannot start in, and vice versa. `fl_busy` (not
`fl_active`) is the walker's guard so that the walker cannot take the bus
during `FL_DONE` while `fl_ack` is holding `clkena` high -- that would break
the walker's own completion test, which is `clkena`.

The bench asserts it directly: `wk_active && fl_active` in any cycle is a FAIL.
**0 in every leg.**

### 2.6 The clkena term

```vhdl
clkena <= '1' WHEN (clkena_in = '1' AND (bstate = "01" OR bus_ready = '1' OR wk_ack = '1' OR wk_berr = '1'
                                         OR fl_ack = '1' OR fl_err = '1')) ELSE '0';   -- :1038
```

`fl_ack`/`fl_err` are the same deadlock guard `wk_ack`/`wk_berr` are, and here
they are load-bearing rather than belt and braces: the router holds `bstate` at
`"01"` only after it has released the bus, and the cache samples `fill_ack`
under `ce`. Without these terms a fill completing between enable pulses would
never be consumed -- a stalled machine with no fault, the failure shape that
cost a day in stage B. `clkena` is otherwise **not** suppressed during a fill,
per ruling 5; section 5 measures what that costs.

`sel_nmi_vector` gains `AND fl_active = '0'` for the walker's reason: a line
word that happens to sit at the NMI vector address is memory and must come from
memory, not from the vector shim.

### 2.7 cpu.xdc

**No change, and deliberately not the one ruling 8 suggests.** The ruling
offers "name it so the existing `addr*` filter catches it (or extend the
filter) ... say which". I did neither, because that filter grants a *two-cycle*
setup relaxation and `fl_busaddr` does not qualify:

* the relaxation on `$cpu_wrapper/addr*` and on `$tg68_kernel -> $tg68_mem`
  (`cpu.xdc:156-160`) is justified by launch stability -- those registers only
  change on a clock enable, so they hold for at least two cycles.
* `fl_busaddr` changes on the free clock, and `cpuAddr_r` inside the controller
  captures it on the **very next** cycle. Its minimum stable window is exactly
  two cycles (`FL_SEL` -> `FL_GAP` -> `FL_SEL`), so a `-start 2` setup exception
  would let the first capture -- the one the controller uses for the line
  address of word 0, the only word that can miss -- close on unsettled data.

So `fl_busaddr` is left timed single-cycle, which is what `wk_busaddr` already
is: the `addr*` filter is `NAME =~ .../addr*` and has never matched the walker's
address register either. The name `fl_busaddr` was chosen to sit next to
`wk_busaddr` and to *not* be caught by that filter.

The other half of ruling 8 -- "any free-running register you add must be
excluded from the kernel set" -- needs nothing: `$cpu_is_kernel` selects cells
under the two kernel instances only, so every new register here lands in
`$tg68_wrap`, which is a multicycle *destination* (`$tg68_kernel -> $tg68_wrap`,
3 cycles) and never a source. That relaxation is valid for the paths that
actually cross it: `fl_req` and `fl_addr` come from `ap040_cache` registers
that only move under `ce`, exactly as `wk_req`/`wk_addr` come from the MMU.

---

## 3. Bench changes

`sim/ddr3_cpu/ddr3_cpu_tb.sv`, `sim/ddr3_cpu/run.sh`,
`sim/ddr3_cpu/asm/ddr3_cpu_test.asm`, `sim/ddr3_cpu/asm/mmu_walk_test.asm`.

### 3.1 The finding that came first: the caches were never on

The first run of the new counters printed

```
INFO: cache line fills -- 0 over the channel, 0 down the adapter, 0 bus errors
```

Zero of **both** kinds. `ddr3_cpu_test.asm` wrote `move.l #3,d0 / movec d0,cacr`
-- the 68020 encoding, "enable both caches, as the OS does" -- and
`ap040_core.v:3352` is

```verilog
12'h002: cacr <= rf_rdata_a & 32'h8000_8000;
```

so on a 68040 only bit 31 (DE) and bit 15 (IE) survive, and `#3` leaves both
internal caches **off**. `ap040_tg68k_compat.v:421-422` wires `.ie(cacr_out[15])
.de(cacr_out[31])`. Every AP68040 run this bench has ever made -- including
task 1's six-leg gate and its phase-timestamp tables -- ran with no data and no
instruction cache, and therefore took no cache line fill of any kind. The fill
channel could not have been exercised at all.

Fixed the smallest way that leaves the TG68K control leg alone: the CACR value
is a `-DCACRVAL` assembler symbol defaulting to the historic `3`, and `run.sh`
passes `$80008003` when `CPU=ap040`. Both programs take it, so the MMU leg now
runs the first cached traffic this bench has ever put through a **translated**
address. Proof the TG68K leg is untouched: every phase timestamp in
`xsim_run_pass.log` is bit-identical to task 1's (section 5, last table).

### 3.2 Counters and assertions added

| addition | where | what it catches |
|---|---|---|
| `fill_ch` / `fill_ad` / `fill_be` | `ddr3_cpu_tb.sv:736-826`, printed in the summary | channel fills (`fl_busy` rising), adapter fills (`cst` entering `C_FILL = 4`), fills answered with `fl_err`. Read through cross-language hierarchical references -- `ddr3_cpu_tb.tg68k.fl_busy`, `...tg68k.g_ap040.ap040.g_cache.cache.cst` -- because a channel fill and eight ordinary word reads are indistinguishable at the wrapper's ports, which is the point of it |
| walker/fill mutual exclusion | same block | `wk_active && fl_active` in any cycle; counted and reported as a FAIL on the summary |
| **address/select contract, both ports** | `ddr3_cpu_tb.sv:694-734` | a chip select going active in the same cycle the address changed, on the SDRAM port and on the DDR3 port. This is ruling 3's assertion; task 4 has not landed, so it is written here. The plan's D1 note lists this rule as an untested hypothesis for a wrapper variant that would not boot and says to teach the bench it first |

### 3.3 Switches added to `run.sh`

* `--fillmutant` (**must fail**): one `sed`, the word assembly reversed to
  `fl_line <= datatg68 & fl_line(127 downto 16)`. That is not a straw man --
  it is precisely the layout `cpu_cache_new`/`ddr3_fastram` use internally and
  the one the brief's ruling 2 names, so it is the mistake actually available
  to make. The `sed` is verified to have matched, as the other mutants' are.
* `--nofill` (**must pass**): one `sed`, `fill_ena_zorro => '0'`. The A/B
  reference for the phase tables, not a mutant. It is needed because the
  wrapper's own task-1 state cannot serve as the reference -- it has no `fl_*`
  signals for the new counters to reference, so it will not elaborate against
  this bench.

### 3.4 What did not need changing

The behavioural SDRAM model already serves exactly the transaction shape the
router drives (one word per select assertion, level cleared by the select going
away). No change. The 5-vs-4 enable phase discrepancy the addendum warns about
is untouched: **the bench still pulses five enable phases while hardware pulses
four**, and every number below was taken as the bench is.

---

## 4. The eight legs

Run one at a time, from `sim/ddr3_cpu`, with
`LD_LIBRARY_PATH=<scratch>/shim`. `--mmu` was run first because it carried the
riskiest bench change (caches on under translation); everything else in the
brief's order, with the A/B reference inserted after `--ap040`.

| # | command | required | result -- summary line |
|---|---|---|---|
| 1 | `./run.sh --ap040` | PASS | **PASS** -- `DDR3 CPU TB: 2 passed, 0 failed`; `82 over the channel, 5 down the adapter, 0 bus errors` |
| 1b | `./run.sh --nofill` | PASS (A/B ref) | **PASS** -- `2 passed, 0 failed`; `0 over the channel, 87 down the adapter, 0 bus errors` |
| 2 | `./run.sh --ap040 --chipbus` | PASS | **PASS** -- `2 passed, 0 failed`; `8 over the channel, 5 down the adapter, 0 bus errors` |
| 3 | `./run.sh --mmu` | PASS | **PASS** -- `2 passed, 0 failed`; `4 over the channel, 2 down the adapter, 0 bus errors` |
| 3b | `PREB1=<nofill copy> ./run.sh --mmu` | PASS (A/B ref) | **PASS** -- `2 passed, 0 failed`; `0 over the channel, 6 down the adapter, 0 bus errors`.  It writes to the same `xsim_run_mmu_ap040.log`, so leg 3's log was saved and restored around it; this one is kept as `task3-baseline-logs/xsim_run_mmu_ap040_NOFILL_ab.log` |
| 4 | `./run.sh --lwmutant` | must FAIL | **failed as required** -- `DDR3 CPU TB: FAIL 1956 32-bit-write protocol violations on the RAM port`, `1 checks failed` (68k program itself PASSes, as its comment warns) |
| 5 | `./run.sh --mmumutant` | must FAIL | **failed as required** -- `FAIL the program stopped making progress (stall watchdog)`, last phase 2, `1 checks failed` |
| 6 | `./run.sh --fillmutant` | must FAIL | **failed as required** -- `DDR3 CPU TB: FAIL code 2 pattern read-back, BYTE load` at phase 2 plus `FAIL: DDR3 array contents wrong in 271 places`, `2 checks failed`. It dies on its **first** channel fill (`1 over the channel`) |
| 7 | `./run.sh` (TG68K control) | PASS | **PASS** -- `2 passed, 0 failed` |

Also, for the record, `tools/test_ap040.sh`: **ALL TESTS PASSED, 11/11**. The
submodule was not touched (`lib/AP68040` still at `c5d5cc3`, clean working
tree) -- see section 7.

**Zero** address/select contract violations and **zero** walker/fill overlaps in
any of the eight. The `--mmumutant` leg reports `0 over the channel, 0 down the
adapter` because its walk never completes, so the program never gets far enough
to touch cacheable memory -- that is consistent with the stall it is supposed
to produce, not a counter that stopped working (leg 3, the same program with
the walker working, reports 4 and 2).

---

## 5. Numbers

All times in microseconds **from CPU release** (64,389,167 ps in every run).
`clk_114` = 113.4375 MHz, one cycle = 8.8154 ns.

### 5.1 The A/B that isolates the channel -- pattern program, caches on both sides

One line of the port map differs (`fill_ena_zorro`). 82 of 87 line fills move
from the adapter to the channel.

| phase | `--nofill` | `--ap040` | delta |
|---|---|---|---|
| 1 | 10.402 | 10.402 | **0.000** |
| 2 | 408.611 | 408.611 | **0.000** |
| 3 | 1377.335 | 1361.503 | −15.832 (−1.149 %) |
| 4 | 1564.883 | 1549.086 | −15.796 (−1.009 %) |
| 5 | 1586.524 | 1570.163 | −16.361 (−1.031 %) |
| 7 | 1856.783 | 1836.561 | −20.222 (−1.089 %) |
| **8** | **1887.926** | **1867.696** | **−20.230 (−1.072 %)** |

The shape is the check on the mechanism, not just the sign: **phases 1 and 2
are bit-identical** -- that is the pattern *write* sweep, which takes no fills
because a store that misses allocates nothing (`ap040_cache.v:` `st_merge`
requires `look_hit`) -- and every phase after the first read-back moves by very
nearly the same absolute amount, which is what a fixed saving per fill looks
like.

**−20.230 us / 82 fills = 0.2467 us = 28.0 `clk_114` cycles removed per Zorro
line fill.**

### 5.2 The same A/B on the MMU program -- and the phase-6 row

Four fills only, and they are taken through translated addresses.

| phase | `--mmu` nofill | `--mmu` fill | delta |
|---|---|---|---|
| 1 | 12.773 | 12.773 | 0.000 |
| 2 | 620.937 | 620.937 | 0.000 |
| 3 | 625.133 | 625.133 | 0.000 |
| 4 | 631.313 | 631.057 | −0.256 |
| 5 | 641.811 | 640.736 | −1.075 |
| **6** | **656.762** | **655.686** | **−1.075 (−0.164 %)** |
| 7 | 668.574 | 667.507 | −1.067 |
| 8 | 672.135 | 671.060 | −1.075 |

**−1.075 us / 4 fills = 0.2688 us = 30.5 cycles per fill** -- an independent
programme, a different memory mix, and the same per-fill number to within 9 %.
That cross-check is the reason to believe the 28.

### 5.3 Against task 1's logs (the saved baseline)

Task 1's logs were copied to
`.superpowers/sdd/plan-v2-with-ddr3/task3-baseline-logs/` before the first run.
They are **not** a like-for-like reference for the channel, because they were
taken with the 040's internal caches off (section 3.1) -- but they do measure
what turning the caches on costs on these programs.

| leg | task 1 (caches OFF) | now, `--nofill` (caches on, adapter) | now, channel on |
|---|---|---|---|
| `--ap040` phase 8 | 1870.296 | 1887.926 (**+0.94 %**) | 1867.696 (**−0.14 %** vs task 1) |
| `--mmu` phase 6 | 615.437 | 656.762 (+6.7 %) | 655.686 |
| `--ap040 --chipbus` phase 8 | 847.245 | not run | 854.861 (+0.90 %) |
| `./run.sh` (TG68K) phases 1-8 | 2.133 / 118.377 / 469.002 / 543.136 / 552.304 / 644.262 / 657.097 | — | **identical to 12 significant figures** |

Two things to read out of that table.

**Turning the 040's caches on costs about 1 % on the pattern program, and 6.7 %
on the MMU one.** Not a defect: the pattern program sweeps a 1 kB region once
per phase and has almost no reuse, so the cache mostly adds a lookup cycle to
each access and fetches eight words where one to four were wanted; the MMU
program's phase 2 is a table build, i.e. a write sweep, where the same applies
and there are no reads to win it back. The channel gives that back and a little
more on the pattern program (−0.14 % net against task 1). It does **not** on
`--chipbus`, which is bound by the 7 MHz bus and takes only 8 fills.

**The TG68K control leg reproduces task 1 exactly**, which is the evidence that
the `-DCACRVAL` change reached only the AP68040 legs.

### 5.4 Why the whole-program figure is only 1 %, and what the next lever is

28 cycles a line is a real, reproducible saving -- roughly half the fill's own
bus time -- but this program takes 82 fills in 1.87 ms, so it is 1 % of the
program. Hardware is a different mix: the plan's own ILA measurement says 44 %
of clocks are stalled on memory and that tight loops that miss stall 62 %, and
Workbench is fetch-bound in a way this program is not. The bench can say what a
fill costs; it cannot say how often the machine takes one.

The measured next lever, in order:

1. **Suppress `clkena` while `fl_busy`** (keeping the `fl_ack`/`fl_err` terms).
   Today `FL_GAP` holds `bstate = "01"`, so a `clkena_in` pulse landing there
   reloads `slower` to `"0111"` and holds the next word's select off for three
   more cycles. At five enables in sixteen phases that is roughly one extra
   cycle per word, ~8 a line -- about a third again on top of the 28. The core
   has nothing to do during its own fill, so nothing is lost by holding it.
   Ruling 5 says `clkena` stays alive, so this was not done.
2. **A held-select burst** would get a line down to ~10 cycles instead of ~24,
   but it breaks the address/select contract of ruling 3 and depends on
   `cpu_cache_new`'s undocumented free-running `cpu_dat_r` (section 2.2). Not
   worth it without a controller-side change.

---

## 6. Concerns

1. **An instruction line now allocates in the external cache's data half.**
   The fill port carries no I/D bit -- not in this checkout and not upstream
   (`ddram_ctrl.v`'s fill port on `apol/ap040x3` has none either, because
   there is no second-level cache behind it there) -- so the router issues
   `bstate = "10"`, a data read, for every line. `cpu_cache_new` splits its
   16 kB into an 8 kB instruction half and an 8 kB data half by
   `cpu_ir`/`cpu_dr` (`sdram_ctrl.v:308-309`, `ddr3_fastram.v:263-264`),
   so AP68040 instruction lines that used to land in the I half now land in the
   D half. On this bench it does not show (phases 1-2 identical, everything
   else improves), but this bench is not fetch-bound. Exporting the cache's
   `c_instr` alongside `fill_req` is a one-line compat-top change and would let
   the router pick `"00"`; I did not make it because the brief says the
   submodule stays at `c5d5cc3` unless the handshake requires a change, and it
   does not. **This is the first thing to measure on hardware.**
2. **The bench's five enable phases against hardware's four** (addendum, task 4)
   are untouched and every number here was taken at five. The router does not
   depend on the cadence -- it paces on `mem_ready`, not on `clkena` -- so it
   should if anything do slightly *better* at four, where `slower` reloads less
   often relative to the fill. Unverified.
3. **The task-1 phase tables in the plan doc were measured with the 040's
   caches off** and should be read that way from now on. Nothing in them is
   wrong; they just do not measure what "the x3 cache" does, because there was
   no cache. Section 5.3 gives the caches-on numbers for the same legs.
4. **`--chipbus` is 0.90 % slower than task 1** and I did not run a
   `--chipbus --nofill` A/B to prove it is the caches-on cost rather than the
   channel. The reasons to believe it is: only 8 of its 13 fills go over the
   channel, the same +0.94 % appears on the turbo-chip leg where the A/B *was*
   run, and its phases 1-5 are within 0.1 % of task 1 with all of the movement
   in phase 7-8, the Exec-List relocation in chip RAM -- which is where the
   D-cache newly caches a 7 MHz window. An extra leg would settle it.
5. **The fill router's start guard tests `state = "01"`, and the bench cannot
   see `state`** (it is inside the wrapper, and the tb sees only the muxed
   `bstate`). The guard is belt and braces -- the cache is in `C_FILLC` and has
   nothing outstanding through the adapter when `fill_req` is up -- but if it
   were ever false the symptom would be a stalled fill, which the stall
   watchdog catches, rather than a lost access. A hierarchical assertion on it
   would be cheap to add if this is ever suspected.
6. **Nothing was built.** No bitstream in this task (task 5), so the `cpu.xdc`
   reasoning of section 2.7 is argued, not measured. The claim to check at the
   next build is that no new failing endpoint appears from `fl_busaddr` into
   the memory side.

---

## 7. Files changed, commits

Superproject, one commit on `v5.0`:

* `rtl/soc/TG68K.vhd` -- the fill router, the bus mux, the `fl_ok` decode, the
  `clkena` and `sel_nmi_vector` terms, the walker's `fl_busy` guard, the
  `fill_*` port map and the TG68K tie-off.
* `sim/ddr3_cpu/ddr3_cpu_tb.sv` -- fill counters, walker/fill exclusion
  assertion, address/select contract assertion, summary lines.
* `sim/ddr3_cpu/run.sh` -- `--fillmutant`, `--nofill`, `-DCACRVAL`.
* `sim/ddr3_cpu/asm/ddr3_cpu_test.asm`, `sim/ddr3_cpu/asm/mmu_walk_test.asm` --
  the CACR value as a define; the MMU program gains the `movec` it never had.
* `findings/ap68040/plan-v2-with-ddr3.md` -- five Numbers rows and a Log
  paragraph.

**`lib/AP68040` is untouched**, still at `c5d5cc3` with a clean working tree:
the handshake needed no compat-top change. The one change that would have been
worth making (concern 1, an I/D bit on the fill port) is not required by the
contract and is left as a measurement to take first.

Staged by explicit path, never `git add -A`. Paul's pre-existing edits are
untouched: `fw/ctrl_832/version.h`, `sim/hostcpu-i2c-bridge/*.wcfg`,
`tools/vivado/ila_fastram_check.py`, and every untracked file. The
`sim/ddr3_cpu/xsim_run_*.log` files were rewritten by the runs and are
deliberately **left uncommitted**, as task 1 left them; task 1's copies are
saved at `.superpowers/sdd/plan-v2-with-ddr3/task3-baseline-logs/`.

---

## 8. Self-review

* **Completeness.** Every brief bullet. Handshake contract stated from the code
  before designing (section 1) with the reference integration read (1.3). FSM
  per the rulings, with the two deviations named and argued (2.2 select held;
  2.7 cpu.xdc). `fill_ena_zorro = '1'`, `fill_ena_chip = '0'` as ruled. Walker
  ordering asserted in the bench, 0 violations. `clkena` term added. Decode
  misses -> `fill_err`. `cpustate(6)`/`longword_pair` untouched. `--fillmutant`
  fails on the summary line. Phase times moved, consistently, with the
  per-fill saving cross-checked on a second program. Plan doc row and Log
  paragraph written. Addendum: nothing from `ap040_fill_cdc.v` is instantiated,
  so the `project_1.xpr` source-list item needs no action; the five-vs-four
  enable phases are noted (3.4, concern 2).
* **Quality.** The router follows the walker's structure, naming and comment
  style deliberately -- `fl_*` beside `wk_*`, the same reset process shape, the
  same `WK_GAP`/`FL_GAP` reasoning written out. Comments say *why*: the
  address/select contract, why the ack is a level, why chip lines stay on the
  adapter, why the two masters cannot both start.
* **Discipline.** Nothing beyond the brief in the RTL. The walker and the
  decode are not restructured -- the walker gains four words in one condition
  and nothing else. The bench grew more than planned, but every addition is one
  the brief asked for except `--nofill`, which exists only because the honest
  A/B was otherwise impossible.
* **Testing.** Output pristine: no new elaboration warnings (the only ones are
  the pre-existing `ddr_ready` forward references in the tb and the akiko
  `req` port note). Every number in section 5 is reproducible from the logs
  named in section 4 by subtracting 64,389,167 ps.

---

# Fix round 1: an undecoded fill must auto-complete, not bus-error

**Status: DONE.** The review's Important finding is real, is worse on the
machine than the review predicted, and is fixed. Three covering legs green.

## F1. The finding

`fl_ok` decodes the 16 MB DDR3 board (and the ZII/ZIII SDRAM boards). The
core's cacheable Zorro windows are `mm_addr[31:27]` and `mm_addr[31:28]` --
128 MB and 256 MB (`ap040_tg68k_compat.v:397-401`) -- so a cacheable read of a
hole inside one raises `fill_req` at an address `fl_ok` rejects. My `FL_DEC`
answered it with `fl_err`; the SoC's stated policy, four lines above the port
map, is to auto-complete such an address with `$FFFF`
(`TG68K.vhd:773-775`, `sel_undecoded`). Report §2.4's claim that the core
cannot ask for such an address was false, and the port-map comment mis-sized
`cache_z3_base0`'s window as 32 MB when it is 128 MB. Section 2.4 above is
rewritten.

## F2. What changed

`rtl/soc/TG68K.vhd`

* **`FL_DEC`'s error arm is now an auto-complete arm**: `fl_line <= (others =>
  '1'); fl_ack <= '1'`, bus released in the same cycle, no transfer. `fl_err`
  is still wired and is now never raised -- said so at its declaration, at the
  `clkena` term and in the FSM header.
* the port-map comment's window sizes corrected to `$40000000-$47FFFFFF`
  (128 MB) and 256 MB, with a pointer to `fl_ok`;
* `fl_ok`'s comment rewritten: why it is deliberately narrower than the
  windows, why the answer is `$FFFF` and not a fault, and why widening it is
  not the alternative (it would hand the fill to a controller that cannot
  decode the address);
* the FSM header carries the RED measurement below, so the next person does
  not re-derive it.

`sim/ddr3_cpu/asm/ddr3_cpu_test.asm`

* `UNDECODED equ $42000000` -- longword-aligned, inside `cache_z3_base1`'s
  cacheable window (base `$41`, so all of `$4xxxxxxx`) and decoded by no board
  in this bench: board 3 is 16 MB at `$41000000`, boards 1 and 2 are disabled
  (`ziiiram_active`/`ziiiram2_active` = 0). Picked from the bench's own decode
  rather than the review's `$41000000`, which in this bench **is** the DDR3
  board.
* one `move.l UNDECODED,d3` checked against `$FFFFFFFF`, new failure code 14.
  No phase marker, so the phase numbering does not shift; it sits just before
  the phase-8 marker, which is therefore the one timestamp it moves.

`sim/ddr3_cpu/ddr3_cpu_tb.sv`

* `fill_und` counter -- channel fills whose address decoded to nothing, taken
  by sampling `fl_ok` in the `FL_DEC` cycle (the cycle after `fl_busy` rises);
* **FAIL if `fill_be != 0`** -- a fill answered with a bus error, which this
  SoC never raises;
* **FAIL if the pattern program ran with the channel in use and `fill_und` is
  0** -- i.e. the undecoded read did not take a channel fill. Gated on
  `!mmutest` (the MMU program does not read it) and on `fill_ch != 0` (with
  `--nofill` it is eight adapter reads and there is nothing here to check);
* failure code 14 named in the status decode.

## F3. RED, on the committed code (fb71459), reduced sizes

`PATBYTES=64 MISLINES=2 CNTN=8 ./run.sh --ap040`

```
DDR3 CPU TB: FAIL  the 68k program never wrote the mailbox (timeout)
       last phase reached: 7
INFO: cache line fills -- 9 over the channel (1 of them undecoded, auto-completed), 5 down the adapter, 1 bus errors
DDR3 CPU TB: FAIL  1 line fills answered with a bus error; this SoC auto-completes
       an address that decodes to nothing with $FFFF and never raises one
DDR3 CPU TB: 2 checks failed
```

**Worse than the review predicted.** The expectation was an access fault --
status 99 through the program's `EXCEPT` handler. What actually happens is
that the machine **stops**: `C_FERR` sets `err_hold`, which waits for the core
to withdraw a request the core has no reason to withdraw, and the program
times out at phase 7 having reported no fault at all. On hardware that is a
black screen with nothing to look at, in a window the OS reaches as soon as it
touches memory past the end of the board.

(The counter says "1 of them undecoded" on the RED run too: it samples the
`FL_DEC` decision, which is the same on both arms, so it measures the traffic
rather than the answer.)

## F4. GREEN -- the three covering legs, one at a time

| # | command | required | result -- summary line |
|---|---|---|---|
| 1 | `./run.sh --ap040` | PASS | **PASS** -- `DDR3 CPU TB: 2 passed, 0 failed`; `83 over the channel (1 of them undecoded, auto-completed), 5 down the adapter, 0 bus errors` |
| 2 | `./run.sh --fillmutant` | must FAIL | **failed as required** -- `DDR3 CPU TB: FAIL code 2 pattern read-back, BYTE load`, `3 checks failed` |
| 3 | `./run.sh --mmu` | PASS | **PASS** -- `2 passed, 0 failed`; `4 over the channel (0 of them undecoded), 2 down the adapter, 0 bus errors` |

The TG68K control was not re-run: the change is inside `g_ap040`'s fill router
and the program's new check is guarded by nothing the TG68K reaches
differently -- and its own leg took no line fills at all before or after.

`--fillmutant` now reports **three** failures rather than two. The third is
the new undecoded-hole check, and it is a true consequence, not a spurious
one: the mutant dies of failure code 2 at phase 2, long before the undecoded
read at the end of the program, so the read genuinely never happens. The
primary failure is unchanged.

## F5. The phase tables above still stand

* **`--mmu`: all eight phase timestamps bit-identical** to the pre-fix run, so
  §5.2 -- including the phase-6 A/B row, 656.762 -> 655.686 us -- is unchanged.
* **`--ap040`: phases 1 to 7 bit-identical**; phase 8 moves 1932.085 ->
  1933.213 us, **+1.128 us**, which is the new undecoded read (one channel
  fill plus the instructions around it, itself an instruction-fetch miss)
  sitting just before that marker. §5.1's A/B table was measured on both sides
  with the program that did not contain the check and is left as it was; the
  per-fill figure of 28.0 `clk_114` cycles is unaffected.
* Channel fills go 82 -> **83**: the one new undecoded fill.

## F6. Commit

`5a20f8e` -- `rtl/soc/TG68K.vhd`, `sim/ddr3_cpu/ddr3_cpu_tb.sv`,
`sim/ddr3_cpu/asm/ddr3_cpu_test.asm`. Staged by explicit path; `lib/AP68040`
still untouched at `c5d5cc3`; Paul's pre-existing edits and untracked files
untouched; the `xsim_run_*.log` files left uncommitted as before.

## F7. Self-review of the fix

* The auto-complete arm needs no bus cycle, so it cannot interact with the
  walker, the `slower` throttle or the chipset FSM: `fl_active` goes low in
  the same cycle it goes to `FL_DONE`.
* `fl_err` is now dead logic and will fold to a constant 0 in synthesis. Left
  in place deliberately, per the ruling, with three comments saying it is
  reserved for a case that cannot occur.
* The new check is one 68k longword read, so it costs one line fill; it is
  placed where it cannot renumber a phase.
* The RED was run at reduced region sizes (12 min instead of 22) because the
  new check is independent of them; the GREEN legs are all at full size.

---

# Fix round 2: the four acknowledge terms come back off clkena

**Status: DONE.** The invariant was checked before the terms were removed, not
after; it holds, so no NEEDS_CONTEXT. Four covering legs green, and the two
passing ones reproduce the previous run's phase timestamps to the picosecond
-- which is what "redundant" should look like.

## G1. The finding (from the ship build, not a reviewer)

`build/stage_ap040_x3fill2` (ila = 0) had **10 failing `clk_114` endpoints**
against `stage_ap040_x3`'s 2. Seven are new, all starting at
`tg68k/fl_active_reg`, running through the `clkena` expression -- 10 LUT
levels, 7.2 ns of routing on an 8.7 ns path -- and ending on kernel clock
enable pins: the FPU's `acc_hi_reg[*]/CE` (−0.004 to −0.030 ns) and
`mmu/atc_v_reg[*]/D` (−0.015 to −0.120 ns). Full list in
`build/stage_ap040_x3fill2/violators.rpt`.

`clkena` is the CE of 7,391 kernel flops and is the plan's "Timing" item 1.
The fill router had added two terms to it (`fl_ack`, `fl_err`) on top of the
walker's two (`wk_ack`, `wk_berr`). All four are gone.

## G2. The invariant, verified before removing anything

> In every cycle in which the walker or the line fill holds its acknowledge or
> its bus error, it has already released the bus and the core's own bus side
> is idle -- so `bstate` is `"01"` and `clkena`'s first term enables the core
> anyway.

**Released.** Every state that raises an acknowledge clears its own `*_active`
in the *same* assignment, and the holding states keep it clear:

| state | raises | `*_active` in that assignment |
|---|---|---|
| `WK_IDLE`, misaligned descriptor | `wk_berr` | `wk_active <= '0'` at the top of the branch |
| `WK_HI` / `WK_LO`, `sel_undecoded` | `wk_berr` | `wk_active <= '0'` |
| `WK_LO`, completion | `wk_ack` | `wk_active <= '0'` |
| `WK_DONE` | holds | stays `'0'` |
| `FL_DEC`, auto-complete arm | `fl_ack` | `fl_active <= '0'` |
| `FL_SEL`, last word | `fl_ack` | `fl_active <= '0'` |
| `FL_DONE` | holds | stays `'0'` |

and the two routers cannot overlap (§2.5), so with both `*_active` low
`bstate` **is** the core's `busstate`.

**Idle.** The core is waiting for that very answer and has nothing outstanding
through the bus16 adapter: the MMU is mid-walk, or the cache is parked in
`C_FILLC`. The one case that could have broken this -- a posted store draining
through the adapter *underneath* a table walk, which would leave `busstate`
non-idle while `wk_ack` is up -- is closed inside the core:
`ap040_mmu.v:478` refuses to start a table search when `walk_hold` is high,
`walk_hold` is `post_busy` (`ap040_tg68k_compat.v:297`), and `post_busy` is
`st_posted | dr_active` (`ap040_cache.v:362`). That was checked first, because
it is the one thing that would have made this a NEEDS_CONTEXT.

## G3. What changed

`rtl/soc/TG68K.vhd`

```vhdl
clkena <= '1' WHEN (clkena_in = '1' AND (bstate = "01" OR bus_ready = '1')) ELSE '0';
```

Four terms dropped. The comment block above it is rewritten: what the net is,
what it cost, the invariant in full, both halves of why it holds with the
`walk_hold` citation, and a pointer to the bench that checks it. The
`fl_active`/`wk_active` muxing is untouched, as ruled; so are `slower`, the
cadence and everything else in the region.

`sim/ddr3_cpu/ddr3_cpu_tb.sv` -- the invariant asserted directly, from
`cpustate` (which carries `bstate` in `[1:0]` and `clkena` in `[5]`) and the
four acknowledge signals:

* `ack_idle_errs` -- an acknowledge held in a cycle where `bstate` is not
  `"01"`. This is the half that makes the removal safe.
* `ack_dry_errs` -- an acknowledge that dropped without the CPU having been
  enabled once while it was up. A hang would already trip the stall watchdog;
  this names the cause rather than leaving a timeout to be diagnosed.

Both are FAILs on the summary line.

## G4. Would it have passed on the old code? Measured: yes.

`PATBYTES=64 MISLINES=2 CNTN=8 PREB1=<TG68K.vhd from 5a20f8e> ./run.sh --ap040`
-- the *previous* wrapper, four terms still in, new assertions active:

```
DDR3 CPU TB: PASS  (68k program completed all phases)
INFO: cache line fills -- 9 over the channel (1 of them undecoded, auto-completed), 5 down the adapter, 0 bus errors
DDR3 CPU TB: 2 passed, 0 failed
```

**Both assertions pass on the old code**, and that is the point rather than a
weakness: they are properties of the two routers, which this change did not
touch. An assertion that only passed after the change would be describing the
`clkena` expression, not the invariant that licenses it. What makes the four
terms redundant is exactly that the invariant already held while they were
there.

## G5. The four covering legs, one at a time

| # | command | required | result -- summary line |
|---|---|---|---|
| 1 | `./run.sh --ap040` | PASS | **PASS** -- `2 passed, 0 failed`; `83 over the channel (1 of them undecoded, auto-completed), 5 down the adapter, 0 bus errors` |
| 2 | `./run.sh --mmu` | PASS | **PASS** -- `2 passed, 0 failed`; `4 over the channel (0 undecoded), 2 down the adapter, 0 bus errors` |
| 3 | `./run.sh --mmumutant` | must FAIL | **failed as required** -- `FAIL the program stopped making progress (stall watchdog)`, last phase 2, `1 checks failed` |
| 4 | `./run.sh --fillmutant` | must FAIL | **failed as required** -- `FAIL code 2 pattern read-back, BYTE load`, `3 checks failed` |

Zero `ack_idle_errs` and zero `ack_dry_errs` in all four. The TG68K control was
skipped as instructed: `wk_ack`, `wk_berr`, `fl_ack` and `fl_err` are all
constant `'0'` in the `g_tg68k` branch, so the expression it sees is unchanged
after constant folding.

`--mmumutant` is worth one line: it ties `walker_ack` low, so no acknowledge is
ever raised and the new checks have nothing to look at -- they correctly stay
silent, and the leg fails on the stall watchdog exactly as before.

## G6. The change is behaviourally invisible, and that was measured

* `--ap040`: **all seven phase timestamps bit-identical** to the fix-round-1
  run (74.79 / 473.00 / 1425.89 / 1613.48 / 1634.55 / 1900.95 / 1933.21 us),
  same 83 channel fills, same 5 adapter fills.
* `--mmu`: **all eight phase timestamps bit-identical**, same 4 channel fills.

Every number in §5 therefore still stands unchanged. Nothing in this round
touched the fill router's own behaviour -- only the enable expression it used
to feed.

## G7. Commit

`727e4f4` -- `rtl/soc/TG68K.vhd`, `sim/ddr3_cpu/ddr3_cpu_tb.sv`. Staged by
explicit path; `lib/AP68040` untouched at `c5d5cc3`; Paul's pre-existing edits
and untracked files untouched; the `xsim_run_*.log` files left uncommitted as
before. The controller rebuilds.

## G8. Concern carried forward

The seven violating paths all *start* at `fl_active_reg`, and `fl_active` still
drives the `bstate`/`buds`/`blds`/`bwr`/`cpuaddr` mux, so it still reaches
`bstate` and through it `clkena`. Removing the four terms takes the routers'
acknowledges off that net but not `fl_active` itself -- the remaining path is
`fl_active -> bstate -> clkena`, which the walker's `wk_active` has always had
too. Whether that alone closes the seven endpoints is the rebuild's answer, not
mine. If it does not, the next lever is registering the enable, which is the
plan's own mitigation for "Timing" item 1 and belongs with Task 4's region
rather than here.
