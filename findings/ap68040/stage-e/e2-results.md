# Stage E2 — results

Running record for [2026-09-15-e2-plan.md](2026-09-15-e2-plan.md), branch
`stage-e`. Each task appends one row from `tools/complexity_report.sh` and the
bench legs it ran.

## Complexity budget

"Code" counts exclude blank lines and full-line comments.

- **Posted-write paths** now counts both paths the spec §2 table names: the
  040's `POST_STORES`, and `cpu_cache_new`'s write buffer, which acknowledges a
  write before the SDRAM write is issued (`cpu_cache_new.v:318–327`). E4a's
  rows printed 1 and undercounted by that second path; the hardware did not
  change.
- **RAM width conversions** is `32-16-32` while `sdram_ctrl` still has the
  16-bit CPU port that the bus16 adapter feeds, and 0 once it takes the unit
  port.
- **Handshake signals** counts which of the spec §2 enable/handshake signals
  (`clkena_r`, `slower`, `bus_step`, `bus_fresh`, `cpu_phase_ok`, `datatg68_r`,
  `mem_ready`, `cpu_bus_settled`) are still in the wrapper. `datatg68_r` is
  counted although nothing reads it (see e4a-results.md, "`datatg68_r` never
  reached the AP68040"); E2 Task 1 deletes it.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes | RAM width conversions | handshake signals |
|---|---|---|---|---|---|---|---|---|---|---|---|
| d3_stable | 2138 | 1029 | 727 | 591 | 2 | 6 | 1 | 15 | dbg_phist dbg_snoop | 32-16-32 | 8 |
| stage-e 971119d (hardware = `stage_ap040_e4a`) | 1934 | 917 | 695 | 587 | 2 | 0 | 0 | 0 | dbg_phist dbg_rtg | 32-16-32 | 8 |

The `e4a` tag waits for Paul's hardware test; 971119d differs from the
`stage_ap040_e4a` build sources only in `sim/`, `tools/` and `findings/`.

## Tasks

### Task 0 — complexity report columns

Two columns added and the posted-write count corrected, as above. Both rows
taken with the new script: `d3_stable` from a scratch `git archive` of the three
files it reads.

### Task 2 — port sweep in `sim/sdram_coherency` (on today's 16-bit port)

New in `sdram_coherency_tb.v`: `cpu_write_bs` (a word cycle with explicit byte
selects), `cpu_access` (a B/W/L request at a byte address, split onto the
16-bit port exactly as `ap040_bus16_adapter.v` splits it), and `port_sweep`,
run by the CPU sequencer through a mailbox (the bench's one-owner-per-port
rule). For each size at each of the 16 offsets of one line, in a CPU-only
window (`W_SWP`, word address $010000): write a pattern unique to (size,
offset, byte), read it back with the same size, then read the eight
surrounding bytes one at a time against a golden copy. 3 × 16 × 9 = 432 checks.
`+sweep` runs it before the rounds; `+sweepmut` makes single-byte reads take
the wrong half of the word. Without either plusarg the bench is unchanged.

| leg | result |
|---|---|
| `./run.sh fast sg7 +nobg +sweep +rounds=1` | **port sweep: 432 checked, 0 failed** (the one other failure is the known "C2P line buffer primed", 1 of 1 round) |
| `./run.sh fast sg7 +nobg +sweepmut +rounds=1` | **416 of 432 failed**: the check has teeth. The 16 that pass are the read-backs of W and L at the eight even offsets, which are whole-word cycles with no single-byte read for the mutant to corrupt |
| `./run.sh fast sg7 +nobg +rounds=50` | 52 errors, 0 timeouts; every category = E4a reference (line buffer 50, longword 2) |
| `./run.sh fast sg7 +rounds=50` | 14 errors, 0 timeouts; every category = E4a reference (P2C 4 late 0 lost, longword 10, 3552 background reads 0 failed) |

The sweep is the test Task 3's unit port must pass unchanged (with
`cpu_access` switched to the unit split table).

### Task 1 — the adapter moves into the wrapper: bit-exact

Done in a scratchpad worktree and kept on local branches, because it implements
D1's recommendation and Paul has not answered D1. `ap040_tg68k_compat.v` gains
`AP040_BUS16` (default 1) and the `m_*` master channel; with `AP040_BUS16 => 0`
the wrapper instantiates `ap040_bus16_adapter` itself, on the same clock, the
same enable and the same connections. The dead `datatg68_r` and its paragraph
go with it.

