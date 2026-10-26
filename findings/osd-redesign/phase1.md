# OSD redesign, Phase 1: `osd_text.v` standalone, bench, OOC

Branch `osd-p1-text` from `5.0-040-56mhz` 7dd35aa2. Plan: `findings/osd-redesign/plan.md` (untracked in the main checkout) sections 3.2-3.5, 3.10, 4.2 and "Phase 1". Written 2026-10-26.

## Result

| Gate | Target | Result |
|---|---|---|
| Bench, every leg byte-identical to the model | pass | pass: 6 legs on Verilator; s1full and off also on Icarus |
| Layer off: output = input delayed exactly LAT | pass | pass (every clock, rgb + syncs + DE) |
| Mutant `+define+OSD_TEXT_MUTANT` | must FAIL | caught by 5 of 6 legs (not by `off`, as expected) |
| OOC WNS at 6.734 ns | > 0.3 ns | +3.163 ns into u_osd (+2.699 ns for the whole wrapper; that path is in the generator) |
| LUT (u_osd) | <= 550 | 364 (338 logic + 26 SRL), 1,201 FF |
| RAMB36 | 2 | 2 (0 RAMB18) |
| DSP | 0 | 0 |

Latency: **LAT = 3 pixels (6 clk_148 clocks)** for video, hsync, vsync and DE; no extra stage was needed.

## Files

- `rtl/openaars/adv7511/osd_text.v` -- the layer (new).
- `rtl/openaars/adv7511/osd_font.mem` -- font RAM power-up content, generated (new).
- `fw/ctrl/font8x16.h` -- 256 x 16 bytes, row-major, bit 7 = left; first version = `charrom.h` converted (column-major, bit 0 = top) and doubled vertically, glyph descriptions kept.
- `fw/ctrl/tools/mkfontmem.py` -- `font8x16.h` -> `osd_font.mem`; `--check` compares (for the later `make check` gate (k)); `--from-charrom` regenerates `font8x16.h`.
- `sim/osd_text/osd_text_tb.v`, `model.py`, `run.sh` -- the bench (nice 19, two legs at a time by default: `JOBS`, `NICE`).
- `tools/vivado/ooc_osd/go.sh`, `run.tcl`, `wosd.v` -- OOC flow (copy of `ooc_hostcpu`); `runs/` is gitignored (`.gitignore`).

No existing RTL file is changed (`signal_generator.sv`, `pal_to_ddr.sv`, `userio_osd.v` untouched).

## Interface (for Phase 2)

```verilog
osd_text #(.FONT_FILE("osd_font.mem"), .LAT(3), .H_ACT(1280), .V_ACT(720), .HS_DE(261)) u (
  .clk(clk_148),
  .i_pe(~w_adv_clk),          // pixel enable: high on the 2nd clock of each pixel (= hd_gen r_vid_enable)
  .i_frame(<hd_gen o_frame>), // frame pulse = the generator's line 0 start; also the commit point
  .i_r(w_o_r), .i_g(w_o_g), .i_b(w_o_b),
  .i_hs(w_hd_gen_hsync), .i_vs(<vsync to delay>), .i_de(w_adv_de),
  .o_r(), .o_g(), .o_b(), .o_hs(), .o_vs(), .o_de(),   // all delayed 2*LAT clocks
  .wclk(dll_28),
  .txt_we(), .txt_lane(), .txt_adr(), .txt_dat(),       // [1:0] lanes, [10:0], [15:0]
  .font_we(), .font_adr(), .font_dat(),                 // [11:0], [7:0]
  .pal_we(), .pal_adr(), .pal_dat(),                    // [5:0], [7:0]
  .txt_cfg(), .txt_commit());                           // [39:0], toggle
```

