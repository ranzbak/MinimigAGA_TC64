# Backlog (QMTech XC7A100T / AP68040-pipelined)

Open issues and planned work that are known but not being worked on now.
Newest at the top of each section. Each item: the symptom, what is known,
and the first step. Details live in the findings documents named.

Release 0.1 ships with these open (see doc/release-0.1.md).

## Stability and correctness

### HDMI: sync loss in RTG modes and in demos that flash a lot (2026-10-03) -- RTG part SOLVED (Paul, 2026-10-12)

- 2026-10-12, Paul: the RTG sync loss no longer happens on the current images
  (since the ADV7511 pad registers with output constraints and the -1.2 ns
  clock delay, 2026-10-10).  The flashing-demo part has not been rechecked.

- Symptom: some RTG display modes that used to sync no longer do; demos with
  rapid full-screen flashes make the monitor lose sync.
- Known: all HDMI changes on this line date from 2026-09-25..27 (ADV7511
  outputs from IOB registers with a clock delay, the 60 Hz upsampler hsync
  timing, the ADV7511 video clock delay -0.8/-1.2 ns, ADV7511 serviced on its
  INT pin). stage_cu9 (2026-09-30) already contains them all, so this is not
  from the CPU work; "worked before" means images from before 2026-09-25.
- First step: flashing demo with other clock delays from the OSD HDMI page
  (-1.2, -0.4, 0 ns): if the behaviour changes, it is output timing (24 data
  lines switching at once). RTG: watch the OSD HDMI page's INT count and
  status while sync is lost; compare with an image from before 2026-09-25.

### The Cure: music stutters / scroll texts flicker without turbo chip RAM (2026-10-11)

- Symptom: RETREAM's The Cure (beam-locked, no interrupts) stutters when its
  frame work misses line $E4; scroll texts in other demos flicker.  Turbo
  chip RAM hides it; the 020 core never shows it.
- Measured (instrumented THE_CURE_meter, 16,495 frames): overruns Standard
  294, Chip slots Fast ~170, Turbo 0 (peak 244 of 270 lines).  Two causes:
  chip-RAM store stalls, and line fills ~5x slower than a real 040's bursts
  (tb/perf/cure profile: memory-bound).
- Done, not yet on the board: chip-RAM store posting (AP040_POST_CHIP /
  POST_CI, image build/stage_postchip with the CIA TOD fix below);
  critical-word-first fills (core branch `cwf`, AP040_CWF, sim: peak frame
  260 -> 230 lines, -11 %; superproject plumbing still to do).
- Next: board test stage_postchip (disk I/O, ChipCoh, the meter at Standard
  and Fast, IrqLat, SerRx, xSysInfo), then a CWF image.  Further: hit-under-
  fill and burst fills (Performance below).

### CIA TOD lost counts under CPU writes (2026-10-11) -- FIXED in sim (bcb7ac4), in build/stage_postchip

- cia_timerd.v dropped a TOD count when a CPU write through the minimig bus
  hit the same clk7 cycle (3 of 4 counts lost under chip write load).
  Explained IrqLat "expected 264".  sim/cia_tod.  Board check: IrqLat matrix.

### XC7=1 (Artix-7 resource mapping) crashes at boot (2026-10-09)

- AP040_XC7=1 (core xc7-all 42ac4b9) boots to guru #80000004/5; the same
  image with XC7=0 works.  All sims clean (346/346, 114 fuzz seeds).  Images
  stay XC7=0.  Suspects: sim model vs Vivado mapping of the XOR-bank LUTRAM
  (read-during-write, init) or a path the benches do not reach.  Not the SPI
  clock crossings (studied 2026-10-12, branch spicdc).  Next: bisect
  xc7-cache vs xc7-fpuframe on the board, or run the benches on the
  post-synthesis netlist.

### OSD reply byte may be stale after OSD_CMD_KEYQ (2026-10-12, lead)

- From the SPI study (disassembly, not observed): the 832 starts the next
  SPI byte sooner than ~350 ns after some OSD commands because the compiler
  drops a read-back in SPI(cmd); the reply byte can then be the previous
  one.  After KEYQ that is the key count -> a possible cause of stuck
  modifier / volume keys.  First step: a sim of the OSD SPI path with the
  firmware's byte spacing, or a scope on SCK.

