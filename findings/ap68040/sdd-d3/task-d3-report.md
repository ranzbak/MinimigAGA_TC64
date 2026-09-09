# D3 -- the CPU island on its own 37.8125 MHz clock

Branch `ap040-d3-enable-scheme`, on top of `82224b7`.  Submodule `lib/AP68040`
unchanged at `c5d5cc3` (see section 4 for why).

---

## 1. The clock, and how it reaches the wrapper

`rtl/clock/amiga_clk_xilinx.v` runs one MMCME2_ADV at a 1134.375 MHz VCO
(50 MHz x 45.375 / 2).  CLKOUT0/1 are at DIVIDE 10 (113.4375 MHz) and CLKOUT2
at DIVIDE 40 (28.359375 MHz).  CLKOUT3 was free:

    .CLKOUT3_DIVIDE(30)     1134.375 / 30 = 37.8125 MHz exactly

and 30 = 3 x 10, so clk_38 is clk_114 divided by three off the same VCO with no
phase shift: **every clk_38 rising edge coincides with a clk_114 one**.  It gets
its own BUFG and leaves the module on a new port `c3`.

The chain, all of it new plumbing that nothing used until the domain split:

| file | change |
|---|---|
| `rtl/clock/amiga_clk_xilinx.v` | `CLKOUT3_DIVIDE(30)`, `dll_38`, `BUFG_38`, port `c3` |
| `rtl/clock/amiga_clk.v` | new output `clk_38`; wired to `c3` on the Xilinx branch, tied to `clk_114` on the Altera one (no fourth PLL output there, and the AP68040 is a Xilinx build); a phase-aligned `#13.071` delay chain for the `SOC_SIM` branch |
| `rtl/soc/minimig_virtual_top.v` | `wire CLK_38`, `.clk_38(CLK_38)` on `amiga_clk`, `.clk_cpu(CLK_38)` on `TG68K` |
| `rtl/soc/minimig_mist_top.v` | `.clk_cpu(clk_114)` -- that top has no `cpu_core` generic, so it is TG68K-only and never reads the port |
| `rtl/soc/TG68K.vhd` | new port `clk_cpu : in std_logic := '0'` |
| `fpga/.../clocks.xdc` | `create_generated_clock -name clk_38 [get_pins $amiga_mmcm/CLKOUT3]` |

The generated clock is declared next to `clk_114`/`dll_28` and deliberately NOT
put in an asynchronous clock group: the two are synchronous siblings and static
timing analyses their real edges.

---

## 2. The split point, and every signal that crosses

`rtl/soc/TG68K.vhd` has one `clk` port and, in the `g_ap040` branch, one kernel
instance.  The split is exactly the brief's:

* **on `clk_cpu` (37.8125 MHz):** the `ap040_tg68k_compat` instance, and
  nothing else except the three-register phase marker described below.
* **on `clk` (113.4375 MHz):** everything else -- the decode, the walker FSM,
  the fill FSM, `slower`, the chipset state machine, Akiko, the address and
  data registers that face `sdram_ctrl` and `ddr3_fastram`, both `datatg68`
  muxes, `chipset_done`.
* **in the `g_tg68k` branch `clk_cpu` is not read at all.**  The kernel is tied
  to `clk` exactly as before and its enable is still `clkena_in`.

### 2.1 The one structure the brief did not anticipate: the phase marker

`clkena` is not only the kernel's clock enable.  Eight places in the `clk`
domain read it as *"the CPU advanced on this edge"*: `slower`'s reload,
`chipset_done`'s clear, `akiko_req`, the walker FSM's two data captures, the
chipset FSM's end-of-cycle test, and `cpustate(5)` (which is what the ILA stall
scripts count).  All of them were written against a **one-clk_114-cycle pulse**.

If `clkena` becomes the plain level `bstate = "01" OR bus_ready`, three of those
break, and two of them deadlock rather than merely degrade:

* `slower` would reload on every clk_114 cycle the level is high, so the memory
  chip select could open on the cycle the address moved (the bench's own port
  setup assertion) or never open at all.
* `chipset_done` would clear on the first clk_114 cycle after the chipset
  answered -- **before** the core's next clk_38 edge -- so `bus_ready` would
  drop again and the core would never see the release.  Same for `akiko_req`,
  which is dropped by `not clkena` and whose acknowledge is `req` itself.

So the level is not usable and a pulse is needed, aligned to the clk_38 edge.
The `clk` domain cannot count its own three phases: nothing aligns a fabric
divider to the MMCM's.  The kernel's clock supplies the alignment instead
(`rtl/soc/TG68K.vhd`, in the `g_ap040` declarative region):

    cpu_tgl   : toggles on every clk_cpu edge          (clk_cpu domain)
    cpu_tgl_d : <= cpu_tgl                             (clk domain)
    cpu_ph    : <= cpu_tgl XOR cpu_tgl_d               (clk domain)
    cpu_ph2   : <= cpu_ph                              (clk domain)

