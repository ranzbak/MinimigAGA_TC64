# A/B board test: 832 host CPU (A) against RISC-V host CPU (B)

Written 2026-10-20 (Phase 5 Task 6). Paul runs this at the board; nothing in it was run on hardware.
Order: A first (about 10 minutes), then B (about 30 minutes). The fallback is at the end.

## What is being tested

| | A (reference, 832) | B (RISC-V) |
|---|---|---|
| Bitstream | `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/stage_spicdc_49b1868/minimig_openaars_top.bit` | `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5b_87577e2/minimig_openaars_top.bit` |
| md5 | `28b07e8caf8345b25365018ef00753a2` (computed with `md5sum`) | `4065f272991c6800dd4e19640be5dcb9` (file `bit.md5` next to the bit) |
| sha256 | not recorded | `1eb0a593053b826a8fa214b50c13c0bac90a4725bbaab5864cfa4bd05c8ab036` |
| Build commit | `49b1868` on `5.0-040-pipelined` | C1 = `87577e2` on `p5-build` (file `COMMIT`: `87577e2992773ac5012b5d83f45d2e8d689de0e9`) |
| Boot ROM loads | `832OSDAD.BIN` (already on your card) | `RV32OSDA.BIN` (added by this protocol) |
| Config files | `MINMGAA.CFG`, `MINMGAA1..4.CFG` (big-endian, 832) | `MINMGAR.CFG`, `MINMGAR1..4.CFG` (little-endian, pre-converted from yours) |

Timing of B (`findings/osd-riscv/phase5.md`, commit `b90fb0a`): the clk_114 margin is +0.019 ns (A: +0.101 ns), and the 16 SDRAM-input paths
(`clk_gen_sdram -> clk_114`, -0.544 ns in B, -0.525 ns in A) fail in B exactly as they do in A. So a memory fault seen in B but not in A is
worth reporting with its log, even if it looks random.

## 1. Card copy (never the live card)

Work on the COPY of your card. The live card is `/media/paul/AARSDISK55`: do not put these files on it.

**Remove the live card from the reader. Insert ONLY the card copy.** The physical card is the identity: a clone has the same label and the same
UUID as the live card, so no software check can tell the two apart. Then find the copy's mount point and put it in one variable:

```
lsblk -o NAME,SIZE,LABEL,UUID,MOUNTPOINT
CARD='/mount/point/of/the/card/copy'   # edit: the MOUNTPOINT column
```

