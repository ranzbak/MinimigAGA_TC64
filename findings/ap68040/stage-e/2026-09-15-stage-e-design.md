# Stage E — one simple memory interface for the AP68040 (design spec, DRAFT)

Status: **DRAFT for Paul's review, 2026-09-15.** Written overnight after the
brainstorming session. Decisions Paul made are marked **DECIDED**. Everything
marked **PROPOSED** still needs his yes before any RTL is touched. The open
questions are collected at the end.

Supersedes the "Stage E" plan text in
[../plan-v2-with-ddr3.md](../plan-v2-with-ddr3.md) ("Stage E — collapse the adapter
stack"). The older "Stage E — both cores in one bitstream" section there is
dropped (see Decisions).

---

## 1. Starting point

**D3 is stable** (tag `d3_stable`, commit 46f0b71). The AP68040 runs on its own
clock, clk_114/3 = 37.8 MHz. Way Too Rude runs to the end with Chip and Kick
turbo on, without corruption, and SysInfo reports 0.28x an A4000/040-25.

The fix that got there is a **placement rule**: with Turbo chip RAM, the CPU's
chip-RAM acknowledges must land on phases 2/6/10/14 of the 16-phase SDRAM round
(counted from `ena7WRreg`, the way `dbg_phist` bins them; phase 13 also
appears in clean runs). `CPU_PHASE_GATE_DLY=3` delivers that at ratio 3. **Why**
phases 3/7/11/15 corrupt inside `sdram_ctrl`/`cpu_cache_new` is still unknown.
The simulation bench never reproduced it; the hardware histogram found it.

Final image without debug ILA: `build/stage_ap040_d3stable_gd3` (commit
46f0b71). Bound generics are verified in its own synthesis run, and the netlist
confirms no ILA: 40,300 LUTs (63.6 %), 59.5 BRAM tiles. It still needs a
hardware test before it goes to the MT25QL128 flash.

## 2. The problem Stage E solves

The CPU reaches memory through five layers:

```
ap040_core → ap040_mmu → ap040_cache ──b_*──► ap040_bus16_adapter ──16-bit TG68K bus──►
  TG68K.vhd (wrapper: decode, gate, clkena/slower, chipset FSM, fill+walker routers)
    ──cpustate/cpuL/cpuU/16-bit──► sdram_ctrl → cpu_cache_new (ways + line buffer + write buffer)
    ──same 16-bit port─────────► ddr3_fastram → cpu_cache_new → 128-bit DDR3 backend
```

Sizes today: `TG68K.vhd` 2,138 lines (about half comments), `sdram_ctrl.v` 824,
`cpu_cache_new.v` 908, `ddr3_fastram.v` 432, `ap040_tg68k_compat.v` 525,
`ap040_bus16_adapter.v` 212.

Every stage-D bug sat on a seam between those layers:

| Seam | Count today |
|---|---|
| Caches in series on the CPU path | **3**: 040 D-cache, `cpu_cache_new` ways, its 16-byte line buffer |
| Posted-write paths, unaware of each other | **2**: `ap040_cache` posted stores, `cpu_cache_new` write buffer |
| Bus width conversions | **32→16→32**: bus16 split, then `longword_pair`/`longword_en` re-join |
| CPU↔memory enable/handshake signals | `clkena`, `clkena_r`, `slower`, `bus_step`, `bus_fresh`, `cpu_phase_ok`, `datatg68_r`, `mem_ready`, `cpu_bus_settled` |

The pieces a native port needs already exist. The core has a clean 32-bit
handshake at `b_*` (`b_req`, `b_write`, `b_instr`, `b_size` B/W/L, `b_addr`,
`b_wdata`/`b_rdata` 32-bit, `b_ack`, `berr`), and only the bus16 adapter turns
it into a 16-bit bus. The DDR3 backend already speaks 128-bit lines. The
line-fill and walker channels already bypass the adapter, and they worked the
first time.

## 3. Decisions

1. **DECIDED — Goal A: robustness first.** Fewer layers and seams, with speed
   held at **≥ 0.28x** SysInfo. Any speed gain is a bonus, not a target.
2. **DECIDED — AP68040 only.** The TG68K branch (`g_tg68k`) and its enable logic
   leave the wrapper. The TG68K design stays reachable through tag `d3_stable`.
   The old "both cores in one bitstream" Stage E is dropped (LUT/BRAM budget;
   most software runs on the 040).
3. **DECIDED — Complexity budget.** Each sub-project must reduce, or at least
   not increase, every count in the seam table in §2, plus the size of the
   wrapper. Each sub-project's report states the before/after numbers.
4. **DECIDED — E1 success = placement check required, reproduction time-boxed.**
   The bench must assert the placement rule. It gets a fixed budget of about
   two working days to also reproduce the corruption; missing that does not
   block Stage E.
5. **DECIDED — Hardware test per build (option B):** boot, Workbench, Way Too
   Rude with Chip+Kick turbo, SysInfo ≥ 0.28x, plus a `dbg_phist` capture during
   the demo showing acknowledges on 2/6/10/14 (+13). E3 adds one fast-RAM
   stress test. No other regression list.
6. **PROPOSED — Approach 1, "one 32-bit memory bus"** (§4). Paul has not
   approved it yet.

## 4. Approaches considered

| | 1. One 32-bit memory bus (**recommended**) | 2. Thin shim | 3. Line-native |
|---|---|---|---|
| Idea | `b_*` becomes the only memory interface. One router in the wrapper decodes once. Native 32-bit ports on `sdram_ctrl` and `ddr3_fastram`. A 16-bit converter remains only on the chipset branch. | Keep the 16-bit controller ports; one tidier 32→16 shim per controller | Everything speaks 16-byte lines; the 040 D-cache is the only cache; `cpu_cache_new` goes |
| Caches in series | 2, or 1 once the line buffer goes (E4) | 3 | 1 |
| Posted-write paths | 1 | 2 | 1 |
| Width conversions | none for RAM, one for the chipset | 32→16→32 | none |
| Handshake | one request/ack, with the phase rule in one place | as today | one |
| Size / risk | medium / medium, each step A/B-able against `d3_stable` | small / low | large / high: also changes how the core's caches fill |

**Why 1:** it removes the 16-bit contract, the longword re-join and most of the
enable plumbing, and it moves the D3 placement rule into one visible block. Its
change stays small enough to A/B against `d3_stable` at every step.
**Approach 2** only moves the conversion around, so it fails the complexity
budget. **Approach 3** simplifies the most, but it changes the core's caching at
the same time. That is two big changes at once, and it could come later on top
of 1.

## 5. Sub-projects

Each sub-project gets its own plan, bench legs and hardware test. They run in
order, and each starts from the previous one's hardware-verified tag.

Implementation plan for E0 and E1: [2026-09-15-e0-e1-plan.md](2026-09-15-e0-e1-plan.md).
Implementation plan for E2 (DRAFT, decisions D1–D8 pending; it amends §5 E2
below in four places the code reading forced):
[2026-09-15-e2-plan.md](2026-09-15-e2-plan.md).
O1-O5 taken as the recommended options (Paul, 2026-09-15: "Start a new branch,
and start implementing"); O6 (flashing) still needs his explicit yes.

**E4a, pulled forward (Paul, 2026-09-15: "Do E4a first, I agree"):** remove what
is already dead right after E1, before E2. Plan:
[2026-09-15-e4a-plan.md](2026-09-15-e4a-plan.md). It does not reduce the
32→16→32 conversions; those go in E2/E3.

### E0 — Close D3, and diagnose RTG (PROPOSED as a precondition)

- Hardware-test `build/stage_ap040_d3stable_gd3`: Way Too Rude, Workbench icons
  (the 8-pixel gaps must be gone), SysInfo. Flash it on Paul's go-ahead.
- **Diagnose RTG before E2 rewrites the path RTG uses.** The evidence and the
  capture plan are in §7. The fix itself is a separate bounded task that Paul
  approves.

### E1 — A bench that checks the rule Stage E must keep

**PROPOSED design.**

- **Base it on `sim/ddr3_cpu` REALSDRAM, not `sim/sdram_coherency`.** The plan's
  exit criterion asked for "the real TG68K.vhd in front of the controller".
  `sim/ddr3_cpu` REALSDRAM already has it: the real AP68040, the real wrapper, the
  real `sdram_ctrl`, the vendor SDRAM model and a chipset DMA agent, with enables
  coming from the controller. Extending it keeps one bench instead of two. Once
  E1 passes, `sim/sdram_coherency` keeps only its controller-only legs, or is
  retired (open question O4).
- **Run the shipping gate.** The bench instantiates the wrapper with
  `cpu_phase_gate_dly` at its VHDL default of **0**, which is the old gate. Add
  a `CPU_PHASE_GATE_DLY` define passed to the instance, default **3** for all
  REALSDRAM legs.
- **Placement monitor.** A 16-phase counter re-synchronised on `ena7WR_real`,
  exactly like `dbg_phist`. On every rising chip-RAM acknowledge
  (`ramready_real` with a chip select), record the phase. A leg fails if any
  acknowledge lands outside {2, 6, 10, 14, 13}. The monitor also prints the
  histogram, so a bench run and a hardware capture compare line by line.
- **Mutant with teeth.** `CPU_PHASE_GATE_DLY=0` must fail the placement check.
  If it does not, the bench cannot see the rule and E1 is not done.
- **Time-boxed reproduction attempt (≤ 2 days).** Try to make 3/7/11/15
  placement corrupt data in simulation, e.g. chipset DMA on the same word in the
  same SDRAM round as a CPU write or read, or the write-buffer drain racing a
  chip slot-1 read. If it reproduces, the mechanism goes into the findings and
  into E2's design. If not, the placement check is the contract.
- **Exit:** all existing `sim/ddr3_cpu` legs still pass (mutants still fail), the
  placement leg passes at 3, the mutant fails at 0.
- **Calibrated, not absolute (Paul, 2026-09-15).** The bench lands chip-RAM
  acknowledges exactly one phase later than the hardware (two anchors, two
  binning formulas), so the monitor judges against the hardware grid shifted
  by `PLACEMENT_OFFSET` = 1, with a 10 % stray limit. **Before E2 changes the
  port, the offset must be explained with a hardware capture.** Details:
  [e0-e1-results.md](e0-e1-results.md).

### E2 — Native 32-bit port into `sdram_ctrl`

**PROPOSED design, to be detailed in its own plan after E1.**

*Where the port attaches.* The wrapper takes the core's `b_*` channel directly.
`ap040_bus16_adapter` is used only when the router sends an access to the
chipset branch. The adapter is an upstream file, so it stays unchanged.

*The router* is one small block in the wrapper that decodes once per access.
Destinations:
- **SDRAM:** chip RAM under Turbo, Kickstart under Turbo, Zorro II RAM, and
  Zorro III boards 1/2 (plus board 3 when there is no DDR3).
- **DDR3:** Zorro III board 3.
- **Akiko:** the RTG registers and CLUT, CD32 C2P and ID.
- **Chipset branch:** custom chips, CIAs, slow RAM and ROM without turbo, all
  still over the 7 MHz FSM with the 16-bit converter.
- **Undecoded:** auto-completes with $FFFF, as today.

*Port contract (SDRAM and, in E3, DDR3):*

| Signal | Meaning |
|---|---|
| `req` | Level, held stable with every field below until `ack` |
| `we`, `instr` | Write / instruction fetch |
| `size` | B, W or L — a longword is ONE access, never two |
| `addr[25:0]` | Byte address in the controller's space (the mapping lives in the router, not the controller) |
| `wdata[31:0]`, `rdata[31:0]` | Right-aligned by size, as `b_*` already is |
| `ack` | One clean completion; `rdata` valid with it |

The core side runs on clk_38 and the controllers on clk_114. The crossing keeps
the D4 contract that D3 proved: a level held stable across the capture window,
and an acknowledge that is edge-shaped in the receiving domain. There is exactly
one such crossing per port, not one per signal.

*The placement rule lives in the SDRAM port's request start.* The port starts a
chip-RAM access only on the opening that gate delay 3 gives today, so there is
one place to read and one place to test. Other SDRAM windows follow the same
rule unless E1 shows it is unneeded there.

*Caches and posted writes (PROPOSED, see O2 and O3):*
- **Keep `cpu_cache_new`'s ways in E2,** driven by the 32-bit port, so speed
  holds. The line buffer's removal waits for E4, after measurement.
- **Keep one posted-write path.** Recommended: keep the 040's own posted stores
  (`ap040_cache` POST_STORES) and make the controller's port write synchronous.
  The controller buffer is the one that raced chipset DMA reads, and the 040 path
  already sits under the core's own coherency logic. Decide with a bench A/B
  plus SysInfo.

*Stays unchanged in E2:* the line-fill and walker channels (they already work
and already bypass the adapter; merging them is an E4 candidate at most), the
chipset FSM itself, and Akiko.

*Exit:* all bench legs pass, including placement; hardware test per decision 5;
the complexity report shows width conversions for RAM at 0 and posted-write
paths at 1.

### E3 — The same port for `ddr3_fastram`

Same contract as E2. `ddr3_fastram`'s front end today instantiates
`cpu_cache_new` behind the 16-bit port, while its backend is already 128-bit
lines, so this is mostly deletion. Hardware test plus one fast-RAM stress test
on the DDR3 board.

### E4 — Remove what E2/E3 made dead

Candidates, each removed only when it is proven unused:
- `g_tg68k` and every TG68K-only term (decision 2).
- `longword_pair`/`longword_en`, and the AGA 32-bit chipset cycle path
  (`clkena_e`/`clkena_f` under `longword_pair`), which is constant-off for the
  AP68040 today.
- `slower`, `bus_step`, `bus_fresh`, `cpu_bus_settled`, `datatg68_r` and the
  A/B switches (`CPU_PHASE_GATE*`, `CPU_DATA_REG`), where the router replaced
  them.
- `cpu_cache_new`'s line buffer, if E2 measurements show the 040 D-cache covers
  it.
- Rename `TG68K.vhd` → `cpu_wrapper.vhd`.

Exit: the complexity report against `d3_stable`, all bench legs, the hardware
test, and SysInfo ≥ 0.28x.

## 6. Hardware test protocol (every Stage E build)

1. JTAG-load the build; flash is untouched.
2. Boot to Workbench. Check the icons (no 8-pixel gaps).
3. Chip + Kick turbo on, Way Too Rude to the end: no graphics or sound corruption.
4. SysInfo ≥ 0.28x.
5. `dbg_phist` capture during the demo (`tools/vivado/ila_phase_hist.tcl`, then
   `phase_hist.py`). Acknowledges on 2/6/10/14 (+13); strays total < 1 %.
6. E3 only: one fast-RAM stress test on the DDR3 board.
7. Once RTG works (§7): enable an RTG screen mode and use a Picasso96 tool.

A build is flashed only after Paul confirms steps 2–4 (and 6–7 when they
apply).

## 7. RTG: what the code says (read-only analysis, 2026-09-15)

Known: RTG works on the TG68K build and fails on the AP68040. It already failed
before D3 (`x3cad`). Symptom: activating RTG gives a gray screen, after a few
seconds the display returns to hires, and the Picasso96 tools cannot talk to the
board.

How the driver (`amiga_sw/rtg/minimig.card.asm`) uses the hardware:
- **`FindCard`** reads the ID at $b8010e and expects $832x. It then allocates a
  4 MB framebuffer with `MEMF_24BITDMA|MEMF_FAST|MEMF_REVERSE`, i.e. Zorro II
  fast RAM from the top. **If that fails, it retries with plain
  `MEMF_FAST|MEMF_REVERSE`**, which can land in Zorro III RAM, highest address
  first.
- **`SetPanning`** writes the framebuffer address as one longword to $b80100. If
  the address is above 24 bits, it keeps the low 24 bits and sets bit 24. So
  scan-out can only follow a Zorro III framebuffer on **board 1** (SDRAM from
  $1000000).
- **`SetDAC`** writes register 3 ($b80106); **`SetColorArray`** writes longword
  CLUT entries from $b80400.
- **Mode switching happens in the vertical-blank interrupt.** `SetSwitch`/`SetGC`
  only set `MoniSwitch`/`HWTrigger`. `VBL_ISR` then calls `SetHardware` on every
  vblank. `SetHardware` writes Akiko register 2 ($b80104), the custom-chip
  timing registers, and **BEAMCON0** ($dff1dc). BEAMCON0 is decoded only with
  `ecs`, and its bit 6 is `displaydual`, which drives `rtg_ena` in
  `agnus_beamcounter.v`.
- The driver **never reads back** a real RTG register (only the harmless ID).

Leads, ranked:
1. **The framebuffer lands outside scan-out's reach.** If the 4 MB of Zorro II
   fast RAM is not free (the 040 setup — 68040.library, MuFastROM, SetPatch —
   uses memory the 68020 setup did not), the fallback puts the framebuffer in
   Zorro III. Unless that is board 1, `SetPanning`'s mapping points scan-out at
   the wrong SDRAM, which fits "gray screen". Fits "only on the AP68040"
   through different memory use. It does not by itself explain the return to
   hires.
2. **The vblank handler or its chipset writes do not work on the AP68040.**
   Interrupt server delivery, or custom-chip writes made from interrupt context
   through the chipset path. Weakened by the gray screen itself: going gray
   means BEAMCON0 bit 6 was written at least once.
3. **The Akiko write path.** Each longword register write is split into two
   16-bit halves by the adapter; both must land. A second issue: `akiko_wr` is
   cleared only when the address leaves $00B8xxxx, which the AP68040 (no
   fetch cycles on the bus) may not do between accesses. That would turn a read
   after a write into a write. Low rank, because the driver never reads a real
   register after writing.

Ruled out tonight: the fill router serving Zorro II lines from DDR3 (`fl_ok`
covers `sel_z2ram` and `sel_z3ram_sdram`, which are answered from SDRAM).

**Cheap diagnosis (PROPOSED, one ILA build, hardware time ~15 min):** probe the
Akiko write strobe with address and data, `rtg_addr`, Akiko register 2/3,
BEAMCON0 writes and `rtg_ena`. Trigger on the first Akiko RTG write while Paul
activates an RTG mode. Capture the same on `build/stage_tg68k` (09-07, where RTG
works) for comparison. The captured `rtg_addr` settles lead 1 (Zorro II $8xxxxx
versus a Zorro III address). Register values and the BEAMCON0 sequence settle
leads 2 and 3.

## 8. Risks

- **Losing the placement rule in the rewrite.** Mitigated by E1's monitor and
  mutant, and the histogram in every hardware test.
- **Speed drop from a synchronous controller write** (O3). Mitigated by an A/B
  before committing to the choice; the ≥ 0.28x floor applies.
- **The unexplained mechanism.** A new port could create a new bad placement the
  current rule does not describe. E1's time-boxed reproduction attempt is aimed
  at this; the hardware histogram catches it either way.
- **Upstream core divergence.** The design touches only the wrapper side of
  `b_*`, not upstream AP68040 files, except for no longer instantiating
  `ap040_bus16_adapter` in the RAM path.

## 9. Open questions for Paul

- **O1** Approve approach 1 (§4)?
- **O2** Keep `cpu_cache_new`'s ways through E2 and decide the line buffer in E4
  (recommended), or remove the line buffer in E2?
- **O3** Which posted-write path stays: the 040's posted stores (recommended) or
  the controller's write buffer?
- **O4** E1 on `sim/ddr3_cpu` REALSDRAM, with `sim/sdram_coherency` reduced to
  controller-only legs or retired (recommended)?
- **O5** E0: diagnose RTG before E2 (recommended), or after Stage E?
- **O6** Flash `stage_ap040_d3stable_gd3` after it passes the hardware test?