With the clk_38 edge at clk_114 edge T and the next at T+3: `cpu_tgl` flips at
T, `cpu_tgl_d` at T+1, so the XOR is high in (T,T+1), `cpu_ph` in (T+1,T+2) and
`cpu_ph2` in **(T+2,T+3)** -- exactly the clk_114 cycle before the next clk_38
edge.  A `clk` register sampling at edge T+3 therefore sees `cpu_ph2 = '1'`, and
'0' on the other two edges.

That makes the enable expression the brief asked to keep, structurally
unchanged, with only the first term redefined:

    cpu_ce_phase <= cpu_ph2 WHEN use_ap040 ELSE clkena_in;
    clkena <= '1' WHEN (cpu_ce_phase = '1' AND (bstate = "01" OR bus_ready = '1')) ELSE '0';

`clkena` is now a one-clk_114-cycle pulse on exactly the edges the kernel
advances on -- **the same shape `enaWRreg` gave it**, at one in three instead of
four in sixteen.  Because of that, `slower`, `chipset_done`, `akiko_req`, the
two bus routers, the chipset FSM and `cpustate(5)` all keep working with their
existing code and their existing meaning, and the bench's `ack_dry_errs` still
counts real core advances.  From the kernel's side the gating is invisible: it
only ever samples at clk_38 edges, where `cpu_ph2` is 1 by construction, so what
the kernel sees is precisely `~cpu_req | bus_complete`, upstream's shape.

The marker free-runs (no reset, INIT 0 on all three registers), for the same
reason the core's stall watchdog does: a wedge anywhere else must not be able to
stop it.

### 2.2 core -> bus

`addr_out`, `busstate`, `nuds`/`nlds`, `data_write`, `longword`, `nresetout`,
`fill_req`/`fill_addr`, `walker_req`/`walker_we`/`walker_addr`/`walker_wdat`,
`cacr`/`vbr`, the debug status.  All are registered on `clk_cpu` and hold for at
least three clk_114 periods, so the bus side samples them directly.  What makes
that safe is not the hold time but the fact that **nothing on the bus side looks
at them for at least two clk_114 cycles**:

* memory: `slower` reloads `"0111"` on `clkena`, which is now a pulse on the
  exact clk_114 edge the address moves, and `slower(0)` forces `ramcs`/`ddrcs`
  high until it has shifted out, so a select cannot open before (T+3,T+4).
* the 7 MHz chipset machine: this is the one place that needed new RTL.
  `ena7WRreg` lands on phase 14 of a sixteen-phase round; 16 and 3 are coprime,
  so with a three-cycle enable every relative phase occurs and the machine could
  latch the kernel's address one clk_114 cycle after it moved.  It now waits on

      cpu_bus_settled <= NOT slower(1) WHEN use_ap040 ELSE '1';

  which is the same `slower` and the same rule the memory side has always had.
  A **no-op for the TG68K and constant-folded away there**: with enaWRreg on
  phases 2/6/10/14 and ena7WRreg on 14, `slower` is always `"0000"` by the time
  the machine looks (reloaded on the phase-10 enable, three shifts, then the
  phase-14 edge).

### 2.3 bus -> core

`datatg68`, `bus_ready` (and through it `mem_ready`, `chipset_ready`,
`chipset_done`, `sel_undecoded_d`, `akiko_ack`), `clkena` itself, `cpuIPL`,
`snoop_stb`/`snoop_addr`, the cache window enables, and the two routers'
acknowledges and payloads (`wk_ack`/`wk_data`/`wk_berr`,
`fl_ack`/`fl_line`/`fl_err`).

Each of these is a **level held until the core has consumed it**, and each hold
is by construction rather than by timing:

| signal | what holds it |
|---|---|
| `mem_ready` | the controller holds its acknowledge until the chip select drops, and the select is closed by `cpu_int` -- `bstate = "01"` -- which the adapter asserts in the same clk_38 edge the core takes the data |
| `chipset_ready` / `chipset_done` | `chipset_done` latches the 7 MHz single-cycle pulse and is cleared only by `clkena`, i.e. only on the edge the core actually advanced |
| `akiko_ack` | `akiko_req` is dropped by `not clkena`, again only on that edge |
| `sel_undecoded_d` | a level for as long as the address is out, and the address is out until the core advances |
| `wk_ack` / `wk_berr` | held in `WK_DONE` until the core drops `walker_req` under its own ce |
| `fl_ack` / `fl_line` / `fl_err` | held in `FL_DONE` until the core drops `fill_req` under its own ce |
| `datatg68` | follows whichever of the above is asserting |

No synchroniser and no CDC bridge anywhere: the crossing is synchronous 1:3 and
adding one would only add latency and break the handshakes above.

### 2.4 One RTL change in the chipset machine that is not about clocks

`clkena_e` used to be cleared at the TOP of the chipset process, and the
`ena7RDreg` `"11"` branch below re-asserts it.  The old comment claimed the two
could not fire together because "clkena is never high on phase 6" -- that is
**false**: `cpu_enable_cadence.v` puts `ena_cpu` on phases 2/6/10/14 and
`ena7rd` on 6, so they always coincided and the re-assertion always won.  What
actually cleared `clkena_e` was the same test firing a SECOND time on the
phase-10 enable, with `chipset_done` still up from phase 7.