If the MOUNTPOINT column is empty, the card did not auto-mount: `udisksctl mount -b /dev/sdX1` (the card copy's partition from the NAME column), then run `lsblk` again.

The block below is one block for bash or zsh; paste it whole. It aborts, before any copy, if `$CARD` is empty, is not a directory, is not a mount
point (checked after `realpath`), or if more than one `AARSDISK55*` card (or more than one filesystem with the same label as `$CARD`) is mounted.
It then prints the device, size, label and UUID of `$CARD` and asks you to type `COPY`; anything else aborts. If it prints `ABORT`, nothing was
copied. A copy mounted alone at `/media/paul/AARSDISK55` is fine.

Copy the six files into the root of the copy, next to your own files. Nothing is replaced: `832OSDAD.BIN`, `MINMGAA*.CFG`, the kickstarts,
HDFs, ISO and `drivesnd.bin` stay as they are.

```
SET=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/ab_card_87577e2
card_ok() {
  local c src label n ans
  [ -n "${CARD:-}" ] || { echo "ABORT: CARD is empty"; return 1; }
  [ -d "$CARD" ] || { echo "ABORT: CARD=$CARD is not a directory"; return 1; }
  c=$(realpath -- "$CARD") || { echo "ABORT: realpath failed"; return 1; }
  src=$(findmnt -n -o SOURCE --mountpoint "$c")
  [ -n "$src" ] || { echo "ABORT: $c is not a mount point"; return 1; }
  label=$(findmnt -rn -o LABEL --mountpoint "$c")
  n=$(findmnt -rn -o LABEL | grep -c '^AARSDISK55')
  [ "$n" -le 1 ] || { echo "ABORT: more than one AARSDISK55 card is mounted: remove the live card first"; return 1; }
  if [ -n "$label" ]; then
    n=$(findmnt -rn -o LABEL | grep -cFx -- "$label")
    [ "$n" -le 1 ] || { echo "ABORT: more than one filesystem labelled $label is mounted: remove the live card first"; return 1; }
  fi
  echo "CARD=$c  device=$src  size=$(lsblk -dno SIZE "$src")  label=$label  UUID=$(findmnt -n -o UUID --mountpoint "$c")"
  printf 'Type COPY if this is the card copy: '
  read -r ans
  [ "$ans" = "COPY" ] || { echo "ABORT: not confirmed"; return 1; }
}
if card_ok; then
  for f in RV32OSDA.BIN MINMGAR.CFG MINMGAR1.CFG MINMGAR2.CFG MINMGAR3.CFG MINMGAR4.CFG; do if [ -e "$CARD/$f" ]; then echo "EXISTS, not copied: $f"; else cp "$SET/$f" "$CARD/$f"; fi; done
  (cd "$CARD" && sha256sum -c "$SET/SHA256SUMS")
  # scratch ADF for the floppy WRITE test (row 6): a copy of one of your ADFs, never overwritten
  SRC_ADF='Workbench.adf'  # edit to one of your ADFs in the card root
  if [ -e "$CARD/SCRATCH.ADF" ]; then echo "EXISTS, not created: SCRATCH.ADF"
  elif [ -e "$CARD/$SRC_ADF" ]; then cp "$CARD/$SRC_ADF" "$CARD/SCRATCH.ADF" && (cd "$CARD" && sha256sum SCRATCH.ADF | tee ~/ab-scratch-adf.sha256)
  else echo "NO SCRATCH.ADF: $SRC_ADF not found in the card root; edit SRC_ADF and run this line again"; fi
  sync
fi
```

- `SCRATCH.ADF` is a copy of `SRC_ADF` made on the card copy; the source ADF is only read. Its sha256 is kept in `~/ab-scratch-adf.sha256` for row 6.
- Do not copy `SHA256SUMS`, `PROVENANCE.txt`, `work/` or `orig/` onto the card; they are provenance only.
- `SHA256SUMS` holds bare file names, so run `sha256sum -c` from the card root as above. Expected: six lines ending in `: OK`.
- The loop never overwrites: if a file of that name is already on the copy it prints `EXISTS, not copied: <name>`, and `sha256sum -c` then shows it as FAILED if it differs. Stop and tell me.
- Then unmount cleanly (`umount "$CARD"`, or eject in the file manager) before the card goes into the board.

The six files (all values copied from `$SET/SHA256SUMS`):

| File | sha256 |
|---|---|
| `RV32OSDA.BIN` | `17bf2563788e3b62d2cedc170c448654617537779f21edab5b2feeb9240ed66f` |
| `MINMGAR.CFG` | `3b0c71632144e47fb3fdb3cfe7c395b1ec52d9981aaa6a8cccda4bb2fee35068` |
| `MINMGAR1.CFG` | `0b527ee9bb2badf5c2adc4a12d3699853a6a182b872689166795c38a147b854d` |
| `MINMGAR2.CFG` | `a85ec0a34a7ad654ed2fd5e17403ca81876d70b642c48734d6f24f680d75c6a2` |
| `MINMGAR3.CFG` | `df3ce27ae76806674f9d54baac1d68bf5994e5ed908baa0bcafc3d99f3805b06` |
| `MINMGAR4.CFG` | `ac3d0cfb153854e2787e8e264440e977ae337745f7445ae61c23781231859dbe` |

`RV32OSDA.BIN` is the floppy-write fix image: osd-riscv commit `6ea1b76` "fw/ctrl_rv: gap between write-FIFO words in the floppy track write"
(93,032 bytes, `PROVENANCE.txt`). It replaced the first image (sha256 `0162e53f...`) on 2026-10-19 at about 22:45. The five `MINMGAR*.CFG` were
converted from your `MINMGAA*.CFG` (`cfgconv --to-rv`, each `cfgconv --check` gave "order = RV").

## 2. Serial log of the host CPU (ttyUSB0)

The boot ROM and the firmware of both CPUs print through the same `cfide` UART (`debugTxD`, `rtl/host/cfide.vhd`). It is transmit only; the
FPGA never reads it. Settings: **115200 baud, 8N1, no flow control**.

Where this comes from: `rtl/host/cfide.vhd` lines 756-760. The bit counter `clkgen` reloads with `"0011110110"` = 246 on `clk_28`, so a bit lasts
247 clocks; `dll_28` is 35.262 ns = 28.359 MHz (B's `clocks.rpt`), so 28.359 MHz / 247 = 114.8 kBd, which is 115200 -0.33 %. The RISC-V boot ROM (`fw/ctrl_boot_rv/uart.h`, `0xFFFFFFF0`) and the
firmware (`fw/ctrl_rv/hardware.h`, `UART_TX 0xFFFFFFF0`) write the same register, so A and B use the same settings.

Command (the options are those of `picocom --help` on this machine: `-b` baud, `-d` data bits, `-y` parity, `-p` stop bits, `-f` flow control, `--imap`, `--logfile`):

```
picocom -b 115200 -d 8 -y n -p 1 -f n --imap crcrlf,lfcrlf --logfile <file> /dev/ttyUSB0
```

Use separate log files, for example `ab-A.log` and `ab-B.log` (the `<file>` is yours to name). Power-cycle the board first, then start picocom, then load the bitstream (section 3), so the boot lines are in the log. Lines printed before the load
come from the bitstream in flash, not from A or B. Leave with Ctrl-A Ctrl-X.

Several firmware lines end in a lone CR (`file "..." found`, `Configuration file size: ...`); `--imap crcrlf,lfcrlf` makes them visible on the screen. The log file
keeps the raw CRs: read it with `tr '\r' '\n' < ab-B.log | less`. `Reading directory sector <n>` repeats once per sector. `/dev/ttyUSB1` is the Amiga `SER:` port (38400 or 57600); it is not needed.

## 3. Loading a bitstream

Power-cycle the board before each load (a JTAG load does not reset the peripherals). Flash is not touched. The success line printed by
`tools/vivado/program.tcl` is

```
=== DONE: <bit path> loaded, DONE pin = 1 ===
```

Anything other than `DONE pin = 1` is a failed load: power-cycle and try again.

Load B:

```
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog -source /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/vivado/program.tcl -tclargs /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5b_87577e2/minimig_openaars_top.bit
```

Load A:

```
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog -source /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/vivado/program.tcl -tclargs /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/stage_spicdc_49b1868/minimig_openaars_top.bit
```

## 4. Run A first (about 10 minutes): the card copy still boots as today

1. Card copy in the board, power-cycle, start picocom with `ab-A.log`, load A.
2. The 832 boot ROM loads `832OSDAD.BIN`; the OSD opens; Kickstart boots to Workbench from the HDF.
3. A runs rows 1 to 7, with row 3 by eye (is there a picture?); rows 8 to 10 are "-" for A. A has no row 1 boot lines to match (they are B's); write "832 ok" and note anything else on the ttyUSB0 log.

## 5. Run B (about 30 minutes)

Power-cycle, start picocom with `ab-B.log`, load B. Work through the table in this order. Where B differs from A in a check, repeat that check
on A (power-cycle, load A, same card copy).

### Row 1: the RV boot ROM finds and loads RV32OSDA.BIN

Strings printed by `fw/ctrl_boot_rv` (`boot.c`, `minfat.c`), in the order the code prints them:

```
Initializing SD card
Hunting for partition
Reading MBR
Partitioncount <n>
Reading boot sector <n>
Read boot sector from first partition
Hunting for filesystem
Reading directory sector <n>
file "RV32OSDABIN" found
```

(`GetFATLink returned <n>` lines may appear on FAT32 while the root directory is searched.) The ROM then jumps to the firmware. Failure lines:
`Can't load firmware`, `Unable to locate partition`, `Failed to initialize SD card`, `No partition signature found`,
`Unsupported partition type!`, `Can't open <name>`, `TRAP `. If the ROM shows any of these, send the log and stop.

Firmware lines (`fw/ctrl_rv`, `main.c`, `config.c`, `fpga.c`) after the jump:

```
Platform has SPI RTC support          (or: Platform lacks SPI RTC support)
Configuration file size: 212
...
Boot file size: <n>
Uploading 512Kb Kickstart ...          (or the 1MB / 256Kb variant, per the Kickstart size)
```

- `MINMGAR.CFG` loaded means the `Configuration file size:` line, and **no** `Converted 832 configuration ...` line and no `(832 byte order)` line.
  If either of those two appears, the RV config was not found or was in the wrong order: report it.
- The version string. The plan names it `AMR2611-RV` (build date 2026-01-01 shimmed, `PROVENANCE.txt`), but the firmware never prints it, and
  `grep -a AMR2611 RV32OSDA.BIN` finds nothing: the constant is not in the image. What the image does hold is the OSD line
  `Firmware version: 2026-1-1-0-0` (`fpga.c`, `MM_FIRMWARE_VERSION`). Look for that line in the OSD info page. The old and new images both carry the
  same string, so the sha256 of the card file is the real check, not the version text.

### Row 2: OSD

- The OSD opens and closes by the button and by the keyboard.
- Menu keys work. Walk every main page (Main, Settings pages, Floppy, Hard disk, CD-ROM, Misc and their sub-pages). Hold a cursor key and watch
  the key repeat. Scroll a long file list in the file selector.
- DebugMode: `menu.c` toggles it with Ctrl + Left Alt + the Menu key (`KEY_MENU` = 0x69, `menu.c` line 571), not from the Misc page. With
  DebugMode on, the OSD shows the debug messages, and each time it goes on the firmware prints one line to ttyUSB0:

  ```
  Stack high water <hex>, OSD RDY timeouts 0x<hex>
  ```

  `OSD RDY timeouts 0x0` is the pass value. To read it again later, switch DebugMode off and on again.

### Row 3: HDMI picture

The ADV7511 init now runs from the RISC-V firmware (`fw/ctrl_rv/adv7511.c`, `i2c.c`) and has never been run against the real chip. If the screen
is black, this is the first suspect.

What the firmware does and reports (checked in the source):

- The init (`adv7511_init`) runs once about 250 ms after the main loop starts (`adv_first` in `main.c`), and again after each hot-plug (HPD low to
  high) the poll sees.
- **It prints nothing on ttyUSB0**, neither on success nor on error: there is no `printf` or `puts` in `adv7511.c` or `i2c.c`. A silent ttyUSB0
  therefore does not mean the init worked.
- A failed status read returns 0xff, which the OSD HDMI page shows as `Chip 0xBA: ff` ("no answer on the bus"); after 8 failed reads in a row
  the firmware clocks the bus free (`i2c_bus_recover`).
- The HDMI page (Settings, HDMI) shows `Chip 0xBA: xx  set: xx` and `INT <0/1>  serviced <n>`. `serviced` counts the init/poll passes.
- Keyboard re-init by hand: Left Shift + keypad `.` (shows `Refreshing ADV7511 config` when no menu is open).

If the picture is black, capture:

1. Does A show a picture with the same cable and monitor? (power-cycle, load A, look.)
2. The ttyUSB0 lines of B up to the black screen (they will show the boot but nothing from the ADV7511).
3. Whether the board otherwise runs: does the Amiga boot (floppy sounds, power LED, disk LED), and does the keyboard still react?
4. Left Shift + keypad `.` once: does the picture appear?
5. If the OSD is visible at all (for example on a second output or after the keypad re-init), the HDMI page lines `Chip 0xBA: xx  set: xx` and
   `INT x  serviced n`.

### Row 4: Kickstart loads (`MINMGAR.CFG`) and boots

Kickstart loads with the config of row 1, no conversion message, and the Amiga reaches the insert-disk screen or Workbench.

### Row 5: floppy READ (ADF)

Insert an ADF from the OSD floppy page and boot or `dir` it.

### Row 6: floppy WRITE

Fixed on 2026-10-19 night by osd-riscv `6ea1b76`. Use a scratch COPY of an ADF, never your only copy.

1. Use `SCRATCH.ADF`; its sha256 was recorded in section 1 (`~/ab-scratch-adf.sha256`).
2. Put `SCRATCH.ADF` in DF0 (or DF1) from the OSD.
3. Write a file to it from Workbench or the CLI (for example `copy S:Startup-Sequence DF0:test`), or format it.
4. Eject and reinsert the ADF or reset the Amiga, and read the file back.
5. Power down, put the card into the PC and mount it (re-set `CARD` if the mount point differs, and `cd "$CARD"`). Run
   `sha256sum -c ~/ab-scratch-adf.sha256`: it must report `SCRATCH.ADF: FAILED`. FAILED means the file changed, which is the pass. Then unmount.

Note the ttyUSB0 lines during the write (`fdd.c` prints track/sector messages) and on failure the last one.

### Row 7: HDF boots to Workbench

Boot the HDF you normally use, to a working Workbench.

### Row 8: CD-ROM

The ISO and CUE listing appears in the CD-ROM page (`CD-ROM drive.  Insert an ISO image or a CUE sheet ...`); mount one; CD-DA play, pause and
stop from an Amiga CD player. The Amiga needs AtapiMagic (3.1.4/3.2) or IDEfix97 (3.1) for the drive.

### Remaining checks

- Row 9, config save to a slot and reload: save to a slot in the OSD, change a setting, load the slot, and check that the setting returned. On
  the PC compare `sha256sum` of the slot's `MINMGAR<n>.CFG` before and after (the card's FAT dates are not reliable); it must change.
- Row 10, reset from the OSD: Misc, Reset, yes; the Amiga restarts and boots again.

Any lock-up: write down the last line on ttyUSB0 and what was on screen.

## 6. Results table

Mark each cell ok or fail (or "-" where the check was not run), with a note.

| # | Check | A ok/fail | B ok/fail | Note |
|---|---|---|---|---|
| 1 | RV boot ROM finds and loads `RV32OSDA.BIN`; `MINMGAR.CFG` loaded, no conversion message | | | |
| 2 | OSD open/close (button, keyboard), menu keys, every main page, key repeat, file selector scroll, DebugMode `OSD RDY timeouts 0x0` | | | |
| 3 | HDMI picture | | | |
| 4 | Kickstart loads and boots | | | |
| 5 | Floppy READ (ADF) | | | |
| 6 | Floppy WRITE (scratch ADF, sha256 changed on the card) | | | |
| 7 | HDF boots to Workbench | | | |
| 8 | CD: ISO + CUE listing, CD-DA play/pause/stop | | | |
| 9 | Config save to a slot and reload | | | |
| 10 | Reset from the OSD | | | |

## 7. Paste back

1. Both ttyUSB0 logs (`ab-A.log`, `ab-B.log`).
2. The filled table above.
3. Any OSD text that differs between A and B.
4. For a black screen: items 1 to 5 of row 3. For a lock-up: the last ttyUSB0 line and what was on screen.

## 8. Fallback

Power-cycle, load A (`stage_spicdc_49b1868`, command in section 3) with the live card `/media/paul/AARSDISK55` in the board. The live card was not
changed by any step here.
