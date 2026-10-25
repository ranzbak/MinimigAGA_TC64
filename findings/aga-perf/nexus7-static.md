# Nexus 7 (Andromeda, TP4 1994): static reverse engineering for the FPGA stall

Date: 2026-10-25. Input: `NEXUS7.EXE` (801,228-byte CODE hunk in chip RAM plus a 754,312-byte BSS hunk).
Method: capstone disassembly. Unicorn (68040 model) emulates the real loader, the decruncher
and the P61 replay, and runs each part's per-frame routines from the memory state captured
when the loader starts that part. No RTL or repo source was changed.

## Notation

- `H+x`: offset in hunk 0 (CODE, `MEMF_CHIP`, so chip RAM). In my emulation hunk 0 sits at
  address 0, so absolute addresses in quoted listings of relocated parts are already `H+`
  offsets (`$7ef10.l` means `H+$7ef10`).
- `B+x`: offset in hunk 1 (BSS, `MEMF_ANY`, so fast RAM when fast RAM exists). In some quotes
  the BSS base shows as `$08000000` (`$80a8440.l` means `B+$a8440`).
- "Sync word": the word at `H+$6f8`, explained in section 2.
- Times are PAL VBL ticks from P61 init (50 per second). They come from emulating the replay
  routine, not from a guess at the song speed.

## 1. Loader (hunk 0 `$000`-`$520`) and the part interface

The startup code checks for AGA and a 68020 or better. It takes over the system with
`trap #0`, sets `CACR=$A119` at `$108` and moves the stack. It installs its level-3 handler
`H+$578` at VBR+$6c and enables VERTB with `INTENA=$c020` at `$174`.

Each part is entered as `jmp (a1)` from `$418`, with `a0 = H+$6ec`, which points to this
variable block:

| a0 offset | address  | content |
|---|---|---|
| `$00` | `H+$6ec` | chip work base + d0 (`$714` = `H+$71c`, moved to `H+$34e08` at `$1c2`-`$1d6`, 8-byte aligned) |
| `$04` | `H+$6f0` | BSS base + d1 (`$718` = `B+0`) |
| `$08` | `H+$6f4` | **VBL hook**: called from the level-3 handler when not 0. The loader waits for it to be 0 at `$342` and `$3c8` |
| `$0c` | `H+$6f8` | **music sync word** |
| `$10` | `H+$6fc` | `H+$408`, the decrunch entry (part 10 uses it) |
| `$14` | `H+$700` | `B+$b6b88`, a delta-decoded table (sine table, inferred) |
| `$18` | `H+$704` | VBR |

The level-3 handler at `H+$578` calls the music, writes the sync word, acknowledges VERTB,
checks the left mouse button for exit, and then calls the hook:

```
00578 movem.l  d0-d7/a0-a6,-(a7)
00582 jsr      $b5bdc.l              ; B+$b5bdc = P61_Music (The Player 6.1A, "P60A" header)
00588 lea.l    $b5bd8.l,a0
0058e move.l   $da2(a0),d0           ; P61 position-list pointer (already advanced)
00592 subq.l   #1,d0
00594 sub.l    $fa0(a0),d0           ; - position-list start  => song position
00598 lsl.w    #8,d0
0059a moveq    #$3f,d1
0059c sub.w    $d9a(a0),d1           ; $d9a counts rows down 63..0 => 63-x = row
005a0 move.b   d1,d0
005a2 lea.l    $6f8(pc),a0
005a6 move.w   d0,(a0)               ; SYNC = position<<8 | row
005a8 move.w   #$20,$9c(a6)          ; ack VERTB *before* the hook
005ae btst.b   #6,$bfe001.l
005b6 beq.w    $484                  ; LMB -> exit
005ba move.l   $6f4(pc),d0
005be beq.b    $5c4
005c0 movea.l  d0,a0
005c2 jsr      (a0)                  ; part hook
005c8 rte
```

The `$d9a` row counter is confirmed from the replay code at `B+$b5bd8+$5c2`
(`subq.w #1,$4(a3)` / `bmi` / `moveq #$3f` with `a3=$d96`).

Consequences of this design:

- The sync word goes up by one per row, and the music and the hook run in the same
  interrupt. Code running inside the hook therefore sees every row.
- If a hook takes longer than a frame, the music only slows down. It never skips a row.
- Only foreground code can miss a sync value.

### Song timeline (P61 emulated, `nexus7_re/musemu.py`)

- The song has 40 positions, `$00`-`$27`, at speed 7 from position 4 (positions 0-3 mix
  speeds 4-15).