That second firing does not survive D3: `chipset_done` is cleared on the first
enable after it is set, and with a three-cycle enable there may be no second
one before the next chipset cycle.  Left alone, `clkena_e` would stick at '1'
roughly one chipset access in sixteen and produce a spurious `chipset_ready`,
i.e. a read released with the previous cycle's data.  So the clear moved to the
BOTTOM of the process, where it wins outright.

For the TG68K this is behaviour-neutral: it clears `clkena_e` at phase 7 instead
of phase 11, and between those two edges the only readers are
`ena7RDreg AND clkena_e` (ena7RDreg is low there) and `S_state = "01"` (S_state
is "00" there).  The `./run.sh` control leg is the check on that claim.

---

## 3. `clkena_in` as a handshake

With `cpu_ce_phase` folded out, what the kernel sees on `clkena_in` is

    bstate = "01"  OR  bus_ready

which is upstream's `~cpu_req | bus_complete | bus_berr` written in this
wrapper's names: the bus adapter parks `busstate` at IDLE whenever it has
nothing outstanding, so `bstate = "01"` is `~cpu_req`, and `bus_ready` is
`bus_complete` (this SoC never raises `berr`; an undecoded address is
auto-completed, which is why there is no third term).

The invariant commit `727e4f4` established is untouched: the net still carries
exactly two terms and no acknowledge terms were put back on it.  `wk_ack`,
`wk_berr`, `fl_ack` and `fl_err` stay off it, and the bench's `ack_idle_errs` /
`ack_dry_errs` assertions -- which are what make that safe -- still pass.

The measured value of the change is exactly the clock ratio and nothing else:
during SysInfo's speed test the core sat at 25.0 % of clk_114 with 0 % memory
stalls, i.e. the four-phase ceiling, so 37.8125 / 28.359375 = **1.33x** on
cache-resident code.  Section 6 is that number, measured.

---

## 4. The acknowledge hazard, and `ce_core`

**Decision: keep `ce_core = clkena_in`.  No third submodule commit, and no
rising-edge-ack fix.  The submodule is untouched at `c5d5cc3`.**

Argued from `ap040_bus16_adapter.v` rather than from the enable's duty cycle.
The adapter clears `mem_ack` inside `else if (clkena_in)`, and it sets it in the
same statement block that does `busstate <= AP040_BUS_IDLE`:

```verilog
if (next_left == 3'd0) begin
        active   <= 0;
        busstate <= `AP040_BUS_IDLE;
        ...
        mem_ack  <= 1;
```

So in the cycle after an acknowledge the adapter's `busstate` IS idle.  With the
enable now `bstate = "01" OR bus_ready`, `bstate = "01"` in that cycle, so
`clkena_in` is high and `mem_ack` is cleared -- which is precisely the reasoning
the A2b-0 commit gives upstream ("visible in the cycle after a qualified edge,
when the adapter is idle and clkena high anyway").  The documented single-cycle
pulse is true again, and the desync that forced `c5d5cc3` cannot occur.

That makes `ce_core = 1'b1` *safe* in the common case -- but not obviously safe
in all of them, and it buys nothing this stage is measuring:

* **What it would buy.** Upstream frees the core so that work which does not
  need the bus proceeds during a bus wait.  The 2.4x in
  `sdd-2026-09-09/task-1-report.md` §6a is not that effect -- it is the effect of
  a core that only ran on 5 of 16 clocks running on all of them, which is what
  D3 delivers by moving to clk_38.  On the benchmark this stage is judged by,
  SysInfo, `bstate` is `"01"` continuously (0 % memory stalls, measured), so
  `clkena_in` is high on every clk_38 edge and the two settings are *identical*.
* **What it would risk.** `bstate` is the MUXED bus state.  In the cycle after
  an acknowledge the walker or the fill router can own the bus and drive
  `bstate` non-idle; then `clkena_in` is low, `mem_ack` is not cleared, and a
  free-running cache reads the stale level as the acknowledge of the next
  request.  With `ce_core = clkena_in` the cache is frozen in exactly those
  cycles too, so adapter and cache stay in lockstep and the hazard is
  structurally impossible rather than argued away.

One variable per stage.  `ce_core = clkena_in` costs nothing measurable here,
keeps the configuration that all eight gates have been run against, and leaves
`ce_core = 1'b1` as a clean, separately-measurable follow-up now that its
precondition (an enable that is high whenever the adapter is idle) genuinely
holds.  The divergence comment in `ap040_tg68k_compat.v` is now partly
out of date -- it explains the duty cycle that no longer exists -- and updating
it belongs with the change that flips the line, not with this one.

---

## 5. Constraints, and where the derivation departs from the brief

### 5.1 What was removed

`cpu.xdc`'s kernel island rested on "the CPU's clock enable is enaWRreg ...
every kernel register therefore holds its value for at least 4 clk_114 cycles".
For the AP68040 that premise is dead, so:

