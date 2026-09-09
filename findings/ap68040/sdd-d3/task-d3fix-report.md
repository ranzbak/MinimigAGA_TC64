# D3-fix -- real margin on the clk_114 -> clk_38 crossing

Branch `ap040-d3-enable-scheme`, on top of `dbeb4d1`.  Submodule `lib/AP68040`
untouched at `c5d5cc3`.  Build `build/stage_ap040_d3fix` (ila=0), compared
against `build/stage_ap040_d3`.

**Result: `clk_114 -> clk_38` goes from +0.273 ns to +1.275 ns.**  The worst
path on that crossing is now a flop, one LUT6 and a clock-enable pin.

---

## 1. What the crossing's problem actually was

The brief's diagnosis was that the crossing carries the CPU read data on the
longest haul in the design.  Measured, that is half right: the haul is real,
but it is not the read data, and it is not a diffuse problem across many
signals.  In `build/stage_ap040_d3` and `build/stage_ap040_d3_ila`, taken from
the routed checkpoints and sorted by slack, **every** `clk_114 -> clk_38` path
with less than 0.3 ns of slack started at one of three registers:

| startpoint | what it is | paths in the worst 4000 |
|---|---|---|
| `tg68k/wk_active_reg` | the MMU table walker router's "walker owns the bus" flag | 3987 |
| `tg68k/wk_busaddr_reg[*]` | that router's bus address | all of the next 3000 |
| `tg68k/fl_busaddr_reg[*]` | the line-fill router's bus address | the rest, down to 0.107 ns |

The next startpoint after those, `tg68k/z3ram_ena_reg`, was 0.24 ns behind, and
the read data (`cpu_dat_r` in either controller) was nowhere near.

Reading the routed path out in full explains why.  `wk_active` and the two
`*_busaddr` registers select the bus-side address mux in `rtl/soc/TG68K.vhd`:

```
cpuaddr <= wk_busaddr WHEN wk_active = '1' ELSE
           fl_busaddr WHEN fl_active = '1' ELSE addrtg68 ...
```

and `cpuaddr` is the head of the longest combinational chain in the design:

```
cpuaddr -> sel_kickram -> cache_inhibit -> sdram_ctrl -> cpu_cache_new's
cpu_cacheline_valid -> cpu_ack -> cpuena -> ramready -> mem_ready ->
bus_ready -> clkena -> the kernel
```