- **Position is derived inside the layer** (coordinator's scope change: no new generator ports). At the edges that sample `i_pe` high the layer samples `i_hs` and `i_de` and keeps:
  - `nx`: the next pixel's x (0-based, counts on through the blanking mod 4096), set to `1 - cal` at the hsync's rising edge, +1 per pixel;
  - `cal`: pixels from the hsync's start to the DE's start, measured on every line that has DE (power-up value `HS_DE` = 261 = sync 40 + back porch 220 + 1). No porch constants are hard-wired, so 720p50 and 720p60 both work (bench leg `hz60`);
  - `ny`: the line, all ones at `i_frame`, +1 per hsync start, so line 0 is the first hsync after the frame pulse. The hsync comes 261 pixels before the line's first pixel, so `ny` is valid in time.
  This reproduces the generator's `hz_count - c_act - 1` / `vt_count` exactly. The `+1` in `cal` encodes one quirk of today's `signal_generator.sv`: its `o_adv_de` rises one clock (half a pixel) **before** the pixel's video (`r_r` is gated by the region flag one clock later). If the generator cleanup on the parallel branch changes that DE/data skew, or the hsync/DE phase relative to `r_vid_enable`, the window moves by one pixel and this bench (which instantiates the generator) fails: re-check `cal`'s `+1`.
- Which generator signals to tap in `pal_to_ddr.sv`: `o_adv_clk` (already `w_adv_clk`; `i_pe = ~w_adv_clk`), `o_hsync` (`w_hd_gen_hsync`), `o_adv_de` (`w_adv_de`), `o_frame` (currently unconnected: `.o_frame()`), and the video `w_o_r/g/b`. `adv_ddr` takes `vsync` from the upsampler (`w_vsync`), not the generator; Phase 2 decides which vsync to route through `i_vs` (any 1-bit signal can ride the delay line). `adv_ddr` makes its own DE from hsync, so `o_de` is informational.
- `txt_cfg[39:0]` byte layout (byte i = SPI data byte d_i of 0x5C): `[7:0]` ctrl {bit 0 enable, bit 1 scale 2}, `[15:8]` x0/8, `[23:16]` y0/8, `[31:24]` cols, `[39:32]` rows. cols/rows 0 = no window; cols > 64 -> 64, rows > 32 -> 32. Window clipped to 1280 x 720.
- `pal_adr[5:0]` = entry * 4 + byte; byte 0 = mode in bits 7:6 (5:0 ignored), 1 = r, 2 = g, 3 = b. The staging palette lives in `osd_text` (wclk registers), as the 4.1 port list implies.
- Cell word `{attr[15:8], char[7:0]}`, lane 0 = char, lane 1 = attr; address = row * 64 + col.
- Commit: `txt_commit` toggles after the staging bytes and `txt_cfg` are written; 2-FF synchroniser (`ASYNC_REG`) on the toggle only; the copy happens at the next `i_frame`. The staging values must stay static from the toggle to that frame pulse. Crossings: staging palette (wclk FFs) and `txt_cfg` -> live registers, covered by wizard.xdc's existing `set_max_delay -datapath_only 6.734` dll_28 -> clk_148; no new XDC. OOC wclk -> clk slack: +5.428 ns.
- Before the first commit the layer is disabled (live enable 0): the picture passes bit for bit, delayed LAT.
- **Sync delay and the 60 Hz upsampler**: hsync reaches `adv_ddr` LAT = 3 pixels later. At 60 Hz the upsampler takes `w_adv_hsync` from `adv_ddr`, so its line timing moves 3 pixels relative to the generator; Phase 2 should check (or compensate) the picture's horizontal position at 60 Hz (`crt_run.sh osd2off` leg).
- Plan 7.2 (adv_ddr row offset: pins show generator rows 15..734) is still open: the layer works in generator coordinates, like the model.

## Pipeline

Every clk_148 clock is a stage (the inputs hold for the two clocks of a pixel); PIPE = 12 clocks from `nx` to the output. The overlay runs `LEAD = PIPE/2 - 1 - LAT = 2` pixels ahead of the video, so LAT is independent of the pipeline depth (LAT 1..5 legal; adding a stage just raises PIPE by 2 and LEAD by 1).

| Clock | Stage |
|---|---|
| +1 | `xi`, `yi` (copies of nx, ny) |
| +2 | `dx = xi - (x0*8 - LEAD)`, `dy = yi - y0*8` (carry chains); x_ok / y_ok (on the raster) |
| +3 | col, row, glyph column, glyph line (2:1 by scale); hin = dx < width, vin = dy < height (carry compares); `{row, col}` = cell RAM address |
| +4 | cell RAM read; win = hin & vin & ok & enable |
| +5 | cell RAM output register (Vivado: the RAMB36's DOB_REG); `{char, line}` = font RAM address |
| +6 / +7 | font RAM read, output register |
| +8 | glyph bit (8:1 mux) |
| +9 | palette index `bit ? attr[3:0] : attr[7:4]` |
| +10 | palette entry (16:1 mux from the live registers) |
| +11 | effective mode (`win ? mode : 2`), 9-bit sums colour + video |
| +12 | output: mode 0 colour, 1 video >> 1, 2 video, 3 sum >> 1 (one LUT6 per bit) |

The cell is fetched for every pixel (the address is the same for all pixels of a cell), so there is no separate prefetch: the "next cell" data is simply the pipeline's next pixel. The video passes `D1 = 2*LAT - 2 = 4` registers (SRL16), then the +11 / +12 registers; the syncs 6 registers.

## Bench

```sh
bash sim/osd_text/run.sh                  # Verilator 5.020, all legs + mutant, ~4.5 min with the defaults (2 legs at a time, nice 19)
SIM=iverilog bash sim/osd_text/run.sh     # Icarus 12 (4-state): ~17 min per leg pair (normal + mutant) on the loaded machine
LEGS="edges off" bash sim/osd_text/run.sh # a subset
```

Per leg, `model.py gen <leg>` writes the data; the tb (generator 720p50, or 720p60 with `+hz60`, + osd_text) writes all 2048 cells in three lane passes (both lanes garbage, then lane 0 = chars with garbage in [15:8], then lane 1 = attrs with garbage in [7:0]), rewrites glyphs 0x80-0xFF through the font port (shuffled order; 0x00-0x7F from `osd_font.mem`), writes palette A + cfg A and toggles commit in frame 0; in frame 1 at line 300 it writes palette B + cfg B and toggles again (frame 1 must still show A); frame 2 shows B. It captures frames 1 and 2 at the layer's input and output (first clock of each pixel with DE), and `model.py check` renders the output from the captured input and compares the PPMs byte for byte. Input video is random per pixel. Every palette has all four modes, mode byte bits 5:0 are garbage.

Bench-side checks every clock: syncs and DE = input delayed exactly 2*LAT clocks; each pixel holds for both its clocks (no half-pixel tear, i.e. the overlay is aligned to the generator's data pairs that `adv_ddr` sends as low/high halves); outside the captured pixels the rgb equals the delayed input; leg `off`: rgb equals the delayed input on every clock.

| Leg | Frame 1 (A) | Frame 2 (B) |
|---|---|---|
| s1full | scale 1, x0 = 0, y0 = 0, 64 x 32 (32 rows) | scale 2, 64 x 20 at (128, 40) |
| edges | scale 2, 30 x 12 at (1120, 400): cut right and bottom | scale 1, 40 x 10 at (960, 560): ends exactly at 1280 / 720 |
| clamp | scale 2, cols 200 / rows 100 -> 64 x 32 (bottom cut) | scale 2, 3 x 3 at (1272, 712): 8 x 8 px visible |
| small | scale 1, one cell at (8, 8) | scale 2, 13 x 7 at (8, 16) |
| hz60 | 720p60: scale 2, 64 x 20 at (128, 40) | 720p60: scale 2, 40 x 5 at (768, 24), cut right |
| off | disabled, window set | enabled, cols 0 |

Results (Verilator):

```
osd_text bench (verilator, LAT 3, 2 jobs, nice 19)
  pass  s1full
          frame 1: identical (193860 pixels differ from the input)
          frame 2: identical (491812 pixels differ from the input)
        mutant caught by s1full
  pass  edges
          frame 1: identical (38500 pixels differ from the input)
          frame 2: identical (39592 pixels differ from the input)
        mutant caught by edges
  pass  clamp
          frame 1: identical (544552 pixels differ from the input)
          frame 2: identical (64 pixels differ from the input)
        mutant caught by clamp
  pass  small
          frame 1: identical (92 pixels differ from the input)
          frame 2: identical (34944 pixels differ from the input)
        mutant caught by small
  pass  hz60
          frame 1: identical (497764 pixels differ from the input)
          frame 2: identical (60888 pixels differ from the input)
        mutant caught by hz60
  pass  off
          frame 1: identical (0 pixels differ from the input)
          frame 2: identical (0 pixels differ from the input)
        mutant not caught by off
  pass  mutant caught by 5 leg(s)
ALL TESTS PASSED
```

Icarus (4-state X-check): run on s1full and off only. A full Icarus pass takes ~1 h 40 min at two legs at a time, and the machine was overloaded (coordinator: nice 19, 2 jobs at most), so the other legs were stopped. s1full: `=== PASS` from the bench, both frames identical (193,860 / 491,812 window pixels), mutant caught (27,501 / 34,632 pixels). off: pass, both frames identical to the input. `LEGS=off` on its own prints "FAILURES" only because no mutant can show with the layer off. The other legs on Icarus: `SIM=iverilog LEGS="edges clamp small hz60" bash sim/osd_text/run.sh`.

Mutant (`OSD_TEXT_MUTANT`: the attribute two clocks late, i.e. the first pixel of each cell takes the previous cell's colours, as a missing prefetch would): fails s1full, edges, clamp, small, hz60 (model mismatch, e.g. s1full frame 1: 27,501 pixels); `off` cannot see it. Extra manual check (not committed): `cal <= hcnt` instead of `hcnt + 1` (window one pixel left) fails `small` and `hz60`, so the bench resolves a one-pixel shift. `LAT=1` and `LAT=5` (`LAT=n bash sim/osd_text/run.sh`, legs small + edges) also pass, so LAT is a working parameter.

## OOC

```sh
bash tools/vivado/ooc_osd/go.sh            # runs/ooc, 6.734 ns
```

Wrapper `wosd.v`: `signal_generator` (u_gen) + `osd_text` (u_osd), all ports registered (video side clk, write side wclk); xc7a100tfgg676-2, Vivado 2023.2, `-flatten_hierarchy rebuilt`, opt/place/phys_opt/route.

```
ooc: period=6.734 wns=2.699 wns_into_u_osd=3.163 wns_wclk_to_clk=5.428 whs=0.069 gens= version=2023.2
| Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | DSP |
| wosd     |            (top) |        412 |        386 |       0 |   26 | 1414 |      2 |      0 |          0 |
|   u_gen  | signal_generator |         48 |         48 |       0 |    0 |   58 |      0 |      0 |          0 |
|   u_osd  |         osd_text |        364 |        338 |       0 |   26 | 1201 |      2 |      0 |          0 |
```

- The worst clk path of the whole wrapper is in the generator (`hz_count` -> its own reset, +2.699 ns), not in the layer.
- Worst path into the layer: `idx9` -> `pc10` (the 16:1 palette mux, LUT6 + MUXF7 + MUXF8), +3.163 ns; the next four are the same mux. All other layer stages have more slack. Hold: WHS +0.069 ns (whole wrapper).
- FF count (1,201) is dominated by the palette: 16 x 26 staging (wclk) + 16 x 26 live. Plan 4.3 estimated ~1,000 FF. If slices get tight in Phase 2, the staging palette could become a 64 x 8 dual-clock LUTRAM read by a 64-clock copy engine at the frame pulse (about -400 FF, -60 LUT); not done, the gate is met.
- An earlier variant that took the generator's counters through new `o_nx`/`o_ny` ports (before the scope change) measured 339 LUT / 1,138 FF / WNS +2.676; the self-derived position costs ~25 LUT and ~63 FF.

## Deviations from the plan

1. **No x/y ports, no `signal_generator.sv` change** (coordinator, mid-phase): the layer derives the position from `i_pe`, `i_hs`, `i_de` and `i_frame` (above). The plan's `i_x`/`i_y` ports are gone; `i_pe` is used for the counters only.
2. **Lead instead of a short pipeline**: the plan expected LAT = 3 from a ~5-stage pipeline; the pipeline here is 12 clocks (one LUT level each, both RAM output registers) and runs 2 pixels ahead, so LAT = 3 is kept with large slack. LAT is a parameter.
3. **Per-pixel cell fetch, no prefetch register**: simpler, same RAM, and it removes the cell-boundary special case. The mutant is therefore "colours one pixel late" (what a broken prefetch shows) rather than literally dropping a prefetch.
4. **No `TXT_OUTREG` parameter**: both RAM output registers are always used (they are the BRAMs' own registers); a version without them would change PIPE and LEAD only.
5. **cols/rows clamp** (cols > 64 -> 64, rows > 32 -> 32) and **cols/rows 0 = no window** are defined (the plan left them open).
6. Mode 3 rounds down: `(colour + video) >> 1`.
7. Bench uses Verilator by default (memory: prefer Verilator), Icarus via `SIM=iverilog`; legs run two at a time under nice 19 (`JOBS`, `NICE`).