* `set_multicycle_path -setup -start 3 / -hold -start 2` kernel -> kernel and
  kernel -> wrapper: **removed for the AP68040**, kept for the TG68K (whose
  enable is still `enaWRreg`, so the premise is still true there).  The two
  kernels are now separate cell sets; the AP68040 has no cell set at all.
* `set_multicycle_path -setup -start 2 / -hold -start 1` kernel -> memory:
  same, kept for the TG68K only.
* `$cpu_ce_aligned` (`wk_active`, `mmu/l_row|l_tag|l_ld`): **deleted.**  For
  `l_*` the two-cycle claim is now just the clk_38 period.  For `wk_active` it
  is false -- the walker router advances on `clkena`, `clkena` is a bus
  handshake, so `wk_active` can change on any clk_114 edge.  It keeps
  single-cycle timing like every other wrapper register.
* `$cpu_not_free` (`*core_stall_watchdog*`, `*walker_wr_d*`, `*wsnp_*`,
  `mmu/l_*`, `*_snooped_reg*`): **the filter is deleted, the comment is kept
  and rewritten.**  There is no relaxation left to exclude them from: the
  island is a clock domain, so a free-running kernel register and an enabled
  one are both checked against one clk_38 period and both answers are true.
  The `ipl_s*` finding (why it was never in the list, what splitting it broke)
  is kept too -- it is the path that decides how far the island clock could be
  raised.

`report_exceptions` on an AP68040 build must therefore show **no multicycles on
the core**, which is the stage's stated exit criterion.  A side effect worth
checking on the first build: `atc_ram -> g_cache.cache/{look,st}_snooped_reg`,
which has failed setup by -0.3 to -0.6 ns in every AP040 build including the
pre-D3 baseline and is the WNS-defining path on clk_114, is entirely inside the
kernel and is now a clk_38 -> clk_38 path with 26.45 ns instead of 8.815 ns.
It should stop being a violation without the RTL change that was deferred for
it.  That is a prediction, not a claim.

### 5.2 The 1:3 pair -- and why the numbers are 2/1, not 3/2

The brief proposed `-setup -end 3 / -hold -end 2` for clk_38 -> clk_114 and the
mirror `-setup -start 3 / -hold -start 2` for clk_114 -> clk_38, "derive them,
do not copy the numbers blindly".  Derived, both come out different.

**clk_38 -> clk_114 is TWO clk_114 periods (17.63 ns), not three.**  The
question a multicycle answers is "how long after the launch edge is this value
first looked at", and with a three-cycle enable gap the answer is two, not
three, on three independent paths:

* The kernel advances at clk_38 edge T and at the earliest again at T+3.
  Everything on the clk_114 side that feeds an answer BACK to the kernel is
  registered, and the copy that matters at edge T+3 is the one captured at
  **T+2**.  `sel_undecoded_d` is the sharpest case: it is `bus_ready` all by
  itself, so a decode that has not settled by T+2 releases the core at T+3 with
  `$FFFF`.
* Memory: `slower` opens the select first during (T+3,T+4); the controllers'
  `cpu_cacheline_match` that gates the access was captured at T+3 from the
  address during (T+2,T+3).  Settled at T+2 again.  (This is the same 17.63 ns
  the old kernel -> memory rule always used.)
* The chipset machine, with `cpu_bus_settled = NOT slower(1)`, starts at edge
  T+3 at the earliest.  Settled at T+2 once more.

With the 1:4 enable the same derivation gives three, which is why the old file
says three -- and the old file was already loose by one on the first two of
those, because it applied its `-start 3` island to `sel_ram_d` and friends.  So
2/1 is both the honest number and a tightening of an existing looseness.

`-end` on both, so the hold check stays on the coincident launch edge: with
`-setup -end 2`, the default hold capture would be T+1 and `-hold -end 1` moves
it back to T, which is the same-edge check every clk_38 -> clk_114 path has
anyway.  Same idiom and same reasoning as `wizard.xdc:14-18`, with 4/3 replaced
by 2/1 rather than 3/2.

**clk_114 -> clk_38 gets NO relaxation, deliberately.**  The mirror rule would
assert that a clk_114 register feeding the island does not change in the
clk_114 cycles just before the island samples, and the wrapper's answers do
exactly that: `clkena`, `datatg68`, `bus_ready`, `mem_ready`, both routers'
acknowledges and payloads are produced on the FREE clk_114 clock and can rise on
the edge immediately before a clk_38 one.  That is the whole point of a
handshake -- the core is released as soon as memory answers, not on the next
slot of a cadence.  Leaving the default is not a compromise: it is 8.815 ns,
which is exactly what these same paths meet today, because nothing in `cpu.xdc`
ever relaxed a path INTO the kernel, `clkena`'s fan-out to 7,391 kernel CE pins
included.  The absence of a rule here is the derivation's answer, not an
omission, and it is written out in the file as such.

**Two cell-scoped overrides.**
* The phase marker must not be relaxed: `cpu_tgl -> cpu_tgl_d` is given
  `-setup 1 / -hold 0`, restoring the default over the clock-scoped rule.  Give
  it two cycles and `cpu_ph2` lands in the wrong place, and `slower`, the
  chipset machine and every chip select go with it.  Same shape as the direct
  FF->FF crossings already listed in `wizard.xdc`.