- Positions `$13` and `$1d` have 32 rows and `$18` has 16 rows (pattern breaks).
- The song ends at tick **17,650 (353.0 s)**. There the sync word **wraps from `$273f` to
  `$0000`** and the song loops.
- Each row lasts 7 or 8 ticks. Every value the demo compares for equality does occur in the
  song (checked).

## 2. Part table, in execution order

Loader call forms:

- `$400`: decrunch with work area `B+0`.
- `$408`: decrunch with work area `H+$30f94`.
- `$414`: run.
- `$42a`/`$42e`: relocate then run. The first long of the part is the offset of its reloc
  table, and the entry is part+4.

The decruncher at `H+$c33aa` (`bra.w $c37de`) is an LZH/Huffman cruncher. The first long of
the stream is the unpacked length, it returns `d0=0` and keeps `d1`-`d7`/`a0`-`a6`.

| # | packed source | destination (len) | entry / how run | code runs in | starts on | ends on |
|---|---|---|---|---|---|---|
| (replay) | `H+$71c` | `B+$b5bd8` (`$23b0`) | init `jsr B+$b5bd8` at `$1ec`, play `B+$b5bdc` each VBL | fast | - | - |
| data for P0 | `H+$faa` | `B+$89664` (`$2c572`) | data (`d1` base for P0) | - | - | - |
| module | `H+$21ef4` | `H+$71c` (`$346e8`) | P61 module, samples stay in chip | - | - | - |
| **P0** intro | `H+$728e6` | `H+$34e08` (`$1b9c0`) | `bsr $418` at `$202`. Setup, then hook `H+$34f08`, then `rts` | chip | at once | its hook is replaced by P1 at `B+$148` |
| P2 code | `H+$76dd0` | `H+$507c8` (`$199b8`) | run later | | | |
| P1 code | `H+$45ca8` copied (`$18c`) to `B+$5ca24` | `B+0` (`$8965a`, work area `H+$6ff08`) | `$42a` relocates, entry `B+4` | **fast** | `>=$41f`, **`==$43a`**, **`==$500`** | `>=$709` |
| **P1** "milky way" | (above) | | foreground main loop + hooks `B+$1c02`, `B+$1c16` | fast | | |
| **P2** | (above) | `H+$507c8` | `$414` with `a2 = H+$442` (loader callback, see next row) | chip | `>=$70a`; hook works from `>=$733` | hook countdown `$108(a5)` |
| callback `$442` (run by P2 at `H+$50846`) | `H+$7fea0`, `H+$8645e`, `H+$8842c`, `H+$8a38c` | `H+$34e08` (`$14190`, data), `B+$a8220` (`$6016`, P4), `B+$a0000` (`$8212`, P7), `H+$7ee08` (`$2542`, P3) | foreground decrunch while P2 animates in VBL | | | |
| **P3** | `H+$8a38c` | `H+$7ee08` | `$42e`, `d0=$a000`, entry `H+$7ee0c` | chip | `>=$800` | **918 loop passes** (deterministic) |
| **P4** | `H+$8645e` | `B+$a8220` | `$42e`, `d0=$a000`, entry `B+$a8224` | **fast** | `>=$a00` | VBL counter `B+$a8440 >= $44c` |
| (copy) | `H+$8b166` | `B+$7000` (`$16564`, still packed) at `$27e` | | | | |
| **P5** | `H+$a16c6` | `H+$92e08` (`$18b2`) | `$42e`, `d0=$a000`, entry `H+$92e0c` | chip | `>=$c22` | 171 loop passes (`$1c6(a5)+=3` to `>$1fe`) |
| **P6** | `H+$a1f34` | `H+$946c8` (`$2e0a`) | `$42e`, `d0=$5000`, entry `H+$946cc` | chip | `>=$c3c` | hook counter `>$380`. **Foreground builds P7's 3D random walk into `B+0`** (`H+$947fa`) |
| **P7** "light sphere" | `H+$8842c` | `B+$a0000` (`$8212`) | `$414`, entry `B+$a0000` | **fast** | `>=$f00` | scene 1: VBL counter `>=$6a4`, then **`==$6aa`**. Scene 2: hook, countdown 225; the part returns while the hook keeps running |
| (copy) | `B+$14c5a` (= `H+$92dc0`, packed) | `B+$a8220` (`$890c`) at `$324`, then wait hook=0 at `$342` | | | | |
| **P8** | `B+$7000` (= `H+$8b166`) | `H+$56e08` (`$40d08`) | `$414`, entry `H+$56e08` | chip | `>=$1316`; hook turns the screen on at `==$1400` | hook countdown `$7b8(a5)` |
| **P9** | `B+$fb0c` (= `H+$93c72`) | `H+$97e08` (`$7030`) | `$414`. Precalc, installs a hook, returns | chip | hook-only copper events at `==$1800`/`$1804`/`$1807` | removed by P10 (`clr.l $8(a0)` at `H+$47dac`) |
| **P10** | `B+$1159a` (= `H+$95700`) | `H+$47cd8` (`$99e2`) | `$42a` with `a3=$a8220` (not relocated: an offset), entry `H+$47cdc` | chip | `>=$180c`, `>=$1900` | chain of hooks with flags. **Decrunches `B+$a8220` to `H+$609c8` itself** (`movea.l $10(a0),a0; jsr (a0)` at `H+$47de2`) and calls it with `d2=-1` |
| **P11** | `B+$a8220` | `H+$609c8` (`$1f758`), written by P10 | `$414`, `d2=0`, entry `H+$609c8` | chip | `>=$1c3c` | hook counter `$eca(a5) >= $44d` |
| **P12** | `H+$a2c8e` | `H+$70e08` (`$fa0`) | `$414`. Installs a hook and returns; loader decrunches P13 meanwhile | chip | `>=$2000` | hook clears itself (flag `$8d2(a5)`). Loader waits hook=0 at `$3c8` |
| P13 code | `H+$a3562` | `B+0` (`$46434`), then **copied to chip `H+$41720`** (`$46500` bytes, loader `$3ce`-`$3e6`) | `$414`, entry `H+$41720` | chip | `>=$2400` | end of scroll text (1,631 loop passes) |
| **P13** "raytraced scrollers are forever..." | | | | chip | | |
| **P14** end | `H+$c1e06` | `H+$34e08` (`$5b14`, same address as P0) | `bra $418`, tail jump, `d0=$6000` | chip | `>=$272e` (80-pass transition), then `>=$273f` | endless loop, left mouse exits |

