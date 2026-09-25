# Getting started

From a bare OpenAARS board to an Amiga on the screen. The next step, a full
Workbench with the FPU, MMU and RTG screen, is in
[workbench-setup.md](workbench-setup.md). If something goes wrong, see
[troubleshooting.md](troubleshooting.md).

## What you need

- An **OpenAARS IO board version 5.0** with the **QMTech XC7A100T DDR3 core
  board** on it.
- The **bitstream** (the FPGA image) on the board, loaded over JTAG or written
  to the board's flash. See [Loading the bitstream](#loading-the-bitstream).
- A **micro SD card formatted FAT32**. Files on it can't be larger than 4 GB
  (a FAT32 limit), which caps the size of one hard disk image.
- A **PS/2 keyboard**, needed for the on-screen menu (OSD). A **PS/2 mouse**
  for Workbench.
- An **HDMI display** that accepts 1280x720 at 50 Hz and 60 Hz.
- Headphones or speakers on the board's headphone output.
- A **Kickstart ROM image**, dumped from your own Amiga or from
  [Amiga Forever](http://www.amigaforever.com/). [AROS](http://aros.sourceforge.net/)
  ROMs work as a free replacement.
- Optional: Amiga or C64 joysticks for the two joystick ports.

## Preparing the SD card

The OSD firmware reads these files. Names are case-insensitive and use the
8.3 format, so `832osdad.bin` and `832OSDAD.BIN` are the same file.

| File | Where | Needed? | What it is |
|---|---|---|---|
| `832OSDAD.BIN` | root | **yes** | The OSD firmware. The boot loader in the bitstream loads it at power-on. |
| `KICK.ROM` | root | **yes**, unless a saved configuration names another ROM | The default Kickstart. Any ROM can be chosen later in the OSD. |
| `ROM.KEY` | **same folder as the ROM** | only for encrypted Amiga Forever ROMs | The Amiga Forever key file. |
| `HRTMON.ROM` | root | no | The HRTmon debugger ROM. Enable it on the Memory page; Ctrl + Pause enters it. |
| `EXTENDED.ROM` | root | no | A 512 KB extended ROM (the CD32 one), loaded only with a Kickstart smaller than 1 MB. |
| `DRIVESND.BIN` | root | no | Floppy and hard disk sounds. |
| `MINIMIG.ART`, `MINIMIG.BAL`, `MINIMIG.COP` | root | no | The boot screen: logo, ball and its copper list. |
| `MINMGAA.CFG`, `MINMGAA1.CFG` … `MINMGAA4.CFG` | root | no | Saved OSD settings: the default slot and slots 1-4. The OSD creates them. |
| `*.HDF` | any folder | for Workbench | Hard disk images. The default name is `HARDFILE.HDF`. |
| `*.ADF` | any folder | no | Floppy disk images. |

Kickstart files may be 256 KB, 512 KB or 1 MB, or 256 KB/512 KB Amiga Forever
files with the extra 11-byte header, which need `ROM.KEY`. The firmware looks
for the key in the folder it loads the ROM from, so an encrypted ROM in
`kickstart/` needs its own copy of `ROM.KEY` in `kickstart/`.

The firmware looks for `HRTMON.ROM` in the folder of the hard disk image it
opened last, which is the root when your HDF is in the root. Keep both in the
root to be safe.

A working card, as an example:

```
/                    832OSDAD.BIN  DRIVESND.BIN  ROM.KEY
                     MINIMIG.ART  MINIMIG.BAL  MINIMIG.COP
                     MINMGAA.CFG  MINMGAA1.CFG  MINMGAA4.CFG
                     4gb.hdf                    (Workbench hard disk image)
/kickstart/          kick.a1200.46.143.rom      (3.1.4)
                     A1200.47.111.rom           (3.2)
                     DiagROM-1.3.rom  aros-rom.rom  aros-ext.rom  ...
/floppy/             ADF images, by category
/aaib/               AIBB (a benchmark)
```

This card has no `KICK.ROM`: its saved configurations name a ROM in
`kickstart/` instead. With no configuration file, the firmware wants `KICK.ROM`
in the root.

## First boot

1. Insert the card and power the board. The FPGA loads the bitstream from the
   flash (or you load it over JTAG), and its boot loader loads `832OSDAD.BIN`.
2. The firmware shows a splash screen and reads `MINMGAA.CFG`. Without it, it
   starts with defaults: an A500-style machine (OCS chipset, 1 MB chip RAM,
   0.5 MB slow RAM, 2 MB fast RAM) with `KICK.ROM`.
3. It loads the Kickstart and starts the CPU. The boot screen appears, then
   Kickstart.

To force the video standard, hold a key while the splash screen shows:
**F2** for PAL, **F1** for NTSC. (F3 and F4 do the same but also switch the
scandoubler off, which the HDMI output isn't meant for (unverified).)

If the Kickstart can't be loaded, the OSD shows an error and the CPU is held.
Choose another ROM in the Memory menu, or fix the card and pick **Reboot**.

Give the first boot time. On the earlier, non-pipelined 68040 core a black
screen for the first minute was normal; how long this core takes hasn't been
measured (unverified).

### Settings for Workbench

The defaults are for old games. For Workbench, open the OSD (F12) and set:

| Page | Setting | Value |
|---|---|---|
| Chipset | Chipset | AGA |
| Chipset | Turbo | BOTH (fast chip RAM and Kickstart; needs AGA, and 2 MB chip RAM for the chip RAM part) |
| Memory | CHIP / SLOW / FAST | 2.0 MB / none / Maximum |
| Memory | ROM | your Kickstart 3.1.4 or 3.2 |
| Harddisks | IDE, Master | on, your HDF |

Then **Settings → save configuration → Default**, so it's loaded at the next
power-on. Chipset and memory changes take effect at the next reset (Misc →
Reset); Turbo and HRTmon take effect at once. Leaving the Harddisks page after
a change asks to reset.

**Zorro III fast RAM needs the saved CPU type to be "020".** The autoconfig
logic offers the Zorro III boards (and the Toccata sound card) only when the
configuration's CPU field says 68020, and on this build the OSD shows the CPU
as a fixed "68040/FPU/MMU" line that can't be changed. A configuration saved
by an older 68020 Minimig core has the right value; a fresh one doesn't, and
then FAST = Maximum gives only the 8 MB Zorro II board. This comes from the
RTL and its simulation (`sim/autoconfig`); it hasn't been confirmed on the
board (unverified). See [troubleshooting.md](troubleshooting.md#no-zorro-iii-fast-ram)
for a workaround.

## The OSD

Open and close it with **F12**, **Scroll Lock**, or the board's **OSD
button**. While it's open, the Amiga gets no keys or mouse buttons.

| Key | In the OSD |
|---|---|
| Up / Down | move |
| Left / Right | previous / next page |
| Enter or Space | select |
| Esc or F12 | close (or go back from a sub-page) |
| Keypad + / - | add or remove a floppy drive (main page) |
| Backspace | eject all floppies (main page); parent folder (file browser) |
| Home | back to the top of the folder listing (file browser) |

With a joystick in port 2 you can also move through the open OSD: directions
to move, fire to select, the second button acts as Esc.

| Key | Shortcut |
|---|---|
| Left Shift + keypad + / - | volume up / down (also with the OSD open) |
| Left Shift + keypad `.` | send the HDMI settings to the video chip again (also with the OSD open) |
| Ctrl + Left Alt + keypad 0 | cycle autofire: off, fast, medium, slow (OSD closed) |
| Ctrl + Pause/Break | enter HRTmon (when HRTmon is enabled and `HRTMON.ROM` is on the card) |
| Num Lock | keyboard joystick on port 2: cursor keys move, Ctrl and Left Alt are the buttons; the numeric keypad is off while it's on |

The pages, left to right:

- **Minimig**: the floppy drives `df0:`-`df3:` (select a drive to insert an
  ADF, select it again to eject), **Floppy disk settings** (number of drives,
  floppy turbo, floppy sounds) and **Hard disk settings**.
- **Settings**: load a configuration (Default, 1-4; loading restarts the
  Amiga with it) or save one, and the Chipset, Memory, Video and Audio pages.
  - **Chipset**: the first line shows the FPGA temperature and an HDMI status
    word; then CPU (fixed: `68040/FPU/MMU`), Turbo (none, CHIPRAM, KICK,
    BOTH), Video (PAL, NTSC), Chipset (OCS-A500, OCS-A1000, ECS, AGA), CD32Pad.
  - **Memory**: CHIP (0.5-2.0 MB), SLOW (none-1.5 MB), FAST (none, 2 MB,
    4 MB, Maximum), ROM (choose the Kickstart; it asks "Reload Kickstart?"),
    HRTmon (enabled, disabled), Boards (all, DDR3 only).
  - **Video**: blur filters for low and high resolution, scanlines. **Video
    Pos**: move the picture.
  - **Audio**: volume, 0 to 31.
- **Misc**: **Reset** (resets the Amiga), **Reboot** (reloads the settings
  and Kickstart from the card, then restarts), About, Supporters.

**Harddisks** page: IDE on or off, then Master and Slave. Each can be
Disabled, `Hardfile (disk img)` (an image with a partition table),
`Hardfile (filesys)` (a single partition without one), the whole SD card, or
SD card partition 1-4. Select the line below Master or Slave to choose the
HDF file.

## Choosing a Kickstart, hard disk and floppies

- **Kickstart:** Memory → ROM, pick the file, answer yes. The Amiga restarts
  with it. Save the configuration to keep it.
- **Hard disk:** Minimig → Hard disk settings. Switch IDE on, set Master to
  Hardfile and pick the HDF. Leaving the page asks to reset. Save the
  configuration.
- **Floppy:** Minimig → select `df0:` and pick an ADF. Select it again to
  eject.

Don't reset, reload the bitstream or remove the card while the Amiga is
writing to a hard disk image: that corrupts the image and the card's
filesystem.

## Loading the bitstream

There are two ways, both from Vivado's Hardware Manager with a JTAG cable:

- **Load it for this session** (JTAG): the image is gone at the next power
  off. Good for trying a build.
- **Write it to the flash**: the board boots it at every power-on.

The commands and steps are in [building.md](building.md#4-loading-the-bitstream-over-jtag).
Swapping the SD card doesn't reload the bitstream; only a power cycle
brings the flash image back.
