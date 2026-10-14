# Scaling survey: HDMI upsampler, both axes, native and RTG (2026-10-13)

Literature and prior-art survey for backlog "Video scaler" item 2 (even
vertical scaling), widened on 2026-10-13 to both axes and the RTG
(Picasso96) path. No RTL was changed and nothing was built. The numbers in
section 4 come from a 1-D model, `findings/scaler/line_model.py` (numpy,
runs in a second). Everything else comes from reading the RTL or from the
cited sources.

Status of sources: for the journal papers I checked the bibliographic data
against Crossref (the DOIs below resolve). I did **not** read their full
texts, which are behind IEEE/ACM paywalls. What a paper "does" is taken from
its abstract, a secondary source (named), or general knowledge of the field,
and is marked like that. The emulator sources (MiSTer, libretro) I read in
source form.

---

## 0. Summary

- **One structure for every path:** a small *polyphase* resampler in each
  axis, 2 taps (3 vertically when downscaling), with weights taken from a
  phase-indexed table, and the multiply-adds done in **linear light**. The
  table decides the kernel. The same hardware then gives nearest, the
  **area-pixel (Winscale) box** with a sharpness knob (the window width),
  bilinear, and the CRT beam profiles. This is the structure crt_post.v
  already has vertically (WROM phase table, 6 DSPs, cur + next line), so
  most of it exists.
- **Native, CRT off:** area weighting (an exact-overlap box), in linear
  light. It is Paul's A, A, (A+B)/2, B, B idea, but the real ratio is
  **2.40, not 2.5** (see 1.1), so the weights follow the measured line phase
  rather than a fixed pattern. In the model a one-line-high white line gets
  the same light at every position: max/min 1.000, against 1.500 for today's
  nearest (2 or 3 HD lines).
- **Native, CRT on:** keep the existing two-line Gaussian beam at the
  time-measured fractional position (this is what crt-lottes and MiSTer's
  scanline filters do). Two changes: always use the two-line beam when
  scanlines are on, and do the beam sum in linear light. Today's trick
  (`w_lin^(1/2.4)` in crt_mkroms.py) is exact only where the two lines
  have the same colour.
- **RTG:** the same area resampler in both axes, with a firmware-set
  sharpness. Downscaling (768 -> 720) needs 3 vertical taps for an exact
  box, and nearest *drops whole lines* there (section 4). Without a frame
  buffer there is one hard constraint: the RTG mode's timing must match
  720p's. That means exactly 50/60 Hz, and the vertical blanking fraction
  active/total = 720/750. Today's modes (55/57 Hz, 768 of 802 lines, and
  so on) neither fit nor fill 720 lines, and they give non-CEA HDMI frames.
  Since the HDMI sink never sees the RTG timing, the Picasso96 modes can be
  defined to meet the constraint (section 5.3).
- **Gamma-correct blending is worth it.** Blending 8-bit codes undoes much
  of the evenness, because a 50 % code is 19 % light. At 1.2x (RTG 600 ->
  720) gamma-space area weighting has a light ratio of 1.71, against 1.00
  in linear light. Cost: about 2-3 block RAMs (decode/encode tables) and a
  few hundred LUTs.
- **Try it first with no RTL change at all:** a new crt_wrom.mem whose
  "V filter, scanlines off" row holds area weights instead of the linear
  blend (section 6, stage 0).

---

## 1. What the RTL does today (read from the tree, not simulated)

### 1.1 Native Amiga video (`pal_to_hd_upsample.v`, `pal_to_ddr.sv`)

- **Line buffer:** one `bram_tdp` of 16 K x 24 per upsampler: a ring of 8
  lines of 2048 words, about 12 RAMB36 each. There are **two instances**
  (`my50hzupsample`, `my60hzupsample`) that write the same input, so about
  24 RAMB36 in all. Port A writes in clk_114. Port B reads in clk_148 =
  2 x the 74.25 MHz HD pixel clock, so there are **two port-B reads per
  HD pixel**. One is the picture (`r_addrb`). The other, in the
  "update clock" `w_hdfall`, reads the **same x of the next buffer**
  (`w_addrb = r_addrb + 0x800`, the CRT next-line read). So exactly
  **two Amiga lines are readable per HD pixel**, with no free slot.
- **Write side:** sample enable `r_pix_en` on a coarse clk_114 grid
  (`r_pix_clock_dev`), not one word per Amiga pixel (backlog item 1). The
  horizontal mapping is therefore *time-proportional*: one input line goes
  onto one HD line, quantised. `crt_mkframe.py` calls the superhires strip
  "the capture limit today": superhires is already *down*sampled
  horizontally.
- **Vertical mapping is time, not a counter:** the reader moves to the next
  buffer at the HD hsync after the write side finished a line
  (`r_next_buf`). The HD raster is genlocked to the input vsync
  (`o_frame_end` -> `signal_generator.i_frame_end`). Each HD line therefore
  shows the newest complete Amiga line, and the vertical scale is the
  **line-rate ratio**:
  - 50 Hz path: T_A / T_HD = 9509.4 / 3960 = **2.401** HD lines per Amiga
    line (12 HD lines per 5 Amiga lines: 3,2,3,2,2). It is not 2.5: 288
    lines become 692 HD lines, not 720.
  - 60 Hz path: T_HD = 3300 clk_148, **2.88** HD lines per input line, for
    NTSC and PAL alike (the chipset clock is PAL-derived;
    `crt_run.sh` vposp60: "8 x 2.88 = 23.0 HD lines"). NTSC 240 lines is
    therefore ~691 HD lines, **not an exact 3x**.
  - Interlaced input is shown field by field. Each field is 2.40x, and the
    long field's half-line vsync shifts the phase by ~0.5 input line, so the
    fields interleave (crt_run.sh `lace`). There is no weave, so the
    "576 -> 720 = 1.25x" case does not arise until item 3 (interlace) is
    done.