* `$tg68_mem` gained `g_ddr3_fastram.ddr3_fastram_i`.  It was missing -- the set
  was `sdram` + `minimig` only -- so kernel -> DDR3 fast RAM has been
  unconstrained (single-cycle) in every DDR3 build.  Its `cpu_cache_new` states
  the same contract `sdram_ctrl` does, so it belongs in the set.  For the
  AP68040 this is now redundant with the clock rule (both say 17.63 ns) but it
  matters for the TG68K, where it is a relaxation from 8.815 to 17.63 ns and
  therefore cannot break closure.

**Known loose, recorded rather than tightened.**  A few wrapper registers read a
kernel output on the very NEXT clk_114 edge and so want one cycle, not two:
`akiko_req`/`akiko_wr` (gated by `slower(2)`, which opens one cycle earlier than
`slower(1)`), and the walker and fill routers, which test `wk_req`, `fl_req` and
the kernel's `busstate` unguarded on every edge.  All of them were loose by TWO
under the old `-start 3` island and have never been near the critical path -- a
16-bit address compare and a two-bit state test.  Making them exact is another
`cpu_bus_settled` term in the RTL, i.e. a second variable, and this stage has
one.  It is written into `cpu.xdc` so the next reader does not have to
rediscover it.

---

## 6. The bench

`sim/ddr3_cpu/ddr3_cpu_tb.sv`:

* a second clock, `clk_cpu`, at 37.8125 MHz.  Rising edges at 4407, 30852,
  57297 ps -- exactly every third `clk` edge (4407, 13222, 22037, 30852) and in
  the SAME simulation time step, which is what makes a `clk` register sample the
  pre-edge value of a `clk_cpu` one, as the hardware does when hold is met.
  Written as its own delay chain rather than as a divider off `clk` for exactly
  that reason: a divider would put the two a delta cycle apart and hide the
  hold relationship the design depends on.
* `.clk_cpu(clk_cpu)` on the wrapper.
* a header paragraph saying what changed and why, since that file has a
  documented history of drifting out of step with the RTL: there is a second
  clock; `enaWRreg` no longer gates the CPU; `cpu_enable_cadence` is still
  instantiated and still drives `ena7RDreg`/`ena7WRreg`, which are the chipset's
  and are unchanged, and its `ena_cpu` output still becomes `ena28` and still
  reaches `clkena_in`, where the TG68K leg uses it exactly as before and the
  AP68040 leg does not read it.
* a note at the cadence block itself saying the same thing in one sentence.

No assertion changed.  The port setup/hold contract on both RAM ports, the
walker/fill mutual exclusion, `ack_idle_errs`/`ack_dry_errs` and the
`cpustate(6)` 32-bit-write guard are all as they were, and `cpustate[5]` is
still `clkena` and still a one-cycle pulse on the edge the core advances -- so
`ack_dry_errs` still counts real advances rather than a level.

---

## 7. Method for the leg results below

Baseline is HEAD's committed `sim/ddr3_cpu/xsim_run_*.log` at `82224b7`, copied
aside before the first run.  Phase timestamps are compared **from CPU release**
(64,389,167 ps in every non-chipbus leg), not from time zero, because the DDR3
island's init sequence before that is identical and would dilute the ratio.

### 7.1 Wall-clock note

`--chipbus` runs at reduced region sizes (`PATBYTES=64 MISLINES=2 CNTN=8`, which
`run.sh` picks automatically) and takes about five minutes, not twenty-five;
`--mmu` and `--mmumutant` run a different, shorter program.  Only the four
pattern-program legs are the long ones.

### 7.2 The eight legs

All from CPU release at 64,389,167 ps; `--chipbus` from its own release at the
same time.  Baseline is HEAD (`82224b7`).

| leg | required | result | phase 8, base -> D3 (us from release) | delta |
|---|---|---|---|---|
| `./run.sh --ap040` | PASS | **PASS**, 2 passed 0 failed; fills 83 ch / 1 und / 5 ad / 0 be, all unchanged | 2323.01 -> **1755.71** | **-24.42 %** |
| `./run.sh --ap040 --chipbus` | PASS | **PASS**, 2 passed 0 failed; fills 9 / 1 / 5 / 0, unchanged | 870.09 -> **853.45** | **-1.91 %** |
| `./run.sh --mmu` | PASS | **PASS**, 2 passed 0 failed; fills 4 / 0 / 2 / 0, unchanged | 838.10 -> **634.02** | **-24.35 %** |
| `./run.sh --nofill` | PASS | **PASS**, 2 passed 0 failed; fills 0 ch / 88 ad, unchanged | 2351.82 -> **1774.78** | **-24.54 %** |
| `./run.sh --lwmutant` | FAIL | **fails**, "1 checks failed": 1769 32-bit-write protocol violations | -- | -- |
| `./run.sh --mmumutant` | FAIL | **fails**, "1 checks failed": stall watchdog, the walk never completes | -- | -- |
| `./run.sh --fillmutant` | FAIL | **fails**, "3 checks failed": read-back code 2, backdoor mismatch, undecoded-hole check | -- | -- |
| `./run.sh` (TG68K control) | PASS, unchanged | **PASS**, and **every phase timestamp byte-identical to HEAD's log** | 803.76 -> 803.76 | **0.00 %** |

