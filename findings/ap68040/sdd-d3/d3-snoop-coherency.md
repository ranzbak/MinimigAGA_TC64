# D3 breaks chip-RAM coherency (2026-09-10, evening)

## Where D3 stands

`build/stage_ap040_d3stable` (+ `_ila` twin) **boots Workbench and gives
SysInfo 0.28x** against 0.23x pre-D3, i.e. **1.22x**, with margins that are
finally sane:

| | crossing `clk_114 -> clk_38` | `clk_114` | `clk_38` | violated |
|---|---|---|---|---|
| pre-D3 baseline `stage_ap040_x3cad` | n/a | -0.408 | n/a | 2 |
| `d3fix` (corrupted memory, AN_MemCorrupt) | +0.273 | +0.183 | +0.707 | 1 |
| `d3fix` retimed (**hung**, never booted) | +1.275 | +0.378 | +0.809 | 1 |
| **`d3stable`** | **+0.951** | +0.147 | +0.628 | 1 |

The candidate's change is small and is preserved beside this file as
`d3stable-candidate.diff` / `d3stable-candidate-TG68K.vhd` -- **uncommitted**,
because of the defect below. It suppresses the bus release for one cycle when
the walker has just taken the bus (`bus_fresh <= wk_active AND NOT wk_active_d`),
so a stale acknowledge from the previous access cannot be read as the new one.
That is why it boots where the retimed enable hung. **It does not touch the
snoop path.**

## The defect

With **Turbo Chip on**, running the demo *Way Too Rude*: uncleared pixels
accumulate at **random** points, then the picture freezes and the audio
distorts. The **machine survives** -- Workbench is reachable -- but the demo's
task is wedged and the OS reports it holding all available memory, i.e. its
allocation state or the free list is corrupted. Same family as the
`AN_MemCorrupt` Guru the marginal build produced, landing in one task instead
of killing the machine.

Uncleared pixels are the signature of a write that never reached memory, or a
read that returned stale data.

**The test case.** *Way Too Rude*, by Logicoma and Loonies, Revision 2020,
Amiga intro compo:
<https://files.scene.org/view/parties/2020/revision20/amiga-intro/logicoma_and_loonies_-_way_too_rude.zip>
Worth having because it is the only workload found so far that reproduces this,
and a party intro of that vintage leans hard on chunky-to-planar conversion and
bulk chip-RAM writes -- exactly the traffic a lost snoop corrupts.

## The controls, which make this a D3 regression and not a chipset bug

| build | Turbo Chip | demo | result |
|---|---|---|---|
| `d3stable` | on | *Way Too Rude* | **corrupts** |
| `d3stable` | **off** | *Way Too Rude* | **clean** |
| `d3stable` | on | roots2 and others tested | clean |
| **`x3cad` (pre-D3)** | **on** | ***Way Too Rude*** | **clean** |

The last row is the one that matters: same demo, same setting, clean before the
clock split and corrupting after. Turbo Chip is what routes CPU chip-RAM
accesses through the fast memory path and lets the 040 **cache chip RAM**; with
it off the question cannot arise. So the clock split broke the thing that keeps
a cached chip-RAM line coherent with chipset DMA: **the snoop**.

## Why the bench does not catch it

`snoop_stb` is one `clk_114` cycle wide (`rtl/sdram/sdram_ctrl.v:633` sets it at
ph2, `:492` clears it every cycle, `:190-196` registers it out) and the kernel
now samples on `clk_38`. Commit `a67e5d5` added `snp_stb_held`/`snp_addr_held`
to carry it across, and the bench was extended to sweep snoop spacings from 128
down to a gap of 3 with a delivery-ORDER check and a mutant that fails at
exactly one-in-three delivery. All of that passes.

But the bench drives **synthetic** snoops. On hardware they come from real
chipset DMA interleaved with real CPU traffic at whatever phase the SDRAM round
produces. A test that passes at every spacing it generates can still miss a
phase relationship it never generates. That this is demo-specific -- one demo of
several -- is consistent with a rarely-hit window rather than a systematic loss.

## Next steps, in order

1. Re-derive the snoop crossing against the hold as it stands, including
   `snoop_addr` alongside the strobe, the clear condition, and the interaction
   with `bus_fresh`. Prove it from RTL; three claims of the form "this is a
   level so sampling it later is safe" have already been wrong this week.
2. Instrument it rather than reason about it: the CPU ILA has no snoop probes.
   A build carrying `snoop_stb`, `snp_stb_held`, `snoop_addr`, `cpu_ph` and the
   cache's invalidate would show a lost snoop directly.
3. Consider whether the hold is the right shape at all, or whether the snoop
   should cross as a toggle with an acknowledge, like the walker and fill
   channels already do.

## What is NOT the cause

* Not the timing margin: `d3stable` has +0.951 on the crossing, three and a half
  times the build that corrupted memory, and the corruption persists.
* Not the router gating or the enable retiming: both were reverted or replaced
  in this candidate and the corruption remains.
* Not a pre-existing chipset defect: the pre-D3 control is clean.

---

# The snoop is NOT lost (2026-09-10, late evening)

Step 2 of the list above was done rather than argued, and it settles step 1 as
well: **no snoop has ever failed to cross.**

## What was built

`rtl/soc/TG68K.vhd` gained `dbg_snoop`, carried on `ila_cpu040`'s new probe8
(`rtl/soc/minimig_virtual_top.v`, `tools/vivado/build_ap040.tcl`).  Two
free-running counters ride it:

