# Porting the MiSTer demo fixes — first batch, 2026-09-19

Written for Paul, to be read at the board.

The survey in [`mister-fixes.md`](mister-fixes.md) listed fourteen findings and
changed no RTL. This is the first batch actually ported: **eight of them**,
chosen because each is small, self-contained, and can be judged by a named demo
or program rather than by reading the diff again.

Nothing here has been run on hardware. Everything here lints clean, and the
build meets timing with no new violations. Treat every line below as "built,
not tested".

## Two bitstreams, and why they are separate

| Bitstream | Contains | State |
|---|---|---|
| `build/stage_ap040_keyq` | keyboard/OSD fixes only — F12, Caps Lock, the CPU line | built, **loaded on the board now** |
| `build/stage_ap040_demo1` | the eight chipset fixes below, on top of the same base | built, **not loaded** |

They are separate on purpose. On 2026-09-13 the only bitstream carrying fix 1.8
also carried a CPU cache change that made the whole machine misbehave, and the
resulting "Roots 2.0 still corrupt" reading proved nothing at all — the doc
records that test as CONFOUNDED. Two bitstreams cost one extra load and make
each result mean something on its own.

**`stage_ap040_keyq` also needs `fw/ctrl_832/832OSDAD.bin` copied to the SD
card.** The F12 fix is half RTL and half firmware, and the firmware half lives
on the card, not in the bitstream. Without the copy, the core has the queue and
nothing drains it — F12 behaves exactly as it does today, and the test says
nothing.

## Test order

Start with the keyboard image, because it is already loaded and the tests are
quick.

**1. `stage_ap040_keyq`** (loaded; copy `832OSDAD.bin` to the SD card first)

- OSD line should read **CPU: MC68040 + FPU + MMU**, not "020 alpha". This is
  the cheapest possible check that the version byte arrives, so if it still
  says 020, stop — the SD card probably has the old firmware.
- F12 opens the OSD. Then try to provoke the old failure: hold and release
  Ctrl and Left-Alt quickly, tap keys while the OSD opens and closes, switch
  the keyboard between the Amiga and the OSD a few times. F12 should keep
  working.
- Caps Lock: press it with the OSD **open**, close the OSD, then use Caps
  normally. Before this change that sequence inverted it — capitals when the
  LED is off — and it stayed inverted. Check the LED agrees with the letters.
- Everything else as usual: keyboard, mouse, disk.

**2. `stage_ap040_demo1`** (load over JTAG when you are ready)

Each line names what it is supposed to fix. A demo that was already fine and
stays fine tells us nothing either way; the ones worth the time are the named
symptoms.

| Test | Watch for | Fix |
|---|---|---|
| WhichAmiga 1.4 | display survives the DMAC probe (it used to go blank for good) | 1.1 gary |
| Contraz "Domination" | the B-channel texture, previously wiped mid-blit | 1.6 blitter |
| Andromeda "Nexus 7", Shade Cluster | the block of white lines should be gone | 1.7 BPLCON4 |
| RAMJAM "Copperslave" | line stride / modulo error | 1.9 bitplane DMA |
| Desire "Hamazing", Hambarger scene | HAM colours at the left edge | 1.10 window mask |
| Essence "Crazy Sexy Cool" | sprites in the border, previously hidden by playfield | 1.11 sprite priority |
| Risky Woods | in-game music tempo and sound effects | 1.2 CIA timers |
| Hybris | cannon/turret sprite vertical jitter | 1.14 beam readback |
| Sanity "Roots 2.0" | the sprite-copper-chunky section | 1.8 — **the confounded re-test**, see below |

**Regressions to check on the same image**, because three of these fixes touch
paths the whole display uses:

- Workbench: drag windows, DPaint fills — the blitter change (1.6) widens when
  `bltbhold` reloads.
- Any title with a blanked border / `brdrblnk` — fixes 1.10 and 1.11 hang the
  bitplane path off `window_ena`, and **our `window` generation is deliberately
  not MiSTer's**: AMR reversed the HDIWSTRT/HDIWSTOP comparison here so that
  `HDIWSTART==HDIWSTOP` blanks correctly. That is the one real risk in this
  batch. It is committed on its own so it can be reverted without taking the
  other seven with it.
- The OS clock, and anything beam-synchronised, for the beam readback (1.14).

**Sanity "Roots 2.0" is a re-test, not a new test.** Fix 1.8 went in on
2026-09-12 and has never had an honest hardware run. Whatever it does on this
image is the first real result.

## What was deliberately NOT ported

Three of the fourteen, each for a stated reason rather than for time:

- **1.5, sprite shifter loads one clk7 late (Hybris scoreboard).** The survey
  says not to port this one blind, and it is right. The same file carries a
  second, independent divergence from MiSTer (finding 2.1, the
  `clk7n_en`/`data16` relatch), and porting 1.5 into our un-relatched shifter
  is not the change MiSTer made. The author's own comment on their output
  pipeline is "Ugly — are we masking a copper timing problem here?". Decide 2.1
  first; the survey proposes a sim-only BPL1DAT-write-to-pixel latency
  comparison, which is the right next step.
- **1.3, TOD mid-counter carry bug (Pit-Fighter, Torvak).** Small and tempting,
  but the survey notes we also lack robinsonb5's *later* TOD `count_ena` fix
  and that the two interact. Porting one half of an interacting pair is how you
  manufacture another confounded test. Port both together or neither.
- **1.12, blitter freeze on mid-blit fill disable (Absolute Inebriation).** The
  largest diff in the group (~53 lines, a new `BLT_FROZEN` FSM state), the most
  likely to move timing, and the least field-proven upstream. Worth doing, not
  worth mixing into a batch whose value is that each item is individually
  falsifiable.

Also still open and untouched: **1.4**, the CIA CNT pin and INMODE count-source
selects (Crystal Kingdom Dizzy). Not risky — the survey's own summary is "a
mode that used to count now correctly counts nothing" — but it is four files
plus a port in `minimig.v`, so it wants its own pass rather than being appended
here.

## If something breaks

Every fix is one commit, each naming its MiSTer hash and its demo, so
`git revert` on a single commit is the whole rollback. The order of suspicion,
most likely first:

1. `denise: mask the bitplane path with the display window` — 1.10/1.11, the
   `window_ena` caveat above.
2. `agnus: the beam readback matches what real Agnus reports` — 1.13/1.14, if
   anything beam-synchronised or the OS clock misbehaves.
3. `blitter: a phantom BLTCON1 read no longer wipes the B texture` — 1.6, if
   general blitter output goes wrong rather than one demo.

The rest (gary, bitplane modulo, CIA reload) are narrow enough that a failure
would be specific and obvious.
