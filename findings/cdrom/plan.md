# CD-ROM drive from an ISO on the SD card -- implementation plan

Status: decisions closed (2026-10-12); phase 0 and phase 1 tasks 1.1-1.6
implemented on branch `cdrom` (section 12); 1.7 (build) onwards open.
Research by a Fable agent against superproject 3987715 (5.0-040-pipelined);
reconciled with Paul's decisions D1-D7 (section 11) and a second read of
rtl/minimig/gayle.v the same day, which changed the Gayle design from one
shared register file to one instance per IDE port (section 7.3, ruling R-A).

Sources: the local RTL and firmware; MiSTer's Main_MiSTer `ide.cpp` /
`ide_cdrom.cpp` and Minimig-AGA_MiSTer `rtl/ide.v`; WinUAE `ide.cpp` /
`gayle.cpp` / `blkdev.cpp`; the OS 3.1.4.1 / 3.2.2 / 3.2.3 release notes and
ROM images under ~/work/amiga.  Claims I could check say where; anything not
checked is marked UNVERIFIED.

Reference copies (re-clone when needed):
`git clone --depth 1 https://github.com/MiSTer-devel/Main_MiSTer`
(ide.cpp, ide_cdrom.cpp, ide.h), `https://github.com/MiSTer-devel/Minimig-AGA_MiSTer`
(rtl/gayle.v, rtl/ide.v, README.md), `https://github.com/tonioni/WinUAE`
(ide.cpp, gayle.cpp, blkdev.cpp).

## 0. Summary

- **What the user gets**: an emulated ATAPI CD-ROM drive.  The OSD picks an
  ISO file from the SD card into it; discs can be swapped without a reset.
  One CD drive (D3).
- **Where it sits**: by default on the **secondary IDE port, master** (D1).
  The CD is a slot type, so it can also be put on the primary port (master or
  slave) -- useful with a stock 3.1.4/3.2 ROM and no extra Amiga software.
- **Amiga side**: secondary port = AtapiMagic (3.1.4/3.2, free) or IDEfix97
  (3.1, shareware) + a CD filesystem; primary port with a 3.1.4/3.2 ROM =
  nothing extra but L:CDFileSystem and a CD0 mount file.  Table in section 4.
- **Booting from the CD**: no, with any setup that uses stock ROMs; accepted
  (D6).  Section 3.
- **Menu**: the CD is one more type in the existing Harddisks menu; port 1 on
  page 1, port 2 on a new page 2; a "CD-ROM:" line on the main page for
  insert/eject.  Port 2 is on whenever one of its slots is configured (D4).
  Eject is refused while the Amiga has locked the drive (D5).  Section 5.
- **RTL**: Gayle becomes two port instances (one register file, status
  logic and 8 KB FIFO each) behind the shared Gayle registers, plus an ATAPI
  packet mode (programmable transfer length instead of fixed 512-byte
  blocks).  Section 7.3.
- **Fit**: about +330-430 LUTs and +2 BRAM36 against ~10,000 free LUTs and 54
  free BRAM36; all of it on the 28 MHz / clk7_en domain.  Firmware +15-20 KB
  of ~330 KB headroom.  Section 6.

## 1. What exists today (verified)

### 1.1 Gayle RTL -- rtl/minimig/gayle.v (418 lines), gayle_fifo.v (74)

- One task-file register file `tfr[7:0]` (8 x 8 bit), one status machine
  (`busy`, `pio_in`, `pio_out`, `error`, `sector_count`) and ONE 4096-word
  FIFO (8 KB, `gayle_fifo.v`), shared by both ports and all four devices.
  The firmware writes/reads the tfr via SPI (`hdd_addr`, `hdd_wr`), the host
  via $DA0xxx/$DA2xxx (`address_in[4:2]` = register).
- Second port = address bit 12: `sel_tfr` accepts `address_in[12]` only when
  `|hdd1_ena` (gayle.v:180).  A drive/head write sets
  `dev <= {address_in[12], data_in[12]}` (gayle.v:260).  Status reads return
  0x00 for a device whose enable bit is clear (gayle.v:400).  This is the
  IDE-splitter mapping, as in MiSTer (`port_num = addr[12]`) and WinUAE
  (`IDE_SECONDARY`, `ide_splitter`).
