# DDR3 in DLL-off mode — the non-MIG option

Refers to `~/work/fpga/Xilinx/ddr3-dll-off/signal-test` (June 2024, on the
XC7A35T board): a 50 MHz `clk_wiz`, differential CK forwarded from fabric, and
a state machine that sequences `RESET#` (200 µs) and `CKE` (500 µs). No
commands, no data path, no mode-register writes yet — it is the first 130 lines
of a controller, not a result. Companion to [ddr3-fast-ram.md](ddr3-fast-ram.md).

## Verified against the schematic and the Micron datasheet

Sources: `QMTECH_XC7A75T_100T_200T-CORE-BOARD-V01-20210109.pdf` sheet 2,
`Software_XC7A100T/DDR3.ucf`, `~/work/fpga/docs/2Gb_DDR3_SDRAM-1283766.pdf`
(Micron 2 Gb DDR3, Rev. S) §"DLL Disable Mode" p.123 and Table 74 p.126.

**Board**

| | | Consequence |
|---|---|---|
| Part | **MT41K128M16JT-125:K** (DDR3L, 2 Gb, x16, 1.35 V nominal, 1.5 V tolerant) | 256 MB |
| Bank | **all 47 signals on bank 16, nothing else on it** | `IDELAYCTRL` in bank 16 only; no pin conflicts |
| VCCO_16 | **1V5** (sheet 1) | use `SSTL15` / `DIFF_SSTL15`. The vendor UCF says `SSTL135`; it works electrically but mis-states the rail |
| VREF | 1k/1k divider from 1V5 = 0.75 V to the DRAM's VREFCA/VREFDQ. The bank's VREF-capable pins C17 and B25 carry `DDR_A3` / `DDR_D11` | FPGA must use `set_property INTERNAL_VREF 0.75 [get_iobanks 16]` |
| CK | F18/F19 = `IO_L3P/N_T0_DQS_16`, a true pair; 100 Ω differential termination at the DRAM (R32) | forward with `OBUFDS` from an `ODDR` |
| DQS0 / DQS1 | B20/A20 (`L15P/N_T2_DQS_16`), A23/A24 (`L21P/N_T3_DQS_16`) | proper pairs; usable by MIG's PHY |
| ODT | pin wired (G19) | must be held LOW in DLL-off (datasheet) |
| CS# | pull-up 4.7k; RESET# pull-down 4.7k; ZQ 240 Ω 1 % | standard |
| Clock source | Y1 SG-8002JC 50 MHz → `SYS_CLK` U22 (matches `clocks.xdc`) | MMCM from `clk_50` as today |
| Address/command termination | none (no VTT rail) | fine point-to-point at these rates |

**Datasheet, DLL disable mode** (quoted where it matters):

* "The DRAM is **targeted, but not guaranteed**, to operate similarly to the
  normal mode" and note 9: "Micron does not warrant compliance with normal
  mode timings" — this is a best-effort mode, not a spec'd one.
* `tCK (DLL_DIS)` **min 8 ns**, max 7800 ns → **113.4375 MHz (8.815 ns) is
  legal**, so is any slower clock.
* **CL = 6 and CWL = 6 only.** `RL (DLL_DIS) = AL + CL − 1 = 5`.
* **`tDQSCK (DLL_DIS)`: 1 ns min, 10 ns max** — "could be larger than tCK".
  `tDQSQ` / `tQH` (data-to-strobe) unchanged.
* **ODT (including dynamic ODT) is not supported**; RTT_nom and RTT_WR must
  be programmed to 0 and the ODT ball held LOW.
* `tWR` becomes the greater of 5 CK or 15 ns.
* MR1[0] may be set to DLL-disable **during initialisation**; the
  self-refresh frequency-change dance is only for switching modes on a
  running device. Init directly into DLL-off at the final clock and it never
  applies.

## What the 1–10 ns tDQSCK means — a correction

The 9 ns spread is the specification envelope over process, voltage and
temperature. One board at one temperature sits at a single point inside it,
and drifts by a few ns with temperature. Two consequences:

1. **At 113 MHz the read data cannot be captured on any fixed phase without
   training**, and even a trained phase has a 4.4 ns eye against several ns of
   drift. That is the SDRAM read-path failure mode
   ([../constraints/sdram-sim-results.md](../constraints/sdram-sim-results.md))
   all over again, with less margin.
