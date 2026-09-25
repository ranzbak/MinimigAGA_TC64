# Troubleshooting

Find the symptom, then read the explanation below the table if you need it.
Several of these look like CPU or core bugs and aren't: try the simple fix
first.

| Symptom | Likely cause | Fix |
|---|---|---|
| No HDMI signal right after loading a bitstream over JTAG | the HDMI side can stay dark after JTAG loads | power-cycle the board, then load the same bitstream again ([1](#1-no-hdmi-after-a-jtag-load)) |
| Picture dark or lost after unplugging the display | the HDMI chip forgot its settings | wait a moment (the firmware re-sends them), or press Left Shift + keypad `.` |
| Wrong colours, sparkles along edges, or the picture drops out after some minutes | OSD firmware and bitstream from different versions | use `832OSDAD.BIN` built from the same commit as the bitstream ([2](#2-firmware-and-bitstream-belong-together)) |
| Right mouse button stuck, odd keys, or "Unknown command" / missing commands at boot, after many JTAG loads | the mouse and SD card kept their state across FPGA reloads | switch the board off and on ([3](#3-odd-input-or-boot-errors-after-many-jtag-loads)) |
| Swapped the SD card, but it's still the JTAG-loaded bitstream | a card swap doesn't reload the FPGA | expected; only a power cycle brings back the flash image ([4](#4-sd-card-swaps)) |
| OSD shows a fatal error with no SD card in, and the reset button doesn't clear it | known firmware bug | insert the card and power-cycle the board |
| OSD error "ROM missing", "ROM size incorrect" or "ROM requires key file" | Kickstart file absent, wrong size, or encrypted without `ROM.KEY` | fix the file; `ROM.KEY` goes in the ROM's folder ([5](#5-kickstart-errors)) |
| Grey or white screen and the firmware never starts, just after a JTAG load | seen once on an earlier core | load the same bitstream again |
| Picasso96 says there's no board | the MMU tables hide the RTG registers | add the `MMU-Configuration` line ([6](#6-rtg-problems)) |
| RTG worked, then fails right after a JTAG load | leftovers in memory from the previous session | judge RTG only after a cold start ([6](#6-rtg-problems)) |
| A program crashes on FPU instructions (Guru `8000000B`, or a crash in maths-heavy code) | no FPSP loaded | install MMULib's `68040.library` ([workbench-setup.md](workbench-setup.md#2-the-68040-its-fpu-and-mmu-mmulib)) |
| AIBB's FPU FLOPS test crashes | open bug | none yet |
| No Zorro III fast RAM, and no Toccata card in ShowConfig | the configuration's CPU field isn't "020" | see [No Zorro III fast RAM](#no-zorro-iii-fast-ram) |
| HDF won't mount, "not a DOS disk", or FAT errors on the card | a reset, JTAG load or power-off while writing | repair the card and the HDF ([7](#7-damaged-hard-disk-image-or-sd-card)) |
| OSD shows `** file not found **` under Master | the HDF was renamed or moved | select it again on the Harddisks page |
| OSD warns "No partition table found" or "No filesystem recognised" | a blank or unusual image | prepare it with HDToolbox and format it, or pick `Hardfile (filesys)` for a single-partition image |
| A demo or game shows graphics or sound errors | Turbo, or the game doesn't run on a 68040 | try Turbo = none first ([8](#8-games-and-demos)) |
| No sound | volume at 0, or listening on HDMI | Left Shift + keypad +; use the headphone output |

## 1. No HDMI after a JTAG load

After several JTAG loads in a row, the HDMI chip can stay dark until the board
is powered off. On 2026-09-24 a new bitstream came up with no picture (while
the Amiga ran fine) and looked broken; the same file gave a picture after a
power cycle. So a missing picture straight after a JTAG load says nothing
about the bitstream. Power-cycle, load it again, and only then judge.

## 2. Firmware and bitstream belong together

The HDMI chip samples the video data with a clock delay that the firmware
sets (`0xBA = 0xA0` in `fw/ctrl_832/adv7511.c`). That value is matched to how
the bitstream drives the video pins (`rtl/openaars/adv7511/adv_ddr.v`, which
since commit 2817521 puts the data in the middle of each clock period). With
a mismatched pair the sampling point is wrong: colour errors, artifacts along
colour edges, or an HDMI signal that drops after a few minutes. Build both
from the same commit, or take both from the same release.

## 3. Odd input or boot errors after many JTAG loads

A JTAG load resets everything inside the FPGA, but the powered devices
around it keep their state: the PS/2 mouse stays in the mode it was put in
(it can then send packets the core reads wrongly, which shows up as a stuck
button), and the SD card can be left halfway through a transfer (which can
return wrong data, for example missing commands at boot). Both disappeared
together after pulling the board's power. This is not a core bug; power off
the board before debugging anything else. The same stuck-button symptom has
been seen with the older 68020 core.

## 4. SD card swaps

Swapping the SD card resets the Amiga side and the OSD firmware reloads
`832OSDAD.BIN` and the Kickstart from the new card, but the bitstream in the
FPGA stays. So after a JTAG load, a card swap doesn't bring back the flash
image. A firmware change on the card needs no JTAG reload. Only a power cycle
loads the bitstream from the flash again.

## 5. Kickstart errors

The OSD holds the 68040 in reset until a Kickstart has loaded, so the screen
stays quiet and the OSD stays usable. Fix the problem and choose the ROM on
the Memory page, or pick Misc → Reboot. File rules:

- 256 KB, 512 KB or 1 MB images, or 256/512 KB Amiga Forever images (11 bytes
  longer), which need `ROM.KEY` **in the same folder as the ROM**.
- Without a saved configuration the firmware loads `KICK.ROM` from the root.

## 6. RTG problems

- **"No board":** with `68040.library` and `mmu.library` loaded, the MMU
  doesn't map the RTG registers at `$B80000`, so the driver never reaches the
  hardware. Put `SetCacheMode 0x00b80000 0x00080000 Valid IOSpace
  CacheInhibit` in `ENVARC:MMU-Configuration`
  ([workbench-setup.md](workbench-setup.md#3-rtg-screen-picasso96-and-minimigcard)).
- **Judge after a cold start.** A JTAG load leaves the RAM contents in place,
  and RTG results taken right after one have been wrong both ways with the same
  bitstream. Power-cycle, boot, then test.
- **Frame buffer:** the driver needs Zorro II fast RAM for the screen; keep
  FAST = Maximum and Boards = all.
- **Unstable picture:** only some modes work through the HDMI scaler; start
  from the table in workbench-setup.md.

## No Zorro III fast RAM

The autoconfig logic (`rtl/minimig/minimig_autoconfig.v`) offers the Zorro
III boards and the Toccata card only when the configuration's CPU field says
68020. This build's OSD shows the CPU as a fixed 68040 line, so the field
keeps whatever the configuration file had: 68000 in a fresh one. The
simulation (`sim/autoconfig`) shows the result: FAST = Maximum then gives only
the 8 MB Zorro II board. This hasn't been confirmed on the board (unverified).

Workarounds (unverified):

- Use a configuration file saved by an older Minimig core with the CPU set to
  "020 alpha".
- Or edit the file on a PC: in `MINMGAA.CFG` (or `MINMGAA1-4.CFG`), set the
  two low bits of the byte at offset 98 (hex `0x62`) to `11`, keeping the
  other bits (they're the Turbo setting). `00` becomes `03`, for example.
- For the DDR3 board alone, Memory → Boards: DDR3 only doesn't need the CPU
  field.

## 7. Damaged hard disk image or SD card

Don't reset, load a bitstream or switch off while the Amiga writes to the
hard disk image: it corrupts the image and the card's FAT. If it happened,
check the card on a PC first (`fsck.vfat` on Linux, `chkdsk` on Windows),
then repair the Amiga partition inside the HDF with an Amiga disk repair tool,
or restore the HDF from a backup. Keep a backup of a working HDF.

## 8. Games and demos

Before blaming the CPU for a demo or game problem, set Turbo to none on the
Chipset page and try again. Chip RAM then goes over the normal chipset bus.
Some old games don't run on any 68040, as on a real A4000/040: the caches
and the missing 68000 timing break them.

## For developers

- **Controller log:** the OSD firmware prints its boot log (ROM loading,
  configuration, errors) on UART1 at 115200 baud, 8N1. The board's CP210x
  USB serial chip has two ports; which one is UART1 is unverified.
- **Did it boot, without a screen:** `tools/vivado/ila_boot_probe.tcl` needs
  an image built with the debug ILA. See
  [build-program-test.md](build-program-test.md) section 5.3.
- A known quirk from the runbook: using the reset button while the firmware
  loader shows a white screen can bring the white screen back after the
  reset.