Ideal timeline at 1 frame per pass:

| Part | Start | Notes |
|---|---|---|
| P0 | 0 s | |
| P1 | 53.5 s (display) | main loop 54.4 to 73.6 s |
| P2 | 73.7 s | |
| P3 | 81.3 s | |
| P4 | 99.2 s | P3 ends about 0.4 s *after* the P4 trigger even on ideal hardware |
| P5 | 121.9 s | |
| P6 | 125.5 s | |
| P7 | 144.0 s | scene 2 at about 178.1 s |
| P8 | 182.9 s | |
| P9 | 220.1 s | |
| P10 | 221.8 s | |
| P11 | 257.7 s | |
| P12 | 280.6 s | |
| P13 | 316.5 s | ends about 349.1 s |
| P14 | 349.8 s | window closes at 353.0 s |

## 3. Scene identification

Scene names below are inferred from code behaviour, ordering and data. I did not render
any frames.

### P0: intro credits

- Contains the font string `abcdefghijklmnopqrstuvwxyz1234567890.,-` and the names
  "andromeda", "dr.jekyll", "mr.hyde", "interphace", "archmage".
- Plays two interleaved delta-compressed animations from `B+$89664` (`'DLTA'`/`'ENDP'`
  chunks, decoder `H+$35030`).
- An animation loops forever via `move.l $4(a1),(a1)` at `'ENDP'`.

### P1: the "milky way rotation" right after the credits

- Runs entirely in fast RAM.
- At init it delta-decodes 512 KB at `B+$265c` and bit-reversal shuffles it (`B+$8`-`$96`):
  a 2D map. Its column ray-caster `B+$768` steps rays rotated by `B+$3e2` over that map and
  draws vertical byte spans (stride `$60`) into chip buffers. It is a rotating
  heightfield/voxel render (inferred).
- The hook `B+$27c` rebuilds a copper list every frame with random bitplane pointers every
  few lines, which gives a twinkling starfield.
- **It contains the demo's only two exact-match waits on the music.**

### P3: the bouncing ball with light beams

- `H+$7ef1a` computes a damped vertical bounce. Height is the parabola `(t^2 - T^2) * amp`;
  `amp` drops from `$100` to `$64`; the half-period is reset to `$1c` at each floor contact
  while the pass counter is below `$352`.
- Horizontal motion bounces between `$2e4` and `$357`.
- The ball is positioned with copper and bitplane pointers (`H+$7f126`, with `$ffdf` PAL wrap
  handling).