### SPI clock constraints and a floppy direct-mode race (2026-10-12) -- fixed on branch spicdc, not merged

- sd_card.xdc's asynchronous clock group left 32 one-cycle cfide paths
  untimed; now a generated clock spi_sck on its own pin register with
  bounded crossings (7c33c98).  paula_floppy could drop the last word of a
  direct-mode sector if the chip select went away within ~30 cycles
  (firmware: ~45; 202e077).  Board check before merging: report_clocks
  shows spi_sck, HDF copy + checksum, ADF read/write.

### Demos: garbage in TBL "Ocean Machine" and the Roots2 rotozoomer (2026-10-03)

- Symptom: Ocean Machine shows garbage after a few effects while the music
  keeps playing (CPU and Paula's interrupts/DMA still run); Roots2's
  rotating and zooming pattern effect shows garbage too.
- Paul: persistent, present since the chipset data bus went to 32 bits
  (CHIP32: an aligned longword to chip RAM in one chipset cycle,
  findings/chip32/plan.md); both demos ran many times without issue on the
  020 Minimig. Ocean Machine targets high-performance machines, so a plain
  CPU-speed timing assumption is unlikely; suspects are the display
  pointers / copper list updates, the interrupt timing against them, or
  the CPU's chip RAM writes on the 32-bit path (chunky-to-planar and
  rotozoom effects write chip RAM with longwords; byte lanes, ordering
  against DMA, or a write landing in the wrong chipset slot).
- 2026-10-05: NOT CHIP32 -- stage_r01ldx_c16 (CHIP32=0) shows the same
  corruption in Roots2. Still open after the interrupt fix too.
- 2026-10-05: NOT the CPU's arithmetic: the rotozoomer's own offset,
  modulo, zoom and palette code (DIVS.L, register-count shifts, ADDX.W
  rounding from X) gives the same 485 values on the pipelined core as a
  Python 68k model (lib/AP68040-pipelined tb/pipe_asm/roto_math.s).  The effect is chipset-heavy: FMODE=3, DDFSTRT $18, 6-bit
  BPLCON1 scroll and BPL1MOD/BPL2MOD written by the copper every line, 8
  planes.  Paul: stripes, colours right but in the wrong place; only this
  one rotozoomer in the demo.  Next: A/B with the four bitplane-path
  chipset commits since the 020 version reverted (eacfb4b, 1963b24,
  009b4f0, d26e476), then STORE_BUF=0.
- Earlier idea (cheap, on the board): `CPU NODATACACHE`, then `CPU NOINSTCACHE`,
  then `CPU NOCACHE` before running Roots2. Data cache -> a chipset write
  (blitter/copper) the snoop misses, CPU reads a stale chip RAM copy;
  instruction cache -> generated code run without CacheClearU; neither ->
  chipset timing (copper/blitter/interrupt vs display pointers).

### Video: static artifacts in the border after a resolution change (2026-10-03) -- FIXED in sim 2026-10-07 (b1fd278), board image build/stage_ab_border

- Symptom: after the screen mode changes, the border is not always cleared;
  the artifacts are static and usually lines at regular intervals.
- Hypothesis (Paul): a few lines of a line buffer are not cleared when the
  mode changes -- the scandoubler's or the HDMI 60 Hz upsampler's buffer,
  whose lines outside the new active area keep the old picture.
- First step: note the interval of the lines and whether it follows the old
  or the new mode; find which buffer (scandoubler / upsampler) holds lines
  at that pitch and how it is cleared on a mode change (border lines are
  never written, so they keep whatever was there).

### Reset and boot: a corrupted 832 firmware survives the board reset (2026-10-02)

- Symptom: after a half-loaded or corrupted 832 firmware, the reset button
  does not recover; the same firmware error repeats until a power cycle.
- Known: the 832 "boot ROM" is a writable 8 KB block RAM at 0x0000-0x1FFF
  (rtl/host/832_bridge.vhd, `rom_wr <= cpu_wr`); the boot code is its first
  ~4.3 KB, the rest is stack and data. The firmware loads to 0x2000 in SDRAM
  and fw/ctrl_boot_832/boot.c jumps into it unchecked (`checksum()` exists,
  unused). The reset button does reset the 832 (gen_reset -> sdctl_rst ->
  init_done -> nReset), but a firmware that overwrote the boot code leaves
  a damaged boot ROM, which only the FPGA configuration restores.
