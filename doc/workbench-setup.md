# Workbench setup

How to get a Workbench hard disk image that uses this machine properly: the
68040's FPU and MMU, the RTG screen, the sound card, the clock and the fast
RAM. Start with [getting-started.md](getting-started.md) if the board doesn't
boot yet.

Everything below is done inside AmigaOS unless it says otherwise. Steps that
were checked on this board say so; the rest is marked.

## 1. The base image: HstWB Installer

Build the Workbench HDF on a PC with
[HstWB Installer](https://hstwb.firstrealize.com/download), following its own
documentation. It needs your own AmigaOS installation files and a matching
Kickstart ROM (Amiga Forever has both). For this board:

- **Image size under 4 GB.** The SD card is FAT32, which can't hold a larger
  file.
- **Kickstart matching the OS.** Kickstart 3.1.4 (46.143) for OS 3.1.4, or
  3.2 (47.x) for OS 3.2. Put the ROM on the SD card and select it in the OSD
  (Memory → ROM).
- Copy the HDF to the SD card, then in the OSD: Harddisks → IDE on → Master →
  `Hardfile (disk img)` → choose the file. The OSD detects the image type by
  itself.

The image used for the board tests is built this way.

Set the OSD as in [getting-started.md](getting-started.md#settings-for-workbench)
(AGA, 2 MB chip RAM, FAST = Maximum, Turbo = BOTH) and save the configuration.

## 2. The 68040, its FPU and MMU: MMULib

The core is a 68040 with the MMU and the 68040's FPU hardware. Like a real
68040 it doesn't implement some FPU instructions (FSIN, FETOX, FLOGN, packed
decimal and others) in hardware. They trap, and a library has to emulate them:
the FPSP (floating-point software package). Without it, programs that use
those instructions crash.

Install Thomas Richter's **MMULib**: its `68040.library` (with the FPSP) and
`mmu.library`, both into `LIBS:`, following MMULib's own instructions. MMULib
is on Aminet (`util/libs/MMULib.lha`) (unverified link).

- **Checked:** `68040.library` version 40.2 from MMULib. Its FPSP passes 278
  checks on this CPU core in simulation, and AIBB's Beachball test (which uses
  the FPU) completes on the board.
- **SetPatch** loads `68040.library` at boot when it finds a 68040. Keep
  SetPatch as the first command in `S:Startup-Sequence`, as the standard
  script has it. (Standard AmigaOS behaviour, not checked separately here.)
- After a reboot, SysInfo or ShowConfig should report a 68040 with an FPU.

The OSD's Chipset page shows the CPU as `68040/FPU/MMU`: that's what the
bitstream contains, not a setting.

## 3. RTG screen: Picasso96 and minimig.card

The core has a simple RTG (retargetable graphics) display for Picasso96. Its
driver is `minimig.card`, in [amiga_sw/rtg](../amiga_sw/rtg) in this
repository (by Alastair M. Robinson, LGPL 2.1).

**Install the driver** (from `amiga_sw/rtg/README`):

1. Install Picasso96 with its installer. When it asks for a card, pick any
   (the steps below assume PicassoIV). It creates a monitor file in
   `DEVS:Monitors`.
2. Rename that monitor file (`PicassoIV`) to `Minimig`.
3. Edit the icon's tool types: set `BOARDTYPE` to `minimig`.
4. Copy `minimig.card` to `LIBS:Picasso96/`.
5. Reboot, then run Picasso96Mode (Workbench → Prefs) to set up screen modes.

**Add the MMU line.** With `68040.library` and `mmu.library` loaded, the MMU
tables don't cover the RTG registers at `$B80000`, so the driver can't find
the board and Picasso96 says there's no board. Tell `mmu.library` about that
range. In a Shell:

```
Echo >ENVARC:MMU-Configuration "SetCacheMode 0x00b80000 0x00080000 Valid IOSpace CacheInhibit"
Copy ENVARC:MMU-Configuration ENV:
```

If `ENVARC:MMU-Configuration` already exists, add the line with an editor
instead: the `Echo` above replaces the file. Then reboot.

**Screen modes.** The HDMI output limits which modes give a stable picture.
These worked on Paul's display (enter them in Picasso96Mode):

