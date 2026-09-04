# Constraint fixes — implemented and verified (2026-09-04)

> **Hardware verified 2026-09-04:** the shipped configuration is HEAD RTL + the cleaned
> constraints (`clocks.xdc`, `cpu.xdc`, `wizard.xdc`, `sdram.xdc`, `i2s.xdc`, `sd_card.xdc`,
> `adv7511_video.xdc`). It **boots on the board**. Bitstream
> `project_1/project_1.runs/impl_1/minimig_openaars_top.bit`, reports in
> `scratchpad/impl/out_keep/`. Every path group meets timing except the SDRAM read
> (−0.349 ns, 16 endpoints), which is the real, pre-existing marginality documented in
> [fix-12](fix-12-sdram-read-capture-clock.md) — now visible in the report instead of hidden
> behind a wrong constraint. fix-12 itself is reverted; it does not run on hardware.

> **Update, later the same day:** [fix-12](fix-12-sdram-read-capture-clock.md)
> (SDRAM read capture clock, RTL + MMCM + XDC) is implemented and verified —
> the read path now meets timing (+3.757 ns), the whole design is clean
> (WNS +0.345, WHS +0.027) and the vendor-model bench reads correctly at all
> four corners. Reports in [impl-reports-fix12/](impl-reports-fix12/). Details
> in the fix-12 file; the text below describes the constraint-only build that
> preceded it.
>
> **Later still:** that +144° build gave a **red screen** on hardware. Root cause: the
> bench's fast-corner model understated the FPGA clock-forwarding spread by ~4.5 ns,
> and the `-hold -end 1` companion put Vivado's hold check on the wrong edge, so the
> fast-corner hold violation was never reported. Capture phase corrected to +22.5°
> (+0.551 ns), hold exception removed, bench corners taken from Vivado min/max.
> Rebuilt and tested on hardware: **fails at every capture phase (white screen)**, swept over
> the whole period with a runtime MMCM phase shift. Not a read-timing fault (no working phase
> window). Reverted from the working tree; kept in findings with ILA evidence. The constraint
> cleanup is retained and boots (verified by bisect). See [fix-12](fix-12-sdram-read-capture-clock.md).

Build: Vivado 2023.2, full synthesis + implementation + bitstream, clean RTL at `HEAD`
(the four stale May-2024 working-tree edits were discarded; diff kept in the session
scratchpad as `wip_rtl_2024-05.patch`). Reports in [impl-reports/](impl-reports/),
script `impl-reports/build.tcl`. Bitstream: `project_1/project_1.runs/impl_1/minimig_openaars_top.bit`.

## What changed (constraints only, no RTL)

| File | Change | Findings |
|---|---|---|
| `clocks.xdc` | rewritten: oscillator, MMCM renames with the derivation documented; `VIRTUAL_clk_148` and its masking clock group removed | fix-03, fix-08, fix-10 |
| `sdram.xdc` | output delays `tSU+trace` / `-tH+trace`; input delays `tAC+trace` / `tOH+trace` against `clk_gen_sdram` (the clock at the pin); read multicycle `-setup -end 2 / -hold -end 1`; `dr_cke` added to the output set | fix-01, fix-06 |
| **`cpu.xdc` (new)** | TG68K island exceptions scoped by cell set (kernel / wrapper incl. Akiko / memory side), filter `IS_SEQUENTIAL || DMEM.* || BMEM.*`; C2P rules on cells; replaces the `[all_registers]` blanket rules | fix-04 |
| `wizard.xdc` | only cross-cutting rules left: `dll_28 → clk_114` now `-setup -end 4 / -hold -end 3`; `clk_114 → dll_28` `-start 4/3`; 11 explicit single-cycle overrides for direct FF→FF crossings; `set_max_delay -datapath_only` in both directions to/from `clk_148` instead of the false path; dead `set_max_delay 1.8` / `-hold -end 2` / `clk_sd_114 → clk_114 setup 2` / "Incorrect" dtram rule removed; SPI clocks moved out | fix-02, fix-05, fix-06, fix-07, fix-10 |
| `i2s.xdc`, `sd_card.xdc` | own generated clock (I2S `sclk`, cfide `sck`) and the `sck` async group live with their interface | fix-08 (part), layout |
| `adv7511_video.xdc` | output registers packed into the IOBs (`IOB TRUE`); `dv_cecclk` false-pathed; group false-pathed **explicitly with the reason** — see below | fix-03 (partial), fix-09 |
| Vivado project | `cpu.xdc` added to constraints fileset **`XC7A100T`** (the one the runs use — not `constrs_1`) | — |