- Plan: write-protect the boot code in 832_bridge.vhd; verify the firmware
  (size + CRC) and reload it up to N times; SD card recovery in spi_init
  (CMD12 and extra clocks with CS high before CMD0); a reset matrix (power,
  button, OSD reboot, Ctrl-Amiga-Amiga: what each one resets).
- Also (2026-10-03, Paul): the board reset button must reset the OSD state
  completely; today OSD state survives it, even though the firmware is
  reloaded. Not the firmware's RAM: its startup (EightThirtyTwo lib832
  crt0.a, premain.S) zeroes .bss before main (checked in 832OSDAD.map) and
  .data comes fresh from the file. So the state lives in hardware: the
  OSD/chipset/memory configuration registers in the Minimig RTL outside the
  reset chain the button drives (and the firmware may read them back at
  start), or a settings file on purpose. First step: list which settings
  survive; check the reset inputs of the userio/OSD registers.
- Also: the firmware is linked with `-s_STACKTOP=0x2000` (fw/ctrl_832
  Makefile), so its stack is the top of the writable 8 KB boot block RAM
  and grows down toward the boot code (its first ~4.3 KB). A deep call path
  or a large local buffer overwrites the boot code -- a concrete way to the
  damaged boot ROM above. Write-protecting the boot code catches it; moving
  the stack or bounding it is the fix.

### SD card gone after Ctrl-Amiga-Amiga (2026-10-02)

- Symptom: after a keyboard reset the SD card does not show up; an OSD menu
  reboot brings it back. Also with CopyBack off.
- Known: Ctrl-Amiga-Amiga resets only the Amiga side, not the 832 or the SD
  card; a card left mid-transfer ignores CMD0. Not yet checked on stage_cu9.
- Part of the reset-and-boot work above.

### Copyback data cache unstable under disk load (2026-10-02) -- FIXED 2026-10-05

- Symptom was: with CopyBack on, random 80000004/80000005 crashes while
  opening programs or directories.
- Cause: a chipset snoop (every chipset write to chip RAM, the blitter
  included) landing in the very clock a copyback store merged into a clean
  line of the same set: the store set the dirty bit in the edge the snoop
  cleared the valid bit, the line went invalid-but-dirty, the next read
  refilled the stale line and the store was lost.  Core ad7008f: the merge
  also refuses on a snoop in its own clock (t_cbsnp_pipe.s, red before,
  green after; suite 326/326 with and without copyback; fuzz with copyback
  1-40 ok).
- Board: build/stage_r03cb (COPYBACK=1 + the fix): demos and disk I/O
  stable (Paul, 2026-10-05); xSysInfo 1.26 / 41,656 Dhrystones with
  CopyBack on, against 1.13 / 37,324 without.
- Still open around it: the keyboard reset below, and the copyback window
  (bits 31:28, so the SDRAM Zorro III blocks too) further down.

### Keyboard reset loses dirty cache lines (2026-10-02)

- Only matters with copyback. Ctrl-Amiga-Amiga resets at once, without the
  $78 reset warning, so the OS never flushes; Kickstart 40.10 discards the
  cache at boot (CINVA BC at $F80C66). Fix: hold any reset until the cache
  has pushed its dirty lines, or send the $78 warning. findings/copyback/plan.md.

### Interrupt deferred for 16+ instructions (2026-10-03) -- FIXED 2026-10-03

- Was: the GEN_IRQ fuzzer saw a qualified request wait 16+ instruction
  starts (seeds 5018, 5081, 3007, 3085).  Core 8ead239 (M9.I): an interrupt
  is taken within one instruction boundary, as on the 68040; the board ran
  stage_r02irq stable.  Use a relative FUZZ_DIR: the bench cuts paths at
  128 chars.

### Serial port runs at about 112 baud (2026-10-01) -- CLOSED 2026-10-11: 112 baud gone; 57600 is the maximum, as on a real Amiga

- Was: serial.device sent at ~112 baud (a spurious read of $DFF032 rewrote
  SERPER, findings/serial/README.md).  On stage_dly12 (core main 0a07062)
  both directions run at the set rate.
- Measured with amiga_sw/SerRx + sertx.py (4096-byte 0..255 pattern, full
  line speed, no handshake): 38400 PERFECT, 57600 PERFECT; ZMODEM both ways
  at 38400 and 57600 without retries.