Plus the two legs the review added, in section F5: `--snoop` PASS,
`--snoopmutant` fails as required.

**The speed-up is the clock ratio and nothing else.**  37.8125 / 28.359375 =
1.3333; measured 1.3232, 1.3218 and 1.3251 on the three fast-RAM legs.  The
~0.8 % shortfall is the fixed cost that does not scale: the DDR3's own latency
and the 7 MHz accesses the program still makes.  There is no memory term to
erode it, which is what the SysInfo stall capture predicted and why the number
came out where it did rather than somewhere between 1 and 1.33.

**`--chipbus` at -1.9 % is the control on that claim.**  Same core, same clock,
chip RAM over the 7 MHz bus: the speed-up nearly vanishes.  Judge D3 on
fast-RAM-resident code, as the plan says.

**D2's A/B survives.**  `--ap040` against `--nofill` is -1.074 % here, against
-1.072 % at HEAD -- the line-fill channel is worth the same as it was, so D3
did not quietly change what D2 measured.

**The TG68K control is the strongest single result.**  Not "passes" but
*identical*: every phase timestamp, the PASS lines and the backdoor check all
byte-for-byte HEAD's log.  That is the check on `cpu_ce_phase`, on
`cpu_bus_settled` being constant-folded, and on the `clkena_e` move.

---

# FIX REPORT -- the snoop that D3 nearly lost

Appended after review.  The reviewer's Critical finding is correct and was a
real hole in my §2.3: I listed `snoop_stb` among the bus -> core signals and
asserted that each was "a level held until the core has consumed it", and it is
the one signal in that list for which that was never true and which I never
checked.  It is a one-`clk_114`-cycle pulse and nothing held it.

## F1. The bug

`sdram_ctrl.v:492` clears `snoop_act` unconditionally on every `sysclk` and
`:633` sets it at ph2, so it is exactly one `clk_114` cycle wide; `:190-196`
registers it out still one cycle wide; `rtl/soc/TG68K.vhd` handed it straight to
the kernel.  With the kernel on `clk_38`, only one `clk_114` cycle in three
precedes a `clk_38` edge, so a snoop was seen only if it happened to land in
that one.  **Two chipset DMA snoops in three vanished.**

The consumer states the contract and, on the very next line, records the
previous occurrence of the same loss (`lib/AP68040/rtl/ap040_cache.v:111-116`):

> `s_stb` is a single CLOCK pulse in THIS clock domain, ce-independent, with
> `s_addr` held alongside it; the matching data-cache set is invalidated on that
> clock.  (A ce-gated snoop port was the 5.1 loss: chipset writes landing while
> clkena is frozen simply vanished.)

D3 reintroduced that loss through the clock rather than through the enable.  The
hardware signature is stale D-cache lines after blitter or trackdisk DMA into
chip RAM: intermittent, data-dependent, **never a hang** -- so nothing else in
the bench, and no boot probe, would have caught it.  It is worse than it looks
because Turbo chip RAM is on and `ap040_tg68k_compat.v:396` makes
`$000000-$1fffff` cacheable on the D side, so the 040 caches chip RAM in
earnest.

## F2. The fix, and why this shape

`rtl/soc/TG68K.vhd`, in the `g_ap040` branch: latch the pulse and its address,
clear the latch on `cpu_ph2` -- the same phase marker `clkena` uses.

```vhdl
IF snoop_stb = '1' THEN
        snp_stb_held  <= '1';
        snp_addr_held <= snoop_addr;
ELSIF cpu_ph2 = '1' THEN
        snp_stb_held  <= '0';
END IF;
```

The kernel then sees a level that is high at **exactly one** `clk_38` edge and
low at the next, which is the single pulse in its own clock domain the contract
asks for.  Walking the three cases, with a `clk_38` edge at `clk_114` edge T and
the next at T+3:

| pulse arrives during | latch set at | cleared at | core samples it at |
|---|---|---|---|
| (T, T+1) | T+1 | T+3 | T+3 |
| (T+1, T+2) | T+2 | T+3 | T+3 |
| (T+2, T+3) | T+3 (set beats clear) | T+6 | T+6 |

Every snoop is delivered exactly once, at most one `clk_38` period late.