- Beams are XOR edges drawn with `bfchg`/`eor.b` (`H+$7f2ac`, `$7f3b4`, `$7f47e`) from
  rotated light points (`H+$7f7e6`) and then **blitter area-filled** (`H+$7f536`: BLTCON
  `$09f0`/`$0012`, BLTSIZE `$640f`).
- Its end is deterministic. The pass counter `$7ef10` reaches `$352`, after which `$7ef12`
  counts up by 1 per pass until `==$28`.

### P7: glowing "light sphere"

This is the strongest candidate for the reported "bouncing light-sphere, one scene over and
over":

- P6's foreground (`H+$947fa`) generates a 58,490-step 3D random walk (6 directions, 3-bit
  codes, 10 per long) bounded by the octahedron `|x|+|y|+|z| < $7e9`. It stores it at
  `B+0`.
- P7 rotates it (`B+$a03fe`) and plots every step as an additive brightness byte,
  `addq.b #1,(a5,d4.w)` into a chip chunky buffer, through a 6-way `jmp` table (`B+$a0508`).
  That draws a glowing ball of light filaments.
- An interrupt-driven chain of 16 blits (`B+$a077c`, masks `$0f0f`/`$3333`/`$5555`)
  converts the buffer to planar (blitter C2P).
- The VBL hook (`B+$a0a92`) moves the object vertically with a parabola on `counter mod 456`.
  It rests at line `$5d`, then falls to `$12c`.
- When it hits the bottom, the main loop (`B+$a020c`-`$a0230`) resets the trail and steps the
  background copper (`$272(a5) += $104`, new COP2LC).
- Scene 2 types "use your perception to penetrate the void of your mind" (`B+$a0c8a`).

### Other parts

| Part | What it is |
|---|---|
| P4 | 3D object of textured/shaded triangles (radix depth sort `B+$a873c`, span filler `B+$aa820`) plus an object on a spline path positioned by copper (`B+$adb8a`) and a distance-based light/flare (`B+$a8442`) |
| P8 | hook-timed effect |
| P9 | copper flashes on music hits |
| P10/P11 | 3D effect with handshake flags |
| P12 | hook-only effect |
| P13 | "raytraced scrollers" |
| P14 | end scroller ("nexus 7 / andromeda / in mcmxciv") |

## 4. Per-frame work, from emulation (`nexus7_re/p7.py`, `p13.py`, `p1314.py`, `prest.py`)

How to read the counts:

- Each counted chip or fast access is one CPU access of any size.
- A `move.l` to chip is 1 count here; it may cost 2 bus transactions on a 16-bit path.
- Blit words are the BLTSIZE height times width. DMA cycles are about words times the number
  of channels.
- "Code" is where the instructions were fetched from.

| Part | Unit | Instructions | Code in | Chip reads / writes | Fast r / w | Blitter |
|---|---|---|---|---|---|---|
| P0 | hook, even / odd frames | 18.5k / 6.3k | chip | 36 / 7,105 and 220 / 1,900 | 8.4k / 0 and 2.2k / 0 | - |
| P1 | main pass | 120k | fast | 0 / 11,974 | 19.8k / 370 | 1 blit, 6,864 words |
| P1 | hook | 2.2k | fast | 67 / 130 | | |
| P1 | `$1aae` precalc (between `==$43a` and `==$500`) | 1.09M | fast | 0 / 0 | 0 / 81,920 | |
| P2 | hook | 36.8k | chip | 522 / 1,285 | | |
| P3 | main pass | 27-36k | chip | 2.9-4.0k / 2.6-3.6k (`bfchg`/`eor` RMW + copper) | ~0 | 2 blits, 12,400 words (fill A->D 2 cycles/word + clear D 1 cycle/word, about 18.4k cycles) |
| P4 | main + hook | 147-151k | fast | 13.6k / 13.7k | 21.6k / 3.3k | 25,600 words (D-only clear) |
| P5 | main pass | 17-31k | chip | 2.7-3.1k / 2.9-4.8k | | 16,128 words |
| P6 | hook | 16-22k | chip | 1.6-1.8k / 1.8-2.7k | | 3 blits, 14,824 words |
| **P7 scene 1** | main pass | **140.5k** | **fast** | **7,500 / 9,816** (7,500 byte RMW + 2,304 long clears) | 8.3k / 16 | **16 blits, 23,040 words, A+B+D = about 69k DMA cycles** |
| P7 scene 1 | hook | 0.3-2.8k | fast | 0 / 10-90 | | |
| **P7** | scene-2 setup (`B+$a0b4e` to the poll) | 65.5k | fast | **1,351 / 29,100** | 2.7k / 470 | 8 blits, 9,216 words (A->D, about 18.4k cycles, **BLTPRI on**: DMACON `$87e0` at `B+$a0b6a`) |
| P8 | main + hook | 205.6k | chip | 10.9k / 9.3k | 16.4k / 16.4k | |
| P12 | hook | 65.8k | chip | 4.4k / 2.9k | | 20 blits, 2,080 words |
| P13 | main pass | 3.4-9.1k | chip | 0.2-0.8k / 1.3-1.6k | | 5-75 blits, 10.5-13.9k words |
| P14 | transition pass | 10.9k | chip | 340 / 7,770 | | 15,360 words |
| decrunch | `B+$5ca24` to `B+0` (562 KB, work area in chip) | 6.29M | chip (I-cached) | 432k / 116k | 310k / 263k | |
| P1 | init (`B+$8`-`$96`) | 8.0M | fast | 0 / 0 | 2.10M / 2.10M (byte-wise) | |

