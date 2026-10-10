# AdvPat -- HDMI (ADV7511) test screens

Two open issues on the HDMI output:

- The ADV7511's 12-bit DDR video bus is hold-limited: blue noise on dark greys
  at the -0.8 ns clock delay, gone at -1.2 ns. A centred-data image is planned
  in which every OSD "HDMI clock delay" step from -1.2 to +1.6 ns should be
  clean. AdvPat is the eye scan for it: a set of screens, each stressing the
  bus in a known way, to step through at each delay.
- doc/backlog.md "HDMI: sync loss in RTG modes and in demos that flash a
  lot": the flash screens reproduce full-screen colour changes every 1, 2 or
  4 frames.

## How the 24-bit pixel crosses the 12 pins

`rtl/openaars/adv7511/adv_ddr.v` sends each pixel `{R, G, B}` as two halves on
the same 12 pins: first `data[11:0]` = {G3..G0, B7..B0}, then `data[23:12]` =
{R7..R0, G7..G4}. So each pin carries two different colour bits:

| pin | 1st half | 2nd half |
|---|---|---|
| 0..3 | B0..B3 | G4..G7 |
| 4..7 | B4..B7 | R0..R3 |
| 8..11 | G0..G3 | R4..R7 |

A hold or setup problem on one pin shows in both of its colour bits; which
patterns and channels are noisy says which pins and which edge fail.

- Dark greys 0..63 use B0-B5, G0-G5, R0-R5: in the 1st half pins 0-5 (blue)
  and 8-11 (green), in the 2nd half pins 0-1 (green) and 4-9 (red).
- Solid `FFF000` is 000 in the 1st half and FFF in the 2nd: all 12 pins
  toggle on **every** edge, the worst case for the bus with no picture detail
  at all. `000FFF` is the same with the opposite phase.

## Usage

    AdvPat [PAT=n] [LIST] [DUMP=n]

- `PAT=n`: start at pattern n (default 0).
- `LIST`: print the pattern list and exit. `DUMP=n`: print pattern n's 256
  colours (RRGGBB) and exit.
- On screen: **left mouse button**, space or cursor right: next pattern;
  **right button**, backspace or cursor left: previous; **both buttons** or
  ESC: exit. Buttons act when released. On exit AdvPat prints the last
  pattern's number. Keys pressed while it runs also reach the Shell afterwards.

There is no on-screen label: count presses, or start at a pattern with
`PAT=n`.

## The patterns

| # | pattern | screen |
|---|---|---|
| 0 | dark grey 0-63, 4 strips | 64 vertical bands of 5 lores pixels, levels 0..63 (every 8-bit level), four strips: **the blue-noise case** |
| 1 | dark red/green/blue/grey 0-63 | the same, one strip per channel: red, green, blue, grey |
| 2 | grey 0-255 | four strips of 64 levels: every 8-bit grey |
| 3, 4, 5 | red / green / blue 0-255 | the same per channel |
| 6 | colour bars | white, yellow, cyan, green, magenta, red, blue, black |
| 7, 8, 9 | stripes 555555/AAAAAA lores / hires / superhires | single-pixel columns of complementary greys: every pin toggles between neighbouring pixels |
| 10, 11, 12 | stripes 00FF00/FF00FF | complementary green / magenta |
| 13, 14, 15 | stripes FFF000/000FFF | the two all-pins-toggle colours side by side |
| 16 | solid FFF000 | all 12 pins toggle on every edge (borders too) |
| 17 | solid 000FFF | the same, opposite phase |
| 18, 19, 20 | flash black/white every frame / 2nd / 4th frame | the whole screen, borders included, alternates black and white (25, 12.5, 6.25 full cycles a second on PAL) |
| 21, 22, 23 | flash 8 colours every frame / 2nd / 4th frame | black, red, green, blue, white, yellow, cyan, magenta in turn |

Patterns 0-6 use 8 lores bitplanes and the full AGA palette; 7-15 one
bitplane (all `$5555`) in lores (320), hires (640) or superhires (1280);
16-23 no bitplanes (COLOR00 everywhere, borders included).

## The eye scan

For each OSD **HDMI clock delay** step from -1.2 ns to +1.6 ns:

1. Set the delay in the OSD, close the OSD.
2. `AdvPat`; step through patterns 0 to 17, a few seconds each, close to the
   screen. Note any sparkle/noise and where: which pattern, which strip or
   band (level), which colour the noise has.
3. Both buttons to exit.

Worksheet (mark `-` clean, or the noise seen, e.g. `b` blue sparkle, `g`, `r`,
`x` heavy):

| delay ns | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| -1.2 | | | | | | | | | | | | | | | | | | |
| -0.8 | | | | | | | | | | | | | | | | | | |
| ... | | | | | | | | | | | | | | | | | | |
| +1.6 | | | | | | | | | | | | | | | | | | |

The clean range of delays is the eye; its centre is where the delay should
sit. Noise only in the 1st-half colours (blue, low green) or only in the
2nd-half ones (red, high green) points at one edge.

## The flash test

At the delays -1.2, -0.4 and 0 ns (the backlog's first step), run
`AdvPat PAT=18` and step through 18-23, about 10 seconds each. Note whether
the monitor loses sync, how long it stays out, and whether it recovers by
itself; watch the OSD HDMI page's INT count and status after a loss. If the
behaviour changes with the delay, it is output timing (24 data lines
switching at once); if not, look at the sync/DE path and the ADV7511's
interrupt handling.

## Build and test

    make            # AdvPat, vasm
    make test       # test_advpat.sh: vamos plumbing test

`test_advpat.sh` runs a `-DVAMOS=1` build under vamos (amitools, python3.10).
vamos has no display; the VAMOS build skips graphics.library and the beam
waits and, instead of reading the mouse and keyboard, shows every pattern from
`PAT` on for four frames and exits. The test checks `LIST`, every `DUMP`
against a Python model of the 24 palettes, and -- rebuilt from the logged
BPLCON3 (bank, LOCT) and COLORxx writes -- that each pattern uploads exactly
those 256 24-bit colours to the AGA palette; that the flash screens change
COLOR00 every 1, 2 and 4 frames; the takeover and restore order (DMACONR
first, sprites off, one COP1LC + COPJMP1 per pattern, the OS's list at the
end, DMACON restored, BPLCON3 left at $0C00); `PAT`, and refused bad values.

**Only the board** shows the pictures: the copper lists (DDF, modulos,
superhires), the input handling, and of course the HDMI output itself.