- The A1200's own device-control register is at $DA3018 (comment
  gayle.v:73), i.e. address bit 12 set, register 6.  Today it is not decoded
  (hdd1_ena is never set).  **With port 2 enabled, $DA3018 is port 2's
  drive/head register**: in the shared design a write there overwrites the
  shared `tfr[6]` (port 1's LBA bits 27:24, DEV and LBA-mode bits) and flips
  `dev` to port 2.  On a real splitter each port has its own registers, so
  the same write only reaches port 2's drive.  -> ruling R-A, section 7.3.
- `hdd_cmd_req = bsy` (gayle.v:368, `bsy = busy & ~drq`) is both "new
  command" and, inside the firmware's ATA read loop, "FIFO drained, send the
  next block" (hdd.c:402 `while (!(GetFPGAStatus() & CMD_IDECMD))`).  A
  pending command on the other port would satisfy that wait -> another
  reason for per-port request bits.
- The firmware receives `dev[1]` in bit 8 of every tfr read
  (`hdd_data_in = {7'h0, dev[1], tfr_out}`, gayle.v:243) and discards that
  byte (`SPI(0); tfr[i] = SPI(0);`, hdd.c:589-590).  Bits 15:9 are free.
- Data phases are hard-wired to 512-byte blocks: `fifo_full` = >= 512 bytes
  (gayle_fifo.v:66), `last_in/last_out` every 256 words, `sector_count`
  clears `busy` at 1 (gayle.v:299), `drq = fifo_full & pio_in | ~fifo_full &
  pio_out & sector_count != 0` (gayle.v:358), `hdd_dat_req = fifo_full &
  pio_out`.  **ATAPI cannot work on this**: a 12-byte command packet (6
  words out), REQUEST SENSE (18 bytes in), INQUIRY (36), READ CAPACITY (8),
  READ TOC (12-20) never fill 512 bytes.
- `tfr` is not cleared on reset; `ATA_Diagnostic` writes error=1 and zeros,
  not the ATA signature (hdd.c:314).  Works with scsi.device 3.1 today.
- `nrdy = pio_in & sel_fifo & fifo_empty` (gayle.v:397) stalls the 68k on an
  empty FIFO -- usable for streaming.
- IRQ: `intreq` on the rising edge of drq after a status write with bit 4
  (pio in), on each bit-4 status write (pio out), or on the END write for
  non-data commands (gayle.v:317-327).  `irq = intreq & intena`.

### 1.2 Firmware -- fw/ctrl_832/hdd.c, paula_floppy.v SPI protocol

- `HandleHDD` (hdd.c:567) runs on `CMD_IDECMD` (bit 2 of status word 0,
  paula_floppy.v:394), reads 8 tfr registers with CMD_IDE_REGS_RD (0x80),
  takes `unit = tfr[6] & 0x10` (master/slave only), dispatches ATA commands
  0x10 0x90 0xEC 0x91 0xC6 0x20 0xC4 0x30 0xC5, anything else -> ABRT.
  `hdfTYPE hdf[2]` (hdd.c:42).  The read and write loops block inside
  HandleHDD until the command completes.
- SPI commands to the HDD block: top nibble of the first SPI word
  (paula_floppy.v:736-739): 1000 regs read, 1001 regs write, 1010 data
  write, 1011 data read, 1111 status write (WriteStatus bits: 0x80 END, 0x10
  IRQ, 0x08 pio-in, 0x04 pio-out, 0x01 ERR).  Bits 11:0 of that first word
  are unused; nibbles 1100/1101/1110 are free.
- Status word 0 is fully used: `{sel[1:0], drives[1:0], hdd_dat_req,
  hdd_cmd_req, trackwr, trackrd, track[7:0]}` (paula_floppy.v:394).
- Direct SD-to-FPGA streaming: `FileReadEx(file, NULL, n)` ->
  `MMC_ReadMultiple(lba, 0, n)` asserts the second chip select so the SD
  data goes straight into the Gayle FIFO (`hdd_data_wr = ... || (scs2 &&
  rx_flag)`, paula_floppy.v:343).  A 2048-byte CD sector is four blocks:
  `HardFileSeek(&cd, lba*4); FileReadEx(&cd.file, 0, 4)`.
- `hdfTYPE` carries a 1024-entry cluster index (4 KB) built once per file;
  for a 700 MB ISO the index granularity becomes 1 MB -- reusable as is.
- `ConfigIDE(gayle, master, slave)` (osd.c:920) sends OSD_CMD_HDD (0x54) with
  3 bits for `ide_config0`; `ide_config1` (command byte 0x58) is never
  written, so port 2 is dormant.  userio_osd.v:449-450 take `wrdat[2:0]`
  into `t_ide_config0/1`, which reach `ide_config0/1` only while reset is
  active (userio_osd.v:96-102) -- IDE configuration applies at reset.
- The firmware never learns of an Amiga-initiated (keyboard) reset.

### 1.3 Config and OSD

- `configTYPE` (config.h) is 212 bytes, checked at compile time
  (config.c:259); `CONFIG_VERSION 4`.  A config with a version above the
  firmware's is rejected ("Wrong configuration file format!", config.c:321)
  -> no version bump in this work (older firmware must still load new
  configs).  `hardfile[2]` = port 1 master/slave; `secondaryhardfile[2]`
  reserved, only zeroed for configs older than version 3 (config.c:302-315);
  `hdfdir[4]` has four directory slots.  `hardfileTYPE` = enabled, present,
  name[8], long_name[16] (26 bytes).  Defaults: `memset(&config, 0)` plus
  fields (config.c:334-345).
- OSD: 8 lines x 32 characters; the title is a separate vertical strip; line
  7 loses 22 px when the right arrow is shown.
- Main page (menu.c:515-565): lines 0-3 floppies, 4 "Floppy disk settings",
  5 "Hard disk settings", **6 empty**, 7 exit.  Harddisks page
  (menu.c:1674-1740): IDE on/off, Master type, Master file, Slave type, Slave
  file, Sounds, blank, back.  Changes apply after a reset via
  MENU_HARDFILE_EXIT/CHANGED (menu.c:1888-1966).
- `SelectFile(ext, SCAN_DIR|SCAN_LFN, okstate, cancelstate)` (menu.c:160)
  compares one 3-letter extension; `ScanDirectory` (fat.c:858) matches one
  extension or '*'.
- `config_hdf_msg[]` (menu.c:90) has 7 entries indexed by
  `enabled & HDF_TYPEMASK`; an OLD firmware shown type 7 in `hardfile[]`
  reads past the array (display garbage only; OpenHardfile ignores unknown
  types).

### 1.4 The 2020 leftovers (Alastair Robinson)

- `bincue.c` (189 lines): CUE parser with a hard-coded test cue;
  `main.c:284` call commented out.  Reusable for phase 3 (BIN/CUE) after a
  file-backed line reader replaces the embedded cue.  Not needed for ISO.
- `audiotrack.c` (167 lines): red-book playback through the host audio
  buffer (`AUDIO_BUFFER` 0x70000, 32 KB).  Reusable for phase 3 CD audio.
- `akiko.c` + `rtl/minimig/akiko.v` + `rtl/akiko/akiko.vhd`: register
  logging stub and the chunky-to-planar unit.  Phase 4 (CD32) only.

### 1.5 Resources and timing (build/stage_postchip)

- Slice LUTs 53,417 / 63,400 (84.25 %), registers 26,112 (20.59 %), BRAM 81
  / 135 tiles (60 %), DSP 44 / 240.
- WNS: clk_114 +0.134, clk_148 +0.063, clk_38 +0.217, clk_ddr100 +1.354; the
  known clk_gen_sdram -> clk_114 group (-0.474, 16 endpoints) is unrelated.
  Gayle runs on the 28 MHz domain with clk7_en.
- yosys `synth_xilinx -family xc7` estimate (not Vivado): gayle 147 LUT, 32
  FF; gayle_fifo 44 LUT, 27 FF, 2 RAMB36E1.  Total ~190 LUTs, 59 FFs, 2 BRAM36.
- Firmware: boot ROM 8 KB BRAM loads `832OSDAD.bin` to host 0x2000 in SDRAM.
  Map: text/data 0x2000-0x15f5a (82 KB), BSS to 0x1d72c (hdd.o BSS 9.6 KB);
  next fixed user `AUDIO_BUFFER` 0x70000 -> ~330 KB headroom.  Stack in the
  8 KB BRAM: new buffers static, not on the stack.

### 1.6 Amiga side (ROMs and notes)

- A1200 ROMs 47.111 / 47.115 (3.2.2 / 3.2.3): `scsi.device` and the ATAPI
  string `NuATAPIismajik`; **no** `CDFileSystem`.  KS 3.1 40.68: no ATAPI.
  3.1.4 ATAPI: UNVERIFIED locally (the split EPROM halves gave no strings),
  inferred from the 3.1.4.1 scsi.device notes (45.4 "... compact flash and
  atapi devices").
- CDFileSystem release notes 3.2.2/3.2.3: 48.44 prepares ISO-file use,
  48.49 no longer needs TD_CHANGESTATE for ReMount(), 48.52 adds a ROM tag
  ("possibly boot with it.  Your mileage may vary").
- `Storage/DOSDrivers/CD0` (40.7) ships with 3.1.4; L:CDFileSystem and CD0
  on the 3.2 install floppy.
- MiSTer Minimig README: "For Secondary Master/Slave devices, you have to
  install either IDEFix97 (shareware, WB3.1/3.9) or AtapiMagic (freeware, WB
  3.1.4/3.2)."
- AtapiMagic 47.1 (Aminet driver/media, Hyperion, free, alpha, OS 3.1.4+):
  "4 IDE interfaces without the need of any third party software".
- IDEfix97 3.5 (Aminet, shareware with nag requesters): atapi.device, 4-drive
  adapters, CacheCDFS.
- Test images: `~/work/amiga/AmigaOS3.9.iso` (245,535 sectors) and
  `ClassicInstallCD-53.71.iso` (275,806 sectors), both plain 2048-byte ISO
  9660 (PVD "CD001" at byte 32769).  ROMs: 3.1 40.68, 3.1.4 46.143 (split),
  3.2.2 47.111, 3.2.3 47.115 (.rom).  OS 3.1.4 / 3.2 ADFs present.

## 2. Which IDE bus

| Option | Amiga sees | Driver support | Verdict |
|---|---|---|---|
| Gayle port 2 (IDE splitter, $DA1xxx/$DA3xxx) | a second IDE port with master/slave = scsi.device units 2/3 with a 4-way driver | AtapiMagic (3.1.4/3.2), IDEfix97 (2.04+); stock scsi.device: no; boot: no | **Default for the CD (D1)** |
| Gayle port 1 (master or slave) | units 0/1 | stock 3.1.4/3.2 scsi.device; 3.1 needs IDEfix97 | **Supported** (same code, other slot) |
| A4000-style IDE at $DD2000 | only with an A4000 ROM; still one port | breaks A1200 behaviour | Rejected |
| Zorro IDE/ATAPI board (Buddha, lide.device) | new autoconfig board with its own driver ROM | boot capable, but needs a third-party ROM image | Rejected (boot not wanted, D6) |

A separate "own IDE bus" that stock software drives does not exist on an
A1200-class machine; Gayle's second port is the closest real equivalent and
is what MiSTer and WinUAE offer.

## 3. Booting from the CD

| Setup | Boots? | Why |
|---|---|---|
| KS 1.3-3.1 (40.68) | No | no ATAPI, no CDFS in ROM.  Boot HDF/ADF, load IDEfix97 or another atapi.device. |
| KS 3.1.4 / 3.2, CD on port 1 | No | scsi.device sees the drive (3.2 verified), but CDFileSystem is on disk, not in ROM. |
| KS 3.1.4 / 3.2, CD on port 2 (default) | No | the ROM does not even see port 2. |
| Custom 3.2.2+ ROM with resident CDFileSystem 48.52+ | Possibly (UNVERIFIED) | not pursued (D6). |
| OS 3.9 CD on a 3.1 ROM | No | 3.9 uses an Emergency Disk; the ISO works as an install source. |
| CD32 | Later | Akiko, not IDE; phase 4. |

The user boots from an HDF or ADF and mounts the CD from there.

## 4. Amiga software per Kickstart/OS

| Kickstart / OS | Device driver | CD filesystem | Mount entry | Cost |
|---|---|---|---|---|
| 3.1.4 / 3.2, CD on port 2 (default) | AtapiMagic 47.1 (LIBS:modules + startup line), or IDEfix97 | L:CDFileSystem from 3.1.4/3.2 | DEVS:DOSDrivers/CD0, Device=scsi.device, Unit=2 (port 2 master) | AtapiMagic free (no redistribution) |
| 3.1.4 / 3.2, CD on port 1 | ROM scsi.device | L:CDFileSystem | CD0, Unit=1 (port 1 slave) or 0 | included |
| 3.0 / 3.1 | IDEfix97 atapi.device, or another A1200 atapi.device (Aminet driver/media) | CacheCDFS (IDEfix97), AmiCDFS 2.40 (free), AsimCDFS (commercial) | CD0, Device=atapi.device | IDEfix97 shareware; AmiCDFS free |
| 3.5 / 3.9 on a 3.1 ROM | the 3.5/3.9 ROM-update scsi.device + bundled CacheCDFS (UNVERIFIED), or IDEfix97 | CacheCDFS | Storage/DOSDrivers/CD0 | included |

Unit numbers with a 4-way driver: 0 port 1 master, 1 port 1 slave, 2 port 2
master, 3 port 2 slave.  A short how-to with exactly these lines goes into
doc/ (task 1.10).

## 5. OSD design

### 5.1 Structure

The CD-ROM is a slot type in the existing Harddisks menu (not a separate CD
menu): the slot is the IDE position, config storage needs no new fields, and
"HDF and CD in the same slot" cannot happen.  A main-page line gives quick
access for inserting and ejecting discs.

### 5.2 Screens (32 columns, 8 lines)

Main page (MENU_MAIN1), line 6 was empty:

```
 df0: Workbench3.2.adf
 df1: * no disk *
 df2:
 df3: KP +/- to add/remove drives
 Floppy disk settings  >
 Hard disk settings    >
 CD-ROM: AmigaOS3.9.iso
             exit
```

Line 6 states:

| State | Line 6 text | Select does |
|---|---|---|
| no slot of type CD-ROM | `CD-ROM: not configured` (stippled, not selectable) | -- |
| CD slot, no disc | `CD-ROM: * no disc *` | opens the ISO file selector; OK = insert |
| disc in, not locked | `CD-ROM: <iso long name>` | eject |
| disc in, locked by the Amiga | `CD-ROM: <name>` with a lock mark at column 31 | nothing; the line shows `CD-ROM: locked by the Amiga` for 2 s (D5) |

Menu bookkeeping: the CD line is menusub 6 and exit becomes menusub 7;
adjust the main-page menumask (today 0x70 + drives) and the
`menusub > drives` fall-through in MENU_FILE_SELECTED; Backspace ("eject all
floppies") does not touch the CD.

Harddisks page 1 (MENU_SETTINGS_HARDFILE1, title "Harddisks", right arrow
to page 2):

```
    IDE : on
 Master : Hardfile (disk img)
              Workbench.hdf
  Slave : Disabled

 Sounds : on

            back            >
```

Harddisks page 2 (new MENU_SETTINGS_HARDFILE3/4, title "IDE port 2", left
arrow back to page 1):

```
 Master : CD-ROM (ISO)
              AmigaOS3.9.iso
  Slave : Disabled

 Port 2 needs AtapiMagic or
 IDEfix97 on the Amiga.
 Not bootable.
<           back
```

Rules:

- `IDE : off` switches both ports off.  Port 2 has no on/off line (D4): it
  is on exactly when IDE is on and at least one of its slots is not
  Disabled.  A configured CD slot counts as enabled with or without a disc,
  so ejecting never makes the drive disappear from the bus.
- The type line cycles Disabled -> Hardfile (disk img) -> Hardfile (filesys)
  -> MMC/SD card -> partitions 1-4 -> **CD-ROM (ISO)** -> Disabled, on both
  pages.  `HDF_CDROM = 7`, `config_hdf_msg[7] = "CD-ROM (ISO)"`.  The cycle
  skips CD-ROM when another slot already is one (one CD drive, D3).
- The file line opens `SelectFile("ISO", ...)` for a CD slot and
  `SelectFile("HDF", ...)` otherwise.  `MENU_HARDFILE_SELECTED` stores
  name/long_name/hdfdir for a CD slot and skips `GetHDFFileType`.  For a CD
  slot, choosing a file while a disc is in is a swap: refused while locked
  (D5), otherwise eject + insert, no reset.
- Leaving a page goes through MENU_HARDFILE_EXIT: a changed slot TYPE or a
  changed hardfile asks for the reset as today (the Amiga must re-probe the
  bus); a changed ISO in an unchanged CD slot does not (it is a media
  change).  MENU_HARDFILE_EXIT compares `enabled` and `name` separately for
  CD slots.
- Long ISO names: the slot page and line 6 show the first characters that
  fit; the file selector scrolls the full name (ScrollLongName).
- Help text for the CD type: "CD-ROM drive.  Insert an ISO image from the
  SD card.  On IDE port 2 the Amiga needs AtapiMagic (3.1.4/3.2) or IDEfix97
  (3.1).  The Amiga cannot boot from it."

Keys: as the existing pages (up/down, select, menu = back, left/right page).

### 5.3 Config storage

- Slots: `hardfile[0..1]` (port 1 master/slave) and `secondaryhardfile[0..1]`
  (port 2 master/slave), directories in `hdfdir[0..3]`.  A CD slot:
  `enabled = HDF_CDROM`, `name`/`long_name` = the ISO in the drive at power
  on (empty = no disc), `present` = that file was found.  212 bytes, config
  version stays 4.
- Default (D1): a fresh config (no file / loading failed, config.c:334) gets
  `secondaryhardfile[0].enabled = HDF_CDROM` with no disc.  Existing config
  files keep their slots (all zero on port 2 today): without a version bump
  there is no way to tell "never configured" from "switched off", and a bump
  would make older firmware reject the file.  Paul's own config: set port 2
  master to CD-ROM once in the OSD.
- Insert/eject at run time changes the RAM copy only; it is saved with the
  rest of the config when the user saves, so the disc in the drive at save
  time is the power-on disc.

## 6. Does it fit

- RTL: second port instance (register file, status machine, FIFO) ~+190
  LUTs, +59 FFs, +2 BRAM36; ATAPI packet mode per instance (13-bit length,
  counters reused from the FIFO pointers, flags, signature mux) ~60-120 LUTs
  each; port select, request mux and the 5-bit ide_config ~20 LUTs.  Total
  about +330-430 LUTs (53,417 -> ~53,850, 85 %), +2 BRAM36 (81 -> 83 of 135).
  Everything is on the 28 MHz / clk7_en domain, away from the clk_148 /
  clk_114 paths with the small margins.  A build is still needed to confirm
  timing (place-and-route moves things), but the logic is small and slow.
- Firmware: atapi.c ~4-6 KB, cdrom.c ~2-3 KB, port-aware hdd.c ~1 KB, OSD
  ~3 KB, two more hdfTYPE (4 KB index each, port 2 hardfiles) + 2 KB
  response buffer + CD index 4 KB: ~20 KB of the ~330 KB headroom.
- Config: no growth.
- Vendor neutrality: plain Verilog registers, comparators and the existing
  inferred FIFO RAM; the Intel ports compile it (they lack the firmware
  support only if their firmware is not updated).

## 7. Device protocol and design

### 7.1 ATA-level behaviour of the CD unit

- Signature after reset / EXECUTE DEVICE DIAGNOSTIC (0x90) / DEVICE RESET
  (0x08): sector count 1, sector number 1, cyl low 0x14, cyl high 0xEB,
  error 0x01, status without BSY/DRQ.  ATA units: 1,1,0,0 (fix
  `ATA_Diagnostic`, which writes 0,0 today).
- IDENTIFY DEVICE (0xEC) on the CD unit: abort (ERR, error 0x04) and reload
  the signature -- how a host that tried ATA learns to send 0xA1.
- IDENTIFY PACKET DEVICE (0xA1), 512 bytes: word 0 = 0x8580 (ATAPI, CD-ROM
  type 5, removable, 12-byte packets); words 10-19 serial "MINIMIGCD0";
  23-26 firmware "1.00"; **27-46 model = the ISO long name, space padded to
  40 characters, "CD-ROM (empty)" without a disc (D7)** (byte-swapped pairs
  as in `IdentifyDevice`); word 49 = 0x0200 (LBA); 53 = 0x0007; 62-64 = 0
  (no DMA); 80 = 0x007E; 82 = 0x4014; 83 = 0x7000; 84-87 = 0x4000; rest 0.
  One DRQ block of 256 words, then END|IRQ.
- SET FEATURES (0xEF) subcommand 0x03: accept.  NOP and everything else:
  abort.
- PACKET (0xA0): features bit 0 (DMA) set -> abort.  Byte-count limit =
  cyl high:low (0 or 0xFFFF -> 0xFFFE).  Device: interrupt reason (sector
  count register) = 0x01 (CoD), DRQ=1, BSY=0, no IRQ.  Host writes 6 words.
  Then:
  - data-in: per DRQ block: byte count = bytes in this block, interrupt
    reason 0x02 (IO), DRQ=1, IRQ.  Block size = min(remaining, limit, 8 KB).
    After the last block: interrupt reason 0x03 (IO|CoD), DRQ=0, DRDY=1,
    IRQ, ERR per status.
  - data-out (MODE SELECT): interrupt reason 0x00, byte count = length,
    DRQ=1, IRQ; receive; complete as above.
  - no data: complete directly.
  - error: ERR, error register = (sense key << 4) | 0x04, interrupt reason
    0x03, IRQ; the sense is kept for REQUEST SENSE.
- Status: DRDY as today (`drdy = ~(bsy|drq)`).  WinUAE and MiSTer clear DRDY
  on an ATAPI unit until its first ATAPI command; whether an Amiga driver
  needs that is UNVERIFIED (risk R4).

### 7.2 SCSI command subset (12-byte CDB), phase 1

Sources: MiSTer `cdrom_handle_pkt` (debugged against OS 3.2 CDFileSystem,
AtapiMagic and IDEfix), WinUAE `scsi_cd_emulate`, MMC-3/SPC-2.  What each
Amiga driver really sends is UNVERIFIED; phase 1 logs every CDB on the
serial console (task 1.6) to confirm the table from evidence.

| CDB | Name | Phase 1 behaviour |
|---|---|---|
| 00 | TEST UNIT READY | GOOD if a disc is in and no UNIT ATTENTION is pending; else CHECK CONDITION (02/3A/00 no medium, 06/28/00 medium changed) |
| 03 | REQUEST SENSE | 18 bytes, response code 0x70, last sense; clears UNIT ATTENTION.  Exempt from the no-disc rule |
| 12 | INQUIRY | 36 bytes: 05 80 00 21 1F, vendor "MINIMIG ", **product = first 16 characters of the ISO long name, space padded, "CD-ROM (empty)" without a disc (D7)**, revision "1.00"; truncated to the allocation length.  Exempt |
| 1A | MODE SENSE(6) | as 5A with the 4-byte header |
| 1B | START STOP UNIT | LoEj=1 Start=0 (Amiga-side eject): if locked -> CHECK CONDITION 05/53/02 (medium removal prevented); else eject as the OSD does.  Start=1: GOOD |
| 1E | PREVENT ALLOW MEDIUM REMOVAL | GOOD; store the lock bit (blocks OSD eject/swap, D5) |
| 25 | READ CAPACITY | 8 bytes: last LBA, block length 2048 |
| 28 | READ(10) | LBA + 16-bit count; count 0 = GOOD, no data; beyond the end -> 05/21/00 |
| 2B | SEEK(10) | GOOD |
| 35 | SYNCHRONIZE CACHE | GOOD |
| 42 | READ SUB-CHANNEL | header + audio status 0x15 (none) |
| 43 | READ TOC | format 0 (track 1 data at LBA 0 + lead-out, control 0x14, MSF or LBA per byte 1 bit 1, starting track, allocation length); format 1 (session info); others -> 05/24/00 |
| 46 | GET CONFIGURATION | 16 bytes, current profile 0x0008.  Exempt |
| 4A | GET EVENT STATUS NOTIFICATION | polled, media class, 8 bytes: event 2 (new media) once after an insert, 3 (removed) once after an eject, else 0.  Exempt |
| 51 | READ DISC INFORMATION | 34 bytes, one session, one track |
| 52 | READ TRACK INFORMATION | 24 bytes for track 1 |
| 55 | MODE SELECT(10) | accept the data, ignore it |
| 5A | MODE SENSE(10) | 8-byte header + pages 01, 0E (volumes 0xFF), 2A (CD-ROM read; audio-play bit 0 until phase 3), 3F = all; unknown page -> 05/24/00 |
| A8 | READ(12) | as READ(10) with a 32-bit count |
| 45 47 4B 4E BC | PLAY AUDIO / PAUSE / RESUME / STOP / PLAY CD | GOOD, no action |
| BE B9 D8 D9 | READ CD and variants | 05/20/00 (phase 3) |
| other | | 05/20/00; invalid field 05/24/00 |

No-disc rule (MMC-5 4.1.6.1, MiSTer): with no disc every command except
INQUIRY, REQUEST SENSE, GET CONFIGURATION and GET EVENT STATUS NOTIFICATION
returns CHECK CONDITION 02/3A/00.  After an insert the first non-exempt
command gets 06/28/00 once.  After an Amiga reset the first non-exempt
command gets 06/29/00 once and the lock is cleared (a real drive forgets
PREVENT on reset).  MiSTer's "becoming ready" countdown (02/04/01) only if a
driver turns out to need it.

### 7.3 Gayle RTL changes -- vendor neutral

**Ruling R-A (2026-10-12, under D2): one port instance per IDE port, from
phase 1.**  D2 says one Gayle if it is sufficient.  With the CD on port 2
by default (D1), port 2 is on for every user, and the shared design is not
sufficient:

1. $DA3018 (the A1200 device-control address) is port 2's drive/head
   register; any device-control write corrupts port 1's shared `tfr[6]` and
   `dev` (section 1.1).
2. While the CD on port 2 is busy, a host write to port 1's command
   register is dropped (`tfr_we = busy ? hdd_wr : ...`) -- the driver times
   out on its hard disk.
3. `hdd_cmd_req = bsy` is shared; port 2's pending command would release
   port 1's ATA read loop early (data corruption).

Separate instances fix all three by construction and behave like a real
splitter.  Cost +~190 LUTs, +2 BRAM36 (section 6), which D2 accepts.

Changes:

1. Split gayle.v into `gayle.v` (address decode, Gayle ID, CS, CFG, INTENA,
   INTREQ, data_out mux) and `gayle_port.v` (one port: tfr, `dev` bit,
   busy/pio_in/pio_out/error, sector_count, the FIFO, packet mode).  Two
   instances, `port 0` selected by `address_in[12]==0`, `port 1` by
   `address_in[12]==1 && |hdd1_ena`.  Port 0 with packet mode off must be
   bit-identical in behaviour to today's Gayle (bench case a).  A parameter
   `IDE_PORTS` (default 2) lets small targets keep one instance.
2. INTREQ: set by either port's existing set conditions (OR), cleared by the
   CPU as today.  `irq = intreq & intena` unchanged.
3. Firmware port select: bit 8 of the first word of every HDD SPI command
   (1000/1001/1010/1011/1111 and the new 1100) selects the port;
   paula_floppy.v latches it as `hdd_port` with the command and passes it to
   gayle, which routes `hdd_wr`, `hdd_addr`, `hdd_data_*`, `hdd_status_wr`
   and `hdd_data_in` to/from that instance.  The SD direct-transfer path
   (`scs2`) writes into the instance of `hdd_port`.
4. Request bits (status word 0 stays as is):
   `hdd_cmd_req = bsy[hdd_port] | (bsy[~hdd_port] & ~busy[hdd_port])` --
   while the firmware serves a command on one port, only that port's `bsy`
   is visible (the ATA loops keep working); when it is idle, either port's
   new command raises CMD_IDECMD.  `hdd_dat_req = dat_req[hdd_port]`.
   Flags in `hdd_data_in[15:8]` of every tfr read (any port): bit 8 port of
   this read, bit 9 `xfer_done`, bit 10 `dev_wr` (host wrote drive/head
   since the last firmware read; sticky), bit 11 `rst_seen` (Gayle reset
   since the last read; sticky), bit 12 `pkt_mode`, bit 13 `bsy[0]`, bit 14
   `bsy[1]`.  Sticky bits clear when the firmware reads register 7 of that
   port.
5. New SPI command `CMD_IDE_XFER_WR` = top nibble 1100 (0xC0 | port bit):
   one payload word `{pkt_mode, 2'b0, xfer_words[12:0]}`.  Decoded in
   paula_floppy.v next to cmd_hdd_wr (`hdd_xfer_wr` strobe at rx_cnt==1).
   Writing it resets that port's FIFO pointers and loads the length.
   `pkt_mode` clears on a host command write and on reset.
6. Packet mode (`pkt_mode=1`) in gayle_port:
   - `drq = pio_in ? (fifo_full | words_in == xfer_words) & ~fifo_empty
     : pio_out & (words_in < xfer_words)` -- short transfers get DRQ when
     complete, long ones stream in 512-byte steps, `nrdy` covers the tail.
   - No `sector_count` decrement, no automatic `busy` clear.
   - Transfer end (`words_out == xfer_words` pio in, `words_in ==
     xfer_words` pio out): drq drops, `busy` stays set (BSY between phases,
     allowed by ATAPI), `pio_in/pio_out <= 0`, sticky `xfer_done <= 1`; for
     pio out `hdd_dat_req = xfer_done`.
   - `intreq` set on every status write with bit 4 in packet mode.
7. Signature mux: `ide_config0/1` widen from 3 to 5 bits (bit 0 port on,
   bits 2:1 master/slave present, **bits 4:3 master/slave is ATAPI**);
   userio_osd.v:449-450 take `wrdat[4:0]`, `t_ide_config0/1` widen.  Per
   port `sig_mode`, set on reset and by a status write with new bit 5,
   cleared by a host command write; while set, host reads of tfr 1..5
   return 1 / 1,1,0x14,0xEB (ATAPI device) or 1 / 1,1,0,0 (ATA) for the
   selected device.  Removes the race between a firmware-written signature
   and the host switching devices.
8. `ConfigIDE(port, on, master, slave, atapi_bits)` sends OSD_CMD_HDD (0x54)
   for port 1 and new `OSD_CMD_HDD1` (0x58) for port 2.  Check in
   userio_osd.v that 0x58 decodes to `spi_harddisk1_cfg_sel` before relying
   on it.  Port 2's `ide_config1[0]` = IDE on && (secondary master or slave
   enabled) (D4).

Not planned: the device-control register (SRST/nIEN; a real splitter loses
it too), DMA, DRDY masking (only if R4 shows up).

### 7.4 Firmware structure

- `fw/ctrl_832/atapi.c/.h` (new, pure C, no hardware access): `struct
  atapi_unit` (sense, unit attention, lock, pending event, media present,
  `sectors`, name), `atapi_identify(buf, unit)`, `int atapi_packet(struct
  atapi_unit*, const uint8_t cdb[12], uint16_t limit, struct
  atapi_result*)` -> RESPONSE (bytes in a 2 KB static buffer), READ (lba,
  count), RECEIVE (length), DONE, CHECK (sense).  Builds for the 832 and for
  the host with gcc (`-DHOSTTEST`).
- `fw/ctrl_832/cdrom.c/.h` (new, board glue): the CD state (`fileTYPE` +
  cluster index, slot, inserted, locked), `CD_Open(slot)`,
  `CD_Insert(name, dir)`, `CD_Eject()` (refuses while locked, returns a
  status the OSD shows), `CD_HandleCommand(port, tfr)` for
  0xA0/0xA1/0xEC/0x90/0x08/0xEF/else using `WriteTaskFile`, `WriteStatus`,
  new `WriteXfer(port, words, pkt)`: response data with CMD_IDE_DATA_WR,
  sectors with `FileReadEx(&cd.file, 0, 4*n)` direct transfer, wait for
  `xfer_done`, next block; data-out via CMD_IDEDAT + CMD_IDE_DATA_RD.
- `hdd.c`: every SPI HDD command carries the port bit (`hdd_port` global set
  per command).  `HandleHDD`: read the registers of port 0; if the flags say
  `bsy[0]` is clear and `bsy[1]` set, read port 1's instead.  `slot = port<<1
  | (tfr[6]>>4 & 1)`; dispatch to the ATA path (`hdf[4]`, one per slot) or
  `CD_HandleCommand`.  `ATA_Diagnostic` writes the proper signature;
  `rst_seen` re-arms UNIT ATTENTION (06/29/00) and clears the lock.
- `config.c ApplyConfiguration`: open all four slots, `ConfigIDE` for both
  ports with the ATAPI bits; the D1 default in the defaults block.
- `menu.c`: section 5.  `fat.c`: no change for "ISO".
- `osd.h/fpga.h/hdd.h`: `OSD_CMD_HDD1`, `CMD_IDE_XFER_WR`, `HDF_CDROM`.

## 8. Data path and performance

- ISO sector n = file bytes n*2048 = FAT sectors 4n..4n+3:
  `HardFileSeek(&cd, 4*lba)` + `FileReadEx(&cd.file, 0, 4*count)` streams
  from the SD card into the port's FIFO, no copy through the 832.  The
  cluster index costs one FAT walk at insert (as a hardfile open).
- Block size per DRQ: min(host limit, 8 KB) = up to 4 CD sectors.
- Estimate (unmeasured): SD SPI ceiling ~2 MB/s; fill-then-drain with the
  832 loop latency per block gives ~0.6-1.2 MB/s (4-8x CD speed).  The
  streaming `drq` term is in the RTL from the start, so overlapping fill and
  drain later is firmware only (task 2.1).
- Acceptance measures a 100 MB copy from CD0: to RAM: (time + MD5).

## 9. Media change, eject and lock

- OSD eject (main-page line 6, or a new ISO on the slot page): if the Amiga
  has locked the drive (PREVENT MEDIUM REMOVAL), **refused** (D5): the OSD
  shows "locked by the Amiga", nothing changes.  Otherwise `CD_Eject()`
  closes the file, media=0, event=REMOVED; the next non-exempt command gets
  02/3A/00 and CDFileSystem sees the disc gone.
- OSD insert: `CD_Insert()` opens the ISO, builds the index, media=1, UNIT
  ATTENTION, event=NEW_MEDIA; the first non-exempt command returns 06/28/00
  once; CDFileSystem rereads the volume.  IDENTIFY/INQUIRY now report the
  new name (D7; drivers read them at probe time, so this is cosmetic).
- Swap = eject + insert in one action.
- Amiga-side eject (START STOP UNIT LoEj): same rules as the OSD, including
  the lock.
- The lock is cleared by ALLOW MEDIUM REMOVAL and by any Amiga reset
  (`rst_seen`) -- a crashed program cannot keep the drive locked past a
  reset.
- Amiga reset: the disc stays in; `sig_mode` re-armed; 06/29/00 once.

## 10. Phased tasks

Order: each task's test is written first and must fail before the change
(named mutant where the test is a bench).  Bitstream builds are Paul's call
and are not started unattended.  Board steps are done with Paul.

### Phase 0 -- the ATAPI layer on the host (no RTL, no board)

- 0.1 `fw/ctrl_832/test/atapi_test.c` + `Makefile` (host gcc), written
  first, against the `atapi.h` interface of section 7.4.  Cases: INQUIRY
  layout with the ISO name in the product field and "CD-ROM (empty)"
  without a disc; IDENTIFY PACKET words 0/49/82 and the model string; READ
  TOC format 0 in LBA and MSF for the 245,535-sector image incl. the
  lead-out at 54:35:60 (LBA + 150 frames); format 1; READ CAPACITY; MODE
  SENSE(6/10) page lengths and 3F; allocation-length truncation; the no-disc
  rule and its exemptions; the one-shot UNIT ATTENTION after insert
  (06/28/00) and after reset (06/29/00); GET EVENT STATUS one-shot; PREVENT
  then START STOP eject -> 05/53/02 and `CD_Eject` refused; ALLOW then eject
  works; reset clears the lock; invalid opcode 05/20/00; READ(10) count 0;
  READ beyond the end 05/21/00.  Sector reads through a callback backed by
  `~/work/amiga/AmigaOS3.9.iso` (PVD "CD001" at sector 16).
  Expected first run: does not compile (no atapi.c).
- 0.2 `fw/ctrl_832/atapi.c/.h` until 0.1 passes.
- 0.3 `fw/ctrl_832/cdrom.c/.h` compiled into the 832 image, not yet called;
  `make -C fw/ctrl_832` builds; the map shows < 20 KB growth.

### Phase 1 -- two-port Gayle with packet mode, CD on port 2, OSD

- 1.1 Bench first: `sim/gayle/gayle_tb.v` + `run.sh` (iverilog, modelled on
  sim/osd_keyq/run.sh), driving the 68k side (sel_ide, address, rd/hwr/lwr,
  clk7_en) and the SPI side (hdd_* ports and the port bit directly).  Cases:
  (a) port 0 ATA READ SECTORS of 2 sectors: the status/drq/irq sequence
  matches a golden trace recorded from today's gayle.v before the change;
  (b) PACKET on port 1: host 0xA0, firmware xfer=6/pkt, pio-out -> drq,
  6 words -> drq low, `hdd_dat_req`, `xfer_done`;
  (c) data-in 18 bytes on port 1: drq + intreq only after 9 words, host
  reads 9 -> drq low, BSY, xfer_done;
  (d) data-in 1024 words: drq after 256 words, `nrdy` when the host
  outruns the writer;
  (e) signature mux per port and device;
  (f) sticky `dev_wr` / `rst_seen` clear on reading register 7;
  (g) a write to $DA3018 with port 2 on leaves port 0's tfr[6] and device
  select unchanged;
  (h) port 0 command written while port 1 is busy: accepted, port 0 shows
  BSY, `hdd_cmd_req` follows the rule of 7.3 item 4 in both orders;
  (i) port 1 disabled (`hdd1_ena=0`): $DA1xxx/$DA3xxx not decoded.
  Mutants: packet mode forced off fails (b)-(d); shared register file
  (port select ignored) fails (g)-(h).
  Expected first run: (b)-(i) fail against today's gayle.v.
- 1.2 RTL per section 7.3 (gayle.v split + gayle_port.v, paula_floppy.v
  port bit and 1100 command, userio_osd.v 5-bit ide_config, minimig.v
  wiring) until 1.1 passes; diff-review that port 0's ATA expressions are
  unchanged with packet mode off.  Intel project files list gayle_port.v.
- 1.3 Firmware: port bit in all HDD SPI commands, `HandleHDD` port
  selection, `hdf[4]`, `ATA_Diagnostic` signature, `ConfigIDE` for both
  ports.  Board regression first (HDF on port 1 master boots, copy speed
  unchanged) before any CD code is called.
- 1.4 Firmware: `CD_HandleCommand`, `WriteXfer`, `CD_Open/Insert/Eject`,
  reset handling.
- 1.5 OSD: section 5 (CD type on both pages, page 2, main-page line 6 with
  the lock state, one-CD rule, swap without reset, D1 default for fresh
  configs, help text).
- 1.6 Serial log (DebugMode gated): every ATA command on a CD unit and every
  CDB, one line each.
- 1.7 Build (Paul's go), timing summary checked against section 6.
- 1.8 Board acceptance, port 2 (the default), 3.2.3 ROM 47.115, 3.2 on an
  HDF on port 1 master:
  - without AtapiMagic: boots normally, HDF works, no hang (port 2 is
    invisible to the ROM; $DA3018 writes are harmless -- case g on the
    board).
  - AtapiMagic 47.1 installed: unit 2 found, name = ISO name; CD0 with
    Unit=2 mounts AmigaOS3.9.iso; `dir CD0:`, `Info`.
  - 100 MB file from CD0: to RAM:, MD5 matches the host, time noted.
  - Interleave: copy a large file HDF -> RAM: while copying from CD0: in a
    second shell; both MD5s match (proves R-A on the board).
  - OSD eject -> CD0: shows no disc; insert ClassicInstallCD -> new volume
    without reset; swap back.
  - Lock: a program that sends PREVENT (or the 3.2 `Eject`/lock path, if
    available -- else a small test tool) -> OSD eject refused with the
    message; after ALLOW or a reset it works.
  - Ctrl-A-A reset with the disc in: CD still mounts afterwards.
  - Serial CDB log reviewed; section 7.2 trimmed or extended from it.
- 1.9 Board acceptance, other setups: CD on port 1 slave with the stock 3.2
  ROM (no AtapiMagic) mounts with Unit=1; KS 3.1 40.68 + IDEfix97 finds the
  drive on port 2 and CacheCDFS mounts it; an HDF on port 2 slave with
  AtapiMagic (slot-agnostic check).
- 1.10 doc: a user how-to (OSD steps, AtapiMagic/IDEfix97 install, the CD0
  mount entry per table 4, "not bootable"), README feature list, backlog
  item closed.

### Phase 2 -- polish

- 2.1 Streaming in the firmware (DRQ as soon as the first 512 bytes are in,
  `nrdy` covers gaps); measure the gain against 1.8.
- 2.2 Only if R4 shows up: DRDY mask for ATAPI units.

### Phase 3 -- BIN/CUE and CD audio (rough size)

- CUE parser from bincue.c (file-backed); 2352-byte tracks need the 16-byte
  header skipped (via `sector_buffer`, or an RTL skip counter in the direct
  path).  READ CD (BE), READ TOC with audio tracks, PLAY AUDIO MSF/10,
  PAUSE/RESUME, READ SUB-CHANNEL with position, MODE SELECT page 0E volume.
  Audio through audiotrack.c into the 32 KB host audio buffer (shared with
  drive sounds -- arbitration needed).  ScanDirectory gets an extension
  list ("ISO"+"CUE").  Firmware ~6-8 KB, RTL 0-30 LUTs; about the size of
  phase 1 again.

### Phase 4 -- CD32 (Akiko)

- Akiko CD controller at $B80000, CD32 ROM 40.60 + extended ROM, its own
  command protocol (MiSTer `akiko_cd32.cpp`, 1634 lines).  Independent of
  IDE; shares atapi.c/cdrom.c's image layer.  Larger than phases 1-3
  together; not estimated further.

## 11. Decisions and risks

Paul's decisions (2026-10-12):

- D1: the CD-ROM's default place is **port 2 master**.  Amiga side needs
  AtapiMagic (3.1.4/3.2) or IDEfix97 (3.1); not bootable (accepted, D6).
  The CD stays a slot type, so port 1 remains possible.
- D2: one Gayle if sufficient, two if needed and the FPGA allows.  Applied
  as ruling R-A: two port instances (section 7.3; fits, section 6).
- D3: one CD drive.
- D4: no port-2 on/off line; port 2 is on when one of its slots is
  configured.  A CD slot counts with or without a disc.
- D5: OSD eject (and swap) is refused while the Amiga has locked the drive.
- D6: no CD boot; the custom-ROM experiment is dropped.
- D7: IDENTIFY model and INQUIRY product carry the ISO name.

Rulings made while reconciling (for Paul to overrule):

- R-A: two port instances from phase 1 (section 7.3).  If wrong: ~190 LUTs
  and 2 BRAM36 spent that a single instance would have saved.
- R-B: the D1 default applies to fresh configs only; existing config files
  keep port 2 empty until the user sets it (no config version bump, so
  older firmware still loads new configs).  If wrong: Paul sets the slot
  once in the OSD.
- R-C: INQUIRY vendor stays "MINIMIG "; the product field is the first 16
  characters of the ISO name; an empty drive reports "CD-ROM (empty)".
- R-D: the lock is cleared by an Amiga reset, as on a real drive.
- R-E: HDFs are also allowed in port 2 slots (the type cycle is the same on
  both pages; costs two more hdfTYPE in BSS).

Risks:

- R2 **Command subset mismatch** -- no capture yet of what OS 3.2
  CDFileSystem / scsi.device / AtapiMagic / IDEfix send.  Mitigation: the
  serial CDB log (1.6), ILLEGAL REQUEST for anything unknown.
- R4 **DRDY always set** on the ATAPI unit; if a driver mistakes it for ATA,
  add the mask (2.2).
- R5 **832 loop timing** -- the firmware serves one command at a time and
  blocks in its data loops (as the ATA path does today); a port 0 command
  waits (BSY) while a CD transfer runs.  Drivers wait seconds; heavy floppy
  and CD use at once may stutter, as HDF + floppy can today.
- R6 **Older firmware** shows a garbage type string for a CD in a port 1
  slot (array overrun on `config_hdf_msg`); harmless for the default port 2
  slot.  Release note.
- R7 **3.1.4 ATAPI** inferred, not verified on a 3.1.4 ROM here (only
  matters for a CD on port 1 with 3.1.4).
- R8 **AtapiMagic is alpha** (Hyperion); if it misbehaves with the
  emulation, IDEfix97 is the fallback and the serial log shows the
  difference.
- Former R1 (interleaving on shared registers) and R3 ($DA3018 aliasing)
  are removed by R-A; bench cases 1.1 (g)/(h) and acceptance 1.8 guard
  them.

## 12. Implementation notes

### 12.1 Phase 0 (2026-10-12)

What exists: `fw/ctrl_832/atapi.c/.h` (command layer, pure C),
`fw/ctrl_832/cdrom.c/.h` (glue skeleton, linked, called by nothing),
`fw/ctrl_832/test/atapi_test.c` + `Makefile`.  `make -C fw/ctrl_832/test`
builds with host gcc (`-DHOSTTEST`, ASan/UBSan) and runs 18 cases; the
ISO-backed case reads `~/work/amiga/AmigaOS3.9.iso` (override `ISO=`) and is
skipped without it.  RED first: the test did not compile without atapi.h,
then did not link with only the header.  Eleven hand mutants of atapi.c
(MSF without the pregap, ATA string byte order, UA not one-shot, lock
ignored by START STOP / OSD eject, reset keeping the lock, overflowing range
check, no truncation, GESN not exempt / not one-shot, MODE SENSE length) all
fail it.

Size: 832l drops unreferenced sections, so the phase 0 image is
byte-identical to 8208e2b (built both with one frozen version.h).  The
< 20 KB check was done on a measurement-only build (not committed) that
referenced the CD entry points from main.c: text +4,150, rodata +56, data
0, BSS +6,540 (atapi_buf 2 KB, cdromTYPE 4.4 KB) -- 10.7 KB in all
(atapi.o 3,645 text, cdrom.o 494).
Phase 1's map shows the real figure once hdd.c calls CD_HandleCommand.

### 12.2 Rulings

- Ruling: the glue's global is `cdrom`, not `cd` -- main.c:245 already
  defines `struct cdimage cd` (bincue leftover) and 832l linked two `_cd`
  symbols without a word -- cost if wrong: none; section 8's
  `HardFileSeek(&cd, ...)` reads `HardFileSeek(&cdrom.hdf, ...)`.
- Ruling: `CD_Insert(name, long_name, dir)` instead of `CD_Insert(name, dir)`
  -- the 8-character short name opens the file, the long name feeds
  IDENTIFY/INQUIRY (D7) and FileOpen does not fill `long_name` -- cost if
  wrong: one argument.
- Ruling: the lock policy lives in atapi.c: `atapi_eject()` and
  `atapi_insert()` return `ATAPI_LOCKED` while locked; `CD_Eject`/`CD_Insert`
  only wrap them (so D5 is host-tested) -- cost if wrong: none.
- Ruling: `atapi_identify(uint16_t id[256], unit)` fills word VALUES with
  ATA strings first character in bits 15:8, as IdentifyDevice() does; the
  glue sends each word low byte first like ATA_IdentifyDevice().  SCSI
  responses are byte streams sent in buffer order, as hdd.c sends
  sector_buffer and as the direct SD path delivers file bytes (MiSTer's
  pkt_send uses one lane order for both too) -- cost if wrong: swapped
  strings or data, visible at the first INQUIRY on the board.
- Ruling: `atapi_packet`'s `limit` is accepted but unused; DRQ block
  splitting is the glue's job -- cost if wrong: none.
- Ruling: `atapi_result.ejected` added -- an Amiga-side START STOP eject must
  tell the glue to drop the file -- cost if wrong: none.
- Ruling: check order = exempt commands, then a pending UNIT ATTENTION, then
  the no-disc rule, then the opcode.  So after a reset with no disc: 06/29/00
  once, then 02/3A/00 (SPC reports UA first); an unknown opcode with no disc
  gets 02/3A/00 (as MiSTer), with a disc 05/20/00 -- cost if wrong: a driver
  that probes an empty drive sees one extra CHECK.
- Ruling: sense = the last command's (GOOD clears it).  REQUEST SENSE with
  nothing stored reports a pending UA (and clears it), else 02/3A/00 with no
  disc (MiSTer load_state 3), else NO SENSE -- cost if wrong: a driver that
  polls REQUEST SENSE on an empty drive sees NOT READY, which is the truth.
- Ruling: an eject leaves a pending UA in place (06/28/00 then 02/3A/00) --
  cost if wrong: one extra CHECK after a very fast insert+eject.
- Ruling: READ TOC keeps the full TOC data length when the allocation
  length cuts the transfer (MMC).  MiSTer instead shortens the TOC and the
  length field, for OAKCDROM.SYS (DOS) -- cost if wrong: an Amiga driver
  with the same bug rejects the TOC; the CDB log (1.6) would show a short
  allocation length.
- Ruling: READ TOC format from CDB byte 9 bits 7:6 when byte 2 bits 3:0 are
  0 (SFF-8020 drivers); starting track 0/1 = both entries, 0xAA = lead-out
  only, anything else 05/24/00 -- cost if wrong: none for format 0.
- Ruling: READ TRACK INFORMATION returns 28 bytes (length 26) with the track
  size at bytes 24-27, not the 24 bytes of 7.2 (MiSTer's 24-byte answer
  carries length 20 and a mangled start address) -- cost if wrong: 4 bytes
  more for a driver that asks for more than 24.
- Ruling: GET EVENT STATUS: non-polled requests 05/24/00; a request without
  the media class gets the 4-byte NEA header; the event is consumed only
  when the descriptor was transferred (allocation length > 4) -- cost if
  wrong: none.  Note: MiSTer does not implement 0x4A at all (it answers
  05/20/00), so "debugged against Amiga drivers" does not cover it.
- Ruling: GET CONFIGURATION with a starting feature other than 0 returns
  the 8-byte header only (MMC), not MiSTer's 05/24/00; current profile
  0x0008 even with no disc, as 7.2 says (MMC would say 0) -- cost if wrong:
  none seen.
- Ruling: INQUIRY allocation length = CDB byte 4 only (SPC-2, MiSTer); EVPD
  -> 05/24/00.  Name bytes outside 0x20..0x7E become '_' (INQUIRY and
  IDENTIFY); a disc with an empty name reports "CD-ROM" -- cost if wrong:
  none.
- Ruling: MODE SENSE ignores page control (current values for every PC),
  medium type 0 (as MiSTer), no block descriptors; page 2A reports tray,
  eject, lock and the lock state, 706 KB/s (4x), 64 KB buffer; MODE
  SELECT(6) (0x15) is not in 7.2 and gets 05/20/00 -- cost if wrong: a
  driver that saves pages sees 05/20/00 on 0x15.
- Ruling: READ SUB-CHANNEL: SubQ=0 header only; format 1 the position at
  the start of track 1; formats 2/3 20 bytes with the valid bits clear;
  others 05/24/00 -- cost if wrong: none until phase 3.
- Ruling: READ(10)/(12) with count 0 is GOOD without a range check; the
  range check cannot overflow (`count > sectors - lba`) -- cost if wrong:
  none.
- Ruling: capacity = file size / 2048 (a partial last sector is ignored).
  AmigaOS3.9.iso's PVD says 245,383 blocks, the file has 245,535 sectors;
  READ CAPACITY / TOC report the file -- cost if wrong: none, the extra
  sectors are padding.
- Ruling: `CD_Insert` ejects first; if the new file then fails to open the
  drive is left empty (REMOVED event) and `CD_NOFILE` is returned -- cost if
  wrong: the OSD shows an empty drive instead of the old disc.
- Ruling: `CD_HandleCommand` is an abort stub (error 0x04, END|IRQ|ERR)
  until 1.4 -- not called in phase 0.
- Ruling: hdd.h got an include guard (cdrom.h includes it; vbcc warned
  "redeclaration of typedef hdfTYPE") -- no code change.
- Ruling: the host test builds with `-Wno-unused-parameter`; vbcc warns
  "statement has no effect" on `(void)x;`, so the firmware sources do not
  use that idiom -- cost if wrong: none.

### 12.3 Open for phase 1

(The long-name and error-register points are settled in 12.5; the
duplicate-symbol check was done, 12.4.)

- `hardfileTYPE.long_name` is 16 bytes: the power-on disc (CD_Open from the
  config) can give IDENTIFY only 16 characters of its name, an OSD insert
  the full long name (D7 says 40).  Cosmetic; accept or keep the long name
  elsewhere.
- 7.1 sets the error register to `(sense key << 4) | 0x04` (ABRT) on every
  CHECK; MiSTer sets `sense key << 4` only (plus MC for a UA).  Decide in
  1.4; `atapi_result` carries the sense.
- 832l accepts duplicate global symbols silently -- check every new global
  in phase 1 against `grep -n " _<name>$" 832OSDAD.map`.
- MiSTer handles neither 0x4A (GESN) nor 0x1A (MODE SENSE(6); its "case
  0x03 // mode sense" is REQUEST SENSE), so those answers are unproven on
  Amiga drivers; the CDB log (1.6) should be read with that in mind.

### 12.4 Phase 1, tasks 1.1-1.6 (2026-10-12)

Commits on `cdrom`: 168f71d (RTL + bench, 1.1/1.2), bc7d5f6 (firmware port
plumbing, 1.3), 11b2f94 (CD glue + serial log, 1.4/1.6), 7aaef6d (OSD, 1.5).

- RTL: `gayle.v` keeps the shared Gayle registers and instantiates
  `gayle_port.v` per port (`IDE_PORTS`, default 2); `gayle_fifo.v` exports
  its pointers; `paula_floppy.v` latches the port bit (bit 8 of every HDD
  command's first word, passed through on the decoded word itself so the
  status write acts on its own port), decodes 1100 (`hdd_xfer_wr` at
  rx_cnt 1) and strobes `hdd_regs_rd` on the 1000 command word;
  `ide_config0/1` are 5 bits from userio_osd.v to gayle; minimig.v sets
  CORE_CAPS bit 7.  gayle_port.v is in minimig.qip, rebuild.tcl,
  .hdl_checker.config and the five tracked tools/vivado/build*.tcl (the
  untracked build_no_ddr3_clean.tcl in the main checkout needs the same
  `add_src $R/rtl/minimig/gayle_port.v`).
- Bench `sim/gayle/run.sh` (iverilog), cases (a)-(i) as task 1.1.  (a)'s
  trace (838 lines: irq/nrdy/cmd_req/dat_req changes and every value read)
  was recorded from 8208e2b's gayle.v (`./run.sh golden`) and matches
  bit for bit.  `./run.sh old`: (a) passes, (b)-(i) all fail.  Teeth:
  `mut_nopkt` fails (b)(c)(d)(h), `mut_shared` fails (b)(e)(f)(g)(h)(i).
  (i) as first written passed on the old Gayle too (its decode already
  gated $DA1xxx/$DA3xxx with hdd1_ena); it now also checks that firmware
  writes for port 2 do not reach port 1, which the old Gayle fails.
  sim/osd_keyq gained the 5-bit OSD_CMD_HDD/HDD1 check (fails on the
  3-bit userio_osd.v); sim/hdmi_upsample osdspi still passes.
- yosys synth_xilinx estimate: gayle 191 -> 557 LUT (+8 RAM32M for the
  task files), 59 -> 148 FF, 2 -> 4 RAMB36 -- inside section 6's +330-430.
  Vivado numbers come with 1.7.
- Firmware: host test `fw/ctrl_832/test/cdrom_test.c` (20 cases) links
  the real cdrom.c/atapi.c against a model of the Gayle port in packet
  mode and an ATAPI host that checks every phase; RED first (1 of 20
  against the phase 0 stub); 11 of 12 hand mutants of cdrom.c fail it
  (the 12th, ignoring rst_seen in the wait loop, is equivalent: a reset
  also clears packet mode).
- Size vs phase 0 (64,092 / 15,750 / 3,460 / 30,672): text 73,751,
  rodata 16,561, data 3,465, bss 46,652; .bin 93,797 bytes; image end
  0x18e65, bss end 0x244a4 (AUDIO_BUFFER 0x70000).  No duplicate globals
  in the map (only the linker's `_STACKTOP`, as before).

### 12.5 Rulings, phase 1

- Ruling: the sticky flags (dev_wr, rst_seen) are captured and cleared by
  the CMD_IDE_REGS_RD command word of that port (new `hdd_regs_rd`
  strobe), not when register 7 is read -- an event during a read then
  shows in the next read instead of falling between the reg-7 word and
  the clear -- cost if wrong: none; one more paula_floppy output.
- Ruling: xfer_done is not read-to-clear; it holds until the next
  CMD_IDE_XFER_WR, host command or reset -- the firmware polls it and
  hdd_dat_req follows it -- cost if wrong: none.
- Ruling: packet-mode interrupts -- a pio-in data phase interrupts on the
  DRQ edge (the ATA block_mark logic: the pio-in status write arms it), not
  on the status write as 7.3 item 6 said; a status write with IRQ and
  without pio in (data-out start, status phase) interrupts at once -- the
  host never sees the interrupt before the data (bench c) -- cost if
  wrong: none seen.
- Ruling: at the end of a pio-out transfer pio_out stays set (only pio in
  ends) so the firmware can drain the FIFO (`fifo_rd` follows pio_out);
  CMD_IDE_XFER_WR clears both directions -- cost if wrong: none.
- Ruling: in packet mode the host's task-file reads use the bus address
  while busy (the one-port Gayle returned tfr[hdd_addr] to a host reading
  during BSY, which an ATA host never does, but an ATAPI host reads the
  interrupt reason and byte count then); the firmware's reads use hdd_addr
  busy or not (it reads idle ports for the flags) -- port 1 ATA unchanged
  (golden trace) -- cost if wrong: none.
- Ruling: the signature mux ends per register: a host write to register
  1-5 ends it for that register only, a command for all -- drivers probe
  a drive after reset by writing the count/sector registers and reading
  them back -- cost if wrong: none.
- Ruling: `IDE_PORTS = 1` does not decode $DA1xxx/$DA3xxx at all (the old
  Gayle mapped them onto port 1's registers) -- nothing ever enabled port
  2 before -- cost if wrong: a one-port target loses a port 2 that never
  worked.
- Ruling: CORE_CAPS bit 7 = two-port Gayle with packet mode; without it the
  firmware keeps port 2 off and offers no CD-ROM -- new firmware on an old
  core would otherwise put port 2 on port 1's registers -- cost if wrong:
  one capability bit.
- Ruling (12.3): PACKET error register = sense key << 4, plus ABRT only for
  ILLEGAL REQUEST (05) and ABORTED COMMAND (0B); no MCR -- ATA/ATAPI-4: ABRT
  for an aborted command or an invalid command/parameter; NOT READY, UNIT
  ATTENTION and MEDIUM ERROR are neither; MiSTer (debugged against Amiga
  drivers) sets no ABRT at all -- cost if wrong: a driver that keys on ABRT
  alone misses 02/06/03 errors, but drivers read the sense after ERR.
- Ruling (12.3): the 16-byte config long name is accepted -- the power-on
  disc reports at most 16 characters of its name, an OSD insert the full
  name (40 for IDENTIFY, 16 for INQUIRY) -- cost: cosmetic.
- Ruling: DEVICE RESET (08) writes the signature (status bit 5) without an
  interrupt and leaves lock and UNIT ATTENTION alone (as MiSTer); IDENTIFY
  DEVICE (EC) writes the signature into the registers itself, so the error
  register keeps ABRT (the mux would show 01) -- cost if wrong: a driver
  expecting 06/29 after DEVICE RESET does not get one.
- Ruling: READ data-in blocks are min(limit, 8 KB) rounded down to 512
  bytes (the direct SD transfer moves 512-byte FAT sectors); a limit below
  512 still gets 512-byte blocks -- cost if wrong: a driver with such a
  limit gets more per DRQ than it asked for.
- Ruling: each phase waits at most 10 s for the host, then the transfer is
  dropped and the command ends with ABORTED COMMAND 0B/00/00 (error B4) --
  the 832 must not hang the OSD on a dead driver -- cost if wrong: none.
- Ruling: an SD read error during a READ drops the transfer (FIFO reset,
  no DRQ, no stall) and ends with MEDIUM ERROR 03/11/00 (error 30) -- the
  host may read garbage words of that block; the status says so.
- Ruling: an Amiga reset (rst_seen) or a command written over a running
  one (packet mode gone) ends the CD command without a status -- the Gayle
  reset already cleared BSY -- cost if wrong: none.
- Ruling: rst_seen is acted on wherever a register read sees it
  (HandleHDD, the wait loops, and CD_Locked, which reads the CD port's flags
  while the drive is locked) -- the OSD eject works right after an Amiga
  reset without waiting for a CD command (R-D) -- cost if wrong: none.
- Ruling: `cdromTYPE.active` marks a configured drive (BSS zero = none; slot
  0 is a real slot), read through CD_SLOT() -- cost if wrong: none.
- Ruling: an Amiga-side eject clears the slot's config name as the OSD
  eject does (5.3: the RAM config names the disc in the drive) -- cost if
  wrong: none.
- Ruling: cycling a slot to CD-ROM clears its name (an HDF name is not a
  disc); a disc chosen for a CD slot that is not live yet (pending reset,
  IDE off) is stored without a reset prompt -- cost if wrong: none.
- Ruling: the CD drive is live only with IDE on and a two-port core; main
  page line 6 says "not configured" otherwise, also for a CD slot that only
  becomes live at the next reset -- cost: a slightly misleading word until
  the reset.
- Ruling: page 2 shows a disabled slot's file line stippled, as page 1
  does, so the plan's blank line 3 is the slave's file line; the note is on
  lines 4-6 -- cost: none.
- Ruling: OpenHardfile marks a slot disabled until it opens (before, a
  failed open kept the previous type and file size and could serve the
  previous file) -- cost if wrong: none; an absent device is already off in
  ide_config.
- Note on 12.2's byte-order ruling: MiSTer's rtl/gayle.v swaps the lanes
  between the 68k and its ide.v (`io_writedata = {data_in[7:0],
  data_in[15:8]}`), so in MiSTer too file byte 0 and CDB byte 0 sit at the
  68k's even address -- the same lane order as this Gayle's FIFO.  The
  first INQUIRY on the board is still the proof.