Every leg run **one at a time** (the concurrent-run trap above). All twelve
match the E4a Task 6 suite exactly:

| leg | result | E4a reference |
|---|---|---|
| `--ap040` | phase 8 at 1677190382 ps | same |
| `--mmu` | 707928242 ps | same |
| `--ap040 --chipbus` | 937021277 ps | same |
| `--nofill` | 1694291482 ps | same |
| `--snoop` | 1762554842 ps | same |
| `REALSDRAM=1 --ap040` | placement 1953 / 78 off | same |
| busy leg | **identical to `ref/overlap_gate3.txt`** | same |
| `--lwmutant` | 2021 protocol violations | same |
| `--mmumutant` | stall watchdog | same |
| `--fillmutant` | 3 checks failed | same |
| `--snoopmutant` | 14890 of 22340, 7295 out of order | same |
| `REALSDRAM=1 --gatemutant` | 1862 of 1972 off the grid | same |

Analysis clean (`xvlog` on the compat top and the adapter, `xvhdl` on the
wrapper). Handshake signals drop 8 → 7 with `datatg68_r` gone.

### Task 4a — the unit splitter as its own entity, with its own bench

Task 4 rewrites the wrapper in one pass, and the bench that would judge it
(`sim/ddr3_cpu`) is deleted and rebuilt in the same step -- so the riskiest
part of it, the split table, would have had no verdict until the very end.
It is now `rtl/soc/ap040_ram_seq.vhd`, a standalone entity with
`sim/ram_seq/`, and it is green before the wrapper is touched.

**The split table is superseded.** Instead of encoding D3's hand-written
table, `ram_seq` walks the operand's byte range and takes, each step, as many
bytes as fit in BOTH the current two-word window AND the current 16-byte
line. "No unit crosses a line" becomes a property of the arithmetic rather
than a table entry that can be mistyped -- and it is cheaper than the table:
a longword at an odd offset takes TWO units (offset 1 -> bytes 1..3 as
`bs=0111`, then byte 4), not the table's byte+word+byte. The worst case
anywhere is two units.

The unit count confirms the derivation arithmetically. Per sweep: byte 16
units; word 15x1 plus offset-15 x2 = 17; long 7 even singles plus offset-14
x2 plus 8 odd x2 = 25. That is 58, doubled for write+read = **116**, which is
exactly what the bench counts.

| leg | result |
|---|---|
| `./run.sh open` (gate held open) | **144 checked, 0 failed, 0 line crossings, 116 units, max 2 per access** |
| `./run.sh gated` (gate open 1 cycle in 4, the D3 grid shape) | identical: 144 / 0 / 0 / 116 / max 2 |
| `./run.sh mutant` (`line_mutant=1` drops the line limit) | **6 line crossings at word 39**, units 116 -> 112. MUST fail, and does |

Note what the mutant does NOT catch: its data checks still report 0 failed,
because the behavioural memory has no concept of a line and a crossing unit
still lands the right bytes in it. The teeth are entirely in the explicit
crossing assertion inside the memory model. That is the point -- in the real
controller the same unit corrupts a DIFFERENT line, which is how this failed
in Task 3: every functional check passed while the DDR3 backdoor showed 26
mismatches exactly one 16-byte line apart.

Two bench faults were caught by the tools before they could mislead, both of
them mine: `access` is a VHDL reserved word, and `mem` then `units_here` each
had two drivers. The `units_here` one is worth remembering -- an unresolved
integer with two drivers fails elaboration outright, but `mem` is an array of
a RESOLVED type, where a second driver silently resolves to 'X' and would
have looked like a DUT fault.

### Task 4b-1 — the fill router is deleted

Task 4b is the wrapper restructure, and it splits once more. The walker
cannot move on its own: it reaches memory THROUGH the 16-bit bus signals
(`wk_bstate`/`wk_busaddr` -> `bstate`/`cpuaddr` -> `ramcs`), so it and the
unit port have to land together. The fill router is different -- nothing
depends on it once the channel is off, it only consumes the bus -- so it
comes out first, on its own, and the file that follows is smaller.

