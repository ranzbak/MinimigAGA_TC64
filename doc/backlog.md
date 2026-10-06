# Backlog (QMTech XC7A100T / AP68040-pipelined)

Open issues and planned work that are known but not being worked on now.
Newest at the top of each section. Each item: the symptom, what is known,
and the first step. Details live in the findings documents named.

Release 0.1 ships with these open (see doc/release-0.1.md).

## Stability and correctness

### HDMI: sync loss in RTG modes and in demos that flash a lot (2026-10-03)

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

### Video: static artifacts in the border after a resolution change (2026-10-03)

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

### Serial port runs at about 112 baud (2026-10-01)

- serial.device receives io_Baud = 112 for Prefs 38400/115200. Worked on the
  020 core up to 56k6. amiga_sw/SerTest2 is ready for the board.
  findings/serial/README.md.

### DDR3-only fast RAM shows 10 MB (2026-10-02)

- With only the DDR3 board configured, AmigaOS sees 10 MB of 16 MB.

### Copyback window covers all of $4xxxxxxx (2026-10-02)

- `cb_win` in ap040_pipe_tg68k_compat.v compares only address bits 31:28, so
  it includes the SDRAM Zorro III blocks, not just the DDR3 board. Only
  relevant once copyback is back.

## Performance (measured: findings/loadstore/plan.md section 11)

| Step | Measured / estimated | State |
| --- | --- | --- |
| Misaligned accesses served from the data cache (DFP_MIS + MIS) | SoC Dhrystone -12.6 %; board 1.26 -> 1.44 (41,656 -> 47,413) | DONE 2026-10-05, built with DFP_MIS=1 |
| LDX (late operand dispatch) on the board | board 1.10 -> 1.13 (36,256 -> 37,316) | DONE, on in the default build |
| Write-allocate on a copyback store miss | ~59 clocks of store holds per run, est. -40 | design report in progress (2026-10-06) |
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