-- out of the wrapper, across the die into a memory controller, through its
cache-hit logic and all the way back into the CPU island, and then four more
levels of MMU logic to `atc_v_reg[*]/D`.  (The same round trip exists a second
time through `ddr3_fastram`'s own `cpu_cache_new`.)  Nothing on that chain is
registered anywhere in the middle: `cpu_ack` is
`cpu_cache_ack || cpu_cacheline_valid || cpu_32bit_ena`, a continuous
assignment, and `cpuena` is `assign cpuena = ccachehit;`.

Driven from the kernel's own `addrtg68` that chain is `clk_38 -> clk_38` and
has 26.45 ns.  Driven from a `clk_114` register in the wrapper it has one
`clk_114` period, 8.815 ns, and it measured **8.24 ns**.  That is the 0.273 ns.

So the crossing had two problems, one behind the other:

1. the two bus routers, which were mis-constrained relative to what they can
   actually do (section 2);
2. the round trip itself, which is 8.28 ns whichever register launches it, and
   which after fixing (1) simply moved its startpoint to
   `ddr3_fastram/cpu_cache/FSM_sequential_cpu_sm_state_reg[0]` and sat at
   +0.347 ns (section 3).  Fixing (1) alone got the crossing to +0.347 ns, not
   to 1 ns; the intermediate build is recorded in section 6.

---

## 2. Approach, and why the pure-constraint route was rejected

The brief offered a register stage (approach 1) or a legitimate multicycle on
signals that are genuinely held (approach 2), and asked for the hold to be
proved from RTL rather than assumed.  **Both were used, but not where the brief
expected, and approach 2 was rejected outright for the read data.**

### 2.1 Approach 2 on `datatg68`: rejected, and here is the proof it is false

`rtl/sdram/cpu_cache_new.v`, state `CPU_SM_FILL1`:

```verilog
end else begin                       // sdr_read_ack
  sdr_read_req  <= #1 1'b0;
  cpu_cache_ack <= #1 1'b1;
  cpu_cacheline_lo[cpu_adr[3:1]] <= #1 sdr_dat_r[7:0];
  cpu_cacheline_hi[cpu_adr[3:1]] <= #1 sdr_dat_r[15:8];
  cpu_dat_r     <= #1 sdr_dat_r;
```

`cpu_dat_r` (which becomes `fromram`/`fromddr` and then `datatg68`) and
`cpu_cache_ack` (which becomes `cpuena` -> `ramready` -> `mem_ready` ->
`bus_ready` -> `clkena`) are set **in the same statement block, on the same
clock edge**, and that edge is whichever `clk_114` edge the SDRAM burst's first
word lands on -- set by the controller's slot and refresh schedule, not by the
CPU clock.  If it is the edge immediately before a `clk_38` edge, then
`datatg68` changes one `clk_114` period before the kernel samples it and the
core is released on that very edge.  A `-setup 2` on the read data would be
false in exactly the case that matters.

(The rest of the hold story for `cpu_dat_r` *is* sound -- the unconditional
`cpu_dat_r <= {cpu_cacheline_hi[cpu_adr_blk], cpu_cacheline_lo[cpu_adr_blk]}`
at the top of the state machine reloads the same value while `cpu_adr` is
stable, and `CPU_SM_FILL2` writes `cpu_sm_adr_next`, never the requested word's
own index -- but "held afterwards" is not the property a multicycle needs.  It
needs "did not change in the cycle before the capture", and FILL1 is a
counterexample.)  The same file is instantiated by `ddr3_fastram`, so the same
argument covers `fromddr`.

The routed evidence agrees: the read data was never the critical thing.  In the
final build the `cpu_dat_r` legs sit at +1.70 ns and up with no exception at
all.

### 2.2 Approach 2 on the bus routers: the premise was made TRUE in RTL

Before D3, `cpu.xdc` carried `$cpu_ce_aligned`, a `-setup -start 2 / -hold
-start 1` on `wk_active` worth 17.63 ns, justified as "every transition of
wk_active is triggered by a ce-aligned event".  D3 deleted it and said the
premise is false once the kernel has its own clock.  **D3 was right**, and the
falsifying cases are specific.  From `rtl/soc/TG68K.vhd`:

* `WK_IDLE -> WK_HI` is gated on `fl_busy`, which the line-fill router drops on
  whatever `clk_114` edge its eighth word lands on;
* the `sel_undecoded` abort in `WK_HI` and `WK_LO` fires on the first edge in
  the state, one edge after the state was entered;
* `WK_GAP -> WK_LO` is gated on `bus_ready` falling, i.e. on the memory
  controller's acknowledge clearing;
* `FL_SEL -> FL_GAP` is gated on `mem_ready` rising and `FL_GAP -> FL_SEL` on
  it falling -- twice per word, eight words per line.

Any of those can land on the `clk_114` edge immediately before a `clk_38` edge,
and that is what makes the honest requirement one `clk_114` period.

So rather than assert the exception back, the premise was made true.  A new
signal gates both router processes:

```vhdl
bus_step <= '1' WHEN NOT use_ap040 ELSE NOT cpu_ph;
...
ELSIF rising_edge(clk) THEN
    IF bus_step = '1' THEN
        CASE wk_st IS ...
```

`cpu_ph` is the phase marker's middle register, high in (T+1,T+2) when the
kernel's edges are at T and T+3.  A `clk_114` edge that samples `cpu_ph = '1'`
**is** edge T+2 -- the one edge before the kernel samples -- so this skips that
edge and no other: T, T+1, T+3 and T+4 all run.  Every register in both routers
therefore holds its value across the pair (T+1,T+2) and (T+2,T+3), which is
exactly and only what `-setup -start 2` asserts.

Two is the maximum: both routers still run at edge T+1, so `-start 3` would be
false.

**Nothing can be lost by skipping an edge.**  Every condition either router
waits on is a *level* held until it is consumed -- `fl_busy`, `wk_req`,
`fl_req`, `bus_ready`, `mem_ready`, `sel_undecoded`, `wk_st` -- with exactly
one exception, `clkena`, which is a pulse; and `clkena` is high in (T+2,T+3),
so it is only ever sampled at edge T+3, where `cpu_ph` is '0' and the routers
run.  The mutual exclusion between the two routers is also untouched: the fill
FSM refuses to start while `wk_req` is high and the walker refuses while
`fl_busy` is high, both are gated on the same edges, and neither can observe
the other mid-change.

### 2.3 Approach 1 on `clkena`: one register stage, and it is free for `bstate`

Fixing the routers moved the crossing's worst startpoint to
`ddr3_fastram/cpu_cache/FSM_sequential_cpu_sm_state_reg[0]` at +0.347 ns -- the
`cpu_sm_state == CPU_SM_IDLE` term of `cpu_cacheline_valid`, i.e. the same
round trip launched from inside the controller.  That register is free-running
and changes on DDR3 events, so no multicycle is available for it either.  The
round trip has to be cut.

It is cut at `clkena`:

```vhdl
bus_release <= '1' WHEN (bstate = "01" OR bus_ready = '1') ELSE '0';

PROCESS(clk) BEGIN
    IF rising_edge(clk) THEN
        clkena_r <= cpu_ph AND bus_release;
    END IF;
END PROCESS;

clkena <= clkena_r WHEN use_ap040 ELSE (cpu_ce_phase AND bus_release);
```

**The waveform is unchanged.**  `cpu_ph` is high in (T+1,T+2), so `clkena_r`
goes high at edge T+2, is high through (T+2,T+3), and goes low at edge T+3 --
exactly where `cpu_ph2 AND bus_release` put it.  All eight `clk_114` consumers
of `clkena` (`slower`'s reload, `chipset_done`'s clear, `akiko_req`, the two
routers' captures, the chipset FSM's end-of-cycle test, `cpustate(5)`) sample
it at edge T+3 and see the same one-cycle pulse.  The bench's `cpustate[5]` is
still a one-cycle pulse on the edge the core advances, so `ack_dry_errs` still
counts real advances.

**The `bstate` term costs nothing at all**, and this is where the two changes
reinforce each other:

* `state`, the kernel's own bus state, changes only on `clk_38` edges, so it is
  identical during (T+1,T+2) and (T+2,T+3);
* `wk_active`/`wk_bstate`/`fl_active`/`fl_bstate`, the borrowers' half of the
  mux, **cannot change at edge T+2 at all** -- `bus_step` skips that edge.

So `bstate = "01"` is exactly equal in the two cycles.  The idle release --
which is what a core running out of its own caches lives on, and what the
measured 1.26x on hardware is made of -- is bit-identical and costs nothing.

**The `bus_ready` term is a genuine one-`clk_114`-cycle delay**, and every term
of it is a level that stays up until the core consumes it: `mem_ready` (the
controller holds its acknowledge until the chip select drops), `chipset_done`
(cleared only by `clkena`), `akiko_ack` (dropped only by `clkena`),
`sel_undecoded_d` (a level while the address is out).  The one pulse among
them, `chipset_ready`, is latched into `chipset_done` on the very next cycle,
so it cannot be missed either.  An acknowledge that lands in (T+1,T+2) instead
of (T+2,T+3) releases the core at T+6 rather than T+3.

`mem_ready` is registered *only* on the way into `clkena`.  `FL_SEL`/`FL_GAP`
and `WK_GAP` keep the live copy, so a line fill's eight words still stream at
the `clk_114` rate.

And `clkena` -- the net the brief says must not be weakened -- is not weakened:
its constraint is unchanged at 8.815 ns and it is now driven by a **flip-flop**
instead of a die-crossing LUT cone, which is the strongest form the enable of
7,391 clock-enable pins can be in.  Its terms are still exactly two
(`bstate = "01"` and `bus_ready`); no acknowledge term was put back on it, so
commit `727e4f4`'s invariant stands.

---

## 3. Signals changed

`rtl/soc/TG68K.vhd` only.  Whitespace-insensitive, the diff is six lines:

| change | what |
|---|---|
| `SIGNAL cpu_ph` moved | from the `g_ap040` generate's declarative region to the architecture's, next to `cpu_ph2`, so the two routers (which live outside that generate) can read it.  Keeps its initial `'0'` in a TG68K build. |
| `SIGNAL bus_step` | new. `'1' WHEN NOT use_ap040 ELSE NOT cpu_ph` |
| `SIGNAL bus_release` | new. the `clkena` release term factored out: `bstate = "01" OR bus_ready` |
| `SIGNAL clkena_r` | new. the AP68040's registered `clkena` |
| `IF bus_step = '1' THEN` | wraps the walker router's `CASE` |
| `IF bus_step = '1' THEN` | wraps the line-fill router's `CASE` |
| `clkena <=` | `clkena_r` for the AP68040; the identical combinational expression for the TG68K |

`fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc`: the `clk_114 -> clk_38` section
gains one exception, scoped to the two routers' registers and to `clk_38` only:

```tcl
set_multicycle_path -quiet -setup -start 2 -from $bus_routers -to [get_clocks clk_38]
set_multicycle_path -quiet -hold  -start 1 -from $bus_routers -to [get_clocks clk_38]
```

86 cells in `build/stage_ap040_d3_ila`'s netlist, `wk_*` and `fl_*` including
the replicas `phys_opt_design` makes.  Scoped `-to clk_38` and no further: the
same registers also feed `sdram_ctrl` and `ddr3_fastram`, which sample
`cpuAddr` unconditionally on every `clk_114` edge, and those paths keep their
single-cycle rule.  `report_exceptions` on the shipping build shows it applied
as MCP 68/69, `cycles=2(start)` / `cycles=1(start)`, not overridden.

The stale paragraph in the file's header that said the `wk_active` exception
was gone for good is rewritten to say why it is back and what it now rests on.

### The `-hold -start 1` was verified, not assumed

Applied to `build/stage_ap040_d3_ila`'s routed checkpoint on its own, before
any RTL change:

| | setup requirement | setup slack | hold requirement | hold slack |
|---|---|---|---|---|
| before the exception | 8.815 ns | +0.006 | 0.000 ns (clk_38@0 - clk_114@0) | +0.128 |
| after the exception | 17.631 ns | +8.822 | **0.000 ns, unchanged** | **+0.128, unchanged** |

i.e. the coincident-edge hold check -- the one that is physically real, because
a `clk_38` edge *is* a `clk_114` edge -- is still being made.  In the shipping
build the crossing's hold slack is +0.129 ns against a 0.000 ns requirement.

### TG68K

`bus_step` is a constant `'1'` (`use_ap040` false and `cpu_ph` a constant `'0'`
because the generate that drives it is not elaborated), `clkena_r` folds away,
and `clkena` takes the same combinational expression it always had:
`cpu_ce_phase AND bus_release` is `'1' WHEN (cpu_ce_phase = '1' AND (bstate =
"01" OR bus_ready = '1'))` written with the middle term named.  Both routers
already folded away there (`wk_req`/`fl_req` are tied low).  The `./run.sh`
control leg is the check on that claim.

---

## 4. Routed timing, before and after

Both `ila=0`, same script, same strategy.

| clock pair | `stage_ap040_d3` | `stage_ap040_d3fix` |
|---|---|---|
| **`clk_114 -> clk_38` setup (WNS)** | **+0.273** | **+1.275** |
| `clk_114 -> clk_38` hold (WHS) | +0.079 | +0.129 |
| `clk_38 -> clk_114` setup | +6.645 | +6.428 |
| `clk_38 -> clk_114` hold | +0.053 | +0.104 |
| `clk_114` (intra) | +0.183 | +0.378 |
| `clk_38` (intra) | +0.707 | +0.809 |
| `dll_28 -> clk_38` | +1.001 | +0.958 |
| `clk_148` (intra) | +0.087 | +0.356 |
| `clk_ddr100` (intra) | +1.415 | +1.743 |
| `clk_gen_sdram -> clk_114` | **-0.501, 16 endpoints** | **-0.498, 16 endpoints** |

The only violated path in the whole report is still
`dr_d[3] -> openaars_virtual_top/sdram/sdata_reg_reg[3]/D`, the SDRAM read
capture, the same 16 endpoints it has always been and untouched by any of this.

The crossing's worst path is now:

```
Slack (MET) : 1.275ns
  Source:      openaars_virtual_top/tg68k/clkena_r_reg/C
  Destination: .../g_ap040.ap040/core/g_fpu.fpu/sh_dst_reg[13]/CE
  Logic Levels: 1  (LUT6=1)
```

a flop, one LUT and a clock-enable pin -- against the 13 levels and 8.24 ns it
was.  Sorted by startpoint, the crossing now looks like this (worst per
startpoint):

| slack | startpoint |
|---|---|
| +1.275 | `tg68k/clkena_r_reg` |
| +1.650 | `tg68k/g_ap040.snp_stb_held_reg` |
| +1.702 | `ddr3_fastram/cpu_cache/cpu_dat_r_reg[*]` (the read data) |
| ... | everything else above 2 ns |

`clk_114` also gained: +0.183 -> +0.378, because the round trip that used to
end 13 levels deep in the MMU now ends at `clkena_r`'s D pin.

---

## 5. Simulation

All legs at the final RTL, run one at a time by
`/tmp/.../scratchpad/legs.sh`.  Baseline is the committed
`sim/ddr3_cpu/xsim_run_*.log` set, saved aside first.  Phase 8 is measured
**from CPU release** (64,389,167 ps in every leg).

### 5.1 The nine legs

| leg | required | result | phase 8 from release, base -> d3fix | delta |
|---|---|---|---|---|
| `./run.sh --ap040` | PASS | **PASS**, 2 passed 0 failed; fills 83 ch / 1 und / 5 ad / 0 be, unchanged | 1755.71 -> **1787.07 us** | **+1.79 %** |
| `./run.sh --mmu` | PASS | **PASS**, 2 passed 0 failed; fills 4 / 0 / 2 / 0, unchanged | 634.02 -> **639.02 us** | **+0.79 %** |
| `./run.sh --ap040 --chipbus` | PASS | **PASS**, 2 passed 0 failed; fills 9 / 1 / 5 / 0, unchanged | 853.45 -> **871.36 us** | **+2.10 %** |
| `./run.sh --snoop` | PASS | **PASS**, 2 passed 0 failed; 25,526 snoops issued, 25,526 seen by the core, 25,526 invalidated a set, **0 out of order** | 1822.54 -> **1874.37 us** | **+2.84 %** |
| `./run.sh --lwmutant` | FAIL | **fails**, 1 check: 1784 32-bit-write protocol violations (1769 at baseline) | -- | -- |
| `./run.sh --mmumutant` | FAIL | **fails**, 1 check: stall watchdog, no progress at phase 2 -- a walk never completes | -- | -- |
| `./run.sh --fillmutant` | FAIL | **fails**, 3 checks: byte-load read-back, 270 wrong places in the backdoor read, and the undecoded-hole fill | -- | -- |
| `./run.sh --snoopmutant` | FAIL | **fails**, 2 checks: 16,480 of 24,722 snoops never reached the core, 8,070 delivered out of order | -- | -- |
| `./run.sh` (TG68K control) | PASS | **PASS**, 2 passed 0 failed | 803.76 -> **803.76 us** | **0.00 %** |

### 5.2 The TG68K control is bit-identical, not merely passing

`git diff sim/ddr3_cpu/xsim_run_pass.log` after the run is four lines, and all
four are the wall-clock timestamp, the testbench's own line number (that file
grew), and xsim's memory counters.  `$finish called at time : 868713842 ps` is
the same picosecond it was before the change, and so is every phase timestamp
in between.  That is the check on "`bus_step` is a constant `'1'` there and
`clkena` is the same expression": nothing in the TG68K build moved by one
simulated cycle.

