# IrqLat -- interrupt latency under load

The demo "The Cure" stutters its music in heavy moments on the 68040 core with
Turbo chip RAM **off**, and never on the 68020 core. Two suspects:

- an interrupt is taken late because the 040's store buffer first has to drain
  slow posted chip-RAM writes (one CPU chip cycle per ~564 ns with Turbo chip
  off) before the exception frame can be written;
- the 040's chip accesses cost more than the 020's in general.

IrqLat measures how late interrupts are taken while one chosen load runs.
Run the same matrix on each image and Turbo setting, then compare the numbers.

## Usage

    IrqLat [LOAD=]NONE|CHIPWR|CHIPRD|CHIPCPY|FASTWR|BLIT|FPU
           [BPL] [FMODE=0..3] [NASTY] [RATE=Hz] [SECS=s] [OS]

| option | meaning |
|---|---|
| `NONE` | no load: the CPU spins on a flag in its own memory (the baseline) |
| `CHIPWR` | `MOVE.L` stores to a 64 KB chip RAM buffer (posted stores: the store buffer case) |
| `CHIPRD` | `MOVE.L` loads from chip RAM |
| `CHIPCPY` | `MOVE.L (A0)+,(A1)+` chip to chip, 64 KB |
| `FASTWR` | `MOVE.L` stores to fast RAM (refuses to run without fast RAM) |
| `BLIT` | back-to-back 32 KB blits, all four channels (A, B, C read, D write); the CPU polls DMACONR for BBUSY between blits |
| `NASTY` | with `BLIT`: blitter-nasty (DMACON BLTPRI), the CPU gets no chip slot while a blit runs |
| `FPU` | `FMUL`/`FDIV`/`FSQRT` loop (needs an FPU) |
| `BPL` | 8 lores bitplanes from our own copper list, combinable with any load |
| `FMODE=n` | AGA fetch mode for `BPL` (default 3, the demo case; 0 = the most slots taken, see below) |
| `RATE=Hz` | CIA-B timer A rate, 20..20000 (default 1000) |
| `SECS=s` | run time, 1..600 (default 5); the left mouse button stops a run early |
| `OS` | measure through the OS's interrupt dispatch instead of our own vectors |

The screen is black during a run (noise with `BPL`) and comes back afterwards.

## What it measures

Two interrupt sources run at the same time:

- **CIA-B timer A, level 6** (what music players use; ProTracker players run
  their tempo and DMA-restart timers on CIA-B). The timer counts the E clock
  (709379 Hz PAL, 1.41 us a tick) down from its latch value; at the underflow
  it reloads and interrupts. The handler's **first instruction** reads the
  timer, so `latch - count` is how long the interrupt took, to 1.41 us. The
  two timer bytes cannot be read at once: the handler reads high, low, high,
  and if the two high reads differ (the low byte borrowed in between) the low
  byte tells on which side of the borrow it was read. It reads the timer a
  second time right after; the difference is the cost of three CIA accesses.
- **The copper, level 3.** Our copper list requests COPER (a `MOVE` to INTREQ)
  at lines $30, $70, $B0 and $F0, horizontal position $10: in the horizontal
  blanking, before any bitplane fetch, so the request itself is not delayed by
  `BPL`. The handler's first instruction reads VHPOSR; the distance to the
  request is the latency in colour clocks (281.9 ns PAL). VPOSR gives V8; a
  second VHPOSR read gives the cost of two custom-register reads.

**Direct mode** (default): `Forbid`, `LoadView(NULL)`, `OwnBlitter`, `Disable`,
then all of INTENA off and our own level 3 and level 6 vectors at VBR+$6C and
VBR+$78 (VBR read with `MOVEC` -- the 68040 has one; it is printed). Only
COPER and EXTER are on, only timer A in the CIA-B ICR. Nothing of the OS runs
during the measurement. Everything is put back afterwards (INTENA, DMACON,
vectors, the CIA-B ICR mask as ciab.resource had it, CRA, the OS copper list
and view). CIA-B timer A is claimed through `ciab.resource` (`AddICRVector`)
in both modes, so a background music player that owns it is detected and
IrqLat refuses to run.