- 115200: 6 of 4096 bytes lost in 2 gaps of 3 bytes, SerErr_LineErr
  (Paula's hardware overrun), NO bit errors -- the RBF interrupt (level 5)
  was serviced ~260-350 us late twice in 0.36 s under the running OS.
  The 020 core does the same (Paul, 2026-10-10), so it is Commodore
  serial.device + Paula's 1-byte buffer, not the 040.  Use 57600, or a
  faster serial driver, for 115200.
- Earlier "ZMODEM fails at 57600" was NComm's state; NComm's terminal
  also shows 8-bit characters with bit 7 cleared (display only).
- 2026-10-11 (stage_fastslot): with Chip slots Fast and Turbo chip off,
  SerRx at 115200 is PERFECT; a full ADF over ZMODEM (NComm saving to the
  hard disk) at 115200 still needs 149 resends (84 % extra; NComm priority
  10 makes no difference, Turbo chip neither), at 57600 one resend in 901 KB.
  Paul: 57600 is the maximum, documented in README.md like on a real Amiga.
  A buffered UART (Paula FIFO option, or a 16C550 clockport card) is under
  "Could have".

### DDR3-only fast RAM shows 10 MB (2026-10-02)

- With only the DDR3 board configured, AmigaOS sees 10 MB of 16 MB.

### Copyback window covers all of $4xxxxxxx (2026-10-02)

- `cb_win` in ap040_pipe_tg68k_compat.v compares only address bits 31:28, so
  it includes the SDRAM Zorro III blocks, not just the DDR3 board, whenever
  the OS places the DDR3 board in $4xxxxxxx.  Copyback is on since
  2026-10-05, so this applies now.
- Why it matters: copyback is only safe in memory that nothing but the CPU
  reads or writes.  The SDRAM Zorro III RAM has a second reader: the RTG
  scan-out fetches the framebuffer straight from SDRAM.  CPU drawing that
  sits in dirty data-cache lines is not in SDRAM yet, so the screen shows
  stale pixels until the line is pushed.  It only bites where the MMU page
  is also marked copyback (c_cb needs mm_cb too); whether P96/MMULib map
  the framebuffer that way is UNVERIFIED.  Paul, 2026-10-12: no RTG display
  problems on the current build -- latent, low priority.
- Fix (small): compare the DDR3 board's real base and size (more address
  bits) instead of a 256 MB window.

## Video scaler (HDMI upsampler, rtl/openaars/adv7511) -- improvements (2026-10-07)

Found while fixing the border stripes (b1fd278, sim/hdmi_upsample). In the
order suggested: 8, then 1 and 4, then 5 and 6.

1. **Pixel-exact capture.** The write side samples on a clk_114 grid with a
   coarsely quantised step (r_line_count[13:6] / (H_RES>>8)), not once per
   Amiga pixel: unequal pixel widths, moire on fine patterns (the Workbench
   background). Write one buffer word per Amiga pixel (the chipset's pixel
   enable) and scale on the output side with a fixed step.
2. **Even vertical scaling.** 288 lines onto 720 is ~2.5 HD lines per Amiga
   line (2, 3, 2, 3): unequal line thickness. An integer mode (2x/3x with
   borders) or vertical interpolation.  Idea (Paul, 2026-10-12): blend
   lines by position.  Area weighting: each HD line takes the Amiga lines it
   overlaps, weighted by the overlap -- for 2.5x the pattern is A, A,
   (A+B)/2, B, B, so every Amiga line gives exactly 2.5 lines of light; a
   50 % mix is an add and a shift, no multiplier.  Laced 576 -> 720 (1.25x)
   gives one blended line in five (weights in quarters).  NTSC 240 -> 720 is
   exactly 3x, no blend.  Needs two Amiga lines readable per HD line
   (current + next); with CRT scanlines on, the beam profile should take the
   same fractional position so the scanlines are even too.  Simulate to PNG
   first, as for the CRT filter.
   **2026-10-13 decided (findings/scaler/plan.md):** one switchable 50/60 Hz
   chain, a 16-line ring, exact 2.5x / 3x vertical in linear light (sharp-
   bilinear 0.5 default, area selectable), no frame buffer.  Branch `scaler`
   (62ec137); **on the board 2026-10-14 (build/stage_scaler, md5 5d05c3c6):
   Paul: working, looks good.**  Not yet merged into 5.0-040-pipelined.
