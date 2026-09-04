# Findings

Investigation notes and fix guides for the OpenAARS Minimig core. Each
subdirectory has its own README with an ordered work plan.

| Area | Directory | Covers |
|---|---|---|
| PAL → HDMI video | [adv7511/](adv7511/) | 13 fixes: line flicker, unstable H/V offset controls, geometry, 50/60 Hz switching |
| AP68040 CPU swap | [ap68040/](ap68040/) | Compatibility assessment ([compatibility.md](ap68040/compatibility.md)) and measured headroom ([performance.md](ap68040/performance.md)): fits at 28.7k LUTs after one RAM-primitive fix, 47 MHz standalone, 37.8 MHz realistic in-system; DDR3 fast RAM assessment ([ddr3-fast-ram.md](ap68040/ddr3-fast-ram.md)); DLL-off in-domain DDR3 as the no-MIG alternative ([ddr3-dll-off.md](ap68040/ddr3-dll-off.md)); the seven DRAM masters and how the SDRAM/DDR3 split must serve chipset, OSD core and RTG ([memory-masters.md](ap68040/memory-masters.md)) |
| DDR3 fast RAM | [ddr3/](ddr3/) | **Design + implementation plan** for Zorro-III fast RAM on the on-board DDR3 using the vendored `core_ddr3_controller` (DLL-off, 100 MHz island); Z2 RAM and the RTG framebuffer stay on SDRAM |
| Timing constraints | [constraints/](constraints/) | 12 fixes: SDRAM delay formulas, disabled hold checks, unconstrained HDMI output, unsynchronised reset, SDRAM read capture clock, blanket multicycles — **verified in Vivado**, see [constraints/verification-vivado.md](constraints/verification-vivado.md) |

## Work overview

Everything found so far, in the order it should be done. Effort: S = an hour,
M = a day, L = several days including hardware verification.

| # | Item | Area | Effort | Severity | Depends on |
|---|---|---|---|---|---|
| 1 | ✅ SDRAM output/input delay formulas | [constraints/fix-01](constraints/fix-01-sdram-delay-formulas.md) | S | High | — |
| 2 | ✅ `dll_28 → clk_114` hold multicycle (`-end`) | [constraints/fix-02](constraints/fix-02-dll28-hold-multicycle.md) | S | High | — |
| 3 | ⛔ SDRAM read capture clock (MMCM + RTL + XDC) — **reverted, does not run on hardware at any capture phase**; not a read-timing fault, see the doc | [constraints/fix-12](constraints/fix-12-sdram-read-capture-clock.md) | L | High | 1 |
| 4 | ◐ Un-mask and rebuild ADV7511 output constraints (done: IOB packing, explicit false path), ODDR on `dv_clk` (RTL, open) | [constraints/fix-03](constraints/fix-03-adv7511-output-unconstrained.md) | M | High | — |
| 5 | Synchronise reset into `clk_148` | [constraints/fix-11](constraints/fix-11-reset-into-clk148.md) | S | High | — |
| 6 | ✅ Replace CDC false path with clock groups + `-datapath_only` | [constraints/fix-05](constraints/fix-05-cdc-false-path.md) | S | Medium | 5 |
| 7 | Swap crossed offset ports (50 Hz instance) | [adv7511/fix-01](adv7511/fix-01-crossed-offset-ports.md) | S | High | — |
| 8 | Synchronise + frame-latch the offset bus | [adv7511/fix-03](adv7511/fix-03-offset-cdc.md) | S | High | 6 |
| 9 | Bound the write address, stop writes in vblank | [adv7511/fix-05](adv7511/fix-05-write-address-runaway.md) | S | High | — |
| 10 | Stop resetting `hz_count` mid-line; adaptive VTOTAL | [adv7511/fix-06](adv7511/fix-06-hcount-reset-genlock.md) | M | High | — |
| 11 | Clamp read address inside its buffer | [adv7511/fix-04](adv7511/fix-04-read-address-underflow.md) | S | Medium | — |
| 12 | Implement vertical offset | [adv7511/fix-02](adv7511/fix-02-vertical-offset-missing.md) | S | Medium | 8 |
| 13 | DDS increment | [adv7511/fix-07](adv7511/fix-07-dds-increment.md) | S | Medium | — |
| 14 | Line-length divider, fixed point + sanity gate | [adv7511/fix-08](adv7511/fix-08-line-length-divider.md) | M | Medium | 13 |
| 15 | Geometry: `PAL_HD_H_RES`, read window in DE coordinates | [adv7511/fix-09](adv7511/fix-09-geometry-hres.md) | M | Medium | 14 |
| 16 | 50/60 Hz decision: hysteresis, vsync-gated | [adv7511/fix-10](adv7511/fix-10-mode-detect-hysteresis.md) | S | Medium | — |
| 17 | ✅ Narrow TG68K multicycles off `[all_registers]` | [constraints/fix-04](constraints/fix-04-tg68k-blanket-multicycle.md) | M | Medium | 2 |
| 18 | ✅ `clk_sd_114` hold companion / delete `wizard.xdc:27` | [constraints/fix-06](constraints/fix-06-missing-hold-companion.md) | S | Medium | 3 |
| 19 | Collapse the two video pipelines into one | [adv7511/fix-11](adv7511/fix-11-collapse-pipelines.md) | M | Low | 7–16 |
| 20 | Interlace: fix or delete the multi-driven counter | [adv7511/fix-12](adv7511/fix-12-interlace-multidriver.md) | M | Low | 19 |
| 21 | Fake SPI generated clocks, MMCM renames | [constraints/fix-08](constraints/fix-08-generated-clocks.md) | S | Low | — |
| 22 | ✅ Duplicate clock group | [constraints/fix-07](constraints/fix-07-duplicate-clock-group.md) | S | Low | — |
| 23 | ✅ Unconstrained ports (re-check on a fresh build) | [constraints/fix-09](constraints/fix-09-unconstrained-ports.md) | S | Low | — |
| 24 | Video housekeeping (RAM port ties, bypassed syncs, dead logic) | [adv7511/fix-13](adv7511/fix-13-housekeeping.md) | S | Low | — |
| 25 | ✅ Comment drift, stale commented-out constraints | [constraints/fix-10](constraints/fix-10-comment-drift.md) | S | Cosmetic | all |
| 26 | AP68040: RAM primitive fix, self-tests, OOC synth | [ap68040/README §A1](ap68040/README.md) | S | — | — |
| 27 | AP68040: wrapper, bring-up at 28 MHz on the 16-bit bus | [ap68040/README §A2](ap68040/README.md) | M | — | 17, 26 |
| 28 | 16-byte line port, 32-bit fast-RAM path, SDRAM fill back-end, **MMU walker port** | [ap68040/README §B1–B3](ap68040/README.md) | M | — | 27 |
| 29 | DDR3 bench: DLL-off init, measure tDQSCK | [ap68040/README §C1](ap68040/README.md) | S–M | — | — |
| 30 | DDR3 DLL-off controller @ 56.7 MHz, trained capture | [ap68040/README §C2](ap68040/README.md) | L | — | 29, 6 |
| 31 | DDR3 arbiter (RTG watermark + CPU line port); fast RAM + RTG move; SDRAM slot cleanup | [ap68040/README §C3–C4](ap68040/README.md) | M | — | 28, 30 |
| 32 | CPU `clkena` every 3 → 37.8 MHz; then sibling clock | [ap68040/README §D1–D2](ap68040/README.md) | S+M | — | 27 |

