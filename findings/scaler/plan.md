# HDMI scaler: one switchable 50/60 Hz chain, a 16-line ring, 2.5x vertical in linear light

Status: plan, decided by Paul 2026-10-13 ("Let's go for that, that sounds like
a win ... @2.5 | linear light").  Background: findings/scaler/scaling-survey.md
(papers, RTL reading, the 1-D model) and the PNG comparison (scratchpad
scaler_png/out, sheet_pal_colour.png row 4 = the 2.5x tiles, judged the most
evenly spaced).

## Decisions

- No frame buffer, no external memory.  A ring of line buffers in BRAM only.
- One scaler chain for 50 and 60 Hz, switched at run time by `r_50hz`, instead
  of two upsamplers and two signal generators that both run all the time.
- The ring grows from 8 to 16 lines; that makes exact 2.5x (PAL 288 -> 720)
  and 3x (NTSC 240 -> 720) possible without a frame buffer: the HDMI frame is
  locked to the Amiga frame, so the reader's lag behind the writer grows to
  ~12 lines within a frame and resets in each vertical blank.  2x integer
  (lag ~48 lines) is not offered.
- Vertical resampling in linear light with a phase-indexed weight table.
  Paul looked at both 2.5x linear tiles (area/Winscale and sharp-bilinear 0.5)
  -- provide both as tables, selectable in the OSD; default sharp-bilinear
  0.5 (his first pick), area as the alternative.  The old line-rate behaviour
  (2.401x / 2.882x, nearest) stays selectable as a fallback.
- CRT scanlines on: the two-line Gaussian beam at the fractional position, in
  linear light ("CRT new" in the sheets).
- RTG: unchanged in this plan (it keeps today's line-rate path).  A per-mode
  lag check and RTG scaling come later (survey section on RTG).
- Horizontal: unchanged in this plan (backlog video scaler item 1).

## Facts the plan builds on (rtl/openaars/adv7511)

- pal_to_ddr.sv instantiates pal_to_hd_upsample twice (my50hzupsample :373,
  my60hzupsample :447) on the same input (w_bh_*), clk_114 in, clk_148 out,
  and signal_generator twice (hd_50hz_gen, hd_60hz_gen); r_50hz selects the
  outputs.  Each upsampler has its own ring: bram_tdp DATA 24, ADDR 14 =
  8 lines x 2048 words, ~12 RAMB36 each.
- The two signal generators differ only in the horizontal front porch (440 at
  50 Hz, 110 at 60 Hz; line length 1980 / 1650).
- The upsamplers differ in PAL_HD_H_RES (1685 / 1980 -- backlog item 8: looks
  swapped against the real line lengths 1980 / 1650; it sets the WRITE-side
  sample step, pal_to_hd_upsample.v:203, so the two rings hold differently
  sampled data), PAL_OFFSET_HZ ('hd0 / 'h80 minus CRT_LAT), the hsync source
  (own generator / adv_ddr's hsync_out) and i_rtg_enable (60 Hz only).
- crt_post.v already has the line phase, a current+next line read, a
  phase-indexed weight ROM (crt_wrom.mem) and 6 DSP multipliers.
- Budget (build/stage_postchip): BRAM 81/135, DSP 44/240, LUT 84 %.

## Steps (each test first; the bench must be seen failing before the change)

1. **Golden reference.**  Record the current RTL's output frames from
   sim/hdmi_upsample at 50 and 60 Hz, CRT off and on, RTG off and on, plus
   the mode switch PAL -> NTSC -> PAL, before touching anything.
2. **One switchable chain.**  One pal_to_hd_upsample with H_RES, OFFSET_HZ,
   the hsync source and RTG as run-time inputs selected by r_50hz; one
   signal_generator with the front porch as an input; the 50/60 output muxes
   removed.  Gate: output pixel-identical to the golden frames in every leg
   (after the one-frame refill at a mode switch).  Keep the odd H_RES values
   for now -- changing them changes the picture; that is a separate,
   visible step (item 8) with its own before/after PNGs.
3. **16-line ring.**  ADDR 14 -> 15 (16 x 2048), write/read ring pointers 3 ->
   4 bits.  Gate: the line-rate mode still matches the golden frames.  A new
   bench check: the reader never reads a line the writer is overwriting
   (assert on the ring distance) at 2.5x PAL and 3x NTSC over whole frames,
   with the worst-case vertical offsets.
4. **Exact-ratio vertical stepping.**  A phase accumulator per HD line (step
   288/720 resp. 240/720 of a line, i.e. 2/5 and 1/3) gives the source line
   and its fractional phase; vertical centring from the existing VPOS offset.
   Mode "line rate" keeps today's stepping.
5. **Linear-light vertical blend.**  De-gamma ROM (8-bit code -> linear, enough
   bits for dark values, e.g. 12) on both line reads, the weighted sum in the
   existing DSPs, re-gamma ROM back to 8 bits; weight tables for
   sharp-bilinear 0.5 and area, indexed by the phase; the CRT beam variant in
   linear light when scanlines are on.  Everything registered (DSP and BRAM
   registers): the clk_148 paths have little margin.  Gate: the bench's frames
   match the Python model (scaler_png tools/scale.py) within +-1 code;
   bench PNGs next to the model PNGs for Paul.
6. **OSD.**  A "Scaling" line on the Video page: Line rate / Sharp / Area (and
   the CRT beam follows automatically).  Config: use a spare bit field; the
   config stays 212 bytes, CONFIG_VERSION stays 4.
7. **Build** (Paul's go), timing and utilisation against the budget: expected
   BRAM about net 0 for the ring (2 x 12 -> 1 x 24) plus 2-6 for the gamma
   and weight ROMs; LUTs fewer than today (one upsampler and generator less).

## Risks

- Picture height/position: exact 2.5x fills 720 lines from 288; today's
  picture is ~692 lines.  Vertical centring and the OSD VPOS range need
  checking at both ratios.
- The 60 Hz path's 8-line 50->60 Hz conversion (backlog item 4) depends on the
  ring; with 16 lines its drop/repeat pattern changes -- gate in step 3.
- Linear light makes dark text on light backgrounds look thinner (survey
  observation); the OSD choice covers it.

## Implementation notes

Steps 1-6 on branch `scaler` (2026-10-13).  Benches: sim/hdmi_upsample
golden.sh (the golden frames, step 1), scaler_run.sh (ring, stepping,
linear light), crt_run.sh and run.sh as before.

- Ruling: golden.sh compares the output pins per input field ("fsig") as
  well as per vsync ("sig"), and skips "sig" in the PAL -> NTSC -> PAL legs
  -- the two-chain design put out one vsync more in its 50 -> 60 Hz splice,
  which renumbers every later vsync-to-vsync window although the pins are
  the same -- cost if wrong: none for the steady legs (both kept); in the
  mode legs a pin difference that does not move by a whole field window
  would still show in fsig.
- Ruling: the line-rate mode keeps to buffers 0..7 of the 16-line ring, with
  its addresses wrapping in 14 bits (i_ring16 = 0), instead of using all 16
  -- the input lines inside vsync do not advance the write side and their
  samples run on through the next buffers (8-line ring: 7 -> 0 -> 1 -> 2),
  which the top HD lines of the next frame show; on 16 buffers those land
  in 8..10 and HD rows 0..6 show older border lines instead (golden.sh
  check, plan-literal 16-buffer ring: the "pic" records of 8 of 8 legs
  differ, the pin records do not -- see the next note) -- cost if wrong:
  none in resources (the same 16-buffer RAM, a 2:1 choice of wrap width).
- Finding (no change made): the HDMI pins do not show the signal
  generator's 720 active rows 0..719 but rows 15..734 -- adv_ddr makes its
  own DE from the vsync the upsampler delays by Y_TRANS = 10 HD lines
  (o_hd_vsync) plus PY_TO_DE = 5, and the ADV7511 takes the DE pin (reg
  0x17 bit 0 = 0).  Bench (tb_crt_frame, the generator's counters when
  o_de rises): pin line 0 starts at vt_count 15, line 719 at 734, at 50 and
  60 Hz alike; horizontally at hz_count 762 / 432 against the generator's
  first active pixel 701 / 371 (61 pixels, which today's read offsets may
  already absorb).  So the top 15 rows of every picture never reach the
  screen and the bottom 15 HD lines are always black (rows 0..6 differing
  does not change the pin signature, see the ring ruling).  It matters for
  the exact 2.5x / 3x picture, which fills rows 0..719: on the board its top
  15 rows (6 PAL / 5 NTSC source lines) are cut and the bottom 15 lines are
  black.  Fixing it moves every mode's picture 15 lines on screen, so it is
  Paul's call (aligning adv_ddr's vertical DE with the generator's, e.g.
  PY_TO_DE or Y_TRANS, is a few lines).