3. **Interlace.** The long-frame logic is commented out; weave/bob from a
   field buffer for laced modes.
4. **50 -> 60 Hz.** The 60 Hz path converts with 8 lines of buffer, so lines
   repeat or drop (judder, tearing). A frame buffer (DDR3/SDRAM), or 720p50
   frame-locked to the Amiga for PAL.
5. **31 kHz input.** Detect 15/31 kHz and size scale and buffer for it; with
   short lines the write side can run past 2048 pixels and its addresses
   wrap into the next buffer (r_wcnt saturates since b1fd278, the address
   does not).
6. **Automatic centring** from DIWSTRT/DIWSTOP instead of PAL_OFFSET_HZ,
   `r_line_count > 300` and the manual OSD offsets.
   **Horizontal centring (Paul, 2026-10-14, after the scaler test):** the
   active video area should sit in the horizontal centre of the 1280-pixel
   screen.  Today the position comes from fixed read offsets
   (PAL_OFFSET_HZ 'hd0 / 'h80 minus CRT_LAT per 50/60 Hz path, now chosen at
   run time in the one chain) plus the OSD Hpos, so it differs per mode and
   resolution.  Centre on the measured active area instead (first/last
   non-border pixel, or DIWSTRT/DIWSTOP), so every mode lands in the middle
   and Hpos becomes a fine-tune around zero.
7. **Border in COLOR00** instead of black.
7a. **OSD through the CRT filters** (Paul, 2026-10-13: the OSD does not bypass
   them).  The OSD is mixed in amber (28 MHz) before crt_beamh, the line ring
   and crt_post, so beam spot, scanlines, bloom and mask all apply to it.
   Option: carry a per-pixel OSD flag next to RGB (amber already has
   osd_blank / the OSD window) through crt_beamh and the ring (24 -> 25 bits,
   about +1 RAMB36 per 12) and let OSD pixels take the unfiltered path
   (nearest vertically, no beam/bloom/mask) at the end of crt_post.  Bigger
   option: render the OSD natively at 720p after crt_post.
8. **Bug: offset wiring.** pal_to_ddr.sv's my50hzupsample gets
   `.i_hd_hoffset(i_voffset)` (the vertical OSD offset moves the picture
   horizontally), and the PAL_HD_H_RES values (1685 / 1980) look swapped
   against the instance names and the 50/60 Hz line lengths (1980 / 1650).
9. Extras: scanlines are covered by the CRT emulation (720p, 2026-10-09).
   1080p: not on this hardware (decided 2026-10-10) -- the 12-bit DDR bus
   over the 2.54 mm header is hold-limited at 148.5 MT/s already.

## Performance (measured: findings/loadstore/plan.md section 11)

| Step | Measured / estimated | State |
| --- | --- | --- |
| Misaligned accesses served from the data cache (DFP_MIS + MIS) | SoC Dhrystone -12.6 %; board 1.26 -> 1.44 (41,656 -> 47,413) | DONE 2026-10-05, built with DFP_MIS=1 |
| LDX (late operand dispatch) on the board | board 1.10 -> 1.13 (36,256 -> 37,316) | DONE, on in the default build |
| Write-allocate on a copyback store miss | compat Dhrystone -2.5 % (zero wait) to -6.4 % (wait states); board 1.51 / 49,767 | DONE on the board 2026-10-08 (build/stage_walloc_fix) |
| Chip slots Fast (a chipset cycle ends with its chip slot) | board chip RAM 3.1 -> 4.4 MB/s | DONE 2026-10-11, OSD Chipset menu |
| Chip-RAM store posting (AP040_POST_CHIP / POST_CI) | The Cure: chip stores 17-22 of ~260 peak lines | built (stage_postchip), board test pending |
| Critical word first + early restart on D-cache fills (AP040_CWF) | The Cure peak frame 260 -> 230 lines (-11 %); Dhrystone unchanged | sim done 2026-10-12 (core branch cwf), superproject plumbing + build pending |
| Hit-under-fill (line read buffer) | the core still waits ~8 clocks per fill for the rest of the line | next after CWF |
| Burst line fill from SDRAM/DDR3 | a fill holds the port 24 clocks vs ~6 BCLK on a real 040 | after hit-under-fill |
| Precise CPUSHL/CPUSHP and CINVL/CINVP | every line/page variant now sweeps all 64 rows like CPUSHA: with copyback one CPUSHL pushes every dirty line and empties the cache; hits OS cache flushes (LoadSeg, CacheClearE), not Dhrystone | next, after write-allocate (copyback plan S3) |
| MOVEM one register per clock | ~20 clocks per run | not planned |
| Timing margin: a Pblock for the CPU island | release has clk_38 +0.44 ns, earlier builds +0.05 | experiment build |
| Higher CPU clock (clk_114 / 2 = 57 MHz) or dual issue | the two large levers; weeks of work | measure first |