Deleted: the `fl_*` declarations, `fl_ok` and its comment, the whole
`FL_IDLE..FL_DONE` router process, and the `fl_active`/`fl_busy` terms in the
bus-side mux, the `cpuaddr` mux, `sel_nmi_vector` and `WK_IDLE`.
`AP040_FILL_CHANNEL => 0` and `fill_ena_zorro => '0'` stub the channel inside
the compat top, and the core's fill ports are left open.

**Verdict: `xvhdl` clean** (with `rtl/akiko/akiko.vhd` compiled into `work`
first -- the wrapper's only VHDL instantiation), and no `fl_`/`FL_` reference
survives outside comments. The bus now has two masters where it had three.

Two things worth writing down about how this was done, both of which caught a
mistake before it reached the file:

* The three deleted blocks are long and comment-wrapped, so the boundaries
  were computed and PRINTED first, writing nothing. That dry run is what
  caught the second range: walking up to the nearest separator line put the
  `fl_ok` block's start at line 665, inside the bus-side mux -- deleting it
  would have removed `bstate`, `buds`, `blds`, `bwr`, `bwdata` and the address
  decode with it. `fl_ok`'s comment has no separator above it and needed a
  different rule (walk up over contiguous comment lines, which stops at 772).
* The entity/signal edit for the unit port had been made FIRST, which left the
  wrapper non-compiling and would have made this step's `xvhdl` meaningless --
  every error would have come from the half-finished port, not from the
  deletion. It was set aside (scratchpad copy) and this step was applied to
  HEAD's file instead. It belongs with the `ram_seq` wiring in Task 4b-2,
  where those ports first have something on the other end.

### Task 4b-2 — the design note the plan was missing: THE DECODE MOVES

Task 4b-2 is the irreducible core: master mux, the three-way router,
`ram_seq` instantiated, the Akiko sequencer, the walker on clk_38, and the
deletion of `bus_step`, `bus_fresh`, `wk_active_d`, `cpustate`, `ramcs` and
`mem_ready`. It does not split further -- the walker's descriptor reads go to
RAM, so the moment `ram_seq` owns the RAM port the walker must go through it
too, and keeping both paths alive would put two drivers on the controller
port.

Reading the decode before writing it turned up what the plan did not say.
**`sel_*` is computed from `cpuaddr`, which is `addrtg68` -- the ADAPTER's
registered output.** Under D4 a RAM access never reaches the adapter, so
nothing would drive `cpuaddr` for one: the router has to decode the MASTER
address (`x_addr`), and the mapped `ram_wadr` has to come from there too.

That is not a rename. Three decode terms are entangled with the BUS-SIDE
state rather than the address, and each has to be re-expressed on the master
channel:

| today | why it exists | on the master channel |
|---|---|---|
| `sel_kick ... AND bstate /= "11"` | the kick window is READ ONLY | `AND NOT x_we` |
| `sel_nmi_vector ... bstate = "10"` | a DATA READ, not a fetch ("00") | `NOT x_instr AND NOT x_we` |
| `cpu_int <= '1' WHEN bstate = "01"` | qualifies `ramcs` with bus idle | gone -- `ram_seq` owns the select |

Get one of these wrong and the result is a wrong memory window -- a silent
decode fault, not a compile error. `sel_kick` in particular: drop the term and
writes start landing in the Kickstart window.

Also retired with the 16-bit RAM path: `sel_ram_d`/`sel_ddr_d` (the registered
decode copies feeding `mem_ready` and the `datatg68` mux) and
`cpu_phase_gate`, whose one job was qualifying `ramcs`/`ddrcs` -- the D3
placement gate moves inside `ram_seq`, where it gates EVERY unit of a split
access rather than only the first.

#### `cpuaddr` splits three ways

`cpuaddr` cannot simply be repointed at the master address: the adapter's
`addr_out` ADVANCES across sub-cycles (A, then A+2) while the master address
stays fixed for the whole access, so the chipset needs one and the router
needs the other. Every consumer sorts into one of three groups:

| consumer | wants |
|---|---|
| all `sel_*`, the NMI compare, the `ramaddr`/`ddraddr` mapping | the MASTER address `x_addr` -- they decide routing and mapping for a whole access |
| the chipset FSM's `addr <= cpuaddr`, and `dbg_rtg` | the ADAPTER's advancing address (`cpuaddr` keeps this meaning) |
| the Akiko instance's `addr => cpuaddr(10 downto 0)` | the SEQUENCER's per-register address (D3b) |

**This changes a behaviour, quietly.** Today every 16-bit sub-cycle re-decodes
itself from the adapter's advancing address. After D4 an access decodes ONCE,
from the master address. That is what a router requires -- one access, one
destination -- and it is the more correct rule, since a single operand cannot
belong to two memory windows. But it is a real change, not a refactor: an
access whose two sub-cycles would have decoded differently (one straddling a
window boundary) now follows its first byte. Every window boundary here is at
bit 18 or above and a unit spans at most four bytes, so nothing reachable
straddles one -- worth re-checking if a window is ever narrowed.


### Task 4b-2, 4c, 4d — the restructure lands, and the bench says it works

Commits `759aae4` (wrapper, top, xdc, bench), `84c8042` (build script),
`639175f` (xdc, one path), `8f97016` (bench timeout). Branch `e2-t4`.

**What was built**, against the design notes above:

- One master mux on clk_38: `x_* = walker WHEN wk_go ELSE m_*`. The walker is
  a ce-gated clk_38 FSM, one longword per descriptor, berr on a misaligned
  address or on `sel_undecoded_d` at completion.
- One router, decoding `x_addr` once: `x_sdram`, `x_ddr`, `x_akiko`, and
  everything else (`x_a16`) to the 16-bit adapter. The three bus-state terms
  became `NOT x_we` (kick), `NOT x_instr AND NOT x_we` (NMI vector) and gone
  (`cpu_int`). The NMI compare is combinational: a registered copy is one clk
  behind `x_addr` on the router's first sample.
- Two `ap040_ram_seq` instances (SDRAM, DDR3), no demux. `ddr_ready` qualifies
  the DDR3 acknowledge.
- The Akiko sequencer (D3b) splits exactly as the adapter did, with `akiko_req`
  low for two cycles between register cycles (Akiko's `ack` is registered and
  cornerturn acks the rising edge). A fetch from Akiko space is now served as
  a read; before E2 it raised no request and hung.
- **Found while wiring the top:** the 832 host bridge read Akiko host requests
  off the old RAM port (`ramaddr(8:1)`, `toram`, `cpustate(0)`). The wrapper
  now exports `host_addr`/`host_d`/`host_wr` from the Akiko sequencer.
- Completion: `x_ack_r` on the `clkena_r` edge with `x_rdata_r` captured on it
  (category 2). `bus_release = NOT x_req OR x_done OR (x_a16 AND (state = "01"
  OR bus_ready16))`.
- The clk_114 sequencers see `q_req = x_req AND NOT clkena_r AND NOT x_fresh`:
  masked on the kernel edge K and K+1, so nothing latches a clk_38 value before
  K+2, and every consumed access is followed by a req-low edge. The cache keeps
  `m_req` high straight from one C_FILL beat into the next, so without the mask
  a sequencer's done level would never clear.
- The placement gate is a one-cycle pulse (`unit_gate = ena_sr(2) AND NOT
  slower(0)`), so the second unit of a split access is also on the grid.
- Deleted: `bus_step`, `bus_fresh`, `wk_active_d`, `cpustate`, `ramcs`,
  `ddrcs`, `mem_ready`, `cpu_int`, `sel_ram_d`, `sel_ddr_d`, `sel_akiko_d`,
  `cpu_phase_ok`, the bus-side mux and the clk_114 walker router.

**Two controller bugs the unit port exposed, both one cause.**
`cpu_cache_new` registers the live `cpu_wadr` (line compare, hit-path
`cpu_rdat`, block pointer, way RAM addresses) and acts in the first cycle
`cpu_req` is high. The old port met that by putting the address up a cycle
before the select. `ap040_ram_seq` put fields and request out on one edge, and:

1. `--ap040` never wrote the mailbox. Trace: the read of vector 1 was
   acknowledged in its first cycle as a line-buffer hit with vector 0's word,
   so the CPU started at $7000 (the SSP).
2. With the hit qualified, the program took an exception early: a refetch at
   $40A came back as the word at $41A, the previous line's buffer at the new
   offset, because the idle state started the read with the old block pointer.

Fixing it inside the controller (wait for `cpu_req_d`) made the program pass
but moved every access a cycle later, and chip-RAM WRITES landed on 3/7/11/15,
the grid that corrupts on the board. So the controller change was reverted and
the plan's own `RS_SETUP` idea restored in `ap040_ram_seq`: each unit's fields
go out one edge before its request, which the gate still places. Writes went
straight back to 2/6/10/14/13. `cpu_cache_new`'s header now states the rule,
and a SOC_SIM check reports any field change on the edge `cpu_req` rises.
The Task 3 benches never presented fields and request together, which is why
they did not see it.

**Read placement re-baselined (Paul, 2026-09-16).** Reads now land on
0/4/8/12 (e2t4b: 6146 of 6558), no longer 3/7/11/15. The unit port removed the
answer-before-select path, so read acknowledges moved; writes, which the
hardware evidence is about, did not. D7 now judges reads on 0/4/8/12 and writes
on 2/6/10/14/13, 10 % stray each, on the pattern program with Turbo chip RAM.

**sim/ddr3_cpu, one leg at a time** (RUNTAG `e2t4c`; `--mmu` `e2t4b`):

| leg | result | phase 8 | E4a phase 8 |
|---|---|---|---|
| `--ap040` | **2 passed, 0 failed**; reads 412/6558 off, writes 0/64 off | 2252.5 us | 1677.2 us |
| `--mmu` | **2 passed, 0 failed** | 1080.3 us | 707.9 us |
| `--ap040 --chipbus` | **2 passed, 0 failed**; DMA 2127 writes, 0 wrong | 1116.7 us | 937.0 us |
| `--snoop` | **2 passed, 0 failed**; 31189 snoops all seen and invalidating, 0 out of order | 2522.2 us | 1762.6 us |
| `--gatemutant` | **failed as required**: writes 37/64 off (to 3/7/11/15), reads 6076/6558 off | | |
| `--ackmutant` | **failed as required**: 180913 completions without `clkena_r`; program code 14 | | |
| `--mmumutant` | **failed as required**: stall watchdog at phase 2 | | |
| `--snoopmutant` | **failed as required**: 9544 of 28634 snoops reached the core, out of order | | |

`--lwmutant`, `--nofill` and `--fillmutant` are retired (their targets no
longer exist). The bench timeout went from 2.5 ms to 4 ms: a healthy `--snoop`
reached phase 8 at 2517 us and timed out finishing its last phase.

**Controller regression**, unchanged from Task 3: `sim/sdram_coherency` sweep
432/0, sweep mutant 416 of 432, `+nobg` 50 rounds 52 errors, 50 rounds with
load 4 errors; `sim/ddr3` 9 passed, 0 failed. The new setup check never fired
in either bench.

**SPEED -- CORRECTED FIGURES FIRST (measured after the table above was written).**
The E4a column above is NOT comparable: those legs ran the behavioural SDRAM
model, which releases the CPU at ~70 us, while every E2 leg runs real SDRAM,
which preloads the program first (CPU released at 232 us) and runs the chipset
DMA agent throughout. Measured from CPU release against E4a's own REALSDRAM leg
(`xsim_run_pass_ap040_t6brs.log`: release 232.19 us, phase 8 1892.09 us):

| run | phase 8 minus release | vs E4a |
|---|---|---|
| E4a REALSDRAM `--ap040` (t6brs) | 1659.9 us | -- |
| E2 `--ap040` (e2t4c) | 2020.3 us | **+21.7 %** |
| E2 with `unit_gate <= '1'` (analysis only, PREB1 copy, RUNTAG spd_nogate) | 1905.7 us | +14.8 % |
| E1 busy reference vs E2 busy leg | 1914.3 -> 2296.9 us | +20.0 % |

So the regression is about +22 %, not +34 %.  Of it, the placement gate's wait
is about a third (114.6 us); the fill channel is about 1 % (E4a `--nofill`
1694.3 vs 1677.2 us).  Largest remaining suspect, not yet measured: Task 3
removed cpu_cache_new's answer-before-select line-buffer path, so a buffer HIT
that used to complete with no select and no gate wait now goes through
ap040_ram_seq's setup cycle, a request, and (when gated) the next gate pulse.
**Measured (RUNTAG spd_count, report-only counters now in the bench; phase 8
identical to e2t4c, so they do not perturb):**

| | count | mean clk |
|---|---|---|
| SDRAM units, request -> acknowledge | 6506 | 1.36 |
| ... of which line-buffer hits | **4588 (70 %)** | **0.00** |
| SDRAM accesses, x_req -> consumed by the core | 6505 | **9.41** |
| DDR3 accesses | 2021 | 11.35 |
| adapter accesses | 4 | 12.00 |

The controller is not the cost: most units are hits answered in the cycle the
request rises. The cost is the pipeline around them, ~9.4 clk (three CPU
clocks) for an access whose memory latency is zero. Budget for a one-unit hit,
kernel edge K:

| clk | what | removable? |
|---|---|---|
| K, K+1 | q_req mask (clkena_r, x_fresh) | no: the two-cycle crossing |
| K+2 | RS_IDLE latches | could merge with the setup cycle (fields straight from x_*) |
| K+3 | RS_LAUNCH: fields out, not yet armed | needed by cpu_cache_new, but see above |
| K+4.. | wait for the gate pulse (0-3 clk) | the D3 rule; gate-open run shows ~1/3 of the loss |
| +1 | RS_WAIT sees ack | -- |
| +1, +1 | RS_GAP, RS_DONE on the LAST unit | yes: set done on the ack edge when nothing is left |
| 0-2 | wait for the cpu_ph decision edge | quantised to the CPU clock |
| +1 | clkena_r -> consumed | no |

Candidates for Task 5, cheapest first: (a) finish on the ack edge of the last
unit (-2 clk, often a whole CPU clock after quantisation); (b) merge RS_IDLE
into the setup cycle (-1 clk); (c) whether a HIT needs the placement gate at
all -- it touches no SDRAM slot, but a gated request is also what places the
acknowledge, so this is a D3-rule question for Paul, not an optimisation.  The MMU, chipbus and snoop legs have no E4a
REALSDRAM baseline, so their E2 times stand alone.

**SPEED (as first written, superseded by the corrected table above):
E2 is SLOWER in the bench, not faster.** Phase 8 is 34 % later on the
pattern program and 53 % later on the MMU program. The plan expected the
opposite. Not yet measured apart (Paul: correctness first, speed is Task 5).
Candidates: the fill channel has been off since Task 4b-1, so every cache line
fill is four gated longword reads over `m_*` (88 fills on `--ap040`); and every
RAM unit now costs a setup cycle plus the wait for the next gate pulse, where a
16-bit sub-cycle that followed a clkena used to find the gate already open.

**Builds** (tree copy, `build_ap040.tcl`):

| build | result |
|---|---|
| `stage_ap040_e2t4` | do not use: clk_38 -> clk_114 **-0.483 ns** on ATC RAM -> `m_addr` -> decode -> `sel_undecoded_d`, which cpu.xdc still timed single-cycle. The decode is now registered from the master address, combinational out of the ATC RAM; its T+1 copy is never read (reasoning in cpu.xdc), so the rule went (`639175f`) |
| **`stage_ap040_e2t4b`** (ship) | clk_114 +0.491, clk_38 +0.142, clk_ddr100 +2.332, clk_114 -> clk_38 +0.303, **clk_38 -> clk_114 +0.004** (ATC RAM -> router decode -> `ram_seq_sdram/rbuf` CE, a legitimate two-cycle path with almost nothing to spare); clk_gen_sdram -> clk_114 -0.552 / 16 (the known SDRAM read path; `stage_ap040_e2t1cap_noila`, flashed, is -0.484). 40,722 LUTs, 59.5 BRAM |
| `stage_ap040_e2t4b_ila` | superseded: its concatenated probes (ila_cpu040 probe7, ila_fastram probe1/2) took arbitrary net names, so the capture scripts would not find them |
| **`stage_ap040_e2t4c_ila`** (812a97e) | both ILAs, depth 1024, named probes (`tg68_ram_hs`, `ddr_ila_st`, `ddr_ila_two`). clk_114 +0.015, clk_38 +1.013, clk_ddr100 +1.495, clk_38 -> clk_114 +0.917, clk_114 -> clk_38 +0.111; clk_gen_sdram -0.530 / 16 |

The +0.004 ns path is the first thing to fix when Task 5 touches the router:
shorten the decode between the ATC and `q_sdram`, or register the route (which
costs a cycle).

**Complexity row**

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes | RAM width conversions | handshake signals |
|---|---|---|---|---|---|---|---|---|---|---|---|
| e2-t4 639175f | 1773 | 1027 | 715 | 580 | 2 | 0 | 0 | 0 | dbg_phist dbg_rtg | **0** | 6 (4 in code) |

RAM width conversions reached 0. Two budget lines are NOT met and are stated
rather than argued: wrapper code rose from 917 (e4a) to 1027 (the router, two
sequencer hookups and the Akiko sequencer outweigh what was deleted), and the
script's handshake count is 6 because it greps comments too -- in code the
remaining ones are `clkena_r`, `slower`, `datatg68_r`, `cpu_bus_settled` (4,
the plan's limit).

**Busy leg** (`DMA_OVERLAP=1 P7LOOPS=10 --ap040`, RUNTAG `e2t4busy`) -- recorded,
NOT saved as a reference until Paul approves (plan D7):

| | E2 (e2t4busy) | E1 reference (`ref/overlap_gate3.txt`) |
|---|---|---|
| program | PASS | PASS |
| phase 8 | 2529.1 us | 2147.7 us |
| DMA window | 4416 writes, 0 wrong | 3670 writes, 0 wrong |
| P2C probe | 176 reads, 10 changes, 0 stale | 167 reads, 9 changes, 0 stale |
| chip-RAM acknowledges | 7726 (7300 reads, 426 writes) | 2602 |
| writes off 2/6/10/14/13 | **0 of 426** | (combined count only: 342 of 2602 off, calibrated) |
| reads off 0/4/8/12 | 421 of 7300 | -- |

Combined bins: ph0 1760, ph2 55, ph3 84, ph4 1620, ph6 50, ph7 150, ph8 1719,
ph10 38, ph11 87, ph12 1780, ph13 189, ph14 94, ph15 100 (1, 5, 9 zero). Split:
every write on 2/6/10/13/14; reads on 0/4/8/12 with 421 on 3/7/11/15.
The acknowledge count is not comparable with E1's: every unit is an
acknowledge now, including line-buffer hits, where E1 counted `ramready`
rising on the 16-bit port.  Under contention the write grid did NOT scatter.

**Still open before Task 4 is done:** Paul's OK to save the busy leg as
`ref/overlap_e2.txt`, and the hardware test.

### Hardware, 2026-09-17 (Paul) -- stage_ap040_e2t4d passes

**`stage_ap040_e2t4b` did not boot.** Kickstart loaded, the Amiga started, black
screen and no disk activity. Boot probe (`stage_ap040_e2t4c_ila`, 240 s):
`dbg_pc` frozen at $F801FA, `dbg_ir` $49F9, busy without fault,
`tg68_ram_hs` = $51 -- an instruction fetch with `ram_req` high and `ram_ack`
never. Cause in `cpu_cache_new`: a cache-inhibited read (Kickstart turbo,
`sel_kickram`) leaves CPU_SM_FILL1 for CPU_SM_FILLW, which acknowledged only a
one-word unit; word A+2 of a two-word unit is loaded in FILL2, which that path
never visits. Fixed in `0a6091a` (FILLW takes the next burst beat). The third
controller bug the unit port exposed; the first two were the setup rule above.
Neither bench ran it: `sim/ddr3_cpu` has Turbo kick off, and
`sim/sdram_coherency`'s cache-inhibited category read single words. It now also
reads a two-word unit ("CI kick long": 3 of 3 timeouts before the fix, 0
after). With `+nocilong` the fixed controller reproduces the Task 3 reference
exactly (52 / 4 errors); with the new check on, the totals are 57 / 5 because it
adds accesses and moves the timing of later categories. `sim/ddr3` 9 passed.

**`stage_ap040_e2t4d`** (0a6091a; clk_38 -> clk_114 +1.320, clk_114 +0.386,
clk_38 +0.448, clk_ddr100 +0.165, clk_gen_sdram -0.479 / 16), JTAG, not flashed:

| check | result |
|---|---|
| boot to Workbench | **pass** |
| Way Too Rude, Chip + Kick turbo | **no corruption** |
| SysInfo | **0.28x**, same as the flashed e2t1cap -- expected: its speed test runs in the 040's own caches, which E2 does not touch, so it cannot show the memory-path slowdown |
| RTG after an Amiga power cycle | **works** (also exercises the Akiko sequencer and the new host ports) |

Assumes the board kept the JTAG image throughout (an Amiga power cycle keeps it;
losing board power would boot the flash image). Not yet measured on hardware:
anything memory-bound, where the bench's +22 % would show.