- **Why other ratios need more memory:** with a ratio other than the
  line-rate ratio, the reader drifts against the writer. For 2.5x the read
  side would consume 288 lines in 720 x 26.7 us = 19.2 ms, while 300 are
  written: a drift of 12 lines over the 8-line ring. An integer 2x
  (576 lines) drifts ~48 lines the other way. **So integer or exactly-2.5x
  native modes need a frame buffer** (or a ring of at least 16 / 64 lines).
  This ties item 2 to item 4 (50 -> 60 Hz).
- **The line phase already exists:** `o_line_phase` = clk_148 since this HD
  line's buffer toggle, /128 (7 bits; 74 steps per Amiga line, 31 per HD
  line at 50 Hz). It is the "based on timing" idea, and it is what the CRT
  stage uses.

### 1.2 CRT stage (`crt_post.v`, `crt_beamh.v`, `crt_mkroms.py`)

- `crt_beamh` (clk_114) is a horizontal Gaussian spot **in linear light**:
  DEC table 8 -> 16-bit linear, a 9-tap symmetric FIR in DSP48s, then an
  ENC table. It runs before the line buffers. This is the in-tree precedent
  for linear-light arithmetic.
- `crt_post` (clk_148, after the 50/60 select): WROM 2048 x 18, address
  `{hz60, vblend, scan[1:0], phase[6:0]}`, gives `{w1, w0}` per HD line.
  Then `v = cur*w0 + next*w1` (6 DSP multipliers), bloom table, a
  horizontal 3-tap, and the mask/brightness LUT. The weights multiply
  **gamma-coded** pixels. crt_mkroms.py stores the beam profile as
  `w_lin^(1/2.4)`, which is exact only when cur == next (a flat field).
- WROM rows in use: `vblend=0, scan=0` is the bypass (nearest). `vblend=1,
  scan=0` is the "V filter with scanlines off" = **plain linear blend
  (bilinear) in gamma space**. Scan 2/3 are dim/black, single-line or
  two-line beam. **The `scan=1` rows (4 x 128 entries) are generated but
  never selected** by pal_to_ddr's OSD mapping (off/dim/black -> 0/2/3).
  They are free room for a new mode without a larger ROM.
- The vertical effects run only with 15 kHz input and RTG off
  (`r_crt_ok`).
- The two-line beam is already "even" by construction (bench gate `ripple`:
  light per input line max/min <= 1.1). The single-line profile used when
  the V filter is off samples a cosine 2 or 3 times per line, so it carries
  the same 2/3 unevenness as nearest.

### 1.3 RTG (Picasso96) path

- The RTG frame buffer lives in Zorro II fast RAM. `minimig_virtual_top.v`
  fetches it at the **Amiga chipset's programmable timing** (`hblank_out`,
  `vblank_out`, `rtg_vbend`, pixel width = 113.44 MHz / divider: 56.72 or
  28.36 MHz) and muxes it onto `VGA_R/G/B/HS/VS`. Those reach `pal_to_ddr`
  exactly like native video, so **RTG goes through the same line-buffer
  upsamplers**.
- There is no RTG-specific scaling. `r_crt_ok`, crt_beamh's `ok` and
  `r_crt_cfg` switch every CRT effect off (more than 400 lines, or RTG).
  The 50/60 Hz path is picked by the input frame rate (`frame_freq`,
  < 53 Hz -> 50 Hz path). On the 60 Hz instance `i_rtg_enable` only selects
  the undelayed HD vsync.
- So RTG today is scaled the same time-proportional way:
  - **Vertical:** each HD line shows the newest complete input line, so
    lines are repeated or dropped by the line-rate ratio. The picture
    height is N_act x T_in_line / T_HD HD lines.
  - **Horizontal:** input line time onto HD line time, quantised.
  - **Frame:** `signal_generator` restarts its vertical counter only at
    `i_frame_end`, so the HDMI frame has the input's refresh. A 55 Hz RTG
    mode gives a ~814-line "720p" frame on the 60 Hz path, which is not a
    CEA timing.

  Paul's working modes (doc/workbench-setup.md) and their heights by that
  arithmetic:

  | Mode | Line time | Path (T_HD) | HD lines high |
  |---|---|---|---|
  | 1024x768 (1279 x 802 @ 56.72 MHz, 55 Hz) | 22.55 us | 60 Hz (22.22 us) | ~779: top and bottom cut at 720 |
  | 800x600 (1280 x 768 @ 56.72 MHz, 57 Hz) | 22.57 us | 60 Hz | ~609 |
  | 832x480 (1012 x 560 @ 28.36 MHz, 50 Hz) | 35.7 us | 50 Hz (26.67 us) | ~642 |
  | 720x480 (940 x 588 @ 28.36 MHz, 51 Hz) | 33.1 us | 50 Hz | ~597 |

  None of them fills or fits 720 lines, and all scale by repeating or
  dropping lines. *Derived from reading; confirm in sim (section 7, leg
  R0).*