### Inner-loop sizes against a 256-byte 020/030 I-cache

| Loop | Size | Fits 256 B? |
|---|---|---|
| P7 point plotter: dispatcher `B+$a058a`-`$a05a0` plus 6 handlers at 32-byte spacing up to `B+$a065c` | **212 bytes** | yes. The handlers are spaced `lsl.b #5` apart on purpose |
| P7 BLIT interrupt handler | small | the handler sets CACR bit 1 (`bset #1`, 030 "freeze I-cache") so the interrupt does not evict the plotter. That bit does nothing on a 68040 |
| P1 ray-caster `B+$7e8`-`$854` | 108 bytes | yes |
| P1 `$1aae` | 78 bytes | yes |
| P3 line loops `H+$7f3f6` and `H+$7f4d6` | 26 and 14 bytes | yes |
| Decruncher literal/match loop `H+$c3894`-`$c39a8` | about 280 bytes | no, but its code is hunk 0 = chip on a 030 |

### D-cache

`CACR=$A119` means different things on each CPU:

- **68030:** EI, CI, IBE, ED, WA. The D-cache is on with write-allocate (useful only for fast
  RAM data).
- **68040 and this core:** only IE counts. `ap68040_backend.sv:2094` does
  `cacr_r <= wb_res & 32'h8000_8000`. So the D-cache is **off**, and every table or stream
  read in fast RAM is an uncached access.

### P7 is by far the heaviest chip-bus user

- The blitter C2P needs about 69k DMA cycles per frame. A PAL frame has about 70.9k
  chip-bus cycles (227.5 x 312) in total, before bitplane, copper, audio and refresh DMA.
- On top of that the CPU makes about 17.3k chip accesses per pass.
- So P7 scene 1 cannot run at 50 fps on any machine. It runs at **2 or more frames per pass**
  even on a real A1200. This is inferred from DMA arithmetic, not measured.
- With Turbo chip off, the FPGA's CPU chip-access cost multiplies the 17.3k CPU accesses and
  the 30.5k setup accesses directly.

## 5. Synchronisation: every decision point

Every compare against the sync word or a timer, from all decrunched code. The
`scanpoll.py`/`scanloop.py`/`scan2.py` scans were checked by hand.

