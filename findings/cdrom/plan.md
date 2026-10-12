# CD-ROM drive from an ISO on the SD card -- implementation plan

Status: plan only, nothing implemented (2026-10-12).  Written against commit
3987715 (superproject 5.0-040-pipelined), the backlog sketch in
doc/backlog.md "CD-ROM drive from an ISO on the SD card", the local RTL and
firmware, MiSTer's Main_MiSTer `ide.cpp`/`ide_cdrom.cpp` and Minimig-AGA_MiSTer
`rtl/ide.v`, WinUAE `ide.cpp`/`gayle.cpp`/`blkdev.cpp`, and the OS 3.1.4.1 /
3.2.2 / 3.2.3 release notes and ROM images under ~/work/amiga.  Every claim
below that I could check is marked with where; anything I could not check is
marked UNVERIFIED.

Reference copies used (session scratch, will vanish; re-clone if needed):
`git clone --depth 1 https://github.com/MiSTer-devel/Main_MiSTer`
(ide.cpp, ide_cdrom.cpp, ide.h), `https://github.com/MiSTer-devel/Minimig-AGA_MiSTer`
(rtl/gayle.v, rtl/ide.v, README.md), `https://github.com/tonioni/WinUAE`
(ide.cpp, gayle.cpp, blkdev.cpp).

## 0. Answers in one screen

1. **Menu**: put the CD-ROM in the existing Harddisks menu as a slot type
   ("CD-ROM (ISO)" is one more value of a slot's type, next to Hardfile and
   SD card), with the two secondary-channel slots on a second Harddisks page,
   plus one quick "CD-ROM: <name>" line on the main page for insert/eject
   without a reset.  Not a separate CD-ROM menu: the slot type is what decides
   the IDE position Paul wants to choose, and the config already has room for
   exactly four slots.  Screens in section 5.
2. **Bus**: a real "own IDE bus" that stock Amiga software sees does not exist
   on an A1200-class machine.  What exists, and what the RTL half-implements
   already, is the Gayle **IDE splitter/doubler** scheme: the second chip
   select ($DA1xxx/$DA3xxx) is a second IDE port with its own master/slave.
   MiSTer and WinUAE emulate exactly this.  Its catch: the stock scsi.device
   (3.1, 3.1.4 and 3.2) only drives the first port; the second port needs
   AtapiMagic (Hyperion, free, 3.1.4/3.2) or IDEfix97 (shareware) on the Amiga
   side, and nothing can boot from it.  Recommendation: implement the CD as a
   type any of the four slots can take (primary/secondary x master/slave), use
   **primary slave** for the first bring-up (works with a stock 3.2 ROM and no
   Amiga software), and let Paul set **secondary master** once AtapiMagic is
   installed.  A4000 IDE or a Zorro ATAPI board: rejected (section 2).
3. **Boot from CD**: not with any stock A1200 ROM.  KS 3.1 (40.68) has no
   ATAPI in scsi.device at all; KS 3.1.4 and 3.2 have ATAPI in scsi.device
   (3.2 verified by the "NuATAPIismajik" string in A1200.47.111/47.115) but no
   CDFileSystem in ROM (verified: no such string in the 3.2 ROMs), so the boot
   strap has nothing to mount the CD with.  Booting becomes possible only with
   a custom Kickstart that includes CDFileSystem 48.52+ (OS 3.2.2 added a ROM
   tag for it, "your mileage may vary"), which Minimig can load because it
   takes any 512 KB / 1 MB ROM image.  CD32 boot is a separate, later project
   (Akiko).  Details in section 3.
4. **Amiga software**: table in section 4.  Short form: KS 3.2 ROM + the
   Install3.2 disk's L:CDFileSystem + Storage/DOSDrivers/CD0 (unit number set
   to the slot) and nothing else, if the CD is on the primary channel; add
   AtapiMagic for the secondary channel; KS 3.1 needs IDEfix97 (atapi.device
   + CacheCDFS) or AmiCDFS/AsimCDFS on top of a third-party atapi.device.
5. **Fit**: yes.  Gayle today is ~190 LUTs / 59 FFs / 2 BRAM36 by a yosys
   synth_xilinx estimate (section 6); the ATAPI additions are ~60-120 LUTs and
   no BRAM in the single-register-file design, ~200 LUTs + 2 BRAM if the
   secondary channel later gets its own register file and FIFO.  Design is at
   84.25 % LUTs, 60 % BRAM; margins hold.  Timing: Gayle runs on clk_28 with
   clk7_en, nothing new is on the tight clk_114/clk_148 paths.  Firmware:
   the 832 runs from SDRAM, not BRAM; the image is 82 KB code+data, BSS ends at
   0x1d72c, and the next fixed user is the audio buffer at 0x70000, so about
   330 KB headroom; ATAPI + OSD code is 8-15 KB.  No budget problem.

## 1. What exists today (verified)

### 1.1 Gayle RTL -- rtl/minimig/gayle.v, gayle_fifo.v

- One task-file register file `tfr[7:0]` (8 x 8 bit) and ONE 4096-word FIFO
  (8 KB, `gayle_fifo.v`) shared by both channels and both devices.  The
  firmware writes/reads the tfr via SPI (`hdd_addr`, `hdd_wr`), the host via
  $DA0xxx/$DA2xxx (`address_in[4:2]` = register).
- Secondary channel = address bit 12 (`sel_tfr` accepts `address_in[12]` only
  when `|hdd1_ena`, gayle.v:180).  `dev <= {address_in[12], data_in[12]}` on a
  drive/head write (gayle.v:260).  Status reads return 0x00 for a device whose
  enable bit is clear (gayle.v:400), otherwise the single shared status.  This
  is the IDE-splitter mapping, identical to MiSTer (`port_num = addr[12]`,
  "0xda3018 Control (not used because of 4xIDE)") and to WinUAE
  (`IDE_SECONDARY` in `get_gayle_ide_reg`, `ide_splitter` set when drives 2/3
  exist).
- The firmware receives `dev[1]` (channel) in bit 8 of every tfr read
  (`hdd_data_in = {7'h0, dev[1], tfr_out}`, gayle.v:243) -- and hdd.c
  discards that byte (`SPI(0); tfr[i] = SPI(0);`, hdd.c:589-590).  Bits 15:9
  of that word are free: the natural place for new flags.
- Data phases are hard-wired to 512-byte blocks: `fifo_full` means >= 512
  bytes (gayle_fifo.v:66), `last_in/last_out` fire every 256 words, the
  `sector_count` down-counter clears `busy` when it hits 1 (gayle.v:299),
  `drq = fifo_full & pio_in | ~fifo_full & pio_out & sector_count != 0`
  (gayle.v:358), and the firmware only learns of host-written data when the
  FIFO is full (`hdd_dat_req = fifo_full & pio_out`).  **None of this works for
  ATAPI**: the 12-byte command packet (6 words out), REQUEST SENSE (18 bytes
  in), INQUIRY (36), READ CAPACITY (8), READ TOC (12-20) never fill 512
  bytes.  RTL changes are required (section 7.3).
- No device control register (SRST/nIEN) -- $DA3018 would decode as the
  secondary channel's drive/head register when hdd1_ena is set.  Same in
  MiSTer; splitter-aware drivers do not use it.  Noted as a quirk.
- `tfr` is not cleared on reset; the firmware's `ATA_Diagnostic` writes
  error=1 and zeros, not even the ATA signature (hdd.c:314).  Works with
  scsi.device 3.1 today.
