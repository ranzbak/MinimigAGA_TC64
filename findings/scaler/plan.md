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
  **Approved by Paul 2026-10-13** after viewing the model render
  scaler_png/out/full/pal_2p5_crt_lin2_L.png ("looks very good, I approve"):
  this is the target for the RTL with CRT scanlines on.
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
- Ruling (step 4): the exact-ratio picture is time-locked like the line-rate
  one -- the HD frame still restarts at the (VPOS-moved) input vsync and y
  starts there -- and the window is centred by moving that restart: the
  Scaling modes add RATIO_VB = -20 (PAL) / -18 (NTSC) input lines to VPOS
  -- the reader can only show lines completed ~2.5 lines before the HD
  line, so the window cannot be moved by y alone -- cost if wrong: a mode
  change glides there at VPOS's 5 lines a frame (4 frames), like a VPOS
  change.
- Ruling (step 4): y starts at YB - p, p the time from the restart to the
  first new input line, measured in lines (r_tph), instead of a fixed
  start -- the restart sits half a line apart in long and short fields and
  anywhere in the line with VPOS; with p the lag is the same in every field
  (bench: 2.41..15.48 lines interlaced, 2.49..15.39 progressive, against
  2..16 allowed) and the long field's lines land half a line above the
  short field's (row 0 at source 24.7 against 24.2), as on a CRT -- cost if
  wrong: none seen in the bench; a source whose line length is not 227 CCK
  would scale p by the wrong T (RATIO_TPH), a small error.
- Ruling (step 4): in the exact-ratio modes the write side starts a new
  buffer on every input line, vsync lines too, so a line's buffer is its
  number since the restart -- otherwise the 3-4 vsync lines in the window
  (VPOS) would shrink the lag by as many lines, more than the ring's slack
  -- cost if wrong: none (the line-rate mode keeps the old rule).
- Ruling (step 4, corrected in step 5): the geometry is the study model's
  (render_all.py, offv 0) one HD row lower: HD row 0's centre at source
  line 23.8 (PAL; the model's 24.2) and 21.8333 (NTSC; 22.1667) -- the
  same line phases (the 5-row cycle 0.3 0.7 0.1 0.5 0.9 at 2.5x, which puts
  the sharp kernel's mixed row on its ramp's middle), and the model's
  exact geometry would leave the ring 0.09 line of slack (0.01 interlaced)
  against 0.49 / 0.61 now (NTSC 0.28 / 2.92).  (Step 4's bench numbered the
  HD rows one off -- tb line count = row, not row + 1 -- and reported 24.2 /
  22.1667 for this same RTL; the step 5 bench found it.)  The input lines
  before the restart's first one are black (a < 0): PAL rows 0..6 (lines
  24, 25: Agnus' vertical blank anyway), NTSC rows 0..7 (lines 22, 23:
  overscan) -- the lag forbids an earlier restart -- cost if wrong: the RTL
  picture is the model's moved down one HD row (its last row cut), NTSC
  overscan's top two lines are lost; all of these top rows are among the
  15 the pins do not show today (Finding above).
- Ruling (step 5): linear light 18 bits (code 1 decodes to 1, not 0),
  weights 15 bits (32768 = 1.0), the encode a 4096-entry piecewise table
  (exact below 2048, buckets of 128 above), per channel -- the plan's
  "e.g. 12" bits and the first cut's 9-bit weights left errors of up to 7
  and 14 codes against the model (dark codes decoding to 0; the beam's far
  tail, 5.8e-4 at gap 0.80, rounding to 0); this chain is within +-1 code of
  the float model for every code pair, phase and kernel of both tables
  (scl_mkroms.py check, exhaustive) -- cost if wrong: BRAM: SDEC 3 RAMB18,
  SENC 3 RAMB36, SWROM 2048 x 36 = 2 RAMB36 (6.5 RAMB36 in all, the plan
  said 2-6).
- Ruling (step 5): with scanlines on, the beam's page gain and soft clip
  stay in crt_post's LUT stage (crt_lut.mem pages 2 / 3, as for the line-rate
  beam) after the linear path's 8-bit encode, instead of an encode page per
  scanline level -- the double rounding stays within +-1 (exhaustive
  check above) and the mask / bloom stages work unchanged -- cost if wrong:
  none found.