| Site | Code | Test | Missable? |
|---|---|---|---|
| P1 `B+$a4` | `cmpi.w #$41f,$c(a0)` / `bcs.b $a4` | `>=` | no |
| **P1 `B+$13c`** | `0c68043a000c cmpi.w #$43a,$c(a0)` / `66f8 bne.b $13c` | **`==`**, foreground spin | **yes** |
| **P1 `B+$15e`** | `0c680500000c cmpi.w #$500,$c(a0)` / `66f8 bne.b $15e` | **`==`**, foreground spin | **yes** |
| P1 `B+$1c6`, `$1c3c` | `cmpi.w #$709,$c(a0)` / `bcs` | `>=` | no |
| P2 `H+$50820`, `$5086c` | `#$70a`, `#$733` / `bcs` | `>=` | no |
| P3 `H+$7eeaa` | `#$800` / `bcs`; end `cmpi.w #$28,$7ef12.l` / `bne` | `>=`; end is pass-counted (+1 per pass) | no (only slow motion) |
| P4 `B+$a83f0` | `#$a00` / `bcs`; end `cmpi.w #$44c,$21c(a5)` / `blt` (VBL counter) | `>=` | no |
| P5 `H+$92f8c` | `#$c22` / `bcs`; end `$1c6(a5)` `ble` | `>=` | no |
| P6 `H+$94788` | `#$c3c` / `bcs`; end `$947c6` `ble` | `>=` | no |
| P7 `B+$a01ca` | `#$f00` / `bcs`; main end `0c6d06a4150a cmpi.w #$6a4,$150a(a5)` / `6d98 blt.b` | `>=` | no |
| **P7 `B+$a0bd8`** | `0c6d06aa150a cmpi.w #$6aa,$150a(a5)` / `66f8 bne.b $a0bd8` | **`==`** on a VBL counter, foreground spin | **yes** |
| P7 `B+$a0e52` (scene-2 hook) | `cmp.w $2(a0,d1.w),d0` / `bne` against table `$1239,$123a,$123c,$123e,$123f,$1301,$1305,$ffff` | `==`, in hook | only if the hook starts after `$1239` (178.8 s). Then the text never appears; cosmetic |
| P8 `H+$56e3e` | `#$1316` / `bcs` | `>=` | no |
| P8 `H+$56e8e` (hook) | `cmpi.w #$1400,$c(a0)` / `bne` (COP1LC + DMA on) | `==`, in hook | if the hook is installed after 184.3 s the part's screen never switches on. Cosmetic, no lock |
| P9 `H+$97e38`/`$97e64`/`$97e6c` (hook) | `#$1800`, `#$1804`, `#$1807` | `==`, in hook | cosmetic |
| P10 `H+$47d96`, `$47db8` | `#$180c`, `#$1900` / `bcs` | `>=` | no |
| P10 `H+$47f9a` (hook) | `cmpi.w #$2a,$48020.l` / `bne`; the counter rises by 1 per hook call | `==` | no |
| P11 `H+$609e4` | `#$1c3c` / `bcs`; end `cmpi.w #$44d,$eca(a5)` / `bcs` | `>=` | no |
| P12 `H+$70e26` | `#$2000` / `bcs` | `>=` | no |
| P13 `H+$4174e` | `#$2400` / `bcs`; end = text terminator | `>=` | no |
| **P14 `H+$38f8c`** | `cmpi.w #$272e,$c(a0)` / `bcs` | `>=`, but **the song wraps to `$0000` at 353.0 s** | yes, after the wrap |
| **P14 `H+$34e6c`** | `cmpi.w #$273f,$c(a0)` / `bcs` | `>=`, valid only in ticks 17,636-17,649 (14 ticks) before the wrap | yes, after the wrap |
| P14 `H+$38fc6` | `addi #$28` / `cmpi.w #$c80,$41d0(a5)` / `bne` | pass-counted | no |

### Lock A: P1 `==$43a` (`B+$13c`)

The poll runs right after `>=$41f` and a 2 KB copy. Value `$43a` holds for ticks
2,676-2,683.

- **Missed when:** P1 reaches `B+$13c` after tick 2,683 (53.7 s). The work before it is: the
  loader's decrunches of 104 KB and 562 KB, relocation, P1's 8M-instruction init, plus P0's
  hook stealing about 6-18k instructions and 2-7k chip writes every VBL.
- **What you see:** P0's intro animation keeps looping, because P1 has not yet replaced the
  hook.
- **How long:** until `$43a` comes round again after the song wraps, about **5 min 53 s**.
- **Risk:** only a much slower machine than an 030/50 misses it. On a fast-RAM 040 the work is
  a few seconds.

### Lock B: P1 `==$500` (`B+$15e`)

`$43a` to `$500` is **43 ticks (0.86 s)**. In that window the foreground runs `bsr $1aae`
(1.09M instructions, 81,920 fast writes) while the hook `B+$1c02` runs every VBL.

- **Missed when:** that precalc takes more than 0.86 s. That needs a slow CPU or BSS in chip
  RAM. For example, a cache-less 020 class core at 14 MHz is on the edge (inferred).
- **What you see:** the copper starfield hook keeps running with the music, then the demo
  resumes after one song loop (5:53).
- **Fit:** this matches "another FPGA core looped in the milky-way part". The WHDLoad note
  "will not lock if the demo is music desynchronized" fits locks A and B (inferred).

### Lock C: P7 `==$6aa` (`B+$a0bd8`), the speed-dependent lock in the light-sphere part

- `$150a(a5)` is a VBL counter. The P7 hook adds 1 per VBL (`B+$a0b48 addq.w #1,$150a(a5)`,
  gated by `tst.w` at `B+$a0b20`).