- `pal_to_ddr` has a `vga_clk_pixel` input wired to `vga_pixel` (the RTG
  pixel strobe `rtg_pixel_d`, or Denise's `vga_strobe`) that is **unused**.
  Pixel-exact capture (item 1) is one wire away.

---

## 2. Literature

### 2.1 Reconstruction and interpolation theory

| Work | What it optimises | Text / pixel art | Hardware cost | Downscaling |
| --- | --- | --- | --- | --- |
| Parker, Kenyon, Troxel, "Comparison of interpolating methods for image resampling", IEEE TMI 2(1):31-39, 1983, doi:10.1109/TMI.1983.4307610 | Frequency response of nearest / linear / cubic B-spline / high-resolution cubic, for resampling *band-limited* images | Ranks nearest worst for smooth images. For hard-edged content this is the wrong yardstick (see 3.1) | Defines the 1-, 2- and 4-tap classes still used | Interpolators only, no prefilter |
| Keys, "Cubic convolution interpolation for digital image processing", IEEE TASSP 29(6):1153-1160, 1981, doi:10.1109/TASSP.1981.1163711 | 4-tap piecewise cubic, a = -1/2: third-order accurate for smooth signals | Overshoot (ringing) at hard edges: halos round text and 1-px lines (general knowledge) | 4 taps per axis: 4 line buffers + 4 vertical MACs per channel | No; needs a widened kernel |
| Mitchell & Netravali, "Reconstruction filters in computer graphics", SIGGRAPH 1988, Computer Graphics 22(4):221-228, doi:10.1145/378456.378514 | Perceptual trade-off of blur, ringing and anisotropy over the (B, C) cubic family; recommends B = C = 1/3 | Less ringing than Keys, softer. Still a smooth-signal model | As Keys | Kernel stretched by 1/r for downscale (standard practice) |
| Duchon, "Lanczos filtering in one and two dimensions", J. Appl. Meteor. 18(8):1016-1022, 1979, doi:10.1175/1520-0450(1979)018<1016:LFIOAT>2.0.CO;2 | Windowed sinc, near-ideal low-pass | Strongest ringing of the set on hard edges | 4-6 taps per axis | Good *if* stretched by 1/r |
| Thevenaz, Blu, Unser, "Interpolation revisited", IEEE TMI 19(7):739-758, 2000, doi:10.1109/42.875199 | Approximation order and frequency response; generalised (prefiltered) B-spline interpolation beats same-support kernels | Smooth-signal theory: best for photos and medical images, not designed for box-like sources | Needs a recursive prefilter (whole-line IIR), which is awkward in a streaming line buffer | Not addressed |
| Blu, Thevenaz, Unser, "Linear interpolation revitalized", IEEE TIP 13(5):710-719, 2004, doi:10.1109/TIP.2004.826093 | Shifted linear interpolation: a 2-tap kernel, shifted by ~0.21 sample plus a 1-tap IIR prefilter, approaching cubic quality | Interesting as "2 taps done better", but still optimises smooth signals | 2 taps + a causal IIR per line | No |
| Meijering, "A chronology of interpolation", Proc. IEEE 90(3):319-342, 2002, doi:10.1109/5.993400; Schaum, "Theory and design of local interpolators", CVGIP:GMIP 55(6):464-481, 1993, doi:10.1006/gmip.1993.1035 | Surveys and design theory | Background | - | - |
| Crochiere & Rabiner, "Interpolation and decimation of digital signals - a tutorial review", Proc. IEEE 69(3):300-331, 1981, doi:10.1109/PROC.1981.11969 | Polyphase structure: an arbitrary-ratio resampler = one FIR whose coefficient set is chosen by the output phase | Kernel-agnostic: it is the *structure*, the table chooses the kernel | N taps x M phases of coefficients in ROM; N MACs | Yes, with the kernel widened by 1/r |

Takeaway: everything from Keys to Thevenaz optimises the reconstruction of
a **band-limited** signal from point samples. Amiga and desktop graphics are
not band-limited: a pixel is meant as a solid block (on an LCD) or a beam
spot (on a CRT). The interpolators that win on photos ring or blur on text.
Smith's memo "A pixel is not a little square" (A. R. Smith, Microsoft
Tech. Memo 6, 1995; no DOI, *not re-read for this survey*) is the classic
statement of the point-sample view. For retro and desktop content, the
square (box) view is the one that matches the author's intent, which is why
the area-pixel family below fits better.

### 2.2 Area-pixel (box / overlap) scalers: the family this design belongs to