### 5.3 On the cost

The 1.79 % / 2.10 % / 2.84 % are the *memory-bound* cost, on a bench program
whose whole job is to walk a pattern through DDR3 and chip RAM.  What the
change actually costs is one `clk_114` cycle on an acknowledge, which the 1:3
quantisation turns into one `clk_38` cycle for one access in three -- and
nothing at all when `bstate = "01"`, i.e. for a core running out of its own
caches, because that term is bit-identical across the two cycles (section 2.3).
D3's own measurement was that SysInfo's speed test runs at 0 % memory stalls,
so the 1.26x measured on hardware should be untouched; that is a prediction to
check on hardware, not a claim.

The `--snoop` leg's fill counts moved (310 channel + 8 adapter, against
300 + 11 at baseline).  That leg races 25,526 chipset DMA writes against the
CPU, so which lines get invalidated and refilled is timing-dependent by
construction; the invariant the leg exists to check -- every snoop seen, every
snoop invalidating a set, none out of order -- is exact.


---

## 6. The intermediate build, recorded because it is the interesting negative

The routers were fixed first and built on their own
(`bus_step` + the `cpu.xdc` exception, no `clkena_r`).  Result:

| | d3 | routers only | + registered clkena |
|---|---|---|---|
| `clk_114 -> clk_38` | +0.273 | **+0.347** | +1.275 |
| `clk_114` intra | +0.183 | +0.003 | +0.378 |