- The main loop leaves at the first check where it is `>= $6a4`. Then it:
  1. waits for blitter idle and restores the level-3 vector (`B+$a024a`-`$a026c`);
  2. **waits one VBL** (`B+$a0b56`): +1;
  3. runs the scene-2 setup S (`$a14a2`, `$a0eda`, `$a0e98`, clear `$4800` chip bytes, text
     render `$a0d18` with `bfins`, 8 blits `$a0dd0`, clear `$16800` chip bytes);
  4. then spins on `==$6aa`.
- Let k be how far the counter has passed `$6a4` at the exit check. k ≤ (frames per main pass)
  − 1.
- **Missed when:** `k + floor(S / 20 ms) >= 6`.
- **What happens on a miss:** the 16-bit counter must wrap: **65,536 VBLs, about 21.8 min**.
  - The copper has already been switched at `B+$a0b66` to the scene-2 list at copper offset
    `$115e`: 1 bitplane, pointer 0, lowres.
  - The hook keeps changing copper words of the scene-1 list, which is no longer shown, so
    the screen stays still or blank while the music plays and loops.
  - Afterwards scene 2's music table has been passed, so its text never appears.
- **Emulated S:** about 3 ms of CPU, plus **30,451 chip accesses** (29,100 writes, mostly
  `move.l` clears of 110 KB), plus 18.4k blitter cycles (about 5.2 ms, with blitter-nasty on).

| CPU chip access cost | S | floor(S/20 ms) | Misses if k ≥ |
|---|---|---|---|
| about 0.3 µs (030/50 on AGA, inferred) | about 17 ms | 0 | 6 (cannot happen) |
| 1 µs | about 39 ms | 1 | 5 |
| 2 µs | about 69 ms | 3 | 3 (needs ≥ 4 frames per pass) |
| 3 µs | about 100 ms | 5 | 1 (2 frames per pass is enough) |

A real A1200 runs about 2 frames per pass (blitter-bound), so k ≤ 1, and S is about 1 frame.
That leaves 3-4 frames of slack. A machine whose CPU chip accesses are several times slower
than AGA's spends both more frames per pass (larger k) and a larger S. **Turbo chip shrinks
both terms.** This is the only lock in the ball/sphere part of the demo that depends on speed.

### Lock D: end of the demo (P13 to P14)

- P13 runs 1,631 VBL-synced passes from `>=$2400` (316.5 s). At 1 frame per pass it ends at
  about 349.1 s.
- Then come the `$c1e06` decrunch (23 KB) and P14's setup (770k instructions, about 206k chip
  accesses, 5,037 blits).
- The 80-pass transition (`H+$38f94`) must finish before tick 17,650 so that `>=$273f` can be
  seen in its 14-tick window.
- **Budget:** about 34.9 s for 1,631 + 80 passes plus setup, **about 4 % slack**.
- **What you see on a miss:** a black screen (P13 turns DMA off at `H+$417bc`) for one whole
  song loop (5:53) before the end scroller.
- A slow machine can hit this even when nothing else locks. It is not the reported scene, but
  it is the same class of bug.

### Can the ball scenes lock?

**P3** (bouncing ball with beams) cannot lock:

- Its exit is a pass count (`$7ef10` reaches `$352`, then `$7ef12` counts up by 1 per pass
  to `==$28`; `H+$7eeea`-`$7eef8`).
- Each pass waits for a VBL and work beyond a frame just adds frames, so a slow machine sees
  slow motion.
- That pushes P4-P6 late; the "music desync" cascade follows. P4 and P6 end on VBL counters;
  P5 on its pass count. P7 then starts at once because `>=$f00` has already passed. P7's
  scene-2 table and P8's `==$1400` screen-on can be skipped, which is cosmetic.

**P7** can lock (lock C). P7 scene 1 itself cannot hang:

- the main loop ends on `>=$6a4`;
- its blitter chain re-dispatches from `B+$a077c` until step 16 sets `$14f8(a5)`.

## 6. Self-modifying code and cache coherency

- **P7 patches its own interrupt handler.**
  - At `B+$a017c` it runs `move.l $6c(a1),$6e6(a5)`, writing the old level-3 vector into the
    operand of `B+$a06e4 jmp $0.l`.
  - That `jmp` runs when the BLIT handler sees VERTB pending (`B+$a0708`-`$a0710`, then
    `B+$a06d8`).
  - The line is written once, long before it first runs, and was never executed before.
    `B+$a0000`+ held nothing executable earlier (P1 ended at `B+$8965a`).
  - Safe on a real 040 and on this core, because the D-cache is off and the line is not
    cached yet. A store that stayed posted, or a stale prefetch, would turn it into
    `jmp $0` and crash on the first VBL inside a blit interrupt.