**Cleared on `cpu_ph2`, not on `clkena`, and that is the choice the reviewer
asked me to justify.**  `clkena` is the "held until consumed" shape everything
else on this crossing uses, but it stops for the whole of a bus access -- a
chipset cycle is some eighty `clk_114` cycles -- and a second snoop arriving
inside that window would be merged into the first and one of them lost.  On
`cpu_ph2` the latch is never held for more than three `clk_114` cycles, and a
chip slot-1 write happens at most once per sixteen-cycle SDRAM round, so two
snoops can never merge.  A plain three-cycle stretch would behave identically;
the latch is written as set/clear because that states the intent ("held until a
`clk_38` edge takes it") rather than leaving it to be re-derived from a count.

Nothing changes for the TG68K: the holder is inside `g_ap040`, and the TG68K
kernel has no snoop port at all.  No constraint change either -- `snp_stb_held`
and `snp_addr_held` are `clk_114` registers feeding the kernel, i.e. the
`clk_114 -> clk_38` direction that is deliberately not relaxed, so they are
checked at the default 8.815 ns.

## F3. The bench, which is the actual deliverable

`sim/ddr3_cpu/ddr3_cpu_tb.sv` tied `snoop_stb` to `1'b0` with a comment
asserting that "the core's own window logic leaves the low chip space uncached
anyway".  That is wrong -- `ap040_tg68k_compat.v:396` says the opposite -- and
it is why nothing ever drove the port.  The comment is corrected in place, since
it is the reason the gap existed.

What is driven now, behind `+SNOOP` (off in every other leg, so their phase
timestamps stay comparable to HEAD's):

* one-`clk_114`-cycle pulses, on the `clk_114` grid, at chip RAM addresses that
  walk the cache sets;
* spaced 128 `clk_114` cycles.  **128 mod 3 = 2**, so the pulse walks all three
  phases relative to `clk_38` -- including the two that are dropped without the
  fix -- and 128 >= 16 means two pulses can never merge in the latch, which is
  also true of the hardware.

What is checked, on the summary line:

| counter | meaning |
|---|---|
| `snoop_iss` | pulses the bench issued |
| `snoop_ph0/1/2` | how many in each `clk_114` phase; `ph2` is the one window a raw pulse survives |
| `snoop_seen` | `clk_38` edges at which the CORE saw its snoop strobe high |
| `snoop_inv` | of those, how many made the cache drive a port-B invalidate (`ap040_cache.v:505`, `snoop_wr -> inv_wren`) |

FAIL if any snoop went missing (`snoop_seen != snoop_iss`), if any that arrived
did not invalidate (`snoop_inv != snoop_seen`), or if the run did not cover all
three phases -- that last one so the test cannot pass by only ever using the
window that works anyway.

`./run.sh --snoopmutant` reverts the hold (two `sed` lines on the port map,
verified as the other mutants are) and MUST fail.

## F4. The other two corrections

* `rtl/soc/TG68K.vhd`, the `clkena_e` note: the claim that the second firing
  "is gone" is withdrawn.  The reviewer is right that `chipset_ready` wins the
  priority in the `chipset_done` process, so `chipset_done` is set on the very
  edge the CPU is released, `bus_ready` stays high and the next `cpu_ph2` fires
  the test again.  The comment now says the clear **clears outright, so the
  release no longer depends on a second firing**, and notes that the second
  firing does still happen.  That line has carried a false mechanism once
  before; it should not carry a second one.
* `cpu_ph2` now has `:= '0'` like its three siblings, so the report's "INIT 0 on
  all three" is true of all four.

## F5. Snoop leg results

| leg | issued | phase 0/1/2 | seen by core | invalidated | verdict |
|---|---|---|---|---|---|
| `--snoop` (fixed) | 1559 | 519 / 520 / 520 | **1559** | **1559** | **PASS**, 2 passed 0 failed |
| `--snoopmutant` (hold reverted) | 1557 | 519 / 519 / 519 | **519** | 519 | **FAILS as required**, 1 check failed |

**519 of 1557 is exactly one in three**, and the phase histogram says which
third: the mutant delivers only the pulses that land in the one `clk_114` cycle
before a `clk_38` edge, and loses both other phases entirely.  That is the bug
stated as a measurement rather than as an argument.

The line that matters most in the mutant log is this one:

    DDR3 CPU TB: PASS  (68k program completed all phases)
    ...
    DDR3 CPU TB: FAIL  1038 of 1557 chipset snoops never reached the core.

The 68k program passes, the DDR3 backdoor read passes, every port and
acknowledge assertion passes -- and 1038 snoops were dropped.  Nothing in this
bench except the new counter can see it, which is exactly why the fix without
the bench extension would have been worth very little.

A second, independent sign that the invalidations are functionally real and not
just tag writes: `--snoop` takes **96** channel line fills against `--ap040`'s
83.  The thirteen extra are lines the snoops invalidated and the program then
re-fetched.

## F6. Legs re-run after the fix, and why not all eight

| leg | result |
|---|---|
| `--snoop` | **PASS** (new) |
| `--snoopmutant` | **fails as required** (new) |
| `--ap040` | PASS, **byte-identical to the pre-fix run** |
| `--mmu` | PASS, **byte-identical to the pre-fix run** |
| `./run.sh` (TG68K) | PASS, **byte-identical to HEAD** |

`--chipbus`, `--nofill` and the three mutants were not re-run.  They ran against
RTL that differs from the current tree only by (a) comment text and (b) the
snoop holder, whose output is identically zero whenever `snoop_stb` is zero --
which it is in every leg without `+SNOOP`.  That is not an argument I am asking
to be taken on trust: `--ap040` and `--mmu` re-running byte-identically is the
measurement of it, on the two legs that exercise the most of the wrapper.

---

## 8. Files changed and commits

| commit | files |
|---|---|
| `ed2c50b` A fourth MMCM output at 37.8125 MHz | `rtl/clock/amiga_clk_xilinx.v`, `rtl/clock/amiga_clk.v`, `fpga/openaars/aars_v5.0/xc7a100t/clocks.xdc` |
| `70710c3` The AP68040 runs on its own clock | `rtl/soc/TG68K.vhd`, `rtl/soc/minimig_virtual_top.v`, `rtl/soc/minimig_mist_top.v`, `sim/ddr3_cpu/ddr3_cpu_tb.sv` |
| `0e1d303` No multicycle exceptions left on the AP68040 | `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` |
| `a67e5d5` Hold the chipset snoop across the crossing | `rtl/soc/TG68K.vhd`, `sim/ddr3_cpu/ddr3_cpu_tb.sv`, `sim/ddr3_cpu/run.sh` |
| (docs) | `findings/ap68040/plan-v2-with-ddr3.md`, `sim/ddr3_cpu/xsim_run_*.log`, this report |

`lib/AP68040` is **untouched**, still `c5d5cc3` on `x3-overlay`.  Nothing was
staged by wildcard; `fw/ctrl_832/version.h`, the `.wcfg` and
`tools/vivado/ila_fastram_check.py` are left as the user had them.

---

## 9. Self-review and concerns

**Is the TG68K branch genuinely untouched?**  Yes, and it is measured rather
than asserted: the control leg's log is byte-identical to HEAD's.  In the
source, `clk_cpu` appears only inside `g_ap040` (the kernel port map and the two
markers); `cpu_ce_phase` is `clkena_in`; `cpu_bus_settled` is a constant `'1'`;
the phase marker and the snoop holder are declared inside `g_ap040` and do not
exist in that build; `cpu.xdc` keeps every TG68K exception at its old value.
The one real behaviour change on the shared path -- `clkena_e` clearing at
phase 7 instead of phase 11 -- is neutral by the argument in §2.4 and by the
identical log.

**Is every crossing signal held until the far side consumes it?**  Now yes.  It
was not when I first wrote §2.3: I listed `snoop_stb` in that table and it was
the one signal in it that had no holder, which is exactly the finding the review
returned.  Fixed and, more importantly, now *testable*.

**Did the AP040 legs actually get faster, and do I know why?**  -24.4 %
uniformly, 1.323x against a predicted 1.333x, with `--chipbus` at -1.9 % as the
negative control.  The residual is fixed cost that does not scale with the core
clock.

**Are the constraints derived rather than copied?**  Yes, and they came out
different from the brief's suggestion in both directions -- 2 cycles rather than
3 one way, nothing at all the other.  Both derivations are written into the file
next to the exception.

**Is the bench header honest?**  Yes, and it now also says what it used to be
wrong about (`snoop_stb` tied low on a false premise about chip RAM
cacheability).

### Concerns, in the order I would act on them

1. **The uniform three-cycle enable gap is the D1 cadence's minimum spacing,
   and D1 did not boot on hardware.**  D1 was five phases at 3-3-3-3-4; the
   failure was never explained (the `slower` hypothesis was refuted in
   simulation, task 4).  D3 makes every gap three.  The differences are real --
   the chipset release is latched, `clkena_e` now clears outright, the chipset
   machine waits for the address to settle, and the snoop is held -- and any of
   those could have been the D1 fault.  But nobody knows, so **this is the
   thing to expect to bite on the first boot**, and the D1 debugging notes are
   the place to start if it does.
2. **`cpu_tgl -> cpu_tgl_d` is a same-edge hold check across two BUFGs, and its
   failure mode is a dead core rather than a mistimed one.**  If that flop
   captures the new value instead of the old, `cpu_ph2` never pulses and the CPU
   never advances.  Every `clk_38 -> clk_114` path in the design has the same
   check, so it is not a new risk class, but this one is load-bearing in a way
   the others are not.  Worth checking hold slack explicitly on the first build.
   (The controller has taken this.)
3. **`-setup -end 2` is one cycle tighter than the old island on the wrapper
   decode paths.**  They have had 26.45 ns and now have 17.63.  I believe they
   are a few nanoseconds, but I have not built, so it is the most likely place
   for a new timing failure to show up.
4. **The known-loose set.**  `akiko_req`/`akiko_wr` and the two bus routers read
   kernel outputs one `clk_114` cycle after they move and so want single-cycle
   timing; they get two.  They were loose by two before, so this is an
   improvement rather than a regression, and it is recorded in `cpu.xdc`.
5. **`report_exceptions` is owed.**  The exit criterion "no multicycles on the
   core" is met in the constraint source but has not been observed in a built
   design.  So is the `atc_ram -> {look,st}_snooped_reg` prediction.
6. **`--snoop` is a dedicated leg rather than being on everywhere.**  That keeps
   the phase timestamps comparable, but it means the ordinary legs still run
   with no snoop traffic.  Turning it on in every leg would be a better test of
   coherency under load; it would need a re-baseline, and it is a change worth
   making deliberately rather than as part of this one.