2. **DQS-clocked capture ("option A" below) is not a hand-rolled option on
   7-series HR banks.** The `_DQS_` pins are byte-group markers, not
   clock-capable pins; a DQS input cannot reach an `IDDR` clock through
   `BUFIO`/`BUFR`. The only DQS-clocked capture path on this silicon is the
   hard PHY — `PHASER_IN`, `ISERDESE2` in memory mode, `IN_FIFO` — which is
   MIG's PHY. Writing to those primitives by hand is not smaller than using
   MIG.

So the realistic hand-rolled design is **fixed-phase capture, trained**:

* Capture DQ on a dedicated MMCM sibling of `clk_114` whose phase is set at
  run time through the MMCM's dynamic phase-shift port; per-lane fine trim
  with `IDELAYE2` on the DQ inputs (`IDELAYCTRL` in bank 16, 200 MHz MMCM
  reference — nothing is *clocked* at 200 MHz).
* Training at init: write a pattern to a reserved row, sweep phase, pick the
  eye centre. Re-check periodically (a read of the reserved row every few ms
  alongside refresh) and nudge the phase — cheap insurance against drift.

## Recommended clock: 56.7 MHz first, 113 MHz as the stretch goal

Run CK at **`clk_114` ÷ 2 = 56.72 MHz** (tCK 17.63 ns):

* DDR data rate is then **one beat per `clk_114` period** — every beat is
  8.8 ns wide. DQ can be captured by ordinary flops on the trained sibling
  clock; no `IDDR` on the read side, and a 4–5 ns drift still sits inside the
  eye after a single training at power-up.
* The write side is trivial: DQ/DM from `ODDR` on `clk_114`, DQS from an
  `ODDR` on the 180° sibling so its edges land mid-bit, CK from an `ODDR` on
  `clk_114` ÷ 2.
* Controller entirely in the `clk_114` domain, commands on every other
  cycle, no CDC, no new clock group.
* Bandwidth **227 MB/s** — the same as the SDRAM today, so the gains are the
  ones that matter: a private port (no chipset contention), 256 MB, and a
  16-byte line in 8 clocks ≈ 70 ns + tRCD + CL6 (≈ 120 ns) instead of 12
  `clkena`. RTG at 110 MB/s fits, but takes half of it.

Then, once that works and the training loop has shown how much this board
drifts, **113 MHz** (454 MB/s) is the same design with `IDDR` capture and a
4.4 ns eye — go there only if the measured drift leaves margin.