- Ruling (step 5): the linear path has its own 6 multipliers (18 x 16 bit)
  next to the gamma path's, not the same DSPs with muxed operands -- the
  gamma (line-rate) path stays bit-identical by construction and no mux sits
  in front of a DSP on clk_148 -- cost if wrong: 6 DSP48 (the plan expected
  0 new).
- Ruling (step 5): the linear path is 3 pixels longer than the gamma path;
  instead of delaying the gamma path to match (CRT_LAT 9 -> 12, the read
  offsets following), the upsampler reads 3 pixels earlier in the
  exact-ratio modes only (RATIO_RDX) -- with CRT_LAT 12 the line-rate
  picture moved in HD row 0 of the NTSC legs (2 pixels; a stale top row
  read while the vsync lines' samples still run through its buffer: a
  read/write race that the earlier read shifts; the pins were identical,
  row 0 is not on them) -- cost if wrong: none (a 2:1 choice in the
  registered read offset).

- Step 5 results (scaler_run.sh lin*, HD frame 8 of the study's frame,
  every pixel and channel): the RTL against scaler/scale.py on the RTL's own
  line-buffer rows at the RTL's phases -- PAL 2.5x sharp 98.5 % equal / 1.5
  % off by 1, area 99.7 / 0.3, scanlines dim 87.5 / 12.5, black 88.8 / 11.2;
  NTSC 3x sharp 100 / 0, area 99.9 / 0.1, dim 89.4 / 10.6; nothing off by
  more than 1.  PNGs in findings/scaler/bench_png (scaler_run.sh writes
  them to build/scaler/png): rtl_lin_* = the bench's HDMI picture,
  model_lin_* = the model on the RTL's rows (the +-1 gate), study_* = the
  study's renders of the same frame (study_pal_2p5_crt_lin2_L.png is
  bit-identical to the picture Paul approved, scaler_png/out/full), sheet_*
  = 4x crops side by side.  The RTL renders sit one HD row lower than the
  study's (ruling above) and use today's horizontal capture, not the
  study's 1.6x area.
- Ruling (step 6): the Scaling setting lives in bits 5:4 of
  config.scanlines -- bits 1:0 are Scanlines, bits 3:2 the old "(laced)"
  item; older firmware never wrote 5:4 (memset 0), preserved them in its
  menu (masks 0xfc / 0xf3) and sent only bits 1:0 to the core, so old config
  files load as 0; the other candidates (crt_mask / crt_bloom / crt_beam
  upper bits) are range-checked by older firmware, which would reset the
  mask / bloom / beam on a downgrade.  Encoding 0 Sharp, 1 Area, 2 Line rate
  (3 loads as Sharp), so fresh and old configs get Sharp; the core's code
  differs (0 line rate, 1 sharp, 2 area: an older firmware sending one or two
  bytes keeps today's picture) and ConfigVideo maps.  212 bytes,
  CONFIG_VERSION 4 -- cost if wrong: none for the struct; a config file
  saved with "(laced)" set keeps those bits, unused.
- Ruling (step 6): "Scaling" replaces the Video page's "(laced)" line
  (the page has 8 lines, all used) -- that item's bits never reached any
  core here (ConfigVideo sends scanlines & 3) -- cost if wrong: an item
  that did nothing is gone.
- Ruling (step 6): the core gets Scaling as bits 7:6 of the OSD video
  command's second byte (userio_osd crt_fx 6 -> 8 bits, crt_cfg 12 -> 14
  bits through minimig.v / minimig_virtual_top to pal_to_ddr), and on
  openaars a Scaling other than line rate turns amber's scandoubler off
  like the CRT items (minimig.v crt_any) -- the exact-ratio modes need the
  15 kHz picture.  With Sharp the default, the HDMI path gets 15 kHz by
  default -- cost if wrong: the scandoubled VGA picture (if anything still
  uses it) is off unless Scaling is Line rate and the CRT items are off.