- `nrdy = pio_in & sel_fifo & fifo_empty` (gayle.v:397) stalls the 68k on an
  empty FIFO -- usable for streaming.
- IRQ: `intreq` on the rising edge of drq after a status write with bit 4
  (pio in), on each bit-4 status write (pio out), or on the END write for
  non-data commands (gayle.v:317-327).  `irq = intreq & intena`.

### 1.2 Firmware -- fw/ctrl_832/hdd.c, paula_floppy.v SPI protocol

- `HandleHDD` (hdd.c:567) runs on `CMD_IDECMD` (bit 2 of status byte 0,
  `paula_floppy.v:394`), reads 8 tfr registers with CMD_IDE_REGS_RD (0x80),
  takes `unit = tfr[6] & 0x10` (master/slave only), dispatches ATA commands
  0x10 0x90 0xEC 0x91 0xC6 0x20 0xC4 0x30 0xC5, anything else -> ABRT.
- SPI commands to the HDD block are the top nibble of the first SPI word in
  paula_floppy.v:736-739: 1000 regs read, 1001 regs write, 1010 data write,
  1011 data read, 1111 status write (hdd.c WriteStatus bits: 0x80 END, 0x10
  IRQ, 0x08 pio-in, 0x04 pio-out, 0x01 ERR).  Nibbles 1100/1101/1110 are
  unused -> room for one new IDE command.
- Direct SD-to-FPGA streaming: `FileReadEx(file, NULL, n)` ->
  `MMC_ReadMultiple(lba, 0, n)` asserts the second chip select so the SD
  data goes straight into the Gayle FIFO (`hdd_data_wr = ... || (scs2 &&
  rx_flag)`, paula_floppy.v:343).  A 2048-byte CD sector is four such
  blocks: `HardFileSeek(&cd, lba*4); FileReadEx(&cd.file, 0, 4)`.
- `hdfTYPE` carries a 1024-entry cluster index (4 KB) built once per file;
  for a 700 MB ISO `index_size` becomes 20 (1 MB granularity, 700 entries) --
  reusable as is for the ISO.
- `ConfigIDE` (osd.c:920) sends only OSD_CMD_HDD (0x54 = SPI address
  0_101_01) for `ide_config0`; `ide_config1` (SPI address 0_101_10, i.e.
  command byte 0x58) is never written, so the secondary channel is dormant.
  `userio_osd.v:449-450` takes `wrdat[2:0]` for each.
- Reset detection: the firmware never learns of an Amiga-initiated reset
  (keyboard reset); HandleFpga only polls floppy/IDE requests.

### 1.3 Config and OSD

- `configTYPE` (config.h) is 212 bytes, checked at compile time
  (`config_size_is_212`, config.c:259).  `hardfile[2]` = primary M/S;
  `secondaryhardfile[2]` reserved and unused except being zeroed for
  configs older than CONFIG_VERSION_ROMPATH (config.c:300-315);
  `hdfdir[4]` already has four directory slots.  `hardfileTYPE` = enabled,
  present, name[8], long_name[16] (26 bytes).
- OSD is 8 lines x 32 characters (`framebuffer[8][256]`, 8 px per char,
  `OsdWriteOffset` line limit OSDLINELEN=256; the title is a separate
  vertical strip).  Line 7 loses 22 px when the right arrow is shown.
- Main page (menu.c:515-565): lines 0-3 floppies, 4 "Floppy disk settings",
  5 "Hard disk settings", **6 empty**, 7 exit.  Harddisks page
  (menu.c:1674-1740) uses all 8 lines: IDE on/off, Master type, Master file,
  Slave type, Slave file, Sounds, blank, back.  Changes apply after a reset
  via MENU_HARDFILE_EXIT/CHANGED (menu.c:1888-1966).
- `SelectFile(ext, SCAN_DIR|SCAN_LFN, okstate, cancelstate)` (menu.c:160)
  compares one 3-letter extension; `ScanDirectory` (fat.c:858) matches
  exactly one extension or '*'.  MAXDIRENTRIES = 8 (one OSD page).
