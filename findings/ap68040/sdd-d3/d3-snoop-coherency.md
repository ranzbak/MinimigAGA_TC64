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