**OS mode** (`OS`): the same copper list and timer, but the copper interrupt
goes through exec's COPER server chain (`AddIntServer`, priority 127, so ours
is first) and the timer through ciab.resource's handler. The OS's own
interrupts (VERTB servers, keyboard, timer.device) stay on. OS minus direct is
the cost of the OS dispatch.

## Output

    IrqLat: DIRECT load CHIPWR bpl 8 FMODE 3 rate 1000 Hz latch 708 secs 5 E 709379 Hz PAL VBR 0802c000 CACR 80008000
    CIA-B timer A (level 6): taken 5000 expected 5000 missed 0 stored 5000
      latency us: min 2.81 avg 3.10 max 12.69
      read (3 CIA reads) us: avg 4.22 max 5.63
      hist us: <1 0 <2 0 <4 4800 <8 180 <16 20 <32 0 <64 0 <128 0 <256 0 <512 0 <1024 0 >=1024 0
      worst us: 12.69#3123 11.28#17 ...
    Copper (level 3): taken 1000 expected 1000 missed 0 stored 1000
      ...

(example numbers are illustrative, not measured)

- `taken`: interrupts handled during the run. `expected`: what should have
  come in that time -- for the timer from CIA-B's TOD (it counts lines; 45.4 E
  ticks a line), for the copper 4 per frame from CIA-A's TOD (it counts VSYNC).
  `missed` = expected - taken: interrupts that arrived while the previous one
  was still pending and merged with it (latency beyond one period), or never
  came. A count off by one at the start or end of the run is not a miss.
- `latency`: from the request to the handler's sample. For the timer the
  sample is the **second** CIA access of the handler (the low byte), so it
  includes one CIA access; subtract about a third of the `read` figure for
  the time to the handler's first instruction. For the copper it includes the
  copper's own `WAIT`/`MOVE` (a few colour clocks). Compare runs with each
  other and with `NONE`, not with zero.
- `read`: what the handler's own reads cost. Three back-to-back CIA accesses
  should be three E-clock periods, 4.23 us, on any Amiga; the beam reads are
  custom-register reads and get slower when the chip bus is busy.
- `hist`: how many samples fell below 1, 2, 4 ... 1024 us. `worst`: the five
  largest, with the sample number (`#n`: the timer's nth interrupt is n ms into
  a 1000 Hz run).
- `stored`: samples kept for the statistics (at most 262144 per source).

## What a real machine should give (estimates, to judge the numbers)

- **CIA, `NONE`**: interrupt recognition and the exception (~1 us on a 25 MHz
  68040, a little more on a 68020) plus one CIA access (0.7-1.4 us, it waits
  for the E clock): 2-3 ticks, 2.8-4.2 us. `read` 4.2 us.
- **Copper, `NONE`**: the copper's `MOVE` and Paula's interrupt plus the
  exception and one custom read: roughly 2-4 us.
- **`CHIPWR`, Turbo chip off, no bitplanes**: a real 040 must finish the
  writes still in its write buffer before the exception frame is stored --
  each a chip cycle (280-560 ns) -- so at most a microsecond or two above
  `NONE`. **Several microseconds more than the 020 image here is the
  store-buffer suspect.** Tens of microseconds or `missed` > 0 is a defect.
- **`BPL FMODE=0`**: on real AGA, 8 lores bitplanes at 1x fetch take every
  slot of the fetch window (DDFSTRT $38 to $D8, ~45 us of each 64 us line), so
  any CPU chip access issued there waits until the window ends: up to ~45 us,
  for any CPU, for both sources (the copper handler's beam read is a chip
  access; the vector fetch is too when VBR is 0). With `FMODE=3` the same
  planes take 8 of 32 slots: a few microseconds at most.