## Verification

- cputest: ae/RTE needs data from a real 68040 (stacked SR); FBASIC not
  generated. No real 68040 is available (only a 68060, whose exception
  frames differ, so it cannot answer this). Stays open until someone with a
  real 040 (EAB, the WinUAE cputest author) can run that one case; it is an
  address error during an RTE, which no normal program does. findings/ap040-pipelined/tests/cputest/board/README.md.
- Only fpga/openaars (QMTech XC7A100T) is built; the MiST, Chameleon and DE
  ports may not build from this tree.
- The compat bench's board arrangement (PIPE_FREE=1, TG68K's free core) only
  ran for the first time on 2026-10-12 and found a PTEST defect in new code:
  add PIPE_FREE=1 to the standard runs.
- Latent PTEST hazard (CWF off too): a PTEST ignores walk_hold and can walk
  under a posted-store drain, a WALLOC fill or a long push.  Fix: feed
  pt_hold from post_busy | sweep_busy (core, ap040_mmu.v).
- The board cannot raise a bus error on the CPU's master port (TG68K ties
  it to 0); the bus-error rules are tested in simulation only.

## Features (planned)

### CD-ROM drive from an ISO on the SD card (Paul, 2026-09-26; OSD part 2026-10-12)

- **State 2026-10-12:** plan complete (findings/cdrom/plan.md, decisions
  D1-D7); phase 0 and phase 1 tasks 1.1-1.6 done on branch `cdrom`
  (two-port Gayle with ATAPI packet mode + sim/gayle bench, firmware,
  OSD; host tests 18/18 + 20/20).  Next: build (after stage_postchip) and
  the board checklist (plan 1.8/1.9).  The notes below are the original
  sketch; the plan supersedes them (CD default on IDE port 2, two Gayle
  port instances).

- Goal: an emulated CD-ROM on the Amiga's IDE port that reads an ISO image
  from the SD card, so CD software (AmigaOS install CDs, CD32/CDTV titles
  run from Workbench) can be mounted.  Paul: the user picks the ISO in the
  OSD, like an ADF or a hardfile.
- What exists (2026-10-12): nothing ATAPI.  The IDE emulation is ATA only
  (Gayle in rtl/minimig/gayle.v, commands served by fw/ctrl_832/hdd.c).
  Gayle already has a secondary channel (hdd1_ena from ide_config1), and the
  config struct already reserves `secondaryhardfile[2]` (config.h; only
  cleared in config.c, never used) -- room for a CD entry without growing
  the 212-byte config file.  Left over from AMR's 2020 CD32 start: a BIN/CUE
  parser (bincue.c, hardcoded test cue), CD audio-track playback through the
  audio buffer (audiotrack.c; the calls in main.c are commented out) and an
  Akiko stub (akiko.c, rtl/akiko: only logs register accesses).  Usable for
  a later CUE/audio step; not needed for plain ISO.
- Device: ATAPI CD-ROM, the route MiSTer's Minimig takes, so the stock
  scsi.device (OS 3.1.4+/3.2) or atapi.device plus a CD filesystem
  (e.g. OS 3.2 CDFileSystem, CacheCDFS) work unchanged.  Firmware:
  signature 0x14/0xEB on reset/EXECUTE DEVICE DIAGNOSTIC, IDENTIFY PACKET
  DEVICE (0xA1), PACKET (0xA0) with the 12-byte command block, and the SCSI
  commands TEST UNIT READY, REQUEST SENSE, INQUIRY, READ CAPACITY, READ(10),
  READ(12), READ TOC, MODE SENSE(10), START STOP UNIT, PREVENT/ALLOW MEDIUM
  REMOVAL, GET EVENT STATUS NOTIFICATION (media change).  ISO = 2048-byte
  sectors, so READ(10) LBA n = ISO bytes n*2048, served with the existing
  hardfile FAT cluster-chain code (4 SD sectors per CD sector).  RTL: check
  that Gayle passes the byte-count registers (cylinder low/high) and the
  interrupt-reason register (sector count) for packet transfers; probably
  no other RTL change.