50 MHz (the experiment's clock) is fine for the first bring-up on the bench,
but as a target it is strictly worse than 56.7 MHz: it needs a CDC to reach
`clk_114` and buys nothing.

## Resource cost — the decisive argument for the hand-rolled core

Measured in this session (Vivado 2023.2, xc7a100t-2, out-of-context,
[synth-reports/util_sdram_ctrl.rpt](synth-reports/util_sdram_ctrl.rpt)):

| Block | LUTs | FFs | BRAM | Hard blocks |
|---|---|---|---|---|
| `sdram_ctrl` proper (this project) | **140** | 262 | 0 | — |
| `cpu_cache_new` inside it | 1,061 | 391 | 0 | — |
| Whole `sdram_ctrl` + cache | 1,201 | 653 | 0 | — |

Documented, not measured here (UG586, DDR3 x16, 4:1, user interface; no MIG
build survives in the 2020 tree — both run directories post-date its removal):

| Block | LUTs | FFs | BRAM | Hard blocks |
|---|---|---|---|---|
| MIG 7-series DDR3 controller + PHY | **≈ 5,000–6,000** | ≈ 5,000–5,500 | 1–2 | 1 MMCM + 1 PLL, PHY_CONTROL, PHASER_IN/OUT ×2–4, IN/OUT_FIFO, IDELAYCTRL, `ui_clk` domain |
| DLL-off controller, DDR3 at 56.7 MHz, IDDR/ODDR PHY (estimate from `sdram_ctrl` + init/training/refresh FSMs) | **≈ 600–1,000** | ≈ 500 | 0 | 2 MMCM outputs, IDELAYCTRL, 16 IDELAYE2 |

Against the device budget after the 68040 swap:

| | LUTs |
|---|---|
| Current design | 14,375 |
| − TG68K, + AP68040 with FPU (measured, [performance.md](performance.md)) | ≈ 39,000 |
| + MIG | ≈ 44,500 (70 %) |
| + DLL-off controller | ≈ 40,000 (63 %) |

Both fit, but MIG spends 5k LUTs — a third of the whole current Minimig — on
a PHY calibrated for 800 MT/s that would then be run at 800 MT/s only to be
throttled by a 28–38 MHz CPU, and it adds a clock domain, a PLL, and 300 ns
of latency. The DLL-off core spends a tenth of that and lives in `clk_114`.
The trade is training-based read capture and Micron's "targeted, not
guaranteed" — a risk you can measure on the bench in an afternoon with the
signal-test build, before committing.

That is the case for DLL-off: not bandwidth, not latency, but **≈ 4–5k LUTs
and a clock domain kept for the core**, at a bandwidth this CPU cannot exceed
anyway.

## Updated comparison

| | SDRAM today | DDR3 via MIG | DDR3 DLL-off @ 56.7 MHz | DDR3 DLL-off @ 113 MHz |
|---|---|---|---|---|
| Clock domain | `clk_114` | `ui_clk` + CDC | **`clk_114`** | **`clk_114`** |
| Peak bandwidth | 227 MB/s | 1.6 GB/s | 227 MB/s | 454 MB/s |
| 16-byte line | 70 ns | 1 beat | 70 ns | 35 ns |
| Miss latency | 100–250 ns (+ slot wait) | ≈ 300 ns | ≈ 120–150 ns | ≈ 80–100 ns |
| Read capture | fixed phase, drifts (fix-12) | hard PHY, calibrated | fixed phase, **trained, 8.8 ns eye** | fixed phase, trained, 4.4 ns eye |
| Shared with chipset | yes | no | no | no |
| Spec status | — | fully supported | "targeted, not guaranteed" | same, less margin |

## Background: what DLL-off mode is (original notes)

JEDEC DDR3 (JESD79-3) allows the DRAM's DLL to be disabled (MR1 A0 = 1) for
clock rates below the DLL's lock range: **tCK ≥ 8 ns, i.e. ≤ 125 MHz**, down to
tCK max. The device then behaves like a slow DDR SDRAM:

* CL and CWL are fixed at **6**; `RL = CL − 1` to `CL` — the DRAM's own read
  data timing loses its CK alignment.
* **tDQSCK(DLL_OFF)** is several nanoseconds and PVT-dependent (Micron
  specifies a wide window for the MT41K family; take the exact min/max from
  the MT41K128M16 datasheet's "DLL Disable Mode" table). This is the whole
  design problem: read DQ/DQS arrive at an uncertain offset from CK.
* Everything else stays: full init sequence (MR2, MR3, MR1, MR0, ZQCL),
  refresh every 7.8 µs (3.9 µs above 85 °C), tRFC 160 ns for a 2 Gb part,
  tRCD/tRP ≈ 13.9 ns, BL8 or BC4 bursts, data on both edges of DQS, DM per byte.
* ODT and write leveling can be off at these rates on a single short-trace x16
  device.

## Why it is attractive here

**It puts the DDR3 inside the Minimig clock domain.** 113.4375 MHz is
tCK = 8.815 ns — just inside the 8 ns limit. The controller runs on `clk_114`
like `sdram_ctrl` does today, with no MIG, no 200 MHz clocks, no `ui_clk`, no
asynchronous FIFOs, and no new clock group. The "how do I make MIG timing
compatible with the Minimig constraints" problem disappears because there is
nothing to make compatible.

| | SDRAM today | DDR3 via MIG | DDR3 DLL-off @ 113 MHz |
|---|---|---|---|
| Clock domain | `clk_114` | own `ui_clk` 100 MHz + CDC | **`clk_114`** |
| Peak bandwidth | 227 MB/s | 1.6 GB/s | **454 MB/s** (2 × 16 bit × 113 MHz) |
| 16-byte line | 8 clocks, 70 ns | 1 beat | **4 clocks, 35 ns = one `clkena`** |
| First-data latency (miss) | slot wait 0–141 ns + 70 | ≈ 300 ns | tRCD + CL6 + capture ≈ **80–100 ns** |
| Shared with chipset | yes | no | **no** |
| Capacity | 32 MB | 256 MB | 256 MB |
| Controller | 790 lines, yours | Xilinx IP | ≈ 800–1200 lines, yours |

454 MB/s is four times what a 38 MHz 68040 plus a 720p RTG framebuffer can
consume. Latency is the best of the three. And it stays a private port —
[ddr3-fast-ram.md](ddr3-fast-ram.md) reason 1 — which is the main gain.

## Read capture — original notes (see the correction above: option A is MIG's PHY)

At 113 MHz a DDR beat is 4.4 ns wide. With tDQSCK(DLL_OFF) uncertainty of the
same order or larger, the read data cannot be captured on a fixed phase of
`clk_114`. Two workable structures, in order of preference:

**A. Source-synchronous capture on DQS (the proper way).**
`IDELAYE2` on each DQS (needs one `IDELAYCTRL` with a 200 MHz reference — an
MMCM output, not a MIG), delayed ≈ 90° into the clock pin of `IDDR`s on the
DQ byte lane; the two beats then cross into `clk_114` through a 4-deep
per-lane FIFO addressed by a DQS-toggle counter. This is what MIG's PHY does,
minus the leveling. The 200 MHz reference only feeds `IDELAYCTRL`; nothing in
the design is clocked by it.

**B. Fixed-phase capture with read training (simpler PHY, more logic).**
Capture DQ with `IDDR` on a phase-shifted copy of `clk_114` (MMCM output, phase
selected at run time via the MMCM's dynamic phase shift port) and find the
phase by reading back a training pattern after init, like MIG's read
calibration in miniature. Re-train on temperature is the weakness; a fixed
phase found at cold start can drift out of a 4.4 ns eye.

At 50 MHz (the experiment's clock, 10 ns beats) option B with a fixed phase is
plausible without training — but 50 MHz DDR3 is 200 MB/s, a 16-byte line takes
80 ns, and the port would need a CDC to `clk_114` after all. The 113 MHz
in-domain version is the one worth building.

Write side is easy at either rate: `ODDR` for CK, DQS, DQ and DM, DQS driven
centred on DQ (a 90° MMCM sibling clock for the DQS `ODDR`), CWL = 6 counted
in the controller.

## Where it sits relative to the other options

* Same 16-byte line port as the SDRAM and MIG back-ends
  ([performance.md](performance.md) step 2, [ddr3-fast-ram.md](ddr3-fast-ram.md)):
  fill = one command, four clocks, ready in about a `clkena` and a half.
* Compared to MIG: less bandwidth (irrelevant), better latency, no CDC, no
  IP, but a PHY-lite and a controller to write and validate — roughly the
  same size job as the SDRAM controller already in the tree, plus the read
  capture, which is the part that needs a scope and patience.
* Compared to staying on SDRAM: private port, 8× capacity, better line
  latency, and it takes the RTG stream off the chipset's memory.

## Risks and unknowns

* **tDQSCK(DLL_OFF) for the MT41K128M16-15E** — the number that decides
  whether option B is even considered. Read it from the datasheet before
  choosing.
* Signal integrity without ODT at 113 MHz on the core board: the traces are
  short and MIG ran them at 333–400 MHz, so likely fine, but verify eye on DQS
  with a scope during bring-up.
* The 100T core board pinout (`Software_XC7A100T/DDR3.ucf`, 47 pins, SSTL135)
  puts CK/DQS on clock-capable pins as MIG requires — that also satisfies the
  `IDDR`/`BUFIO` needs of option A. Check bank assignment for `IDELAYCTRL`
  coverage (one per bank).
* Refresh scheduling has to be the controller's, as in `sdram_ctrl`; DLL-off
  does not relax tREFI.
* Open lightweight DDR3 controllers for 7-series without MIG exist; worth a
  survey before writing one, but expect to own it either way.

## Suggested path

1. Finish the signal test into a real init: MR writes with DLL-off, ZQCL,
   refresh; prove the chip answers a single BL8 write/read at 50 MHz with a
   scope on DQS. Cheap, and it measures tDQSCK on this board.
2. Move the test to `clk_114`, add option A capture on one byte lane, read
   training pattern, thermal test.
3. Then the controller proper, against the same 16-byte line port as the
   SDRAM back-end, and the memory map/RTG move from
   [ddr3-fast-ram.md](ddr3-fast-ram.md).


See [memory-masters.md](memory-masters.md) for the full list of DRAM masters and the split.