- `config_hdf_msg[]` (menu.c:90) has 7 entries indexed by
  `enabled & HDF_TYPEMASK`; a new type value 7 must extend it, and an OLD
  firmware shown a config with 7 in `hardfile[]` would read past the array
  (display garbage only; OpenHardfile's switch ignores unknown types).

### 1.4 The 2020 leftovers (AMR)

- `bincue.c` (189 lines): a CUE parser with a hard-coded test cue string and
  `cdimage`/track structures; `main.c:284` call commented out.  Parser logic
  is reusable for Phase 3 (BIN/CUE); it needs a file-backed line reader and
  removal of the embedded cue.  Not needed for ISO.
- `audiotrack.c` (167 lines): red-book playback through the host audio
  buffer (`AUDIO_BUFFER` 0x70000, 32 KB, `AUDIO` register).  Reusable for
  Phase 3 CD audio (PLAY AUDIO MSF/10, PAUSE/RESUME) -- the mechanism (fill
  the buffer the hardware is not playing) is right.
- `akiko.c` + `rtl/minimig/akiko.v` (77 lines) + `rtl/akiko/akiko.vhd`
  (221 lines): register logging stub and a corner-turn (chunky-to-planar)
  unit.  Phase 4 only (CD32).  Nothing in them touches IDE.

### 1.5 Resources and timing (build/stage_postchip)

- utilization.rpt: Slice LUTs 53,417 / 63,400 (84.25 %), registers 26,112
  (20.59 %), BRAM 81 / 135 tiles (60 %), DSP 44 / 240.  No hierarchical
  report in that build directory.
- timing_summary.rpt: clk_114 WNS +0.134, clk_148 +0.063, clk_38 +0.217,
  clk_ddr100 +1.354; the one failing group is clk_gen_sdram -> clk_114
  (-0.474, 16 endpoints), pre-existing and unrelated to Gayle.  Gayle sits on
  the 28 MHz domain with clk7_en.
- yosys `synth_xilinx -family xc7` on gayle.v + gayle_fifo.v (scratch, not a
  Vivado run): gayle 147 LUT (31 LUT2, 63 LUT3, 8 LUT4, 11 LUT5, 34 LUT6) +
  7 MUXF7 + 32 FDRE + 2 CARRY4; gayle_fifo 44 LUT + 27 FDRE + 8 CARRY4 +
  2 RAMB36E1.  Total ~190 LUTs, 59 FFs, 2 BRAM36 tiles.  Vivado numbers will
  differ a little, the order of magnitude is what matters here.
- Firmware memory: boot ROM 8 KB BRAM (`832_bridge.vhd` maxAddrBitBRAM=12),
  `832OSDAD.bin` loaded by the boot loader at host 0x2000 **in SDRAM** (host
  window `zmAddr = {... ~hostAddr[22], ~hostAddr[21], hostAddr[20],
  ~hostAddr[19], ...}`, sdram_ctrl.v:287).  Map: text/data 0x2000-0x15f5a
  (82 KB; hdd.o 0x83f8-0x9cfd = 6.4 KB, menu.o 0xa0f6-0x11052 = 28 KB),
  BSS 0x15f5c-0x1d72c (hdd.o BSS 9.6 KB = two hdfTYPE + id buffer).  Next
  fixed address above BSS: `AUDIO_BUFFER` 0x70000 (hardware.h:33).  The boot
  loader's `LoadFile` has no size limit other than that.  Stack lives in
  the 8 KB BRAM (`-s_STACKTOP=0x2000`); keep new buffers static, not on the
  stack.

### 1.6 Amiga side (what the ROMs and notes say)

- `~/work/amiga/Update3.2.3/ROMs/A1200.47.115.rom` and 47.111: contain
  `scsi.device` and `NuATAPIismajik` (ATAPI code present), **no**
  `CDFileSystem` string.  `Kickstart-v3.1-rev-40.68-A1200.rom`: scsi.device,
  no ATAPI string.  The 3.1.4 "to_burn" hi/lo halves did not yield strings
  with simple interleaving (probably EPROM-swapped); 3.1.4 ATAPI support is
  therefore UNVERIFIED locally, but the 3.1.4.1 scsi.device notes (45.4,
  "SCSI_INQUIRY should now return the correct drive type ... for compact
  flash and atapi devices") show ATAPI handling existed in 45.x.
- OS 3.2.2/3.2.3 `ReleaseNotes/L/CDFS-RelNotes`: 48.44 "preparations for
  making it possible to use ISO image files instead of mass storage devices";
  48.49 "ReMount() no longer expects the mass storage device driver to
  support TD_CHANGESTATE"; 48.52 "Added a ROM tag which should allow for
  making the file system resident and possibly boot with it.  Your mileage
  may vary."; 48.x "Revived the missing WaitIO() calls ... might be just what
  makes the difference ... for other devices, e.g. those which emulate a
  CD-ROM drive using a disk file".
- 3.1.4 Storage disk ships `Storage/DOSDrivers/CD0` (40.7) with
  `FileSystem = L:CDFileSystem`, device/unit via tooltypes.  The 3.2 install
  floppy ships L/CDFileSystem and Storage/DOSDrivers/CD0 (AmigaSetup notes).
- MiSTer Minimig README "IDE and CDROM": "By default up to 2 IDE devices are
  supported.  For Secondary Master/Slave devices, you have to install either
  IDEFix97 (shareware, WB3.1/3.9) or AtapiMagic (freeware, WB 3.1.4/3.2).
  Removable/CD mode allows to hot swap CDs.  Currently audio portion of CD
  isn't implemented (although playback commands should be accepted)."
- AtapiMagic 47.1 (aminet driver/media, Hyperion copyright, free download,
  LIBS:modules, "OS 3.1.4 or better", tested 3.1.4 and 3.2, alpha): gives
  "4 IDE interfaces without the need of any third party software".
- IDEfix97 3.5 (aminet, shareware with nag requesters): atapi.device, or the
  same units through scsi.device when IDEfix runs; 4-drive adapter support;
  CacheCDFS included; "MountCD" for booting from CD (separate, beta).
- Hyperion forum thread (A1200 + 4xEIDE splitter, ROM 3.1.4): the second
  channel of a splitter "is not supported by the built-in scsi.device", the
  interface's driver is needed.  Consistent with MiSTer's note.
- Test images: `~/work/amiga/AmigaOS3.9.iso` (245,535 sectors) and
  `ClassicInstallCD-53.71.iso` (275,806 sectors) are both plain 2048-byte
  ISO 9660 images (PVD "CD001" at byte 32769, size % 2048 == 0).
  Kickstarts on disk: 3.1 40.68 A1200 (kickstart/), 3.1.4 46.143 A1200
  (Update3.1/ROMs/to_burn, split), 3.2.2 47.111 and 3.2.3 47.115 A1200
  (.rom, usable directly).  OS 3.1.4 and 3.2.x floppy ADFs are present.

## 2. Question 2: which IDE bus

### 2.1 Options

| Option | Amiga side sees | Driver support | RTL cost | Verdict |
|---|---|---|---|---|
| (a1) Gayle second port = IDE splitter ($DA1xxx/$DA3xxx, `address_in[12]`) | a second IDE port with its own master/slave, units 2/3 of scsi.device once a 4-way driver is loaded | AtapiMagic (3.1.4/3.2), IDEfix97 (2.04+); stock scsi.device: no; boot: no | RTL already decodes it; firmware must honour `dev[1]`; shared tfr/FIFO stays (see risk R1) or +~190 LUT +2 BRAM for a second instance | **Implement** (it is what Paul calls "own bus" in practice) |
| (a2) A4000-style IDE at $DD2000 | only if the ROM is an A4000 ROM; scsi.device picks A1200 vs A4000 by Gayle/A4000 detection (3.2 notes: ReadGayle()) | would need the A4000 ROM and an A4000 Gayle identity; breaks A1200 behaviour | new decoder + mux, ~same as Gayle | Reject: it is still ONE port (the A4000 IDE is one channel), gains nothing |
| (a3) Zorro IDE/ATAPI board with autoconfig (Buddha, lide.device) | a new autoconfig board whose driver ROM must be supplied (Buddha flash ROM or lide.device open-source ROM) | its own driver, boot capable | autoconfig entry + register block + ROM image loader (~300-500 LUT + ROM BRAM or SDRAM mapping) + licensing of the driver ROM | Reject for now; the only route with boot from a third-party ROM; revisit if boot from CD matters more than the stock-ROM path |
| (b) a device on Gayle's existing channel (primary master or slave) | unit 0/1 of scsi.device | stock 3.1.4/3.2 scsi.device (ATAPI built in); 3.1 needs IDEfix97/atapi.device | the same ATAPI RTL changes as (a1) | **Implement** -- it is the same code with `dev[1]=0` |

### 2.2 Recommendation

Slot-agnostic: the CD is a type a slot can take; the four slots are
primary M/S (`hardfile[0..1]`) and secondary M/S (`secondaryhardfile[0..1]`).
First bring-up as primary slave with the 3.2 ROM (no Amiga software needed).
Default for a saved config: whatever the user picked; the OSD help text says
"secondary port needs AtapiMagic/IDEfix".  Keep the single register file and
FIFO in phase 1 (risk R1 below); the second-instance Gayle is phase 2b if R1
bites.

## 3. Question 3: booting from the CD

| Setup | Boots from CD? | Why / what to do |
|---|---|---|
| KS 1.3 / 2.0x / 3.0 / 3.1 (40.68) A1200 ROM | No | scsi.device has no ATAPI, no CDFS in ROM.  Boot from HDF/ADF, load IDEfix97 (atapi.device + CacheCDFS) or another atapi.device + AmiCDFS, then CD0: appears. |
| KS 3.1.4 / 3.2 (46.143 / 47.111 / 47.115) stock ROM, CD on primary | No | scsi.device sees the ATAPI unit (3.2 verified, 3.1.4 UNVERIFIED locally), but CDFileSystem is on disk (L:), not in ROM, so strap cannot mount it.  Boot the Install3.2 floppy (ADF) or an HDF; CD0 mounts with L:CDFileSystem. |
| KS 3.1.4 / 3.2, CD on secondary port | No | as above plus the port itself is invisible to the ROM. |
| Custom 3.2.2+ ROM with CDFileSystem 48.52+ resident (ROM tag), CD on primary | Possibly | Hyperion: "possibly boot with it.  Your mileage may vary."  Minimig loads any 512 KB / 1 MB ROM (config.c:90-128), so a 1 MB custom ROM has room.  UNVERIFIED; test item in phase 2. |
| OS 3.9 CD with a 3.1 ROM | No | 3.9 CD boots only on machines with CD-boot firmware; the normal route is the Emergency Disk made from the CD.  Our ISO still serves as a data CD to install from. |
| CD32 ROM (40.60) + Akiko emulation | Later | CD32 boots from its own CD controller, not IDE.  Phase 4. |
| OS 4.1 Classic ISO | n/a | needs OS4 hardware; useful only as a second test image for swaps. |

Practical consequence: "boot from CD" is not a phase-1 goal; the plan makes
the CD mountable from Workbench first.

## 4. Question 4: Amiga software per Kickstart/OS

| Kickstart / OS | Device driver for the ATAPI CD | CD filesystem | Mount entry | Free? |
|---|---|---|---|---|
| 1.3 / 2.0x (no IDE in ROM except A600 2.05) | IDEfix97 atapi.device (needs 2.04+) | CacheCDFS (in IDEfix97) | DEVS:DOSDrivers/CD0 from IDEfix installer | shareware (nag) |
| 3.0 / 3.1 (A1200 39.106 / 40.68) | IDEfix97 atapi.device, or an "A1200 Atapi" cd.device package (Aminet driver/media) | CacheCDFS, AmiCDFS 2.40 (Aminet disk/cdrom/amicdfs240, free), AsimCDFS (commercial), OS 3.1's own L:CDFileSystem 40.x works on top of a working device | CD0 with Device=atapi.device Unit=<n> | IDEfix shareware; AmiCDFS free |
| 3.5 / 3.9 on a 3.1 ROM | OS 3.5/3.9 ship a ROM-update scsi.device with ATAPI and a licensed CacheCDFS (UNVERIFIED here, from the 3.9 package description); otherwise IDEfix97 | CacheCDFS (bundled) | Storage/DOSDrivers/CD0 | included |
| 3.1.4 ROM | ROM scsi.device (ATAPI; unit 1 = primary slave) | L:CDFileSystem 45.x (Storage3_1_4.adf, verified CD0 40.7 mount file) | copy Storage/DOSDrivers/CD0 to DEVS:, set Device=scsi.device Unit=1 (or 0/2/3) in the icon tooltypes | included in 3.1.4 |
| 3.2 ROM (47.111/47.115) | ROM scsi.device (ATAPI verified) | L:CDFileSystem 47/48.x from Install3.2 | same CD0 mount file | included in 3.2 |
| 3.1.4 / 3.2 with the CD on the **secondary** port | AtapiMagic 47.1 in LIBS:modules + startup line (Hyperion, free download, alpha) or IDEfix97 | as above | Unit=2 (secondary master) / 3 | AtapiMagic free, redistribution forbidden |

Unit numbering convention (scsi.device): 0 primary master, 1 primary slave,
2 secondary master, 3 secondary slave -- with a 4-way driver loaded.

## 5. Question 1: OSD design

### 5.1 The two structures compared

| | A. slot type in the Harddisks menu | B. separate CD-ROM menu |
|---|---|---|
| expresses the IDE position (Q2b requirement) | directly: the slot IS the position | needs its own "Port/Device" selector and must then grey out the HDF slot it takes |
| config storage | the slot's `hardfileTYPE.enabled = HDF_CDROM`, no new fields | needs a new CD entry + a position byte; the only free bytes are the `secondaryhardfile` ones anyway |
| conflicts (HDF and CD in the same slot) | impossible by construction | must be checked and reported |
| insert/eject without reset | main-page quick line (needed in both) | the CD menu itself |
| code size | small: the type cycle grows by one value, the file selector gets "ISO" | a new page pair + state machine, ~2-3 KB more |
| discoverability | CD hides behind "Hard disk settings" | obvious entry |

Recommendation: A, with the main-page quick line for discoverability and
hot swapping.  B's one advantage (finding it) is covered by the main-page
line.

### 5.2 Screens (32 columns, 8 lines; `>` marks the cursor; `*` stippled)

Main page (menu.c MENU_MAIN1), line 6 was empty:

```
 df0: Workbench3.2.adf
 df1: * no disk *
 df2:
 df3: KP +/- to add/remove drives
 Floppy disk settings  >
 Hard disk settings    >
 CD-ROM: AmigaOS3.9.iso        (line 6, new; stippled if no CD slot)
             exit
```

- Select on line 6 with a disc inserted = eject (UNIT ATTENTION to the
  Amiga, line shows "* no disc *"); without a disc = file selector for ISO.
  Backspace ("eject all floppies" today) is left alone.
- If no slot is of type CD-ROM, line 6 reads "CD-ROM: not configured" and is
  not selectable (menumask bit 6 clear; exit stays on line 7 / menusub 6
  renumbering: make the CD line menusub 6 and exit menusub 7 -- adjust the
  menumask (today 0x70 + drives) and the `menusub > drives` fall-through in
  MENU_FILE_SELECTED).

Harddisks page 1 (MENU_SETTINGS_HARDFILE1, title "Harddisks", right arrow):

```
    IDE : on
 Master : Hardfile (disk img)
              Workbench.hdf
  Slave : CD-ROM (ISO)
              AmigaOS3.9.iso
 Sounds : on
                            
            back            >
```

Harddisks page 2 (new MENU_SETTINGS_HARDFILE3/4, title "IDE port 2", left
arrow), reached with Right from page 1:

```
   Port : on               (ide_config1 bit 0; off = no decode at $DA1xxx)
 Master : CD-ROM (ISO)
              Settlers2.iso
  Slave : Disabled
                            
 Needs AtapiMagic/IDEfix on
 the Amiga (not bootable)   
<           back
```

- The type line cycles: Disabled -> Hardfile (disk img) -> Hardfile
  (filesys) -> MMC/SD card -> partitions -> **CD-ROM (ISO)** -> Disabled.
  (`t_hardfile[n].enabled` cycle in MENU_SETTINGS_HARDFILE2 menusub 1/3; add
  `HDF_CDROM = 7` to the modulo and `config_hdf_msg[7] = "CD-ROM (ISO)"`.)
- The file line opens `SelectFile("ISO", ...)` when the type is CD-ROM and
  `SelectFile("HDF", ...)` otherwise; `MENU_HARDFILE_SELECTED` branches on the
  type: for CD it stores name/long_name/dir and skips `GetHDFFileType`.
- Leaving page 1 or 2 goes through the existing MENU_HARDFILE_EXIT compare;
  changing a slot TYPE or a hardfile still asks for the reset (the Amiga must
  re-probe the bus).  Changing only the ISO of an existing CD slot does not
  (that is a media change) -- MENU_HARDFILE_EXIT must compare `enabled` and
  `name` separately for CD slots.
- Two CD slots are allowed by the data model; phase 1 firmware supports one
  CD unit (`cdTYPE cd[1]`), the menu refuses a second ("one CD-ROM in this
  version") -- decision D3.

Key handling: as the existing pages (up/down move within menumask, select,
menu = back, left/right page change).  The ISO file selector is the stock
MENU_FILE_SELECT1/2 (long names scroll via ScrollLongName).

### 5.3 Config storage

- `hardfile[0..1]` and `secondaryhardfile[0..1]` (both `hardfileTYPE`) as
  the four slots; `hdfdir[0..3]` the four directories.  New type value
  `HDF_CDROM = 7` in `enabled` (fits HDF_TYPEMASK 15; HDF_SYNTHRDB bit
  unused for it).  212 bytes unchanged.  Config version stays 4 (older
  firmware: secondary slots ignored; a CD in a primary slot shows a garbage
  type string there -- acceptable, note in the release notes).
- Boot-time state: `cd[0].slot` (0-3), `cd[0].inserted`, the open
  `fileTYPE` + index.  Insert/eject at run time changes only RAM; the saved
  config keeps the ISO name as the "disc in the drive at power-on".
- `enable_ide` stays the primary port switch; secondary port on/off =
  `secondaryhardfile[0].enabled || secondaryhardfile[1].enabled` (no new
  byte), or use `secondaryhardfile[1].present` as a flag -- decision D4.

## 6. Question 5: does it fit

- RTL (section 7.3): a 13-bit transfer-length register, two 13-bit
  word counters (or one counter compared against the length; the FIFO
  pointers already exist -- reuse `inptr`/`outptr` difference), a packet-mode
  flag, three sticky flags, a signature mux on four tfr reads, ~10 extra
  decode terms: estimate 60-120 LUTs, 30-45 FFs, 0 BRAM.  Against 10,000 free
  LUTs that is noise; the Gayle logic is on the 28 MHz / clk7_en domain, so
  no pressure on the +0.06 ns clk_148 paths.  A second Gayle register file +
  FIFO (phase 2b, only if R1 forces it): +~190 LUTs, +2 BRAM36 (54 free).
- Firmware: atapi.c ~4-6 KB of 832 code, cdrom.c glue ~2 KB, OSD additions
  ~2-3 KB, response buffer 2 KB static + one `hdfTYPE`-like index (4 KB)
  for the ISO: ~15 KB of the ~330 KB headroom (BSS end 0x1d72c, audio
  buffer at 0x70000).  The 82 KB image grows to ~95 KB; the boot loader has
  no limit below the audio buffer.
- Config: no growth.

## 7. Device protocol

### 7.1 ATA-level behaviour of the CD unit (what hdd.c must do)

- Signature after reset / EXECUTE DEVICE DIAGNOSTIC (0x90) / DEVICE RESET
  (0x08): sector count 1, sector number 1, cyl low 0x14, cyl high 0xEB,
  error 0x01, status without BSY/DRQ (WinUAE `set_signature`; MiSTer
  `cylinder = 0xEB14`).  For an ATA unit the signature is 1,1,0,0 (fix
  `ATA_Diagnostic`, which writes 0,0 today).
- IDENTIFY DEVICE (0xEC) on the CD unit: abort (ERR, error 0x04) and reload
  the signature registers -- this is how a host that tried ATA learns to
  send 0xA1 (MiSTer `case 0xEC`, WinUAE unknown-ATAPI-command path).
- IDENTIFY PACKET DEVICE (0xA1): 512 bytes.  Word 0 = 0x8580 (ATAPI, CD-ROM
  device type 5, removable, 12-byte packet, DRQ within 3 ms; WinUAE uses
  0x85C0 = 50 us DRQ -- either).  Words 10-19 serial "MINIMIGCD0 ...",
  23-26 firmware ".100", 27-46 model "Minimig CD-ROM <isoname>" (byte-swapped
  pairs as in `IdentifyDevice`), word 49 = 0x0200 (LBA), word 53 = 0x0007,
  words 62-64 = 0 (no DMA), word 80 = 0x007E, word 82 = 0x4014 (NOP, PACKET
  and removable features, WinUAE), 83 = 0x7000, 84-87 = 0x4000, rest 0.
  Completion: DRQ block of 256 words, then status END|IRQ.
- SET FEATURES (0xEF) subcommand 0x03 (transfer mode): accept, no data.
  NOP (0x00): abort with ERR (both references).  Everything else: abort.
- PACKET (0xA0): if features bit 0 (DMA) is set -> abort.  Byte-count limit
  = cyl high:low (0 and 0xFFFF -> treat as 0xFFFE).  Device: interrupt
  reason (sector count register) = 0x01 (CoD), DRQ=1, BSY=0, no IRQ (MiSTer
  comments out the IRQ here; WinUAE `atapi_packet` sets DRQ without IRQ).
  Host writes 6 words.  Then per the SCSI command:
  - data-in: for each DRQ block: byte count regs = bytes in this block,
    interrupt reason = 0x02 (IO), DRQ=1, IRQ.  Block size = min(remaining,
    limit, 8 KB FIFO).  After the last block: interrupt reason 0x03
    (IO|CoD), DRQ=0, DRDY=1, IRQ, ERR per status.
  - data-out (MODE SELECT): interrupt reason 0x00, byte count = length,
    DRQ=1, IRQ; receive; complete as above.
  - no data: complete directly.
  - error: ERR, error register = (sense key << 4) | 0x04 (ABRT), interrupt
    reason 0x03, IRQ; the sense is kept for the next REQUEST SENSE.
- Status register: keep DRDY as today (`drdy = ~(bsy|drq)`).  WinUAE and
  MiSTer clear DRDY on an ATAPI unit until its first ATAPI command; neither
  Amiga driver is known to require it (UNVERIFIED).  If a driver mis-detects
  the unit as ATA, add an RTL `atapi_drdy_mask` (risk R4).

### 7.2 SCSI command subset (12-byte CDB), phase 1

Sources: MiSTer `cdrom_handle_pkt` (its list was debugged against OS 3.2
CDFileSystem, AtapiMagic and IDEfix), WinUAE `scsi_cd_emulate` (complete),
MMC-3/SPC-2 for formats.  Which commands each Amiga driver actually issues
is UNVERIFIED by capture; phase 1 logs every CDB on the serial console (see
task 1.4) so the subset can be trimmed or extended from evidence.

| CDB | Name | Phase 1 behaviour |
|---|---|---|
| 00 | TEST UNIT READY | GOOD if a disc is inserted and no pending UNIT ATTENTION; else CHECK CONDITION (sense 02/3A/00 no medium, or 06/28/00 medium changed) |
| 03 | REQUEST SENSE | 18 bytes, response code 0x70, sense key/ASC/ASCQ of the last error; clears UNIT ATTENTION.  Exempt from the "no disc" check |
| 12 | INQUIRY | 36 bytes: 05 80 00 21 (ANSI 2, response format 2) 1F, vendor "MINIMIG ", product "CD-ROM ISO      ", rev "1.00"; truncated to allocation length.  Exempt |
| 1A | MODE SENSE(6) | same pages as 5A with the 4-byte header (WinUAE supports; cheap) |
| 1B | START STOP UNIT | GOOD; LoEj=1 Start=0 (eject) -> mark "no disc" + tell the OSD; Start=1 -> GOOD |
| 1E | PREVENT ALLOW MEDIUM REMOVAL | GOOD, remember the lock bit (OSD eject refused while locked? decision D5) |
| 25 | READ CAPACITY | 8 bytes: last LBA (sectors-1) and block length 2048 |
| 28 | READ(10) | LBA + 16-bit count -> ISO sectors; count 0 = GOOD with no data |
| 2B | SEEK(10) | GOOD |
| 35 | SYNCHRONIZE CACHE | GOOD |
| 42 | READ SUB-CHANNEL | minimal: header + "no audio status" (0x15); needed by some CD tools; MiSTer implements |
| 43 | READ TOC | format 0 (one data track 1 at LBA 0 + lead-out at sector count, control 0x14, MSF or LBA per bit 1 of byte 1, honour starting track and allocation length); format 1 (session info); other formats -> ILLEGAL REQUEST |
| 46 | GET CONFIGURATION | 16 bytes, current profile 0x0008 CD-ROM (MiSTer `get_conf`); exempt |
| 4A | GET EVENT STATUS NOTIFICATION | polled, media class: 8 bytes, event code 2 (new media) once after an insert, 3 (removed) once after an eject, else 0; exempt.  (OS 3.2 CDFS uses TD_CHANGESTATE polling through scsi.device, which maps to TEST UNIT READY -- UNVERIFIED which path; implement both) |
| 51 | READ DISC INFORMATION | 34 bytes, one session, one track (MiSTer `disc_info`) |
| 52 | READ TRACK INFORMATION | 24 bytes for track 1 (MiSTer `track_info`) |
| 55 | MODE SELECT(10) | accept the data-out phase, ignore the content (only page 0x0E volume matters later) |
| 5A | MODE SENSE(10) | 8-byte header + pages 01 (error recovery), 0E (audio control, volumes 0xFF), 2A (capabilities: CD-R/RW read, no audio play bit in phase 1? MiSTer sets 0x71 incl. audio play; set audio play=0 until phase 3), 3F = all; unknown page -> 6-byte dummy page (MiSTer) or ILLEGAL REQUEST (WinUAE) -- choose ILLEGAL REQUEST (sense 05/24/00) |
| A8 | READ(12) | as READ(10) with a 32-bit count |
| 45 47 4B 4E BC | PLAY AUDIO (10)/MSF, PAUSE/RESUME, STOP PLAY/SCAN, PLAY CD | GOOD, no action (MiSTer accepts them; makes players not fail) |
| BE B9 D8 D9 | READ CD / READ CD MSF / READ CD-DA | ILLEGAL REQUEST (05/20/00) in phase 1; phase 3 with BIN/CUE |
| other | | ILLEGAL REQUEST 05/20/00 (illegal opcode); invalid field -> 05/24/00 |

"No disc" rule (MMC-5 4.1.6.1, MiSTer): with no disc, every command except
INQUIRY, REQUEST SENSE, GET CONFIGURATION and GET EVENT STATUS NOTIFICATION
returns CHECK CONDITION with sense 02/3A/00.  After an insert, the first
non-exempt command gets 06/28/00 (UNIT ATTENTION, medium may have changed)
once (MiSTer `mcr_flag`, WinUAE `mediawaschanged`).  MiSTer additionally
walks a "becoming ready" countdown (02/04/01 then 02/28/00) after an insert;
copy it only if a driver turns out to need it.

### 7.3 Gayle RTL changes (rtl/minimig/gayle.v, paula_floppy.v) -- vendor neutral

Goal: keep the ATA path bit-identical when the new mode is off; add a
"packet mode" with a programmable transfer length.  Modelled on the
length/`io_done`/`request` scheme of MiSTer's ide.v, but as a small patch
to the existing Gayle instead of a port (ide.v needs a 32-bit host path,
two dual-port RAMs per channel and a different SPI management protocol;
porting it would mean rewriting hdd.c's transport and userio for no gain
in phase 1).

1. New SPI command `CMD_IDE_XFER_WR = 0xC0` (top nibble 1100, free): one
   16-bit payload word = `{pkt_mode, 2'b0, xfer_words[12:0]}`.  Decoded in
   paula_floppy.v next to cmd_hdd_wr (one more `cmd_hdd_xfer` reg and a
   `hdd_xfer_wr` strobe at `rx_cnt==1`); new port on gayle.  Writing it
   resets the FIFO pointers (phase start) and loads the length.  `pkt_mode`
   clears on `sel_command` (new host command) and on reset.
2. In packet mode (`pkt_mode=1`):
   - `drq = pio_in ? (fifo_full | words_in == xfer_words) & ~fifo_empty
     : pio_out & (words_in < xfer_words)` -- short responses get DRQ once
     complete, long ones stream in 512-byte steps as ATA does, `nrdy`
     covers the tail.  `words_in`/`words_out` are the existing FIFO
     pointers (`inptr`/`outptr` exported, or two new 13-bit counters).
   - No `sector_count` decrement, no automatic `busy` clear
     (`sector_count_dec_in/out` gated by `~pkt_mode`).
   - Transfer end (`words_out == xfer_words` for pio in, `words_in ==
     xfer_words` for pio out): `drq` drops, `busy <= 1` (BSY visible to the
     host between phases, as ATAPI allows), `pio_in/pio_out <= 0`, sticky
     `xfer_done <= 1`.  For pio out also `hdd_dat_req = pkt_mode ? xfer_done
     : fifo_full & pio_out` so the firmware's existing `CMD_IDEDAT` poll
     fires for a 6-word packet.
   - `intreq`: set on any status write with bit 4 in packet mode (both
     directions, independent of the drq edge), in addition to the existing
     paths.  Clearing stays as is.
3. Flags readable by the firmware in the high byte of every tfr read
   (`hdd_data_in[15:8]`, today `{7'h0, dev[1]}`): bit 8 `dev[1]`, bit 9
   `xfer_done`, bit 10 `dev_wr` (sticky: host wrote drive/head since the
   last firmware tfr read), bit 11 `rst_seen` (sticky: Gayle reset since the
   last read), bit 12 `pkt_mode`.  Sticky bits clear when the firmware
   reads register 7 (last of the 8-register read).
4. Signature mux: new config input `ide_atapi[3:0]` (one bit per slot,
   from `ide_config0/1` extended to 5 bits: `userio_osd.v:449-450` take
   `wrdat[4:0]`; `ConfigIDE` sends them).  New reg `sig_mode`, set on reset
   and by a status write with a new bit 5 ("signature"), cleared when the
   host writes the command register.  While `sig_mode`, host reads of tfr
   2..5 return the constant signature for the selected device
   (`ide_atapi[dev]` ? 1,1,0x14,0xEB : 1,1,0,0) and register 1 returns 0x01.
   This removes the race of a firmware-written signature when the host
   switches devices (one shared register file).  Cost ~20 LUTs.  Firmware
   still writes the signature after 0x90/0x08/0xEC for the WriteTaskFile
   path (harmless redundancy).
5. `hdd1_ena` gating of `sel_tfr` stays; `ConfigIDE` must now send
   `ide_config1` (SPI address 0_101_10 = command byte 0x58, name it
   `OSD_CMD_HDD1`).  Verify the `wrdat[7:2]` decode in userio_osd.v:330
   maps 0x58 to SPI_HARDDISK1_CFG_ADR before relying on it.
6. Everything above is plain Verilog registers and comparators, no
   primitives; the Intel ports compile it unchanged (they will simply not
   have the firmware).

Not in phase 1: a second register file + FIFO for the secondary channel
(phase 2b), the device control register, DRDY masking.

### 7.4 Firmware structure

- `fw/ctrl_832/atapi.c/.h` (new, pure C, no hardware access): `struct
  atapi_unit` (sense triple, unit-attention flag, lock, event pending,
  media present, `sectors`), `atapi_identify(buf, name)`,
  `int atapi_packet(struct atapi_unit*, const uint8_t cdb[12], uint16_t
  limit, struct atapi_result*)` returning one of: RESPONSE (bytes in a
  2 KB static buffer), READ (lba, count), RECEIVE (length, for MODE SELECT),
  DONE, CHECK (sense).  Builds for the 832 and for the host with gcc
  (`-DHOSTTEST`).
- `fw/ctrl_832/cdrom.c/.h` (new, board glue): the CD unit state
  (`fileTYPE` + index like hdfTYPE, slot, inserted), `CD_Open(slot)`,
  `CD_Insert(name, dir)`, `CD_Eject()`, and the Gayle-level driver:
  `CD_HandleCommand(tfr)` for 0xA0/0xA1/0xEC/0x90/0x08/0xEF/else using
  `WriteTaskFile`, `WriteStatus`, new `WriteXfer(words, pkt)`, the data-in
  loop (fill FIFO with CMD_IDE_DATA_WR for responses, `FileReadEx(&cd.file,
  0, 4*n)` direct transfer for sectors, wait `xfer_done`, next block), the
  data-out receive (poll `CMD_IDEDAT`, CMD_IDE_DATA_RD of `words` words).
- `hdd.c`: `HandleHDD` reads the high byte of the tfr read (channel +
  flags), computes `slot = dev1<<1 | (tfr[6]>>4 & 1)`, dispatches to the ATA
  path (`hdf[]`, now 4 entries or a slot->hdf map) or `CD_HandleCommand`;
  `ATA_Diagnostic` writes the proper signature; `OpenHardfile(slot)` for
  the two new slots; `rst_seen` -> re-arm signature / UNIT ATTENTION.
- `config.c ApplyConfiguration`: open slots 2/3, `ConfigIDE(enable_ide,
  present bits, atapi bits, port2 enable)`.
- `menu.c`: section 5.  `fat.c`: no change for "ISO" (one extension);
  phase 3 adds a small extension-list match for "ISO"+"CUE".
- `osd.h/fpga.h/hdd.h`: new command codes and `HDF_CDROM`.

## 8. Data path and performance

- ISO sector n = file bytes n*2048 = FAT sectors 4n..4n+3 of the ISO file:
  `HardFileSeek(&cd, 4*lba)` then `FileReadEx(&cd.file, 0, 4*count)`
  streams straight from the SD card into the Gayle FIFO (direct mode), no
  copy through the 832.  Cluster crossings are handled inside FileReadEx.
  The cluster index (`BuildHardfileIndex`) costs one FAT walk at open
  (hardfiles report "indexed in N ms" -- a 700 MB ISO is in the same range
  as a 700 MB HDF).
- Block size per DRQ: min(host limit, 8 KB) = up to 4 CD sectors per DRQ
  block; a 64 KB read (OS 3.2 CDFS keeps HD_SCSICMD transfers <= 64 KB per
  its notes) is 8 blocks with one IRQ each.
- Throughput estimate (no measurement possible before implementation): the
  SD SPI ceiling is ~2 MB/s raw (findings/sdio plan: 18.9 MHz bit clock,
  `SPI_fast`), the hardfile path achieves a fraction of that today
  (UNVERIFIED: no board number for HDF reads is in findings/; Jakub's 2010
  comment says 400-520 KB/s with a 28 MHz 68k, the 040 and faster SPI will
  be higher).  With the firmware serialising "fill 8 KB, then host drains"
  and the 832 loop latency per block (~50-100 us), expect 0.6-1.2 MB/s,
  i.e. 4-8x CD speed; streaming (DRQ on the first 512 bytes, `nrdy` for
  gaps) overlaps the two and should approach the SD ceiling.  Phase 1 ships
  fill-then-drain; the streaming `drq` term is in the RTL from the start
  (section 7.3 item 2) so the switch is firmware-only.
- Measure in acceptance: copy a 100 MB file from CD0: to RAM: with a
  stopwatch / `c:copy` timing; compare md5 (3.2 has C:MD5Sum per the 3.2.2
  notes) against the host.

## 9. Media change and eject without reset

- OSD eject (main-page line 6 or the slot page): `CD_Eject()` closes the
  file, `media=0`, `event=REMOVED`; the next non-exempt command gets 02/3A/00;
  TEST UNIT READY fails -> CDFileSystem sees "no disc" through
  TD_CHANGESTATE polling (scsi.device polls the unit periodically,
  TD_ADDCHANGEINT per the 3.2 scsi notes 47.3).
- OSD insert: `CD_Insert()` opens the ISO, builds the index, `media=1`,
  `unit_attention=1`, `event=NEW_MEDIA`; the first non-exempt command returns
  06/28/00 once, then normal; GET EVENT STATUS reports NewMedia once.
  CDFileSystem re-reads the TOC/PVD and mounts the new volume.
- Swap = eject + insert (two OSD actions, or one "select ISO while
  inserted" that does both).
- START STOP UNIT with LoEj (Amiga-side `Eject` command, 3.2 has one):
  behaves like OSD eject; the OSD line updates on the next redraw.
- PREVENT MEDIUM REMOVAL lock: honour it only in the sense that the OSD
  shows a padlock; the OSD still ejects (a user with the OSD is the hand
  on the tray) -- decision D5.
- Amiga reset (`rst_seen`): keep the disc, re-arm `sig_mode`, set UNIT
  ATTENTION (a real drive reports 06/29/00 power-on/reset).

## 10. Phased tasks

Each task: files, test, board check.  Builds of bitstreams are Paul's call
(do not start one unattended; see memory "No unattended across limits").

### Phase 0 -- scaffolding and the host test (no RTL, no board)

- 0.1 `fw/ctrl_832/atapi.c/.h` with `atapi_identify`, `atapi_packet` for
  the section 7.2 table, sense/unit-attention/event state, TOC builder.
  Test: `fw/ctrl_832/test/atapi_test.c` built with the host gcc
  (`make -C fw/ctrl_832/test`), feeds CDBs and asserts response bytes
  (INQUIRY layout, READ TOC format 0 LBA and MSF for a 245,535-sector
  image incl. the lead-out at MSF 54:35:60 (LBA 245,535 + 150 frames), READ CAPACITY,
  MODE SENSE page lengths, allocation-length truncation, the no-disc rule,
  the one-shot UNIT ATTENTION, GET EVENT STATUS one-shot, invalid opcode ->
  05/20/00, READ(10) count 0, READ beyond end -> 05/21/00).  Sector reads
  go through a callback that the test backs with
  `~/work/amiga/AmigaOS3.9.iso` (compare the PVD at sector 16).
- 0.2 `fw/ctrl_832/cdrom.c/.h` compiled for the 832 but not yet called;
  `make -C fw/ctrl_832` still builds (vbcc832 toolchain at
  `EightThirtyTwo/`).  Check the map: growth < 20 KB.

### Phase 1 -- RTL packet mode + ISO data on the primary channel

- 1.1 gayle.v / paula_floppy.v / minimig.v / userio_osd.v / userio.v per
  section 7.3 (xfer command, packet mode, flags, signature mux, 5-bit
  ide_config).  Keep every ATA-path expression unchanged when
  `pkt_mode=0` (diff-review for that).
- 1.2 New bench `sim/gayle/gayle_tb.v` + `run.sh` (iverilog, modelled on
  sim/osd_keyq/run.sh): instantiate gayle + gayle_fifo, drive the 68k side
  (sel_ide, address, rd/hwr/lwr, clk7_en) and the SPI side (hdd_* ports
  directly, no paula_floppy).  Cases: (a) ATA READ SECTORS of 2 sectors
  behaves exactly as before (golden VCD/compare of status sequence);
  (b) PACKET: host writes 0xA0, firmware side writes xfer=6/pkt, status
  pio-out -> drq high, host writes 6 words -> drq low, `hdd_dat_req`,
  `xfer_done` flag; (c) data-in 18 bytes (9 words): firmware fills 9 words,
  status pio-in|IRQ -> drq + intreq only after all 9 words, host reads 9
  words -> drq low, BSY, xfer_done; (d) data-in 1024 words streams: drq
  after 256 words, `nrdy` asserted when the host outruns the writer;
  (e) signature mux: after reset tfr 2..5 read 1,1,0x14,0xEB for an
  ATAPI slot and 1,1,0,0 for an ATA slot, and the real tfr after a command
  write; (f) `dev_wr`/`rst_seen` sticky flags clear on reading register 7.
  Mutant mode: packet mode forced off must fail (b)-(d).
- 1.3 Firmware: hdd.c dispatch by slot, `CD_HandleCommand`, `WriteXfer`,
  signature in `ATA_Diagnostic`, `ConfigIDE` with atapi bits, `OpenHardfile`
  for a CD slot (type HDF_CDROM -> `CD_Open`).  Serial log of every ATA
  command on a CD unit and every CDB (one line each, `DebugMode` gated),
  used in 1.5 to prune the table.
- 1.4 OSD: `HDF_CDROM` type in the slot cycle (primary slots only in this
  phase), ISO file selector, main-page line 6 insert/eject, help text.
- 1.5 Board acceptance (QMTech, 3.2.3 ROM 47.115, Install3.2 ADF or an HDF
  with 3.2 installed, CD slot = primary slave):
  - scsi.device sees unit 1: `HDToolBox` or `C:ScsiQuery`/`SysInfo` lists
    "MINIMIG CD-ROM ISO"; no hang at boot with and without a disc.
  - Copy Storage/DOSDrivers/CD0 to DEVS: with Unit=1; `AmigaOS3.9.iso`
    mounts as CD0:, `dir CD0:` lists the OS 3.9 CD, `Info` shows the size.
  - Copy a 100 MB file to RAM:, `MD5Sum` matches the host's md5sum; note the
    time (section 8).
  - Eject from the OSD: CD0: shows "no disk"; insert `ClassicInstallCD`:
    new volume appears without reset; swap back.
  - Reset (Ctrl-A-A) with the disc in: still mounted afterwards.
  - Regression: an HDF on the primary master boots and `DiskSpeed`/copy
    results are unchanged (ATA path untouched).
  - KS 3.1 (40.68) + IDEfix97 demo from Aminet: `atapi.device` finds the
    unit; CacheCDFS mounts it (confirms a second driver's command set).

### Phase 2 -- secondary port and polish

- 2.1 OSD page 2 (IDE port 2), slots 2/3, `OSD_CMD_HDD1`, `ide_config1`,
  `hdd1_ena`; firmware `dev[1]` honoured; CD on secondary master.
  Board: AtapiMagic 47.1 on 3.2 -> unit 2 mounts; without AtapiMagic the
  port is invisible and nothing hangs.  HDF on primary + CD on secondary:
  copy test while the HD is busy (R1 probe).
- 2.2 Streaming `drq` in the firmware (DRQ as soon as the first 512 bytes
  are in), measure the gain.
- 2.3 Custom-ROM boot experiment: build a 1 MB 3.2.2 ROM with CDFileSystem
  48.52+ resident (Hyperion's ROM tools or Remus; UNVERIFIED tooling), CD on
  primary, see if strap boots the OS 3.2 CD / a bootable ISO.  Outcome
  decides whether "boot from CD" stays a documented limitation.
- 2.4 Phase 2b, only if R1 shows up: second register file + FIFO for the
  secondary channel (duplicate the gayle core per channel, mux by
  `address_in[12]`, firmware reads both request bits).

### Phase 3 -- BIN/CUE and CD audio (rough size)

- CUE parser from bincue.c (file-backed), 2352-byte tracks: READ(10) must
  skip the 16/24-byte headers, so sector data goes through `sector_buffer`
  (4 x 512 + offset handling) instead of direct transfer -- slower; or add
  a "skip N bytes" option to the direct path (RTL: a byte counter that
  drops the first 16 bytes of each 2352 block; cheap but another RTL
  change).  READ CD (BE) for raw reads, READ TOC with audio tracks (control
  0x10), PLAY AUDIO MSF/10, PAUSE/RESUME, READ SUB-CHANNEL with position,
  MODE SELECT page 0E volume.  Audio through audiotrack.c into the 32 KB
  host audio buffer (shared with drive sounds -- arbitration needed).
  Firmware ~6-8 KB, RTL 0-30 LUTs.  Extension list "ISO"/"CUE" in
  ScanDirectory.  Size: about the same as phase 1 again.

### Phase 4 -- CD32 (Akiko)

- Akiko CD controller registers at $B80000, CD32 ROM 40.60 + extended ROM,
  its own command protocol (MiSTer `akiko_cd32.cpp`, 1634 lines, is the
  reference), chunky-to-planar is already in rtl/akiko.  Independent of
  IDE; shares cdrom.c/atapi.c's image layer.  Size: larger than phases 1-3
  together; not estimated further here.

## 11. Risks and open decisions

Risks:

- R1 **Shared register file and FIFO across two channels.** A 4-way driver
  may interleave a command on the HD (port 1) while a CD command (port 2)
  is between phases.  With one tfr/FIFO the two corrupt each other.  Real
  drivers serialise per IORequest but scsi.device is one task serving all
  units (UNVERIFIED whether it waits for completion before touching the
  other port).  MiSTer avoids it with two `ide` instances.  Mitigation:
  phase 2.1 test; fallback 2.4.
- R2 **Command subset mismatch.** No capture of what OS 3.2 CDFileSystem /
  scsi.device / AtapiMagic / IDEfix send.  Mitigation: serial CDB log in
  phase 1, ILLEGAL REQUEST for everything unknown (drivers survive that).
- R3 **$DA3018 device control register** decodes as the secondary channel's
  drive/head register when `hdd1_ena` is set.  MiSTer has the same mapping
  and works with 3.1.4/3.2; watch for `dev` flips in the log.
- R4 **DRDY always set** on the ATAPI unit (WinUAE/MiSTer clear it until the
  first ATAPI command).  If scsi.device treats the unit as ATA, add the mask
  bit in RTL.
- R5 **Timing of the 832 loop between phases.** The host sees BSY while the
  firmware prepares the next block; CDFileSystem timeouts are seconds, fine,
  but the floppy emulation shares the loop -- heavy floppy + CD use at once
  may stutter (as HDF + floppy does today).
- R6 **Older firmware** seeing `enabled=7` in a primary slot displays
  garbage in the Harddisks menu (array overrun on `config_hdf_msg`).  Harmless
  if the CD is in a secondary slot; document.
- R7 **3.1.4 ATAPI support** inferred from 3.1.4.1 notes and 3.2 strings, not
  verified against a 3.1.4 ROM here.

Decisions for Paul:

- D1 Default slot for the CD in a fresh config: none (user picks), or
  primary slave?  Plan assumes "none".
- D2 Accept the shared-register-file design for phase 1 (R1) and defer the
  second Gayle instance?  Plan assumes yes.
- D3 One CD unit in phase 1 (menu refuses a second CD slot)?  Plan assumes
  yes; two units cost one more state struct and index (4 KB) each.
- D4 Secondary port on/off switch: derived from the slot types (no extra
  byte) or an explicit "Port: on/off" line?  Plan draws the explicit line
  but stores it as "any secondary slot enabled".
- D5 OSD eject while the Amiga has locked the tray (PREVENT MEDIUM
  REMOVAL): obey (refuse) or override?  Plan assumes override with a
  padlock shown.
- D6 Phase 2.3 (custom ROM with resident CDFileSystem) -- worth the time, or
  is "boot from HDF/ADF, mount the CD" enough?
- D7 Name strings: INQUIRY vendor/product "MINIMIG " / "CD-ROM ISO", IDENTIFY
  model with the ISO name (as hardfiles show their file name)?