| Work | Method | Text / pixel art | Hardware | Downscaling |
| --- | --- | --- | --- | --- |
| Fant, "A nonaliasing, real-time spatial transform technique", IEEE CG&A 6(1):71-80, 1986, doi:10.1109/MCG.1986.276613 | Streaming 1-D resampler: input and output pixels as intervals, each output pixel = input weighted by overlap; separable two-pass for 2-D | Exact box: edges stay one transition wide, total light is preserved | Built for real-time hardware: one accumulator per channel, input consumed in order (*from the abstract and the standard textbook account, Wolberg's "Digital Image Warping"; full text not read*) | **Yes**: area averaging *is* the anti-alias prefilter, any ratio |
| Kim, Seong, Lee, Kim, "Winscale: an image-scaling algorithm using an area pixel model", IEEE TCSVT 13(6):549-553, 2003, doi:10.1109/TCSVT.2003.813431 | Output pixel = window over the source grid, value = area-weighted sum of **at most 4 (2x2) source pixels**. Abstract: "fine-edge and changeable smoothness" (the window size is the sharpness knob); handles streaming data; scale up and down; FPGA implementation | Designed for display scaling of sharp content | Abstract (quoted in IJCII 5(3) 2015): "four line buffers rather than a full frame buffer". Secondary table: 29 K gates, 65 MHz | Up and down, but 2x2 limits an exact box to output pixels no larger than a source pixel (my reading: 2 taps cover a window of at most 1 source pixel) |
| Aho, Vanne, Kuusilinna, Hamalainen, "Comments on 'Winscale...'", IEEE TCSVT 15(3):454-455, 2005, doi:10.1109/TCSVT.2004.842599 | Comment paper. Semantic Scholar TLDR: in upscaling, Winscale's computation is close to bilinear interpolation | Supports section 3.1: the area model is a clamped (trapezoidal) linear interpolator | - | - |
| P.-Y. Chen, C.-Y. Lien, C.-P. Lu, "VLSI implementation of an edge-oriented image scaling processor", IEEE TVLSI 17(9):1275-1284, 2009, doi:10.1109/TVLSI.2008.2003003 | Area-pixel scaling plus a "simple edge catching technique" that adapts the window to local edges; "floating-point magnification factor" (arbitrary ratio) | Edge preservation aimed at natural images. For pixel art, steering towards nearest at edges brings back uneven widths (my inference) | Abstract: 7-stage pipeline, 10.4 K gates, ~200 MHz (0.18 um), **one line buffer** | Arbitrary factor per the abstract; downscale quality not stated in the abstract |
| S.-L. Chen, H.-Y. Huang, C.-H. Luo, "A low-cost high-quality adaptive scalar for real-time multimedia applications", IEEE TCSVT 21(11):1600-1611, 2011, doi:10.1109/TCSVT.2011.2129790 | Bilinear plus sharpening and clamp prefilters (T-model / inverse-T kernels) to undo bilinear blur | Sharpening on 1-px content adds overshoot | Secondary (Khalaf et al. 2021): "two line buffers"; IJCII table: 9.28 K gates, 280 MHz | Not the focus |
| S.-L. Chen, "VLSI implementation of a low-cost high-quality image scaling processor", IEEE TCAS-II 60(1):31-35, 2013, doi:10.1109/TCSII.2012.2234873; and "VLSI implementation of an adaptive edge-enhanced image scalar for real-time multimedia applications", IEEE TCSVT 23(9):1510-1522, 2013, doi:10.1109/TCSVT.2013.2248492 | Bilinear with combined sharpening/clamp prefilter; edge detector + sharpening spatial filter + simplified bilinear | As above | Small (thousands of gates), 1-4 line buffers | Upscaling focus |

The secondary sources are named because they supply the gate and
line-buffer numbers I could not read in the originals: IJCII 5(3) 2015
(Periyar University, an abstract digest) and Khalaf et al., J. Healthc.
Eng. 2021, doi:10.1155/2021/6297856. Both are low-tier venues. Treat their
numbers as indicative.

### 2.3 Edge-directed and content-adaptive methods (context, rejected)

- Li & Orchard, "New edge-directed interpolation" (NEDI), IEEE TIP
  10(10):1521-1527, 2001, doi:10.1109/83.951537. It estimates local
  covariance and interpolates along edges, for 2x upscaling of natural
  images. It needs a 4x4 (or larger) neighbourhood and a small matrix
  inversion per pixel. On pixel art it rounds corners and invents
  diagonals.
- Hardware edge-directed: Chen, Sun, Zhang, Tao, "Algorithm and VLSI
  architecture of edge-directed image upscaling for 4k display system",
  IEEE TCSVT 26(9):1758-1771, 2016, doi:10.1109/TCSVT.2015.2473255. This
  shows ED upscaling *can* be pipelined, but at multi-line-buffer and
  multiplier cost well beyond our budget (*abstract-level; numbers not
  read*). It also targets natural video.
- Kopf & Lischinski, "Depixelizing pixel art", ACM TOG 30(4), SIGGRAPH
  2011, doi:10.1145/2010324.1964994. It vectorises the pixel grid (a
  similarity graph, splines). Offline and far too costly, and it changes
  the art. Context only.
- Kopf, Shamir, Peers, "Content-adaptive image downscaling", ACM TOG 32(6)
  2013, doi:10.1145/2508363.2508370, and Oztireli & Gross, "Perceptually
  based downscaling of images", ACM TOG 34(4) 2015, doi:10.1145/2766891.
  Optimised (iterative) downscalers that keep thin features. They show
  that box/area is the right *baseline* for downscaling and that thin lines
  are the hard case. Both are offline.

### 2.4 FPGA/VLSI real-time scaler architectures

- Nuno-Maganda & Arias-Estrada, "Real-time FPGA-based architecture for
  bicubic interpolation: an application for digital image scaling",
  ReConFig 2005, doi:10.1109/RECONFIG.2005.34.
- C.-C. Lin et al., "Real-time FPGA architecture of extended linear
  convolution for digital image scaling", FPT 2008,
  doi:10.1109/FPT.2008.4762423. A secondary source says ~60 % less
  hardware than their bicubic design.
- Mahale et al., "Hardware architecture of bi-cubic convolution
  interpolation for real-time image scaling", FPT 2014,
  doi:10.1109/FPT.2014.7082790.
- Arnabat-Benedicto & Cardells-Tormo, "Flexible hardware architecture for
  2-D separable scaling using convolution interpolation", SiPS 2005,
  doi:10.1109/SIPS.2005.1579953.

All of these follow the same template: separable, N line buffers for N
vertical taps, a phase accumulator (DDA) per axis, and a coefficient ROM
indexed by phase. What changes between them is the kernel and N. *Titles
and venues verified; architecture details are general knowledge of this
class, not read from these specific texts.*

### 2.5 Gamma and perception of thin grey edges

- Poynton, "The rehabilitation of gamma", SPIE 3299:232-249, 1998,
  doi:10.1117/12.320126. Video codes are perceptually uniform, not linear
  in light. Arithmetic that models light (filtering, blending) belongs in
  linear light.
- Naiman & Makous, "Spatial nonlinearities of gray-scale CRT pixels", SPIE
  1666, 1992, doi:10.1117/12.135955, and "Undetected gray strips displace
  perceived edges nonlinearly", JOSA A 10(5):794, 1993,
  doi:10.1364/JOSAA.10.000794. A grey sliver at an edge, too thin to be
  seen as a strip, *moves the perceived edge*, and not linearly in the
  code. This is the vision-science basis for area weighting: the mixed line
  is read as an edge position, so lines look evenly thick if (and only if)
  the sliver carries the right *light*.
- Klassen & Bharat, "Correcting for short-range spatial non-linearities of
  CRT-based output devices", SIGGRAPH 1993, doi:10.1145/166117.166123.
  Adjacent CRT pixels do not add linearly (beam rise and fall). Relevant to
  a faithful CRT model, not to the scaler.
- Brasseur, "Gamma error in picture scaling",
  http://www.ericbrasseur.org/gamma.html (web article, not peer-reviewed).
  Demonstrates the darkening of 50 % mixes when scaling in sRGB.

### 2.6 Retro-scaler practice (shortened; read in source form)

- **MiSTer ascal.vhd** (github.com/MiSTer-devel/Template_MiSTer,
  `sys/ascal.vhd`):
  - Modes: Nearest, Bilinear, Sharp Bilinear, Bicubic, **Polyphase**.
  - Polyphase: 4 taps, 2^FRAC phases (16 by default), 10-bit
    coefficients, separate H and V tables loaded at run time, plus an
    "adaptive" second set blended by the pixel's max(R,G,B). That second
    set is a brightness-dependent beam, like our bloom.
  - Vertical filtering reads 4 output-side line buffers. The source comes
    from a DDR frame buffer, which is what frees it from genlock (triple
    buffering optional).
  - `vscale_mode` (MiSTer.ini): fit / integer / 0.5 steps / 0.25 steps.
  - The Filters_MiSTer README says custom coefficient sets are for "high
    quality without uneven scaling and shimmering during scrolling". The
    scanline filters there are just *vertical coefficient sets aligned to
    source lines*. This is the "one structure, table picks the kernel"
    approach proposed here.
  - Gamma is a separate LUT in the MiSTer framework, not in ascal (none in
    ascal.vhd).
- **libretro sharp-bilinear** (Themaister) and **sharp-bilinear-simple**
  (rsn8887), slang-shaders `pixel-art-scaling/shaders/`. A nearest prescale
  by an integer s, then bilinear:
  `f = (d - clamp(d, -(0.5 - 0.5/s), 0.5 - 0.5/s)) * s + 0.5`, with
  s = floor(out/in). This is a clamped linear ramp of width 1/s source
  pixels. The area box is the same ramp with width = one output pixel
  (1/ratio), see 3.1.
- **crt-lottes** (slang-shaders `crt/shaders/crt-lottes.slang`). In linear
  light (`ToLinear`), three source lines -1/0/+1, each weighted by
  `Gaus(dst + off, hardScan) = exp2(hardScan * |d|^shape)` of the output
  pixel's fractional distance `Dist(pos).y` from the line centre. This is
  the per-output-line beam intensity from fractional source position: what
  crt_post's two-line beam does, except crt_post does it in gamma space.
  **crt-easymode** uses a cos^beam scanline weight on the fractional
  position, with gamma in/out powers.
- **OSSC / RetroTINK-2X/5X** are line multipliers whose output timing is
  derived from the input (integer line repeat, scanlines per source line).
  RetroTINK-4K and Analogue: *not verified for this survey*; their public
  notes were not re-read.

---

## 3. Theory, as it applies here

### 3.1 Area weighting is a clamped linear ramp

Let an output line (or pixel) be an interval of width h in source units
(h = 1/ratio), centred at distance d0 in [0, 1) below source line k's
centre. The next line starts at d0 = 0.5. The share of line k+1 is the
overlap:

    w1 = clamp((d0 - 0.5)/W + 0.5, 0, 1),   w0 = 1 - w1,   W = h

This is linear interpolation with the ramp narrowed from 1 source line to
W.

- **W is the single sharpness knob:**
  - W -> 0: nearest
  - W = h: exact area (Fant / Winscale)
  - W = 1/floor(1/h): sharp-bilinear
  - W = 1: bilinear
- **One mixed line per boundary:** for upscaling (h < 1) with W = h, every
  source boundary falls inside exactly one output line. That line is the
  only one mixed. All others are pure.
- **Downscaling (h > 1):** an output interval can cover a whole source line
  plus slivers of both neighbours, so an exact box needs 3 taps (enough for
  any ratio >= 0.5). With 2 taps the sliver is dropped: at 768 -> 720 that
  is at most 6.7 % of one line's light. Small, but nearest drops *whole*
  lines (section 4).
- **Integer ratios:** with the phase aligned to the grid, area = nearest
  exactly (no mixed lines). So an integer mode costs nothing extra in this
  structure.

### 3.2 Light, not codes

The ramp gives every source line exactly 1/h output lines of *light* only if
w0, w1 multiply light. Multiplying 8-bit codes (gamma ~2.2-2.4) makes a
w = 0.5 sliver 0.5^2.4 = 19 % light. A white line on black then gets
2 + 0.19 instead of 2.5 lines' light, and the amount depends on where the
boundary falls: unevenness and scroll shimmer come back (section 4,
"gamma" rows). A CRT also adds the light of its beams: the Gaussian spots of
neighbouring lines sum in light, and the gap between scanlines depends on
spot width against line pitch. Bright lines bloom wider, which crt_post's
bloom table models.

### 3.3 Shimmer

The output grid is fixed on screen (genlocked, time-based phase). A vertical
scroll by one source line per frame moves every source line through all
phase positions. Any method whose rendering of a line depends on phase
"breathes" while scrolling:
- nearest: 2/3 lines
- gamma-space blends: light varies
- too-narrow beam: scanline beat

Linear-light area keeps the light and the centroid steady; only the edge
softness moves between the two edges.

---

## 4. Model numbers (findings/scaler/line_model.py)

A white line one source line high on black, at 20 successive positions
(scroll). The columns are:
- **light max/min:** the line's light over positions (1.000 = perfectly
  even)
