# Porting the MiSTer demo fixes — first batch, 2026-09-19

Written for Paul, to be read at the board.

The survey in [`mister-fixes.md`](mister-fixes.md) listed fourteen findings and
changed no RTL. This is the first batch actually ported: **ten of them**,
chosen because each is small, self-contained, and can be judged by a named demo
or program rather than by reading the diff again.

Nothing here has been run on hardware. Everything here lints clean, and the
build meets timing with no new violations. Treat every line below as "built,
not tested".

## Two bitstreams, and why they are separate

| Bitstream | Contains | State |
|---|---|---|
| `build/stage_ap040_keyq` | keyboard/OSD fixes only — F12, Caps Lock, the CPU line | built, **loaded on the board now** |
| `build/stage_ap040_demo1` | the ten chipset fixes below, on top of the same base | built, **not loaded** |
| `build/stage_ap040_temp` | the die temperature on the Chipset menu, on top of demo1 | built, **not loaded** |

The temperature image is third for a reason: the XADC configuration in it has
never been read back from a running board, so if the number it shows is absurd,
that says nothing about the ten chipset fixes underneath it. Test `demo1`
first, and treat `temp` as a separate question. One firmware binary is correct
on all three — the temperature line only appears when the core says it decodes
the register, so on `keyq` and `demo1` that line stays blank instead of
printing whatever else answers that address.

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
| Crystal Kingdom Dizzy [cr FLT] | black screen versus a running game | 1.4 CIA CNT/INMODE |
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
  other eight with it.
- The OS clock, and anything beam-synchronised, for the beam readback (1.14).

**Sanity "Roots 2.0" is a re-test, not a new test.** Fix 1.8 went in on
2026-09-12 and has never had an honest hardware run. Whatever it does on this
image is the first real result.

## TURN TURBO OFF BEFORE BLAMING A CHIPSET FIX

Learned the hard way on the first run of this batch, 2026-09-19. RAMJAM
"Copperslave" flickered through the opening effects and then lost the display
signal entirely — which looked exactly like fix 1.9 (the bitplane modulo) had
broken it, since that is the very demo 1.9 targets.

**It was the CPU speed.** With Turbo off the demo does not crash and renders
far better. Paul called it: an AP68040 with Turbo chip and kick RAM reaches
chip RAM without waiting for the Amiga's bus slots, so the CPU-to-chipset
timing ratio is nowhere near what a demo written for a 7 MHz 68000 assumes.
Beam-chasing code that polls VHPOSR and writes registers "just in time" simply
overruns.

Two things follow:

- **A demo that misbehaves is not evidence against a chipset fix until it has
  been retried with Turbo off.** Record the Turbo state with every demo result;
  a result without it is ambiguous.
- Before suspecting a fix, check whether the port is even in question: 1.9 was
  character-for-character upstream's, and the pointer-arithmetic block that
  consumes it is byte-identical between our tree and MiSTer's. That took one
  diff against the reference clone at
  `~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer` and would have ruled
  it out before any reverting was considered.

The other candidate explanations, both still worth remembering for a demo that
loses the display: the demo may not support AGA at all (try ECS/OCS in the
OSD), or it may switch to a mode the scandoubler and ADV7511 cannot carry,
which looks identical from the monitor's side and is not a chipset fault.

## Results so far, 2026-09-19 (image `stage_ap040_mousefix`)

| Test | Result |
|---|---|
| Sanity "Roots 2.0" | **PASS — fix 1.8 confirmed.** This closes the 2026-09-13 run recorded as CONFOUNDED; it is the first honest result for that fix, and it is a pass |
| Essence "Crazy Sexy Cool" | **PASS** — looks good (fixes 1.10/1.11, the `window_ena` pair, the highest-risk item in the batch) |
| RAMJAM "Copperslave" | Crashes with **Turbo on**, fine with **Turbo off** — CPU speed, not fix 1.9. Whether the modulo error itself is gone is still to be confirmed with Turbo off |
| Contraz "Domination" | not available on the Amiga yet — TBD |
| Desire "Hamazing" | not available yet — TBD |

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

**1.4 was ported after all** (CIA CNT pin and INMODE count-source selects,
Crystal Kingdom Dizzy). It is five files rather than one, which is why it was
set aside at first, but the behaviour change is almost entirely "a mode that
used to count the wrong thing now correctly counts nothing": CNT is tied high
at both CIAs, exactly as MiSTer ties it, because CIA-A's CNT is KCLK and
CIA-B's is a parallel-port handshake and this core models neither. The one live
mode, CRB 11, is cascade gated by CNT high, which with CNT constant is the
plain cascade it already did.

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