- **Decrunched code is run with no cache flush.**
  - The loader (`$400`/`$408`, then `jmp (a1)`), the chip copy at `$3ce` (then `jmp`), and
    P10's runtime decrunch into `H+$609c8` (then `jsr (a1)`) all run fresh code without
    `CINV`/`CPUSH`. The only `cinva`/`cpusha` the scan found are data bytes misread as code.
  - Per `ap68040_fetch.sv` (header comment), the core's I-cache is invalidated only by
    CINV/CPUSH, by snooping, and by a change of IE/TC/TTx. The CPU's own stores do not
    invalidate it.
  - The hazard therefore depends on executed code addresses being reused.
    `nexus7_re/flow.py` (recursive descent) found exactly one reuse: P0's code lines
    `H+$34e00`-`$35d1f` are reused by P14, about 5 minutes and tens of KB of other code
    later. With 8 KB, 4 ways, 128 sets this is safe in practice. In theory a stale line could
    survive.
  - P10's target `H+$609c8` and P13's chip copy target hold no previously executed lines.
- **CACR.**
  - On the core the startup's `$A119` becomes `$8000`, and P7's
    `movec cacr; bset #1; movec` in every BLIT interrupt (`B+$a06ec`-`$a06f6`, restored at
    `$a0720`) is a no-op.
  - IE does not change, so it does not flush the I-cache or BTIC. Good.
  - On the 030 this freezes the I-cache during the 16-plus blitter interrupts per frame.

## 7. What this means for the FPGA stall (inferred), and what to check on hardware

1. The scene that slows and then stalls only without Turbo chip is most likely **P7**.
   - Its frame is bounded by chip-bus time: blitter C2P of about 69k DMA cycles, plus about
     17k CPU byte RMW and long clears, from code in fast RAM.
   - Its end transition has a 6-frame exact-match window that a slow chip path can miss.
   - The result is a frozen or blank screen with music playing for about 22 minutes.
2. If the stall shows a *still animating* scene, it is a different mechanism:
   - the intro loops: lock A;
   - starfield only: lock B;
   - a bouncing but frozen sphere image would mean P7's main loop is stuck at `B+$a0202`
     waiting for the blitter chain's done flag. That points to a lost BLIT interrupt, not
     speed.
3. Checks that settle it with the debug bridge or ILA. The BSS base is the runtime hunk-1
   address.
   - CPU PC spinning in `B+$a0bd8`/`$a0bde` together with `word B+$a150a > $06aa` confirms
     lock C.
   - PC at `B+$a0202`/`$a0206` with `byte B+$a14f8 == 0` means the BLIT chain is stuck.
   - PC at `B+$13c` or `B+$15e` means locks A/B.
   - PC around `H+$34e6c` or `H+$38f8c` means lock D.
4. Things worth comparing with real AGA in the core:
   - CPU chip-access cost while the blitter runs with **BLTPRI=0**. Real Agnus gives the CPU a
     slot after 3 blitter cycles. P7 scene 1 depends on that.
   - CPU chip-access cost for `move.l` clears with BLTPRI=1 and 1 lowres plane (P7 setup).
5. A patch like WHDLoad's would turn the four `bne.b *-6` spins into `blt`/`bcs`.
   - The sites are `B+$142`, `B+$164` and `B+$a0bde` (`66f8` to `65f8`/`6df8`).
   - For the end, guard P14's `>=` waits against the wrap.
   - These bytes are inside crunched data, so test them by runtime patching, not by editing
     the file.

## Artefacts (scratchpad, not in the repo)

The base directory for all paths below is
`/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/e8a7f0b9-a3ef-4709-b8f1-3ea1b64bb312/scratchpad/nexus7_re/`.

| Path | What it is |
|---|---|
| `emu.py` | loader emulation: decrunch log, per-part snapshots `o2/snapH_NN.bin`/`snapB_NN.bin`, decrunched blobs `o2/dec_*.bin` |
| `dec1.py` | single decrunch (used for P11 from `B+$a8220`) |
| `musemu.py` | P61 tick/sync-word timeline, `o2/musicseq.json` |
| `harness.py`, `p7.py`, `p13.py`, `p1314.py`, `prest.py`, `deccount.py` | per-frame traffic counts |
| `m68d.py`, `flow.py`, `scanpoll.py`, `scanloop.py`, `scan2.py`, `copper.py` | disassembly, recursive descent and SMC scan, sync-site scans, copper decode |
| `o2/partNN.dis` | linear disassembly of each part (P11 from the runtime blob) |