| field | clock | counts |
|---|---|---|
| `snp_in_cnt` (7:0) | `clk_114` | every snoop the BUS offered (`snoop_stb`) |
| `snp_out_cnt` (15:8) | `clk_38` | every snoop the KERNEL saw (`snp_stb_held` at a `clk_38` edge -- literally the value `ap040_cache`'s ce-independent `s_stb` port samples) |

plus the live `snoop_stb`, `snp_stb_held`, `cpu_ph2` and `snoop_addr(21:1)`.

Both start at zero out of configuration and are **never cleared**, so at any
instant `(in - out) mod 256` is the total number of snoops that failed to
cross, for all time.  A lost snoop is then a subtraction on a single sample
instead of a waveform to be argued about, and it does not matter when the
sample is taken relative to the failure: the difference is permanent.

Read with `tools/vivado/ila_snoop_check.tcl`.  Bitstream
`build/stage_ap040_d3snoop_ila` -- the `d3stable` tree plus the probes, and
timing equal or better than `d3stable` on every CPU clock pair
(`clk_114 -> clk_38` WNS 1.06 / WHS 0.07, `clk_38 -> clk_38` WNS 0.86, the
only violation the same 16 pre-existing `clk_gen_sdram -> clk_114` paths that
every build in this project has, including the shipping baseline).

## What was measured

The build **reproduces the defect**: Paul ran *Way Too Rude* with Turbo Chip on
and it corrupted as before.  Across samples taken before, during and after that
run:

```
=== sample  1  in 234  out 234  lost   0    ... idle at Workbench
=== sample  6  in 150  out 150  lost   0
=== sample 10  in  58  out  58  lost   0
--- demo started, corruption observed ---
=== sample  1  in  31  out  31  lost   0
=== sample  2  in   3  out   3  lost   0    ... counters idle: the demo's
=== sample  8  in   3  out   3  lost   0        task is wedged, as reported
```

`in == out` on every sample, `lost = 0` throughout, **including after the
corruption had already happened**.  (The absolute values move because the
counters are 8 bits and wrap; `lost` is computed from two counters read in the
same ILA word, so wrapping cannot affect it.)

## What that proves, and what it does not

Proved: every `snoop_stb` that `sdram_ctrl` offered arrived at the 040's cache
port across the `clk_114 -> clk_38` crossing.  The crossing stage D3 introduced
is clean, `snp_stb_held` is the right shape, and the "cross it as a toggle with
an acknowledge instead" idea in step 3 above would be solving a problem that
does not exist.

Not proved: that `sdram_ctrl` *raised* a snoop for every chipset write that
needed one (`sdram_ctrl.v:633` snoops slot 1 CHIP writes only), nor that the
cache *acted* correctly on each snoop it received.  Both are unchanged by D3,
and the pre-D3 control is clean, so neither can be the whole story on its own.

Also settled, from the reports rather than from argument: the crossing is not
under-constrained either.  `clk_114 -> clk_38` in `d3stable` reports WHS
**0.11 ns over 8069 endpoints, 0 failing** -- the coincident-edge hold that the
holder's clear depends on is checked, and met.

## The next suspect, and why it is weaker than it looks

Posted stores.  `ap040_post_stores` defaults to 1, and chip RAM
`$000000-$1fffff` is hard-wired cacheable on the D side
(`ap040_tg68k_compat.v:396`), so with Turbo Chip on a CPU store to chip RAM is
a store to a *cacheable* page and is therefore **acknowledged before it reaches
memory** (`ap040_cache.v:360`, `st_post_ok`).  D3 tripled the core's rate
against the bus and so tripled that drain window.  That is the other direction
of the same symptom: uncleared pixels are equally what a write that has not
landed yet looks like to display DMA or to the blitter.

Against it, from the RTL: the drain is **one slot deep** and every subsequent
access waits for it.  `ap040_cache.v:664` holds a following *store* while
`dr_active` -- including a cache-inhibited IO write such as `BLTSIZE`, which
takes the same `if (c_write)` branch -- and `:713` holds a bypassed *read* for
the same reason, "as the 68040 completes pending writes before a serialized
access".  So memory order is program order and a blitter cannot be started
before the pixels it is to read have landed.  The remaining exposure is only
display DMA reading a buffer at most one store late, which is a stale word for
one frame and self-correcting -- not pixels that accumulate.

It is being measured anyway, because that argument is exactly the shape of the
three that have already been wrong: `AP040_POST_STORES` is now a build-time
generic threaded from `minimig_openaars_top` down to `TG68K.vhd`
(`tools/vivado/build_ap040.tcl` takes it as a fourth `-tclargs`), and
`build/stage_ap040_d3nopost_ila` is the synchronous-store leg.

## Ruled out on this pass

* the snoop crossing (measured, above);
* the snoop crossing's timing (WHS 0.11 ns, 0 failing);
* the I-cache caching chip RAM behind a decruncher: `c_nocache` includes
  `mm_instr & cache_chip` (`ap040_tg68k_compat.v:437`), so instruction fetches
  from the chip window bypass the cache, and D3 did not touch it;
* a snoop displacing a store's own row invalidate and losing it: the recording
  and the clear of `store_inv_lost` are both inside the same `else if (ce)`
  block as the write that serves it (`ap040_cache.v:591,612,617`), so they
  cannot separate.  The one hole is a `C_FERR` fill-error invalidate taking
  priority in the same cycle, which needs a bus error, and undecoded space is
  auto-completed with $FFFF rather than faulted.

## Next

1. `build/stage_ap040_d3nopost_ila` -- posted stores off.  One demo run.
2. If it still corrupts: make chip RAM **non-cacheable** on the 040
   (`cache_chip`) as a bisect.  Clean would put the fault inside the 040's data
   cache; still corrupting would exonerate it and point at the wrapper and
   `sdram_ctrl`'s own `cpu_cache_new`, which is the path Turbo Chip switches
   on and the reason the Turbo-off control is clean.  It is also a plausible
   *fix* rather than only a probe: a real 040 Amiga marks chip RAM
   noncacheable through the MMU in `68040.library`, which is precisely why this
   class of bug cannot arise there.

---

# Found: chip-RAM CPU writes are POSTED IN THE CONTROLLER (2026-09-10, night)

The file's title is now a misnomer and is kept only so the commits that
reference it still resolve.  The snoop was never the problem, and neither was
the 040.  **The defect is in `sdram_ctrl`, it predates stage D3, and D3 merely
widened its window until this demo fell through.**

## The two controls that broke it open

Both from Paul, at the machine, within an hour:

1. **I and D caches disabled in SysInfo -- no difference.**  `movec` to CACR is
   honoured for real by this core (`ap040_core.v:3352` keeps bits 31 and 15,
   the 68040 DE/IE layout, and they are wired straight to the cache as
   `.de`/`.ie`, `ap040_tg68k_compat.v:421`); with DE clear, `bypass` forces
   every data access past the cache (`ap040_cache.v:196`).  So the corruption
   survives with the 040's caches out of the picture entirely.

   It cut deeper than intended, because the *external* cache does not follow
   CACR at all: `CACR_out <= ap040_maint & "001"` (`rtl/soc/TG68K.vhd:1104`)
   holds `cpu_cache_ctrl`'s enable bit high whatever the 040 does.  So the run
   with caches off still had `sdram_ctrl`'s own `cpu_cache_new` fully active --
   and by then it was the only cache left in the path.

2. **Kickstart turbo on, chip turbo off -- clean.**  This is the one that
   names the region.  Kickstart under Turbo goes through exactly the same
   SDRAM, the same `cpu_cache_new`, the same slots -- and it is fine, because
   Kickstart is read-only and is never a DMA target.  Chip RAM is the only
   window where a CPU write and chipset DMA meet in the same memory.

## The mechanism, end to end

A CPU write is acknowledged the cycle after it is handed to the write buffer:
`cpu_cache_ack <= 1'b1` in `CPU_SM_WRITE` (`rtl/sdram/cpu_cache_new.v`),
one cycle after `sdr_write_req` goes up and long before SDRAM has the data.
`cpuena = ccachehit` (`sdram_ctrl.v:281`), so that acknowledge is what releases
the CPU.  **Every CPU write in this design is a posted write, at the
controller, independently of whatever the CPU's own caches are doing.**

That is invisible for any region only the CPU can see.  Chip RAM under Turbo is
not such a region, and three things compound:

* a chip-RAM write can drain **only through slot 1**.  `wb_slot2ok` requires a
  non-zero bank -- "Reserve bank 0 for slot 1", `sdram_ctrl.v:459` -- and chip
  RAM is bank 0 (`ba <= 2'b00` for every chipset access);
* **slot 1 goes to the chipset first**: "we give the chipset first priority",
  `sdram_ctrl.v:561`;
* the chipset reads chip RAM straight out of that SDRAM, and **nothing
  forwards the buffered write to that read**.  There is not one comparison
  between `chipAddr` and `writebufferAddr` in the whole controller -- grep for
  it; the file has none.

So while the chipset is saturating slot 1 -- which is what a demo does -- the
CPU's write to chip RAM sits in the buffer for exactly as long as the chipset
is busy reading the buffer that write was meant to update.  The chipset reads
the old value.  Uncleared pixels, at random points, accumulating.

## Why every control fits

| control | result | why |
|---|---|---|
| Turbo chip on | corrupts | the above |
| Turbo chip off | clean | chip writes go via the 7 MHz chipset machine and never enter the buffer |
| **Turbo kick on, chip off** | **clean** | Kickstart is read-only, never a DMA target |
| 040 I+D caches off | **still corrupts** | the buffer is in `sdram_ctrl`, not in the 040 |
| pre-D3, turbo on | clean | narrower window |
| snoop counters | 0 lost | the opposite direction; irrelevant |
| roots2 and the other demos | clean | they do not saturate slot 1 against CPU chip writes the way a C2P intro does |

## Why stage D3 exposed it

D3 did not create this.  It raised the rate at which the CPU issues writes --
the core advances on every clk_38 edge instead of one clk_114 edge in four --
so more writes are in flight per unit of chipset time, and the odds that any
given buffered write is still unwritten when DMA reads it went up with it.
Turbo chip RAM has always been the Minimig feature that some software does not
survive; D3 moved this demo across that line.

**This is worth being precise about: it is a pre-existing hazard in
`sdram_ctrl`, not a stage D3 regression.**  It would be reachable by any core
fast enough, and it is reachable on the TG68K build too, given a workload that
saturates slot 1 hard enough.

## The fix

`cpu_wr_sync`: hold the CPU's acknowledge until SDRAM has actually taken the
write.

* `rtl/sdram/cpu_cache_new.v` -- new input `cpu_wr_sync` and new state
  `CPU_SM_WSYNC`.  Both write paths (16-bit via `CPU_SM_WRITE`, aligned 32-bit
  via `CPU_SM_WRITE_32BIT`) go there instead of acknowledging, and wait for
  `sdr_write_ack`.  `sdr_write_req` is already held until that acknowledge
  (`:534`), so the wait is all that is needed.
* `rtl/sdram/sdram_ctrl.v` -- the port, passed to its `cpu_cache` instance.
* `rtl/ddr3/ddr3_fastram.v` -- tied to 0.  The Zorro III DDR3 board is
  CPU-private; no DMA reads it, so a buffered write there can never be read
  stale.
* `rtl/soc/TG68K.vhd` -- `cpu_wr_sync <= sel_chipram`, and `sel_chipram`
  already folds in `turbochip_d`, so the signal is low whenever Turbo chip RAM
  is off and the whole question goes away with it.
* `rtl/soc/minimig_virtual_top.v` -- the wire.

Cost: nothing on Kickstart, Zorro, DDR3 or slow RAM, nothing when slot 1 is
uncontended, and a stall equal to the chipset's slot-1 occupancy when it is.
That is strictly better than Turbo chip RAM off, which pays a 7 MHz chipset
cycle on every access whether contended or not.

Risk noted rather than assumed away: `CPU_SM_WSYNC` waits on a signal the
controller produces, so a slot 1 that never yields would wedge the CPU.  It
always yields -- blanking alone guarantees it -- and the 040's own bus
watchdog (`ap040_bus_timeout`) would turn a genuine wedge into a halt rather
than a silent hang.

Build: `build/stage_ap040_d3chipsync_ila` (the `d3stable` tree + the snoop
counters + this fix).  `build/stage_ap040_d3nopost_ila` was built as the
posted-store A/B leg and is kept as a control; it was not tested on hardware,
because by the time it landed the two controls above had already moved the
fault out of the 040.

---

# Two real bugs, proven and fixed in simulation -- and neither is the demo's (2026-09-11, overnight)

Both hardware fixes failed. The second one made the corruption *worse* by
Paul's description, which is the signal that stopped the guess-and-build loop:
two speculative RTL changes deep, on a forty-minute cycle with a human at the
screen, debugging a moving target. The tree was put back to `d3stable` exactly
and the effort moved to building a reproducer.

## The gap that let this happen

`sdram_ctrl` + `cpu_cache_new` **under simultaneous CPU and chipset traffic is
simulated nowhere**. `sim/ddr3_cpu` drives `ddr3_fastram` with a behavioural
stand-in for the controller and has no chipset master at all; `sim/sdram_timing`
drives the real controller but only for read-path timing, one master at a time.
Every control we had pointed into that region and there was no way to look at
it except by reading source and building bitstreams.

## The new bench

`sim/sdram_coherency/` -- the real `rtl/sdram/sdram_ctrl.v`, the Alliance
vendor SDRAM model, the routed board delays, and both masters live. One process
owns each port (two processes assigning the same reg is a race that reads like
a DUT bug) and the main process asks them through mailboxes. Four checks:

| check | what it proves |
|---|---|
| C2P | chipset writes an address the CPU has never touched, CPU reads it |
| **C2P line buffer primed** | CPU reads A first, THEN the chipset writes A, then the CPU reads again |
| C2P two-way primed | same, with the line buffer displaced first, so the hit comes from the tag RAM ways |
| P2C | CPU writes, chipset reads -- with a retry that separates **late** from **lost** |
| P2C longword | the same by 32-bit write, which is what the AP68040 actually issues |

`+nobg` runs it with no background traffic at all and must pass; that validates
the bench before any failure it reports is believed. Runs in about a minute.

## What it found, on unmodified HEAD RTL

```
C2P line buffer primed   15 checked, 15 FAILED     got 5000  want f000
P2C                      20 checked,  6 FAILED     (6 late, 0 lost)
C2P                      20 checked,  0 FAILED
C2P two-way primed       15 checked,  0 FAILED
```

* **The line buffer is unsnooped, and it fails 100 % of the time.** The CPU
  returns the value from before the chipset's write, deterministically, with no
  contention needed. The two-way control passing in the same run is what makes
  it precise: the ways ARE snooped, the sixteen-byte buffer in front of them is
  not.
* **Every CPU write is posted at the controller and the chipset can read the
  address before it lands.** All six failures came back on the retry, so *late*
  and never *lost* -- which is exactly the posted-write mechanism, measured
  rather than argued.

Both fixes were then switched on (`+wrsync`, `-DCL_SNOOP`) and every check
passes, longword included. So the fixes are sound and they do what they claim.

One incidental finding worth keeping: **contention MASKS the line-buffer bug**
in this bench, because background CPU reads displace the buffer between the
prime and the re-read. A stale line buffer is therefore intermittent and
workload-shaped on hardware -- which is what "only this one demo" looks like.

## Why neither can be the demo's bug

`sdram_ctrl` and `cpu_cache_new` are **byte-identical in the pre-D3 build.**
Both bugs above are present in `stage_ap040_x3cad`, and `x3cad` runs *Way Too
Rude* with Turbo Chip on, cleanly. A defect that exists equally on both sides
of a clean/dirty control cannot be the differentiator.

That should have been said much earlier and it re-frames the search: **the
demo's fault is in what stage D3 changed**, which is the `clk_38` island, the
bus routers gated on `bus_step`, the registered `clkena`, and `bus_fresh` --
all of it in `rtl/soc/TG68K.vhd`, none of it in the controller.

## The bisect now building

`build/stage_ap040_d3div4_ila`: the D3 architecture **entirely intact**, with
the island clock divided by four instead of three -- 28.359 MHz, the pre-D3 CPU
rate. Everything downstream is ratio-agnostic (the phase marker derives
`cpu_ph` from a toggle, so it makes a one-in-N pulse for any N), so this is a
single-variable experiment:

* **clean** -> a rate-dependent window: something in the D3 wrapper races and
  D3 only made it likelier. Chase the windows, not the structure.
* **still corrupts** -> structural: the fault is in what D3 *is*, not how fast
  it runs, and the router gating and `clkena` retiming are next.

`CPU_CLK_DIVIDE` is now a proper build knob (`build_ap040.tcl` fifth
`-tclargs`, default 30), threaded to the MMCM, so this is reproducible and so
the island clock can be tuned later -- which the plan wants anyway.

## State of the tree

* Both fixes are **committed but default OFF**: `cpu_cache_new`'s `CL_SNOOP`
  parameter defaults to 0 and `cpu_wr_sync` is tied low at the `sdram_ctrl`
  instantiation, so a build is `d3stable` exactly unless switched on. They are
  proven improvements and should be turned on once the demo's actual fault is
  found -- turning them on now would just add variables to the search.
* `sim/sdram_coherency/` is the regression that locks both down.
* The board holds `build/stage_ap040_d3clsnoop_ila`, which corrupts. For a
  usable machine, program `build/stage_ap040_x3cad` (pre-D3, 0.23x, known
  good) or `build/stage_ap040_d3stable` (D3, 0.28x, corrupts only on this one
  demo with Turbo Chip on).

## The bisect is built and on the board

`build/stage_ap040_d3div4_ila` -- `CPU_CLK_DIVIDE=40`, so the island runs at
28.359 MHz, the pre-D3 CPU rate, with the D3 architecture otherwise untouched.
Timing is clean: `clk_114 -> clk_38` WNS 0.80, `clk_38 -> clk_38` **3.39**
(it was 0.54 at divide 30 -- the jump is the longer period, and is the proof
the divider actually took effect), zero failing endpoints apart from the same
16 pre-existing `clk_gen_sdram -> clk_114` paths every build in this project
has.  It is programmed and waiting.

**The test:** Turbo Chip on, Kickstart turbo on, caches on, run *Way Too Rude*.

* **Clean** -> a rate-dependent window.  D3 did not break anything structural;
  it made an existing race likelier.  Then the question is which race, and the
  candidates are the ones D3 touched in `rtl/soc/TG68K.vhd`: `bus_step` gating
  both routers, the registered `clkena`, `bus_fresh`.  Expect roughly 0.23x on
  SysInfo, i.e. the D3 speedup given back -- that is the price of the
  information, not a regression.
* **Still corrupts** -> structural, and the rate is irrelevant.  The fault is
  in what D3 *is*.  Highest-value next step then is not another build but
  extending `sim/sdram_coherency` with the real `TG68K.vhd` wrapper in front of
  the controller, so the D3 wrapper itself comes under the same scoreboard that
  just caught two bugs in an evening.

Either answer halves the search, which is the first time that has been true
since this started.

---

# Phase is proven; aligning the bus-cycle START is not the fix (2026-09-11)

## The three-point proof

Hardware, Turbo chip RAM on, *Way Too Rude*:

| island ratio | clock | vs the 16-phase SDRAM round | result |
|---|---|---|---|
| 3 | 37.81 MHz | coprime -- walks all 16 phases | corrupts |
| **4** | **28.36 MHz** | **divides 16 -- four fixed phases** | **CLEAN, 0.21x** |
| 5 | 22.69 MHz | coprime -- walks all 16 phases | corrupts WORSE: flashing lines in Workbench, then a memory-corruption Guru, 0.17x |

Ratio 5 is **slower** than the ratio that is clean, so this cannot be a
rate-dependent race -- a slower CPU cannot lose a window a faster one wins.
What ratio 4 has and the other two lack is a fixed phase relationship to the
SDRAM round.  Rate is eliminated by contradiction.

Ratio 5 also corrupted the **Workbench**, not just the demo, which says the
defect was never demo-specific; *Way Too Rude* was only the workload that
provoked it soonest.

Linear scaling holds across all three (0.21 x 37.8/28.4 = 0.28, and 0.17 is
ratio 5's prediction to two places), so the island clock buys speed exactly and
nothing else.

## The fix that did NOT work

`cpu_phase_ok` in `rtl/soc/TG68K.vhd`: hold `ramcs`/`ddrcs` off until the first
`enaWRreg` after `slower` has drained, putting every bus-cycle START back on a
fixed four-phase grid while the kernel keeps its own clock and full rate.

Result: **SysInfo 0.28x -- the gate costs nothing, exactly as predicted -- and
*Way Too Rude* still corrupts.**

So the cost model was right and the hypothesis was too narrow.  Aligning the
REQUEST is not sufficient.

## What that leaves, and the refinement it points to

Three readings, in the order they are worth testing:

1. **The return path, not the request path.**  This is the strongest, and it is
   what the failed fix actually rules in.  The gate pins when a select OPENS.
   It does nothing about when the answer ARRIVES: `ramready`/`cpuena` comes
   back on whatever clk phase the controller finishes on, and the kernel
   samples it on its own clk_38 edge.  At ratio 4 the kernel's edges divide the
   round, so completions land in a fixed relationship to it; at ratios 3 and 5
   they do not.  If the hazard is a completion sampled at a phase where some
   producer is mid-update, this fix could never have helped -- and the
   registered `clkena` decided one edge early (the D3-FIX) is exactly the sort
   of thing that would be sensitive to it.
2. **The grid is fixed but wrong.**  The gate lands starts on {3,7,11,15};
   pre-D3 used {5,9,13,1}.  Ratio 4's set is a third set and is clean, which is
   why "fixed" looked sufficient -- but it is cheap to shift the grid and see.
3. **Ratio 4 is clean for some other reason entirely** and the phase reading is
   coincidence.  Hard to sustain against three points, but not impossible.

`cpu_phase_ok` is kept in the tree.  It is cheap (0.28x is unchanged), it is
correct as far as it goes, and reading (1) says the next experiment sits on top
of it rather than replacing it.

## State

* Board holds `build/stage_ap040_d3phase_ila` -- 0.28x, corrupts on the demo.
* `build/stage_ap040_d3div4_ila` -- 0.21x, **stable**, the only clean D3 build.
* `build/stage_ap040_x3cad` -- 0.23x, pre-D3, stable; still the best thing to
  run if the machine has to be usable.
* Timing on the phase build: 0 failing endpoints on every CPU pair, but
  `clk_38 -> clk_38` WNS is **0.11 ns** against 0.63 in `d3stable`.  Placement
  variance rather than the gate, which is outside the kernel -- noted because a
  build with 0.11 ns has been worth distrusting before.

---

# Ruled out: `datatg68` sampled off-edge (2026-09-13)

The D4 contract enumeration found `data_in <- datatg68` to be the one crossing
into clk_38 that is neither held stable across the capture window nor shaped
into a pulse on the destination's edge.  `datatg68_r` in `rtl/soc/TG68K.vhd`
captures the read data on the same clk edge that decides `clkena_r`, so the
kernel gets data and enable from one instant.

Hardware, `build/stage_ap040_d3datareg_ila` (ratio 3, phase gate, data
capture; timing clean, 0 failing endpoints on every CPU pair): **Way Too Rude
with chip and Kickstart turbo still corrupts.**

So the contract gap was real on paper and is not the defect.  The change is
kept: it makes the crossing correct by construction for one register, the same
reasoning that kept `cpu_phase_ok`.

Crossed off so far, all with evidence: lost snoops to the 040, snoop crossing
timing, the 040's I/D caches, clock rate, phase alignment of bus-cycle starts,
the Kickstart turbo path, `cacheline_clr`, temperature, the AP68040 core itself
(identical commit pre-D3 and D3), upstream's cache race (made it worse), and now
the read-data crossing.  Every clk_114 -> clk_38 input on the contract list is
now either proven or fixed and still corrupting, which says the defect is NOT a
crossing INTO the kernel.  The remaining direction is the kernel's OUTPUTS into
clk_114 -- address, bus state, write data -- as sampled by sdram_ctrl.

---

# REALSDRAM bench: sound, and clean on disjoint memory (2026-09-14)

`sim/ddr3_cpu` with `REALSDRAM=1`: the real AP68040 and `TG68K.vhd` wrapper
driving the REAL `sdram_ctrl` + vendor SDRAM part, with the controller's own
enables and a chipset DMA agent running for the whole of the CPU's execution.

After three bench defects of my own (two processes on the chipset port; window
entries one word apart when a chipset write covers a longword pair; and
`{x[22:1],1'b0}` clearing bit 0 instead of doubling), the corrected run:

    DMA window: 3960 writes during CPU execution, 0 wrong
    DDR3 CPU TB: 2 passed, 0 failed

So every earlier "32 wrong words" result was the bench, never the design.  The
tell was cheap and is worth reusing: decode each wrong value back to the entry
that wrote it from the SDRAM model's WRITE log -- the aliasing appeared during
the preload, before the CPU was released.

What this does NOT show: the 68k program's data traffic never touched the DMA
window, so CPU and chipset shared no cache line and a coherency bug could not
have fired.  `DMA_OVERLAP` moves the chipset into the unused longword slots of
the lines phase 7 reads ($8008 $800C $804C $8088 $808C $80CC) and is the first
configuration of this bench that can fail for the reason the hardware does.

## Shared cache lines, one pass: clean (2026-09-14)

`REALSDRAM=1 DMA_OVERLAP=1`: the chipset writes, ~7 times in 8, into the unused
longword slots of the 16-byte lines phase 7 reads and writes ($8008 $800C
$804C $8088 $808C $80CC), for the whole of the CPU's execution.

    DDR3 CPU TB: PASS  (68k program completed all phases)
    DMA window: 3919 writes during CPU execution, 0 wrong

Controls for the same leg, both clean: CPU run on disjoint memory (3960 writes,
0 wrong) and the CPU-off control (3960 writes, 0 wrong).

So chipset DMA sharing cache lines with the CPU does not, on its own and at this
exposure, reproduce the hardware corruption.  Phase 7 is ~37 us of a ~1.9 ms
run, so the collision window was small; `P7LOOPS=40` repeats it forty times and
is the next run.  If that is clean too, the remaining difference from the
hardware is the SHAPE of the traffic -- a chunky-to-planar demo writes whole
bitplanes the chipset is concurrently displaying, not a handful of longwords --
and the kernel's outputs into sdram_ctrl, which no test has yet targeted.

## Shared cache lines, phase 7 repeated 40 times: clean (2026-09-14)

`REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=40`:

    INFO: program phase 8 at 2969830797.0 ps     (1.89 ms unlooped)
    DDR3 CPU TB: PASS  (68k program completed all phases)
    DMA window: 6457 writes during CPU execution, 0 wrong

Phase 8 moved out by ~1.08 ms, so all forty passes really ran (~27 us each),
with the chipset writing ~7 times in 8 into the unused slots of the lines those
passes read and write.  Sustained chipset DMA inside the CPU's cache lines does
not reproduce the hardware corruption in this bench.

That still leaves the direction every DMA agent so far has skipped: the CPU
writes and the CHIPSET reads.  The P2C probe (commit 99d7a12) is the first test
of that with the real CPU and real controller, and runs next.

---

# REPRODUCED IN SIMULATION: the chipset reads a value the CPU has already written (2026-09-14)

First failure in this investigation that is the DESIGN rather than the bench.

`REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=40`, the P2C probe: every pass of phase 7
the real AP68040 writes its pass counter to byte $8012; the chipset agent reads
it back through the real `sdram_ctrl`, bracketed by the bench's shadow of what
the CPU believes it wrote (recorded from its own bus cycle, before the
controller drains the write into SDRAM).

    P2C probe: 688 chipset reads of the CPU's counter, 40 value changes seen, 5 stale
    FAIL P2C probe at 2067254132.0 ps: chipset read 0022, CPU had written 0021 (before) / 0021 (after)
    DDR3 CPU TB: PASS  (68k program completed all phases)

Every stale read returns EXACTLY the previous pass's value, and the CPU's
program passes -- the CPU never sees a problem, only the chipset does.  That is
the hardware symptom's direction: uncleared pixels.

**The timing, from the SDRAM model's own write log** (byte $8012 = Row 32,
Col 9; 40 writes, one per pass):

    read 2067.2541us  want 0x0021: landed 2067.3405us = 86.3 ns AFTER the read began
    read 2210.5508us  want 0x001c: landed 2210.6371us = 86.3 ns AFTER the read began
    read 2295.7389us  want 0x0019: landed 2295.8253us = 86.3 ns AFTER the read began
    read 2495.4516us  want 0x0012: landed 2495.5379us = 86.3 ns AFTER the read began

Identical to the picosecond, four times.  The CPU's write was accepted into the
controller's write buffer before the chipset read started, and physically
reached SDRAM 86.3 ns -- about ten clk_114 cycles -- later.  A chipset read
inside that window samples the old value.

**Why that is enough for accumulating corruption.**  A display read would show
one stale frame and recover.  The BLITTER reads, combines and writes back, so a
stale source or destination word is written back permanently -- which fits
"uncleared pixels that accumulate" far better than any mechanism before it.

**The standing objection, and the test that answers it.**  `sdram_ctrl`'s write
buffer is byte-identical before stage D3, and pre-D3 is clean on hardware.  But
whether a chipset read can fall inside that 86 ns window depends on WHEN the CPU
writes relative to the sixteen-phase SDRAM round -- precisely what the island
clock ratio changes, and precisely what distinguished the clean ratio 4 from the
corrupting ratios 3 and 5.  Two runs settle it:

* `WRSYNC=1` -- `cpu_wr_sync`, proven in `sim/sdram_coherency` to remove
  posted-write lag.  Stale reads should go to zero if this is the mechanism.
* `CPU_RATIO=4`, no `WRSYNC` -- if ratio 4 is clean here as it is on hardware,
  the simulation reproduces the phase dependence, and the posted-write race is
  the D3 corruption.

Note the phase-alignment gate (`cpu_phase_ok`) is in the RTL under test here, and
did not prevent it -- consistent with that gate aligning when a bus cycle STARTS
while this race is about when the drained write LANDS.

## Mechanism confirmed: `cpu_wr_sync` removes the stale reads (2026-09-14)

Same run, `WRSYNC=1` (sdram_ctrl's `cpu_wr_sync` held high -- every CPU write
reaching the controller in this bench is chip RAM, so that is what the
wrapper's `sel_chipram` drives):

    P2C probe: 772 chipset reads of the CPU's counter, 40 value changes seen, 0 stale
    DDR3 CPU TB: 2 passed, 0 failed          (without WRSYNC: 5 stale in 688)

So the 86.3 ns posted-write lag is the mechanism, and holding the CPU's
acknowledge until SDRAM has the write removes it.  Cost: phase 8 moves from
3.007 ms to 3.168 ms, about 5 % of the run.

**The contradiction still to explain.**  `build/stage_ap040_d3chipsync_ila` put
`cpu_wr_sync <= sel_chipram` on hardware and Way Too Rude still corrupted.  The
genuine difference: that build predates `cpu_phase_ok` and `datatg68_r`, so
hardware has never run `cpu_wr_sync` together with the RTL that just passed
here.  `build/stage_ap040_d3wrsync_ila` is exactly that combination.  The
ratio-4 run (next) says whether this race also carries the hardware's phase
dependence; if it does not, it is a real defect but perhaps not the whole of
the D3 corruption.

## On the board: `stage_ap040_d3wrsync_ila` (2026-09-14, programmed over JTAG)

Ratio 3 (37.8 MHz), `cpu_phase_ok`, `datatg68_r`, and `cpu_wr_sync <= sel_chipram`
(commit 8847d0b); `CL_SNOOP` off.  Timing: 0 failing endpoints on every CPU
clock pair (`clk_114 -> clk_38` 0.97, `clk_38 -> clk_114` 1.39, `clk_38 -> clk_38`
0.32 ns); only the 16 pre-existing `clk_gen_sdram -> clk_114` SDRAM read-capture
paths, at -0.65 ns.

This is the first hardware build whose fix was reproduced failing and then
passing in simulation before it was built.  Test: power-cycle, a minute in
Workbench, Way Too Rude with chip and Kickstart turbo, then SysInfo (~0.28x
expected, minus a little for the synchronous chip-RAM writes).  JTAG only --
not flashed.

## Ratio 4: the race is WORSE, so it is not the D3 differentiator (2026-09-14)

Same P2C probe, `CPU_RATIO=4` -- the ratio that is CLEAN on hardware -- no
`WRSYNC`:

    P2C probe: 859 chipset reads of the CPU's counter, 40 value changes seen, 10 stale
    DDR3 CPU TB: PASS  (68k program completed all phases)

Ratio 3 gave 5 stale in 688; ratio 4 gives 10 in 859.  On hardware ratio 4 shows
no corruption at all.  So the posted-write race **does not carry the hardware's
phase dependence**: it is present at the clean ratio, and there it produces
nothing visible.

Conclusions, stated plainly:

* The race is a REAL defect and `cpu_wr_sync` is a correct fix for it (0 stale
  at ratio 3 with it on).  It stays in the RTL.
* It is **not the Way Too Rude corruption**.  This also resolves the old
  contradiction honestly: `d3chipsync` ran `cpu_wr_sync` on hardware and still
  corrupted because this race was never the cause.
* The build on the board (`d3wrsync`) is therefore expected to STILL corrupt.
  It is worth testing anyway -- it is correct, and a surprise either way would
  be information -- but it is not claimed as the fix.

The differentiator is still something that fails at ratio 3 and passes at
ratio 4.  Next: the block-burst probe (`P2CBLOCK=32`, the chunky-to-planar
shape) WITH `WRSYNC` on, so the known race is suppressed and any stale read is a
different mechanism, at ratio 3 and then ratio 4.

## Block bursts: the stall is the workload, not `cpu_wr_sync` (2026-09-14)

`P2CBLOCK=32` (32 longwords burst every pass, the chunky-to-planar shape),
`P7LOOPS=40`, ratio 3:

* **With `WRSYNC`**: 2 stale reads, stall watchdog, undecoded-hole check
  failed (that check sits after phase 7, which was never reached).
* **Without `WRSYNC` (control)**: 11 stale reads -- every one exactly the
  previous pass's value, the known posted-write race at full strength -- and
  the stall watchdog fired just the same.

So the "stall" is not `cpu_wr_sync` starving the CPU: the CPU was still writing
its block at 4.52 ms in the WRSYNC run, and the watchdog trips without WRSYNC
too.  Forty block passes under a chipset agent that barely releases slot 1
simply run longer than 300,000 cycles without a phase marker.  For the board
build this means no evidence that `cpu_wr_sync` raises hang risk -- though a
bench this contrived cannot prove it harmless either.

The two stale reads WITH `WRSYNC` were bench bug five: the shadow `chipmem`
is written at the START of a write access, not at its acknowledge, so during a
`cpu_wr_sync` hold it shows a value the CPU has not been told is written.  Fixed
in c289caa (the probe now uses an acknowledge-time shadow; under DMA_OVERLAP
the watchdog is 1,000,000 cycles and TIMEOUT 12 ms).  The WRSYNC block probe is
being rerun, correctly judged, at ratio 3 and ratio 4 with `P7LOOPS=10`.

## `cpu_wr_sync` removes the race completely, at both ratios (2026-09-14)

Block-burst probe (`P2CBLOCK=32`), `WRSYNC` on, judged against the acknowledge
(`p2c_acked`), `P7LOOPS=10`:

    ratio 3: P2C probe: 481 chipset reads, 464 value changes seen, 0 stale   PASS, no stall
    ratio 4: P2C probe: 551 chipset reads, 542 value changes seen, 0 stale   PASS, no stall

With it off, the same traffic gave 11 stale reads.  So the posted-write race is
fully accounted for and fully fixed, for single words and whole blocks, at the
hardware-corrupting ratio and the hardware-clean one.

**What that leaves.**  This bench now has no failure that differs between ratio
3 and ratio 4, so it does not yet reproduce what distinguishes the corrupting D3
build.  The thing it has never run is the MMU TABLE WALKER against the real
controller -- and the walker's bus router is the most ratio-dependent machinery
in the wrapper: `bus_step` skips the single clk edge before each kernel edge
(`NOT cpu_ph`), which falls at a different place in the SDRAM round at ratio 3
than at ratio 4, and `bus_fresh` masks the acknowledge for one cycle after the
walker takes the bus.  The OS on the hardware runs with translation on; the
`--mmu` leg has only ever run against the behavioural memory model.  Next:
`--mmu` under `REALSDRAM` + `WRSYNC`, ratio 3 and ratio 4.
