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

### SD card gone after Ctrl-Amiga-Amiga (2026-10-02)

- Symptom: after a keyboard reset the SD card does not show up; an OSD menu
  reboot brings it back. Also with CopyBack off.
- Known: Ctrl-Amiga-Amiga resets only the Amiga side, not the 832 or the SD
  card; a card left mid-transfer ignores CMD0. Not yet checked on stage_cu9.
- Part of the reset-and-boot work above.

### Copyback data cache unstable under disk load (2026-10-02)

- Symptom: with CopyBack on (MuSetCacheMode on $40000000, which includes the
  DDR3 board that is used first), random 80000004/80000005 crashes while
  opening programs or directories; Elysium and xSysInfo ran.
- Known: fixed on the way: the table walker now sees the data cache (core
  350b988, M68040UM 3.2.5), the snoop is registered (b5cfdf4). Still open.
  The release is built with COPYBACK=0.
- First step: amiga_sw/CBTest on the board (reports the first wrong address
  instead of a Guru), then the ILA. findings/copyback/plan.md.

### Keyboard reset loses dirty cache lines (2026-10-02)

- Only matters with copyback. Ctrl-Amiga-Amiga resets at once, without the
  $78 reset warning, so the OS never flushes; Kickstart 40.10 discards the
  cache at boot (CINVA BC at $F80C66). Fix: hold any reset until the cache
  has pushed its dirty lines, or send the $78 warning. findings/copyback/plan.md.

### Interrupt sometimes taken one instruction late (2026-10-03)

- The fuzzer with random interrupts (lib/AP68040-pipelined/tb/perf/fuzz,
  GEN_IRQ=1) reports "qualified level-2 request not taken at the next
  boundary" for seeds 5018 and 5081 with the board's store-buffer switches
  (with and without BTFN; the all-off reference passes), and 3007/3085 (the
  reference too). Not a lost interrupt; a deviation from the 68040's
  boundary rule. Use a relative FUZZ_DIR: the bench cuts paths at 128 chars.

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
| Misaligned reads served from the cache (two hits instead of a DDR3 read) | ~85 clocks per Dhrystone run, ~8 % | plan step 3 |
| LDX (late operand dispatch) on the board | -6 % in the SoC bench | built, verified, off by default |
| Write-allocate / store coalescing | ~59 clocks per run | needs copyback |
| MOVEM one register per clock | ~20 clocks per run | not planned |
| Timing margin: a Pblock for the CPU island | release has clk_38 +0.44 ns, earlier builds +0.05 | experiment build |
| Higher CPU clock (clk_114 / 2 = 57 MHz) or dual issue | the two large levers; weeks of work | measure first |

## Verification

- cputest: ae/RTE needs data from a real 68040 (stacked SR); FBASIC not
  generated. findings/ap040-pipelined/tests/cputest/board/README.md.
- Only fpga/openaars (QMTech XC7A100T) is built; the MiST, Chameleon and DE
  ports may not build from this tree.