| Resolution | Depth | Width | Height | Clock | il | ds | or | Framesize | BorderSize | pos | syncsize | syncpol | freq |
| ---------- | ------- | ----- | ------ | ----- | --- | --- | ---- | --------- | ---------- | --- | -------- | ------- | ----- |
| 1024x768 | HiColor | 1024 | 768 | 56.72 | | | hor | 1279 | 8 | 0 | 64 | | 44kHz |
| | | | | | | | vert | 802 | 0 | 18 | 8 | | 55Hz |
| 800x600 | HiColor | 800 | 600 | 56.72 | | | hor | 1280 | 24 | 96 | 64 | | 44Khz |
| | | | | | | | vert | 768 | 0 | 0 | 6 | | 57Hz |
| 832x480 | 256Col | 832 | 480 | 28.36 | | | hor | 1012 | 0 | 55 | 64 | | 28kHz |
| | | | | | | | vert | 560 | 0 | 38 | 8 | | 50hz |
| 720x480 | HiColor | 720 | 480 | 28.36 | | | hor | 940 | 0 | 72 | 64 | | 30kHz |
| | | | | | | | vert | 588 | 0 | 98 | 8 | | 51hz |

**Things to know:**

- The frame buffer has to be in Zorro II fast RAM. The driver asks for 4 MB
  of it and, when there isn't enough, silently takes Zorro III memory, which
  the display can't reach. So keep FAST at Maximum (8 MB Zorro II) and Boards
  at "all". (From the lab notes; unverified in isolation.)
- **Judge RTG only after a cold start.** Right after a bitstream is loaded
  over JTAG, the memory still holds the previous session and the result is
  unreliable: the same bitstream has both failed and worked, depending on
  this alone. Power-cycle, then test.

## 4. Sound

- **Paula** (the Amiga's own four channels) works as on any Amiga.
- **Toccata**: the core has a Toccata-compatible Zorro II sound card (an
  AD1848-style codec; playback only, recording is a stub). It appears in
  ShowConfig after the fast RAM boards. Use it through AHI with a Toccata
  driver (which driver package was used on this board is unverified). The
  card is offered only together with the Zorro III boards; see section 6.
- **WavPlay** ([amiga_sw/WavPlay](../amiga_sw/WavPlay)) plays 44.1 kHz 16-bit
  stereo WAV files through the core's extra audio channel (unverified on this
  build).
- Floppy and hard disk sounds come from `DRIVESND.BIN` on the SD card and are
  switched in the OSD; they're not an Amiga feature.

All audio leaves the board on the headphone output.

## 5. Real-time clock

The board has a battery-backed clock chip (PCF2123). The core presents it to
the Amiga as the standard Amiga clock (an Oki MSM6242 at `$DC0000`), so
AmigaOS uses it without a driver. As usual:

- `SetClock LOAD` in `S:Startup-Sequence` (the standard script has it) reads
  the time at boot.
- Set the time in Prefs → Time and save, or with `Date` and `SetClock SAVE`.

(Standard AmigaOS commands; the clock was tested with an A1200 setup.)

## 6. Fast RAM

The OSD's Memory page sets it. **FAST**:

| Setting | Boards the Amiga gets |
|---|---|
| none | none |
| 2 MB, 4 MB | a Zorro II board of that size |
| Maximum | 8 MB Zorro II, 16 MB Zorro III on the SDRAM, 16 MB Zorro III on the DDR3, and the Toccata card |

**Boards: DDR3 only** leaves out the Zorro II board and the SDRAM Zorro III
board, so all fast RAM is on the DDR3. It's there to measure the DDR3 memory
on its own. It also removes the Zorro II memory RTG needs.

The Zorro III boards and the Toccata card are offered only when the saved
configuration's CPU field says 68020, which the 68040 build's OSD can't set.
See [troubleshooting.md](troubleshooting.md#no-zorro-iii-fast-ram) (found in
the RTL and simulation, unverified on the board).

Check what AmigaOS found with `ShowConfig` in a Shell, or with SysInfo.

## 7. Extras

- **Mouse wheel:** the core counts the PS/2 mouse's wheel in a Minimig
  register. `WheelDriver`
  ([amiga_sw/WheelDriver.adf](../amiga_sw/WheelDriver.adf)) turns it into
  scroll events.
- **HRTmon:** put `HRTMON.ROM` on the card, enable HRTmon on the Memory page,
  press Ctrl + Pause to enter it.

## Checklist

- [ ] HDF under 4 GB, IDE on, Master = the HDF, configuration saved
- [ ] Kickstart matches the OS version
- [ ] MMULib's `68040.library` and `mmu.library` in `LIBS:`, SetPatch first in the Startup-Sequence
- [ ] Picasso96 installed, `minimig.card` in `LIBS:Picasso96/`, monitor file `Minimig` with `BOARDTYPE=minimig`
- [ ] `ENVARC:MMU-Configuration` has the `SetCacheMode 0x00b80000 ...` line
- [ ] FAST = Maximum, Boards = all
- [ ] RTG judged after a cold start