- **centroid jitter:** the line's light-weighted centre, max deviation from
  its ideal path, in output lines
- **width spread:** RMS width max - min, in output lines
- **light in mixed lines:** a sharpness proxy (0 % = hard edges only)

The window column scales W against an output line (1.0 = exact area, 0.5 =
half an output line).

| Ratio | Method | Blend in | Light max/min | Centroid jitter | Width spread | Light in mixed lines |
| --- | --- | --- | --- | --- | --- | --- |
| **2.40 (native 50 Hz)** | nearest (today) | - | **1.500** | 0.21 | 0.32 | 0 % |
| | area, W = 1 | gamma | 1.127 | 0.12 | 0.13 | 30 % |
| | area, W = 1 | **linear** | **1.000** | 0.05 | 0.04 | 38 % |
| | area, W = 0.5 | linear | 1.387 | 0.03 | 0.30 | 16 % |
| | bilinear | gamma | 1.138 | 0.02 | 0.07 | 100 % |
| | sharp-bilinear (s = 2) | linear | 1.072 | 0.04 | 0.06 | 50 % |
| **2.88 (60 Hz path)** | nearest | - | 1.500 | 0.42 | 0.32 | 0 % |
| | area, W = 1 | gamma | 1.200 | 0.03 | 0.09 | 23 % |
| | area, W = 1 | linear | 1.000 | 0.02 | 0.12 | 32 % |
| **1.5 (RTG 480 -> 720)** | nearest | - | 2.000 | 0.00 | 0.50 | 0 % |
| | area, W = 1 | gamma | 1.029 | 0.08 | 0.10 | 56 % |
| | area, W = 1 | linear | 1.000 | 0.06 | 0.04 | 67 % |
| | area, W = 0.5 | linear | 1.191 | 0.08 | 0.04 | 33 % |
| **1.2 (RTG 600 -> 720)** | nearest | - | 2.000 | 0.30 | 0.50 | 0 % |
| | area, W = 1 | gamma | **1.706** | 0.14 | 0.38 | 80 % |
| | area, W = 1 | linear | **1.000** | 0.06 | 0.10 | 83 % |
| | bilinear | linear | 1.105 | 0.07 | 0.04 | 100 % |
| **0.9375 (RTG 768 -> 720)** | nearest | - | **line vanishes** (inf) | - | - | 0 % |
| | area, W = 1 | gamma | 2.637 | 0.20 | - | 100 % |
| | area, W = 1 | linear | 1.000 | 0.03 | - | 100 % |
| 2.0 / 3.0 (integer) | nearest = phase-aligned area | - | 1.000 | 0 | 0 | 0 % |