- **`BLIT NASTY`**: the blitter takes every chip cycle while a blit runs; one
  32 KB four-channel blit is ~18 ms. Any chip access waits for it: the copper
  handler's beam read, and the vector fetch when VBR is in chip RAM (VBR 0).
  Expect copper latencies up to ~18 ms and copper `missed` > 0 on any machine.
  Without `NASTY` the blitter gives the CPU a cycle after three: microseconds.
- **`OS`**: exec's dispatch adds a few microseconds on a 25 MHz 040 (about
  10-20 instructions plus the server-chain walk).

What matters for the stutter: a player whose interrupt is milliseconds late,
or missed, glitches. Look at `max`, the `>=1024`/`<1024` buckets and `missed`
first, then at the averages.

## The A/B matrix

`IrqLatMatrix` (an AmigaDOS script next to the binary) runs the 16 standard
runs for one image and one Turbo chip setting and appends them to a log:

    CD SD0:IrqLat
    Execute IrqLatMatrix SD0:irqlat.log "040 turbo off"

It takes about two minutes; do not touch the mouse (the left button ends a
run). Repeat for each combination, all into the same log:

| image | Turbo chip (OSD) | label |
|---|---|---|
| the 68020 (TG68K) image | off | `020 turbo off` |
| the 68020 image | on | `020 turbo on` |
| the current 68040 image | off | `040 turbo off` |
| the current 68040 image | on | `040 turbo on` |
| `build/stage_sb0` (040, store buffer off), when it exists | off | `040 sb0 turbo off` |
| `build/stage_sb0` | on | `040 sb0 turbo on` |

Note the CPU control panel settings (data cache, copyback) with each set; run
the 040 sets with the caches as they are when the demo stutters. `FPU` prints
an error line on an image without an FPU and the script carries on.

Back on the PC:

    ./irqlat_table.py irqlat.log > irqlat.md

gives one table row per run. Read it this way:

- `CHIPWR` (and `CHIPCPY`) **040 turbo off** much worse than **020 turbo off**,
  and **sb0** back near the 020: the store buffer delays the interrupt.
- 040 worse than 020 in every chip load including `CHIPRD`, and sb0 the
  same as the 040: the 040's chip access path, not the store buffer.
- Turbo on clean, turbo off bad on both cores: chipset slot arbitration, not
  the CPU.
- `NONE` already worse on the 040: the exception entry itself.

To try a single condition by hand: `IrqLat CHIPWR SECS=20`, or the demo's
rate: `IrqLat CHIPWR BPL RATE=50`.

## Build and test

    make            # IrqLat, vasm, -m68040 (runs on a 68020+: MOVEC, MULU.L)
    make test       # test_irqlat.sh: vamos plumbing test

`test_irqlat.sh` assembles a `-DVAMOS=1` variant and runs it under vamos
(amitools, python3.10). vamos has no custom chips, CIA or ROM: those reads
return 0 and every access is logged. The VAMOS build skips the graphics.library
and ciab.resource calls, runs each load loop for one pass, and replaces the
samples with a fixed synthetic set. The test checks:

- the options, and that bad ones are refused with rc 10;
- every statistic printed for the synthetic samples against a Python model of
  the post-processing (timer byte reconstruction across a borrow on either
  side and across a reload, beam position to latency across V8 and the frame
  wrap, histogram, worst five, missed counts);
- the register access order: INTENAR and DMACONR read before anything is
  written; INTENA `$7FFF`, ours on, `$7FFF`, the saved value; the copper list
  pointer written and strobed, then the OS's; CIA-B timer A stopped before its
  latch is written (low, then high), then START|LOAD, ICR timer A only, and
  the ICR mask restored; the OS path never writes the ICR or INTENA `$7FFF`
  and calls `AddIntServer`/`RemIntServer`; the blitter load writes BLTSIZE
  last;
- `irqlat_table.py` on a matrix-style log.

**Only the board can check** that the interrupts arrive, the latency numbers
themselves, the takeover and restore leaving the OS working (mouse, keyboard,
disk, screen after the run), and the copper list's display (`BPL`).