Items 1–6 are constraint/clocking work and should land first — they change what
the timing report says about everything after them. Items 7–16 are the video
RTL. Items 26–32 are the CPU and memory upgrade; 29 can start any time. Verification recipes: [adv7511/verification.md](adv7511/verification.md),
[constraints/verification-vivado.md](constraints/verification-vivado.md),
[sim/sdram_timing/](../sim/sdram_timing/).

## Read the constraints first

The two sets overlap. An unconstrained or mis-constrained interface produces
symptoms indistinguishable from an RTL bug, so
[constraints/fix-01](constraints/fix-01-sdram-delay-formulas.md) through
[fix-03](constraints/fix-03-adv7511-output-unconstrained.md) should land before
the video RTL work — otherwise the remaining artefacts cannot be attributed.

They also share a root cause in one place: the `dll_28`/`clk_114 → clk_148`
crossings are false-pathed in [constraints/fix-05](constraints/fix-05-cdc-false-path.md)
and carry an unsynchronised offset bus ([adv7511/fix-03](adv7511/fix-03-offset-cdc.md))
and an unsynchronised reset ([constraints/fix-11](constraints/fix-11-reset-into-clk148.md)).
Fix them together.

The Vivado run also exposed **49 hold violations on the VGA RGB registers that
feed the HDMI upsampler** — hidden by a mis-specified multicycle
([constraints/fix-02](constraints/fix-02-dll28-hold-multicycle.md)). That is a
candidate cause for pixel-level noise independent of everything in `adv7511/`.

## SDRAM: simulated, not just inferred

[constraints/sdram-sim-results.md](constraints/sdram-sim-results.md) — the
controller driven against the Alliance vendor model with the routed-design
delays: at the slow corner every chipset read burst comes back **one word
late** (`chipRD` = Hi-Z), at the fast corner it is correct. Testbench in
[sim/sdram_timing/](../sim/sdram_timing/), one second per run.

## Status

2026-09-04: the constraint items are implemented and verified — see
[constraints/implementation-status.md](constraints/implementation-status.md).
Same day: [constraints/fix-12](constraints/fix-12-sdram-read-capture-clock.md)
(SDRAM read capture clock) implemented in RTL + MMCM + XDC; full build meets
timing, vendor-model bench passes at all four corners. Not yet tested on
hardware. Other RTL items untouched.

### Original note

Analysis only. No RTL or constraint files have been modified. Vivado was run
read-only against the existing routed checkpoint; proposed constraints were
applied in memory and discarded.

Added, not modified: `sim/sdram_timing/` (testbench) and
`lib/models/AS4C16M16SA.v` (vendor model copied from `~/work/fpga/Xilinx/wf68k30/sim/ip/`,
with its default speed-grade define guarded — see the comment in its header).