Reading the table:
1. Exact-overlap area in linear light is the only method that is perfectly
   even at every ratio, including downscaling.
2. Gamma-space area already cuts the native unevenness from 1.5 to
   1.13-1.20, but fails badly at the low RTG ratios.
3. Narrowing the window (W = 0.5) buys sharpness and loses evenness quickly.
4. At 1.2x and below, *every* even method mixes most lines: a desktop at
   600 -> 720 will look soft whatever the kernel. The only sharp *and* even
   answer there is an integer ratio (section 5.3).

---

## 5. Recommendation

### 5.1 Native, CRT off

**Area weighting, W = output line (exact overlap), in linear light, phase
from the existing time measurement.** Horizontally the same once the write
side is pixel-exact (backlog item 1). Lowres is ~3.5-4 HD pixels per
pixel, so the gain there is smaller but real for horizontal scrolling.
Superhires is a *down*scale and needs it most. Offer W as an OSD
"sharpness" with 2-3 steps (exact, sharper, and maybe bilinear-soft). Paul
judges it in the PNGs of section 7.

Gamma: worth it for the native path too. Gamma-space area takes the light
ratio to 1.13, linear to 1.00. A gamma-space mix of two *different* bright
colours also leaves a visibly darker seam line. Stage 0 (gamma-space,
ROM-only) is still a useful first look because it costs nothing.

### 5.2 Native, CRT on

Keep the beam model: two adjacent lines, Gaussian of the fractional
time-based distance (= crt-lottes, MiSTer scanline coefficient sets).
1. Always use the two-line beam when scanlines are on. The single-line
   cosine profile has the nearest-neighbour 2/3 problem. This is an OSD
   mapping change in pal_to_ddr; keep the V bit only for "scanlines off".
2. Move the beam multiply-add to linear light (the same decode/encode as
   5.1). The beam profile then becomes the plain Gaussian, without the
   `^(1/2.4)` flat-field trick, and stays correct where cur != next (a
   white line under a dark one).
3. The bloom table (its input becomes the linear sum) and the mask/LUT
   stage stay as they are. The LUT stage can absorb the re-encode.

With CRT on, the area kernel and the beam kernel are just two table
contents for the same 2-tap MAC.

### 5.3 RTG