The exception did exactly what it was meant to -- the `wk_*`/`fl_*` paths went
from +0.006 to +8.822 on the standalone check -- but the routed WNS barely
moved, because the tool routes to *meet*, not to maximise: with the routers out
of the way the crossing's worst path simply became the same round trip launched
from inside the DDR3 controller's cache FSM, at +0.347 ns, and `clk_114` fell to
+0.003 as the placer spent the freed margin elsewhere.

That is worth keeping because it is the answer to "why not just fix the
constraint": the constraint was half the problem, and the other half was a
combinational round trip through a memory controller and back that no exception
can honestly relax.  Only the register stage moves it.

---

## 7. What is not fixed, and what to watch

* **The SDRAM read capture still fails**, -0.498 ns on 16 endpoints, exactly as
  before.  Pre-existing, out of scope, and unchanged by this work.
* **`clk_114` is +0.378 and `clk_38` +0.809.**  This design is full; the tool
  equalises.  Do not read the crossing's +1.275 as headroom that will survive
  an unrelated change -- re-measure after anything that touches the wrapper.
* **`dll_28 -> clk_38` is +0.958**, worst startpoint
  `minimig/autoconfig/board_base_addr_reg[3][*]` -> the AP68040's cache tag RAM
  address.  It meets, it is a different clock pair from the one this task was
  about, and it is quasi-static (the Zorro III base is written once per board
  during autoconfig).  It was not touched because a multicycle there would need
  an argument nobody has made yet.  It is now the tightest thing entering the
  island after `clkena_r`.
* **The gate and the exception are one thing.**  If `bus_step` is ever removed
  from either router, the `cpu.xdc` exception must go with it.  Both files say
  so at the point of use.
* **This does not prove the hardware bug is gone.**  It removes the only
  mechanism anyone has identified for it -- a `clk_114 -> clk_38` path with
  0.27 ns of margin feeding the core's clock enable and the MMU's ATC valid
  bits, which is exactly the shape of a silent `AN_MemCorrupt` -- but the
  original failure was intermittent and "it booted" proves nothing.  The
  hardware test is a long soak, not one boot.