- OSD (firmware, fw/ctrl_832/menu.c):
  - "Harddisks" page: a line for the secondary channel master,
    "CD-ROM : <name> / Disabled", selectable when IDE is enabled.
  - Selecting it opens the file selector with the ISO extension
    (SelectFile("ISO", SCAN_DIR | SCAN_LFN, MENU_ISO_SELECTED, ...)).  The
    directory filter (fat.c ScanDirectory, one 3-letter extension) needs a
    list ("ISOCUE") only when CUE/BIN follows.
  - Store the choice in secondaryhardfile[0] with a new type HDF_CDROM
    (enabled, present, 8.3 name, 16-char long name); config file stays 212
    bytes, older firmware sees it as disabled.
  - Swapping or ejecting the ISO WITHOUT a reset (unlike hardfiles, which
    apply at reset): an "Eject / Insert" line; the firmware reports
    UNIT ATTENTION / media change to the next command so the CD filesystem
    rereads the disc.  Also a quick "CD" entry next to the floppy slots on
    the main page, so swapping game discs needs no submenu.
  - Long filenames: ISO names are often longer than 16 characters; show the
    first 16 in the menu and the full name in the selector (as ADFs).
- Out of scope for step 1: CD audio (red book), BIN/CUE with audio tracks,
  CD32 (Akiko CD controller, CD32 boot).  Step 2 candidates, building on
  bincue.c/audiotrack.c.
- Tests: a host-side unit test of the packet decoder (hdd.c built for x86),
  then on the board with OS 3.2 (scsi.device sees the ATAPI unit; mount an
  AmigaOS 3.2 ISO, copy a big file, compare its checksum), media swap with
  a second ISO.
- First step: read MiSTer Minimig's ATAPI code (Main_MiSTer
  support/minimig/) for the command subset Amiga drivers really issue; then
  the hdd.c packet path, then the OSD.

## Could have (not urgent)

### Serial at 115200 under load (2026-10-11)

- Paula's one-byte buffer loses bytes at 115200 when an interrupt is held
  off for more than 87 us (disk writes).  Real Amigas used buffered serial
  hardware.  Options: a 16-byte receive FIFO in paula_uart.v behind an OSD
  option (transparent to serial.device, not authentic), or a 16C550/16C650
  UART at the clockport address (Silversurfer-like, its own Aminet driver,
  authentic; needs a free pin pair or sharing the 832 debug UART).  Tests:
  amiga_sw/SerRx + sertx.py, a ZMODEM ADF transfer to disk.

### 8 MB chip RAM, emulator-style (study 2026-10-11)

- WinUAE offers 4/8 MB chip: chip RAM continues from $000000 to $3FFFFF /
  $7FFFFF (over the bottom of the Zorro II space), every DMA pointer keeps its
  full high word and one mask (chip size - 1) applies to all DMA; ECS/AGA
  only.  Costs there: Z2 fast RAM <= 256 KB, no Z2 RTG board, and its own
  boot ROM patches exec's chip MemHeader (stock Kickstart never adds chip
  above 2 MB).  No real Amiga had it (Alice / Super Agnus address 2 MB; the
  A4000's 8 MB jumper was for AAA); no released software found that needs it.
- Here: the CPU path already maps $200000-$7FFFFF to SDRAM bank 1; needed:
  Agnus DMA pointers 21 -> 23 bits (all six engines, masked unless enabled),
  gary decode (and drop sel_bank_1's $FFFF reads), bank mapper / SRAM bridge,
  sdram_ctrl (chip slot in bank 1, bank 1 reserved for slot 1, the 040 snoop
  address split from the SDRAM address), autoconfig without the Z2 board, an
  OSD option (AGA only, off by default), and a small Amiga tool that adds the
  memory (AddMemList or extending the chip MemHeader).  About a week incl.
  benches; do it only after the "every free slot" chip access is stable on
  the board, and only if a program needs it.