## Results

| Path group | Before (Apr-2024 build, masked) | Now | Note |
|---|---|---|---|
| `clk_114` intra | 1.160 (kernel relaxed by blanket rule) | **+1.258**, 0/9085 failing | kernel→kernel paths get 4 cycles, kernel→memory 3, everything else 1 |
| `dll_28 → clk_114` hold | 78.999 (check disabled) | **+0.080**, 0 failing | the 49 hidden violations were fixed by the router once visible |
| `clk_114 → clk_gen_sdram` (SDRAM write) | 3.672 (3 ns fictitious) | **+0.834** | honest numbers, met |
| `clk_gen_sdram → clk_114` (SDRAM read) | 8.124 (wrong parameter, wrong clock) | **−0.349**, 16/16 failing | **real**; matches the vendor-model simulation. RTL fix: [fix-12](fix-12-sdram-read-capture-clock.md) |
| `clk_114/dll_28 → clk_148` | ignored (false path) | **+5.51 / +1.35** datapath-only | bounded; the 148-endpoint reset fanout fits in one period |
| `clk_148 → dv_*` (ADV7511) | ignored (async group) | explicitly false-pathed | see below |
| `check_timing` HIGH ports | 5 | **0** | |
| Exceptions overridden | 3 dead constraints | 0 (two "non-existent path" reports, see notes) | |

Utilisation unchanged (14,419 LUTs). Numbers are from the final build on `HEAD` RTL;
an earlier build that still carried the stale RTL edits gave the same picture within
0.3 ns (`clk_114` +1.281, read −0.544, write +1.328).

## Still open, and why

**SDRAM read, −0.349 ns.** ~~The constraint is now correct; the design is not.~~
**Resolved by fix-12** (see the update at the top): `sdata_cap` in the IOB on
`clk_sd_rd` (+144°), retimed into `clk_114`; read path +3.757 ns, retime +2.672 ns.

**ADV7511 output group.** A generated clock on `dv_clk` was tried and rejected by the
tool: `TIMING-36 Critical Warning — no rising/falling edge propagation between clk_148
and dv_clk_out`. The pixel clock leaves `adv_ddr.v` through an FDRE's D→Q, which no
generated clock can propagate through; with the fallback zero-latency waveform every
path showed −6.8 ns, a false failure. The interface therefore stays untimed — but now
by a documented `set_false_path` in `adv7511_video.xdc` rather than an async group, and
with all thirteen output registers packed into OLOGIC so clock and data leave the pins
with matched delay (before, `dv_d[3]` had 8 ns of fabric route and the bits were skewed
against each other by several ns). Proper timing needs an ODDR-forwarded clock
(fix-03, RTL). **If HDMI output changes on hardware after this build, the ADV7511's
clock-delay register set by `i2c_sender` may have been compensating the old skew and
needs re-tuning.**

**`TIMING-46` still lists 11 pairs.** They are the direct FF→FF crossings between
`dll_28` and `clk_114` (edge detectors, config bits). `wizard.xdc` now gives each an
explicit single-cycle exception; the methodology check appears to flag the clock-level
rule regardless. All eleven paths are 1–2 ns and pass single-cycle. Accepted.

**`TIMING-47` (10)** — the expected warnings for `-datapath_only` and the SPI clock
group between same-source clocks. Accepted, documented in the XDC.

**`report_exceptions -ignored`** lists the `dr_d` read multicycle as "non-existent
path" while `report_timing` shows it applied (requirement 11.791 ns = 2 cycles). A
reporting quirk of port-scoped exceptions with input delays; the timing report is the
authority.

**Not touched (RTL):** [fix-11](fix-11-reset-into-clk148.md) reset synchroniser into
`clk_148` — the crossing is now bounded (+1.35 ns) but still unsynchronised;
~~fix-12~~ (done); the ODDR for fix-03.

## Two things learned the hard way

* The project's runs use constraints fileset **`XC7A100T`**, not `constrs_1`. A file
  added to `constrs_1` is silently never read.
* `IS_SEQUENTIAL` is 0 for distributed RAM (`RAM32X1D`, the TG68K register file) and
  block RAM. Cell-set filters for multicycle endpoints must include
  `PRIMITIVE_TYPE =~ DMEM.* || BMEM.*` or the register-file and Akiko-CLUT paths are
  left single-cycle (−8.3 ns, 2300 endpoints — the first build).
