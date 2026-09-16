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