**The same resampler, both axes, area kernel with firmware-set W, linear
light, 3 vertical taps (exact down to 0.5x).** Plus three system-level
points that matter more than the kernel:

1. **Integer ratios are the only sharp-and-even answer** for desktop text.
   Offer Picasso96 modes 1280x720 (1:1), 640x360 (2x), 426x240 (3x), and
   say so in doc/workbench-setup.md. Phase-aligned area = nearest at
   integer ratios, so no special case is needed.
2. **Timing rule (no frame buffer).** With the time-based phase, the
   reader always shows the newest line and never drifts, but the vertical
   scale is then *fixed* at T_in_line / T_HD. A scale chosen freely (e.g.
   "fit N_act to 720" by a line counter) drifts against the writer by
   720 x |N_tot/750 - N_act/720| lines per frame, even at exactly 50/60 Hz:
   - 1024x768 / 802: 1.9 lines (fits the 8-line ring)
   - 800x600 / 768: 137 lines
   - 832x480 / 560: 58
   - 720x480 / 588: 84

   The HDMI sink only ever sees the 720p raster, so the RTG timings are
   internal and can be chosen to suit the scaler:
   - refresh **exactly 50 or 60 Hz**, so the HD frame is 750 lines and
     CEA-standard (today's 55/57 Hz modes are not)
   - vertical total **N_tot = N_act x 750/720** (600 -> 625, 480 -> 500,
     768 -> 800), so the active picture takes the same time as 720p's
     active lines

   Then the time-based phase *is* "fit to 720" with no drift. Horizontal has
   no such constraint: the line buffer holds the whole line, and the step is
   a per-frame constant (measured written extent `r_wend` / 1280). The
   driver's mode table (`minimig.card`, Picasso96Mode settings) is the place
   for it. Whether the chipset's beam counters and the RTG fetch can run with
   such short vertical blanking is to be checked.
3. **Long term: fetch the RTG frame buffer directly** at output timing, as
   ascal does with DDR. Any mode, any refresh, no blanking rule. It costs a
   memory port on Zorro II fast RAM at about the bandwidth RTG scan-out uses
   today, and shares the frame-buffer work with backlog items 3 and 4. Out
   of scope here.

Edge-oriented area scaling (Chen et al. 2009) and the sharpening prefilters
(S.-L. Chen 2011/2013) are **not recommended**. They are tuned for natural
images. On 1-px desktop lines, edge steering pulls back towards nearest
(uneven), and sharpening adds overshoot.

### 5.4 Gamma-correct blending: cost

| Item | Size | Where |
| --- | --- | --- |
| Decode 8 -> 16 bit linear | 256 x 16 per channel. 6 lookups per HD pixel (2 lines x 3 ch), 9 with 3 taps. A RAMB18 port does 2 lookups per pixel (2 clk_148 each), so 2-3 RAMB18 | After the line-buffer read |
| Encode 16 -> 8 | crt_beamh's piecewise index (11-bit linear segment + log segment) into 4096 x 8: one RAMB36 serves 4 lookups per pixel, so 1 RAMB36 for 3 channels | After the last MAC; could merge with crt_post's stage-E LUT (another page) |
| Wider MACs | 16 x 9 bit products: still one DSP48E1 each | - |
| LUTs | ~150-300 (muxing, pipeline) | - |

Total about **2-3 RAMB36 equivalents and no extra DSPs** beyond the MACs.
Worth it: section 4 shows it is the difference between "more even" and
"even".

---

## 6. Fit to the current RTL

### Stage 0: ROM only (an evening; the first board look)

- Regenerate `crt_wrom.mem` with the `vblend=1, scan=0` row (and/or the
  unused `scan=1` rows) holding gamma-space area weights from the formula
  in 3.1, h = 3960/9509.4 (50 Hz) or 3300/9509.4 (60 Hz).
- Selected by the existing OSD "V filter" bit with scanlines off. No RTL
  change (if the scan=1 rows are used: a 2-line OSD mapping change in
  pal_to_ddr, and `i_lut` must stay 0 for it).
- Native 15 kHz only, vertical only. Expect a constant vertical shift of
  ~0.5 Amiga line against the bypass. The two-line read sees cur + next, so
  the box boundary sits at d0 = 0.5, while nearest switches at the buffer
  toggle. The same is true of today's linear blend.

### Stage 1: linear-light vertical in crt_post

- Decode tables on `i_cur`/`i_nxt` and an encode after stage C. The
  weights become plain linear (area or Gaussian beam).
- Line buffers and reads unchanged: 2 Amiga lines per HD pixel, as today.
- Cost: ~2-3 RAMB36, ~300 LUTs, 0 new DSPs (the 6 exist).

### Stage 2: the general resampler (native horizontal + RTG)

- **Write:** one word per source pixel on `vga_pixel` (item 1). With a
  mode-independent write side, **the two upsamplers can share one ring**
  (today both write the same input into separate 12-RAMB36 rings), which
  frees ~12 RAMB36.
- **Vertical taps:** RTG downscale needs 3 lines per HD pixel; port B gives
  2. Use the freed BRAM to split the ring into even/odd-line banks, each
  with its own port B (4 reads per HD pixel), or a 16-line ring.
- **Horizontal:** a DDA per HD line (16.16 step, per frame from the written
  extent, or firmware). Source pixels are consumed in order (Fant-style), so
  the horizontal taps come from a 2-3 entry shift register, not extra BRAM
  reads. Downscaling (r < 1) needs up to 2 new source pixels per HD pixel
  per line: store 2 pixels per 48-bit word (same BRAM count, half the
  depth).
- **Weights:** two phase tables, V per HD line (exists as WROM) and H per
  pixel (new, 256 x 27 for 3 taps x 9 bit, one RAMB18). Both are
  firmware-writable (crt_post already has the `i_wwe` port, tied off today)
  so the 832 firmware loads the kernel and W per mode.
- **RTG vertical phase:** the time-based phase normalised by the measured
  input line period. A reciprocal once per frame (sequential divider) and
  one multiply per HD line, off the pixel path.

| Resource | Stage 1 | Stage 2 (incl. 1) | Budget |
| --- | --- | --- | --- |
| RAMB36 (equiv.) | +2...3 | +4...6 new, -12 if the rings merge | 81/135 used |
| DSP48 | 0 | +6...9 (H MACs; V reuses crt_post's 6, +3 for a third tap) | 44/240 used |
| LUTs | ~300 | ~1,000-1,500 (DDAs, banks, control) | ~10,000 free |
| Pipeline | +2-3 clk_148 (decode, encode), absorbed by reading earlier like `CRT_LAT` | +4-6 HD pixels | - |

Timing: every multiply is a fully registered DSP48 (A/B/M/P), every table a
BRAM with its output register, plus one fabric register before each DSP, as
crt_post does today. No new arithmetic sits on the clk_148 fabric paths.
Divide and reciprocal run per frame or per line, multi-cycle.

Core vendor-neutrality (memory "Core vendor-neutral"): this is inferred
BRAM and multipliers only, no Xilinx primitives.

---

## 7. Simulation plan (as for the CRT filter: render to PNG, judge, then RTL)

### Phase A: Python reference model (no RTL; hours)

`findings/scaler/` or `sim/hdmi_upsample/scaler_model.py`:
- Inputs:
  - `crt_mkframe.py`'s Amiga frame (bars, ramps, Workbench text, 1-px
    lines, hires/superhires text)
  - a new `scaler_mkrtg.py` desktop frame at 640x480, 800x600, 1024x768:
    Workbench-style window, 1-px frames, an 8-px font, a 1-px grid,
    checkerboards, a diagonal line
- Kernels, each in gamma and linear light:
  - nearest
  - area with W = {1, 0.75, 0.5} x output pixel
  - sharp-bilinear
  - bilinear
  - Keys a = -0.5 (to show the ringing)
- Ratios: native 2.40 / 2.88 (HD line phases from the bench's
  `PREFIX_phase.txt`, so the model uses the RTL's own phase sequence);
  RTG 1.5, 1.2, 0.9375, plus 1280x720 1:1.
- Output: 1280x720 PNGs named like the bench's (`img/<leg>.png`), and a
  2x nearest crop of the text and line regions for close viewing.
- **Scroll test:** 24 frames, the source moved down one line per frame
  (native) or one pixel per frame in both axes (RTG), written as an
  animated PNG/GIF and as a "strip" image. Rows of the same 1-px line
  across frames are stacked side by side, so breathing is visible in one
  still.
- Metrics per picture (extending `crt_check.py`): light max/min per
  1-px line, centroid jitter and width spread (as line_model.py, but 2-D
  and on real pictures), the 10-90 % edge width of text stems, and the
  overshoot (for Keys).

### Phase B: ROM-only stage 0 through the real RTL (Verilator, existing bench)

`crt_mkroms.py --area` writes the variant WROM. New legs in
`crt_run.sh`:
- `area15`: `+cfg=` with the V filter on, scanlines off
- `area60`: `+force60`, same
- `arealace`: `+lace`

`crt_check.py ripple`-style gate: light per input line max/min <= 1.05
(gamma-space area expected ~1.13, so this leg also *measures* the gamma
penalty in RTL). Phase stability: from `PREFIX_phase.txt` over 4 frames,
every HD line's WROM index identical frame to frame. A /128 boundary
flicker would show as shimmer on a still picture.

### Phase C: scroll in the bench

New tb plusarg `+vscroll=N`: the source row index is offset by N x
(frame number) (the input frame wraps). The leg dumps 8 HD frames and
renders the same strip image as Phase A. Gate: the per-line light ratio
over frames equals the static one.

### Phase D: RTG bench

New tb plusarg `+rtgmode=WxH,Ntot,Htot,div` that drives an RTG-like timing
from a desktop frame:
- `R0`: today's path, to confirm the section 1.3 heights and line
  repeat/drop
- `R1..R3`: the blanking-rule timings
- `R4`: 1280x720 1:1, bit-exact against the source frame

**Paul's review step:** a contact sheet per input (methods x settings) at
1:1 HD pixels, viewed on the actual monitor full-screen (not scaled by an
image viewer), for both the static picture and the scroll strips.

---

## 8. Open points / not verified

- The full texts of Winscale, Chen 2009 and the S.-L. Chen papers were not
  read. In particular: Winscale's exact downscale handling, and the
  edge-catching thresholds.
- RTG output heights in 1.3 are from arithmetic on the RTL, not simulated.
- RetroTINK-4K / Analogue scaler notes not re-checked.
- Smith 1995 memo cited from memory.
- Whether 720p sinks would accept a non-CEA line rate (an alternative to
  the blanking rule) was not explored. The blanking rule avoids the
  question.

## Paul's review of the PNGs (2026-10-13)

- Sharp-bilinear with a 0.5 output-pixel ramp "looks pretty close" (Paul, judged
  by eye on the comparison sheets, scratchpad scaler_png/out).  Known cost from
  the model: line light varies ~1.4 (max/min, linear light) while scrolling,
  against ~1.005 for exact area weighting.  Since the method is only the
  weight table, the ramp can be an OSD setting (nearest .. 0.5 .. area).
