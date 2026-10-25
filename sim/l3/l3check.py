#!/usr/bin/env python3
"""l3check.py: offline data checks of an L3 run directory (sim/l3/run.sh).

    python3 -I l3check.py kick <run>
    python3 -I l3check.py order <run>
    python3 -I l3check.py mmc <run> [<golden>]
    python3 -I l3check.py memhash <run>
    python3 -I l3check.py keys <run>
    python3 -I l3check.py fdd_rd <run>
    python3 -I l3check.py fdd_wr <run> [<reference run>]
    python3 -I l3check.py hdd <run>
    python3 -I l3check.py cd <run>
    python3 -I l3check.py cdda <run>
    python3 -I l3check.py akiko <run>

kick: the 256 KB kickstart the firmware uploaded equals the card's KICK.ROM
byte for byte.  UploadKickstart (fw/ctrl/config.c) sends a 0x40000-byte
ROM twice with SendFileV2 (fpga.c), to the Amiga addresses 0xf80000 and
0xfc0000 (the mirror); SendFileV2 writes Amiga address a at host address
(a & 0x7fffff) ^ 0x680000 (HOSTMAP_ADDR, hardware.h): 0x100000 and 0x140000.
The memory is <run>/sdram.bin, the SDRAM model's dump (tb_l3.v
+SDRAM_DUMP: file offset = host byte address, byte A+0 = the upper byte of
halfword A), the file <run>/card/content/KICK.ROM.

order (plan 7.1 item 14): the kickstart is in the SDRAM before the Amiga
CPU runs.  From the run log <run>/tb_boot_*.log (mon_l3.vh): the cycle of
the last SDRAM write into the kickstart region ("=== KICK last SDRAM write
... at cycle W") must be before the last cpurst fall ("=== KICK cpurst
falls at cycle R", userio_osd releasing the CPU); the bench's own "=== MARGIN
14 kick_order" line must say R - W and ok.

mmc: the firmware's MMC_Init card commands equal <golden> (default
sim/l3/gold/mmc_init_rv.txt).  From the run log (+SD_LOG=1: sd_spi_model's
"SD: <time> <cmd> arg=<a> cs=<b>" lines): the commands after the jump to the
firmware ("=== BOOT first read of 0x2000"), up to and including the first
CMD58, as "<cmd> arg=<a>"; the golden's lines without '#' comments.

memhash: the MEM lines of <run>/hw.txt (sim/common/hostmon.vh +HW_LOG:
"MEM <region> <first host byte> <bytes>", hex, one per SDRAM region the CPU
wrote) become "MEM <region> <sha256>" of those bytes of <run>/sdram.bin, in
place (a line already hashed stays).

keys (scenario keys): the OSD key path, from the run log's "=== KEYS
script <file>", "=== KEYS step" and "=== KEYS ev <n> <code> at cycle <c>"
lines (bfm_keys.v, tb_l3.v) and <run>/spi_t.txt (the frames with their
cycles):
  - the events the bench made are the script's (run.sh's default
    sim/l3/keys/menu_tour.txt: KEY <c> = <c>, 00; BURST = its codes), step
    by step
  - the KEYQ frames (20 98) against userio_osd's queue modelled as a FIFO:
    at a frame's start the queue holds the events made before it and not
    yet read; the status byte (MISO 1) must be {overflow 0, count = the
    queue's length}, the frame must have count bytes after it, and per-key
    byte i the queue's head (each read pops one, as the RTL does: a wrong
    byte is lost, not repeated); at the end the queue is empty (none lost,
    none twice, in order).  No event may come while a KEYQ frame is open
  - each KEY / BURST step's events come in ONE KEYQ frame (the first after
    them), the BURST's with count = its length (6 in menu_tour.txt)
  - the OSD_CMD_VERSION reply (20 88) = the milestone of
    milestones_boot.txt, byte by byte
  - no OSD_CMD_OSD_WR frame before the first event (the boot draws no OSD
    page: one there is an error page; a page check of the main loop alone
    cannot tell it from the fatal-error loop), and the pages
    (spitrace.py osd) = osdtext_expect/keys.txt, which must equal what
    osdtext_expect/osdpages.py keys writes (not stale)
It prints "REPLY <cmd> byte <k>: <right> of <n> right" per reply byte
(VERSION 88 bytes 0-5, KEYQ 98 byte 0 = the status, 1.. the per-key bytes)
before its verdict.

fdd_rd (scenario fdd_rd): the floppy reads of bfm_floppy against TEST.ADF.
The run log's "=== FDD dma <k> cylinder <c> head <h>: <n> words to
blckint" lines must be the 10 track reads of the scenario (FDD_TRACKS
below, in order, FDD_WORDS words each), and each dump
<run>/fdd_rd_<c>_<h>.hex (the words Agnus moved, in order) must:
  - decode with fw/ctrl/test/gold/mfm.py's decode_sector: the read runs
    with WORDSYNC, so Paula starts the DMA with the word after the sync word
    it matched; the decoder gets that sync word (and two preamble words,
    which it does not read) in front of the dump.  Every sector found
    (sync sync at a word boundary, 1,088 bytes) has its header and data
    checksums right, the track number c * 2 + h, a sector number 0..10 with
    "sectors to the gap" 11 - sector, and the 512 data bytes of
    <run>/card/content/TEST.ADF at (track * 11 + sector) * 512; all 11
    sectors are found
  - equal, byte for byte, the stream mfm.py's read_track() makes of the ADF
    track (sectors 0..10 and the gap, 12,668 bytes) read cyclically from
    some offset: a DMA starts at a sync, after the sectors the firmware sent
    before it (the offset is printed: 6 = sector 0's preamble and first
    sync, the WORDSYNC start); a dump that does not start with the sync word
    is decode-only (said so)
  - for cylinder 0 head 0 and cylinder 79 head 1 also equal, read the same
    way, the committed golden streams of exec-3 Task 13
    (fw/ctrl/test/gold/mfm_c00_s0.hex, mfm_c79_s1.hex)
and the OSD and UART:
  - no OSD_CMD_OSD_WR frame before the first key event (an error page) and
    none after the first track DMA started (the OSD is closed; fdd.c's
    FatalError would draw one)
  - after the first key event, an OSD row 3 "Floppy disk sounds : on" and
    then an OSD row 0 "df0: TEST" (keys/insert_df0.txt: sounds on, TEST.ADF
    in df0), decoded as spitrace.py osd
  - no UART line with "Illegal track", "Fatal" or "Wrong header"

fdd_wr (scenario fdd_wr): the floppy writes of bfm_floppy against the card
the run left.  The run log's "=== FDD wdma <k> cylinder <c> head <h>: <n>
words to blckint" lines must be the 10 track writes of the scenario
(FDD_WR_TRACKS below, in order, FDD_WORDS words each).  TEST.ADF is copied
out of <run>/card_saved.img (+SD_SAVE) with mtools (mcopy, the partition's
offset from the MBR) to <run>/fdd_wr_saved.adf, and compared, sector by
sector, with the original <run>/card/content/TEST.ADF:
  - every sector of a written track holds its new data
    (sim/l3/gen/mkwrtrack.py new_data: mfm.py's new_sector), except the
    bad-header sector (FDD_WR_BAD: cylinder 40 head 0, sector 3)
  - every other sector is unchanged
  - the bad-header sector is classified: "skipped" (the original data),
    "written" (its new data; the stream's data block is right, only the
    header checksum is wrong) or "other" (anything else: BAD)
  - fsck.fat -n of the saved card's partition is clean
and the OSD and UART:
  - no OSD_CMD_OSD_WR frame before the first key event, none from the first
    track write's start to the last one's blckint
  - after the first key event, an OSD row 3 "Floppy disk sounds : on" and
    then an OSD row 0 "df0: TEST", as fdd_rd
  - the OSD rows written after the last blckint (the error page, if any)
    are recorded, rows 0, 2, 3 and 4 (title, category, message, code)
  - no UART line with "Illegal track", "Wrong header" or "Second sync"
It prints "HEADER track <t> sector <s> (LBA <n>): <skipped | written |
other>; error page: <rows> | none".  With <reference run> (another run of
the same scenario on the same card, e.g. at another timing point): the saved
TEST.ADF must equal the reference's byte for byte and the HEADER line must
be the reference's (the bad-header path taken the same way in both runs).

hdd (scenario hdd, bfm_ide.v): from the run log's "=== IDE cmd" / "=== IDE
end" lines and the dumps <run>/hdd_<k>.hex (the 68k's words, first word
first = the bytes in its memory order):
  - the commands are HDD_PLAN below, in order, each ending with status 40
    (DRDY, no ERR), error 00, at least one interrupt or nrdy wait (item 8:
    every command waits for the firmware's interrupt), the words in /
    out of its kind, and the task file the firmware leaves: the CHS of the
    last sector (hdd.c's CHS advance; the cylinder > 255 reads), the host's
    own registers for IDENTIFY / SET MULTIPLE
  - IDENTIFY of SYNTH.HDF = fw/ctrl/test/gold/identify.py's stream for
    HDF_FILE | HDF_SYNTHRDB at CHS 257.1.32 (words 1, 3, 6, little-endian
    in the 68k's memory, = the geometry bfm_ide converts LBAs with)
  - every read sector = the drive: SYNTH.HDF (drive LBA = file block + 32)
    with the synthesised RDB cylinder in front (LBA 0 / 1 = gold/rdb.py's
    rdsk / part for 257.1.32, the rest zeros); RDB.HDF's block 0 as hdd.c
    patches it for unit 0 (rdb_Flags 0x12, the checksum computed from
    scratch with rdb.py, which must equal hdd.c's ChkSum + Flags - 0x12),
    its other blocks as on the card; a sector written before = the write
    pattern (bfm_ide.v; wpattern here).  The HDF files' own tags ('H',
    file id, block) are checked first
  - every written sector (the dumps of the WRITE commands = the write
    pattern) is in <run>/card_saved.img (+SD_SAVE) in SYNTH.HDF's cluster
    of its block (spitrace.py's Card on <run>/card/hdd.img), and no other
    card sector differs from <run>/card/hdd.img

cd (scenario cd, bfm_ide.v plan_cd): the CD drive on IDE port 2 master
(gayle port 1), the disc of the run's "=== CD config <cue|iso>" line
(it must be the card's: <run>/card/cd.img or cd_iso.img, and the config's
CD slot, <run>/card/cfg_<cfg>/MINMGAA.check, must name TEST.CUE / TEST.ISO).
From the "=== IDE cmd", "=== IDE phase" and "=== IDE end" lines and the
dumps <run>/cd_<k>.hex:
  - the commands are CD_PLAN below, in order, with their packets and byte
    count limits; each ends with its status (40, or 41 = CHECK CONDITION
    where the plan expects it), the error register cdrom.c's cd_error()
    makes of the sense key (key << 4, | ABRT 04 for ILLEGAL REQUEST and
    ABORTED COMMAND), and the task file cd_complete() leaves (interrupt
    reason 03, the sector register and the host's byte count limit as the
    command found them, device A0); IDENTIFY PACKET DEVICE the host's
  - the data phases: reason 02 (IO), each at most the byte count limit
    and 8 KB (the FIFO); their bytes add up to the answer's length
  - IDENTIFY PACKET DEVICE = the words atapi_identify() of the firmware
    source (fw/ctrl/atapi.c, read field by field: each "id[n] = v", "ata_string(id + n, s, len)" and the loop of
    id[84..87]), each word little-endian in the 68k's memory as for ATA
    IDENTIFY; the disc name in the model field is the config's (long name,
    else the 8-character name, cdrom.c CD_Open / CD_Insert); and decoded:
    ATAPI, CD-ROM, removable, 12-byte packets
  - TEST UNIT READY: CHECK CONDITION UNIT ATTENTION 06/29/00 (the insert's
    06/28/00 replaced by the Amiga reset the first command's task file read
    saw, gayle rst_seen -> cdrom.c CD_Flags -> atapi_reset), then REQUEST
    SENSE = that sense, a second TEST UNIT READY GOOD
  - INQUIRY, READ CAPACITY, READ TOC (format 0, every track and the
    lead-out), MODE SENSE(10) of all pages = the bytes atapi.c builds
    (inquiry, the READ CAPACITY case, read_toc, mode_sense / mode_page),
    for this disc: the TOC from TEST.CUE (a parser here: INDEX 01 + the
    PREGAPs; CDCFG=cue) or one DATA2048 track of TEST.ISO's size (iso)
  - READ(10) 32 sectors from LBA 16, READ(12) 8 from LBA 56 = the disc's
    2048-byte user data: TEST.ISO's blocks, or TEST.BIN's MODE1/2352
    sectors from byte 16 (the CUE's data track)
  - READ CD MSF (B9, not supported): CHECK CONDITION 05/20/00 (atapi.c's
    default), REQUEST SENSE = that sense
  - item 9: the bench ran at TICKDIV 643 from the scenario's start, its
    "=== MARGIN 9 cd_timeout_left" line is ok over one window per phase
    (each packet's command phase and each data phase), and the longest
    window is far from CD_TIMEOUT; printed as INFO lines with the command
    it was in, and the longest 68k-side wait on the firmware per command (the
    firmware's service time)

cdda (scenarios cdda and cdda_load, bfm_ide.v plan_cdda, bfm_audio.v,
mon_l3.vh "CDDA"): CD audio from TEST.CUE's track 2 through the ring.  The
scenario is the log's SCENARIO=; the card is <run>/card/cd.img (cdda) or
cdhdd.img (cdda_load), its config's CD slot TEST.CUE.  From the "=== IDE"
lines, the dumps <run>/cdda_<k>.hex, the "=== CDDA" lines and the ring
snapshots <run>/cdda_half_<n>.bin:
  - the commands are CDDA_PLAN below, in order: TEST UNIT READY (CHECK
    CONDITION, the reset's UNIT ATTENTION: error 60), PLAY AUDIO MSF,
    (cdda_load: SET MULTIPLE 16, READ MULTIPLE 256 sectors of SYNTH.HDF
    from drive LBA 1000 = its blocks 968..1223, compared with the file),
    PAUSE, READ SUB-CHANNEL, RESUME, STOP; each with its status, error
    register and task file (cd's rules)
  - the player: two runs from the PLAY command on, the PLAY's with 7
    halves (6 flips, then PAUSE) and the RESUME's with 2 (one flip, then
    STOP); the ring half of the k-th half of a run is k mod 2.  A run
    before the PLAY is the boot's audio_clear() (main.c: the ring zeroed,
    ENA for one TIMER count, CLEAR) and is not counted; nor are the refill
    lines before it
  - every half equals what cdaudio.c's fill() puts there for its place in
    the run: range frame f = base + k * 8,192 of the range (LBA 214 .. 326)
    -- TEST.BIN's bytes (LE 16-bit stereo, the CUE's track 2 from its INDEX
    01; a gap or data sector, the end of the file or of the range: zeros),
    scale()d at the volume when it is not 255 / 255 (the run CPU's
    cdaudio.c: cda_init's volume; the scenario sends no MODE SELECT).  base
    is 0 for the PLAY's run; for the RESUME's, the firmware's paused
    position pos (a multiple of 256 frames: TIMER units) inside the sector
    READ SUB-CHANNEL reports, within one half of the frames the player had
    played when the PAUSE stopped it
  - a half that differs is an underrun (late refill) when each of its
    frames is the expected one, the half's earlier content (the same ring
    half two halves before in the run) or zero; anything else is a wrong
    half (FAIL in both scenarios).  cdda: no underrun (and no write into the
    playing half); cdda_load: the underruns are counted (INFO, recorded:
    README "cdda")
  - READ SUB-CHANNEL (format 1, LBA): 16 bytes, audio status 12 (paused),
    adr/control 10, track 2 index 1, the absolute LBA 214 + pos // 588 and
    the relative pos // 588; within one half (8,192 frames) of the player
  - the refills (mon_l3.vh): one "=== CDDA fill" line per flip, each with a
    write ("done"); min / median / max ms and the main-loop gaps as INFO
  - the run is at TICKDIV 643 from the scenario's start
  - the ring at the end (<run>/sdram.bin, host 0x70000..0x7ffff) is all
    zero: the STOP's cdaudio.c release() clears it, so that the drive
    sounds do not start on a remnant of the music (Task 17 review I2)

akiko (scenario akiko): the host's Akiko request service, served from
cfide's amiga_* window by bfm_akiko.v (README "akiko").  The firmware's
akiko_inthandler (fw/ctrl/akiko.c) is a logging stub: it prints one UART
line per request and answers DATA = 0 (the ack); there is no C2P in the host
path (the C2P is rtl/minimig/akiko.v, Amiga side; the virtual top ties the
host path off).  From the run log's "=== AKIKO req <b> <k> <W|R> ..." lines,
the "UART: Akiko ..." lines, <run>/hw.txt and the track dumps:
  - 128 requests, 2 blocks of 32 writes then 32 reads, in order (none lost,
    none repeated); addr 0x20 + 0x80 b + i, write data ((i + 1) * 0x9E37) &
    0xFFFF (xor 0xC3A5 in block 1: the pattern is computed here, not read
    from the bench); every ack came (lat > 0), every read returned 0
  - the UART shows exactly those requests as the firmware prints them, in
    order, one line each: "Akiko write: <0xC000 | addr>, <data>" and
    "Akiko read: <0x8000 | addr>" (hex, upper case), nothing else
    mentioning Akiko
  - hw.txt has exactly 128 writes of 0 to the Akiko DATA register (ffff84):
    one ack each
  - block 1 starts while a track DMA is in progress and at least 16 of its
    requests are acked inside the DMA (the log's "dma 1"); the two track
    reads (cylinder 0 and 1, head 0) decode to TEST.ADF as in fdd_rd
  - the OSD of fdd_rd (no page before the first key, none after the first
    track DMA, "Floppy disk sounds : on", "df0: TEST"); no UART line with
    "Illegal track", "Fatal" or "Wrong header"
It prints the latency table (amiga_req rise to amiga_ack in clk_114 cycles,
per block and request type: n, min, median = the middle of the sorted
values, max; and the ack to the host's EnableInterrupts write, the window in
which a new request would set no interrupt).

Each prints one line, "PASS <name>: ..." (exit 0) or "FAIL <name>: ..."
(exit 1); exit 2 on a usage error.  Python 3 standard library only.
"""
import glob
import hashlib
import re
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
L2 = os.path.join(HERE, "..", "host_bridge")

GOLD = os.path.join(HERE, "..", "..", "fw", "ctrl", "test", "gold")

# scenario fdd_rd (scenarios.vh FDD_PLAN): (cylinder, head) in order
FDD_TRACKS = [(0, 0), (1, 0), (2, 0), (39, 0), (40, 0), (41, 0), (77, 0), (78, 0), (79, 0), (79, 1)]
FDD_WORDS = 6334
FDD_SYNC = 0x4489
FDD_GOLDEN = {(0, 0): "mfm_c00_s0.hex", (79, 1): "mfm_c79_s1.hex"}

# scenario fdd_wr (scenarios.vh FDD_WPLAN, run.sh FDD_WR_PLAN): (cylinder,
# head) in order, and the track / sector with the bad header checksum
FDD_WR_TRACKS = [(0, 0), (1, 0), (2, 0), (39, 0), (41, 0), (77, 0), (78, 0), (79, 0), (79, 1), (40, 0)]
FDD_WR_BAD = ((40, 0), 3)

# scenario hdd (bfm_ide.v plan_hdd): the drives (port, dev) -> file, CHS,
# the drive LBA of the file's block 0 (SYNTH.HDF: the firmware's RDB
# cylinder in front), the file id of its block tags (gen/mkhdf.py)
HDD_GEO = {(0, 0): ("RDB.HDF", 16, 4, 63, 0, 1), (0, 1): ("SYNTH.HDF", 257, 1, 32, 32, 2)}
# the commands in order: name, port, dev, cylinder, head, sector, count
# (IDENTIFY / SET_MULT: the task file the host writes, CHS 0/0/0)
HDD_PLAN = [
    ("IDENTIFY", 0, 1, 0, 0, 0, 0),
    ("READ", 0, 1, 0, 0, 1, 2),            # LBA 0: RDSK, PART (FakeRDB)
    ("READ", 0, 1, 3, 0, 5, 64),           # LBA 100
    ("SET_MULT", 0, 1, 0, 0, 0, 16),
    ("READ_MULT", 0, 1, 255, 0, 1, 64),    # LBA 8160, into cylinder 256
    ("READ_MULT", 0, 1, 256, 0, 1, 32),    # LBA 8192: cylinder high 1
    ("WRITE", 0, 1, 62, 0, 17, 64),        # LBA 2000
    ("WRITE_MULT", 0, 1, 93, 0, 25, 32),   # LBA 3000
    ("READ", 0, 1, 62, 0, 17, 64),         # read back
    ("READ_MULT", 0, 1, 93, 0, 25, 32),
    ("SET_MULT", 0, 0, 0, 0, 0, 16),
    ("READ_MULT", 0, 0, 0, 0, 1, 16),      # RDB.HDF blocks 0..15, block 0 patched
]
HDF_FILE, HDF_SYNTHRDB = 1, 128

# scenario cd (bfm_ide.v plan_cd): name, packet (12 bytes, hex; None for
# IDENTIFY PACKET DEVICE), byte count limit, CHECK CONDITION expected
CD_FW = os.path.join(HERE, "..", "..", "fw")
CD_PORT, CD_DEV = 1, 0
CD_PLAN = [
    ("ID_PACKET", None, None, False),
    ("TEST_UNIT_READY", "000000000000000000000000", 0xFFFE, True),
    ("REQUEST_SENSE", "030000001200000000000000", 0xFFFE, False),
    ("TEST_UNIT_READY", "000000000000000000000000", 0xFFFE, False),
    ("INQUIRY", "120000002400000000000000", 0xFFFE, False),
    ("READ_CAPACITY", "250000000000000000000000", 0xFFFE, False),
    ("READ_TOC", "430000000000000324000000", 0xFFFE, False),
    ("READ10", "280000000010000020000000", 0xFFFE, False),
    ("READ12", "a80000000038000000080000", 0x0400, False),
    ("MODE_SENSE10", "5a003f000000000100000000", 0xFFFE, False),
    ("READ_CD_MSF", "b90000000200000003001000", 0xFFFE, True),
    ("REQUEST_SENSE", "030000001200000000000000", 0xFFFE, False),
]
CD_FIFO = 8192          # bytes: gayle's FIFO, cdrom.c CD_FIFO_512 x 512
CD_TICKDIV = 643        # the board's TIMER rate (run.sh cd)

# scenarios cdda / cdda_load (bfm_ide.v plan_cdda): name, packet (None for
# the ATA commands of cdda_load), status, error, data bytes; port / dev
CDDA_START, CDDA_END = 214, 327          # PLAY AUDIO MSF 00:04:64 .. 00:06:27
CDDA_HALF = 8192                         # frames in a half (cdaudio.h CDA_HALF_FRAMES)
CDDA_UNIT = 256                          # frames per TIMER unit (cdaudio.c frames_played)
CDDA_RUNS = (7, 2)                       # halves of the PLAY's and the RESUME's run
CDDA_HDF_LBA, CDDA_HDF_N = 1000, 256     # cdda_load: READ MULTIPLE on SYNTH.HDF
CDDA_RING = 0x70000                      # AUDIO_BUFFER (hardware.h), 2 x 32 KB
CDDA_PLAN = [
    ("TEST_UNIT_READY", "000000000000000000000000", 0x41, 0x60, 0),
    ("PLAY_AUDIO_MSF", "47000000044000061b000000", 0x40, 0x00, 0),
    ("PAUSE", "4b0000000000000000000000", 0x40, 0x00, 0),
    ("READ_SUBCHANNEL", "420040010000000010000000", 0x40, 0x00, 16),
    ("RESUME", "4b0000000000000001000000", 0x40, 0x00, 0),
    ("STOP", "4e0000000000000000000000", 0x40, 0x00, 0),
]
CDDA_LOAD = [("SET_MULT", None, 0x40, 0x00, 0), ("READ_MULT", None, 0x40, 0x00, CDDA_HDF_N * 512)]

HOSTMAP_ADDR = 0x680000
KICK_SIZE = 0x40000
KICK_AMIGA = (0xF80000, 0xFC0000)


def host_addr(amiga):
    return (amiga & 0x7FFFFF) ^ HOSTMAP_ADDR


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b)) if len(a) != len(b) else -1


def kick(run):
    dump_path = os.path.join(run, "sdram.bin")
    rom_path = os.path.join(run, "card", "content", "KICK.ROM")
    for p in (dump_path, rom_path):
        if not os.path.isfile(p):
            print("FAIL kick: no %s" % p)
            return 1
    with open(dump_path, "rb") as f:
        mem = f.read()
    with open(rom_path, "rb") as f:
        rom = f.read()
    if len(rom) != KICK_SIZE:
        print("FAIL kick: %s is %d bytes, not 0x%x" % (rom_path, len(rom), KICK_SIZE))
        return 1
    bad = []
    for a in KICK_AMIGA:
        h = host_addr(a)
        got = mem[h:h + KICK_SIZE]
        k = first_diff(got, rom)
        if k >= 0:
            if k < len(got):
                bad.append("Amiga 0x%06x (host 0x%06x): differs from offset 0x%05x (%02x, want %02x)"
                           % (a, h, k, got[k], rom[k]))
            else:
                bad.append("Amiga 0x%06x (host 0x%06x): the dump ends at offset 0x%05x" % (a, h, k))
    if bad:
        print("FAIL kick: " + "; ".join(bad))
        return 1
    print("PASS kick: KICK.ROM (%d bytes) at Amiga 0x%06x and 0x%06x (host 0x%06x, 0x%06x)"
          % (KICK_SIZE, KICK_AMIGA[0], KICK_AMIGA[1], host_addr(KICK_AMIGA[0]), host_addr(KICK_AMIGA[1])))
    return 0


def run_log(run, name):
    logs = sorted(glob.glob(os.path.join(run, "tb_*_x*_s*_j*.log")))
    if len(logs) != 1:
        print("FAIL %s: %d tb_<scenario>_*.log files in %s (want 1)" % (name, len(logs), run))
        return None
    with open(logs[0]) as f:
        return logs[0], f.read().splitlines()


def order(run):
    got = run_log(run, "order")
    if got is None:
        return 1
    log, lines = got
    w = r = margin = None
    for line in lines:
        m = re.match(r"=== KICK last SDRAM write into the kickstart region at cycle (\d+) \(host ([0-9a-f]+)\)", line)
        if m:
            w, wa = int(m.group(1)), m.group(2)
        m = re.match(r"=== KICK cpurst falls at cycle (\d+)", line)
        if m:
            r = int(m.group(1))
        if line.startswith("=== MARGIN 14 kick_order "):
            margin = line
    if w is None:
        print("FAIL order: no kickstart-region SDRAM write in %s" % log)
        return 1
    if r is None:
        print("FAIL order: no cpurst fall in %s" % log)
        return 1
    if w >= r:
        print("FAIL order: the last kickstart-region SDRAM write (cycle %d, host %s) is not before the last "
              "cpurst fall (cycle %d)" % (w, wa, r))
        return 1
    want = "=== MARGIN 14 kick_order min %d.0 clk_114 (bound 1, ok)" % (r - w)
    if margin is None or not margin.startswith(want):
        print("FAIL order: the bench's MARGIN 14 line is %r, want it to start with %r" % (margin, want))
        return 1
    print("PASS order: the last kickstart-region SDRAM write at cycle %d (host %s), the CPU released at "
          "cycle %d, %d cycles later" % (w, wa, r, r - w))
    return 0


def mmc(run, golden):
    got = run_log(run, "mmc")
    if got is None:
        return 1
    log, lines = got
    if not os.path.isfile(golden):
        print("FAIL mmc: no golden %s" % golden)
        return 1
    with open(golden) as f:
        want = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    seen = cmds = None
    for line in lines:
        if line.startswith("=== BOOT first read of 0x2000"):
            seen, cmds = True, []
            continue
        # (Verilator prints a space for the model's empty "%0s": "SD: <t>  CMD0")
        m = re.match(r"SD: \d+ +(A?CMD\d+ arg=[0-9a-f]{8}) cs=", line)
        if seen and m:
            cmds.append(m.group(1))
            if m.group(1).startswith("CMD58 "):
                break
    if not seen:
        print("FAIL mmc: no '=== BOOT first read of 0x2000' line in %s" % log)
        return 1
    if not cmds:
        print("FAIL mmc: no SD command after the jump to the firmware (was the run made with +SD_LOG=1?)")
        return 1
    for i in range(max(len(cmds), len(want))):
        a = cmds[i] if i < len(cmds) else "(none)"
        b = want[i] if i < len(want) else "(none)"
        if a != b:
            print("FAIL mmc: command %d is %s, the golden %s says %s" % (i + 1, a, golden, b))
            return 1
    print("PASS mmc: MMC_Init's %d commands after the jump (%s ... %s) = %s"
          % (len(cmds), cmds[0], cmds[-1], golden))
    return 0


def memhash(run):
    hw_path = os.path.join(run, "hw.txt")
    dump_path = os.path.join(run, "sdram.bin")
    if not os.path.isfile(hw_path):
        print("FAIL memhash: no %s" % hw_path)
        return 1
    with open(hw_path) as f:
        lines = f.read().splitlines()
    mem = None
    out, names = [], []
    for line in lines:
        w = line.split()
        if len(w) == 4 and w[0] == "MEM":
            if mem is None:
                if not os.path.isfile(dump_path):
                    print("FAIL memhash: %s has MEM lines but there is no %s" % (hw_path, dump_path))
                    return 1
                with open(dump_path, "rb") as f:
                    mem = f.read()
            a, n = int(w[2], 16), int(w[3], 16)
            if a + n > len(mem):
                print("FAIL memhash: MEM %s 0x%x+0x%x beyond the dump (%d bytes)" % (w[1], a, n, len(mem)))
                return 1
            line = "MEM %s %s" % (w[1], hashlib.sha256(mem[a:a + n]).hexdigest())
        if line.startswith("MEM "):
            names.append(line.split()[1])
        out.append(line)
    tmp = hw_path + ".tmp"
    with open(tmp, "w") as f:
        f.write("".join(l + "\n" for l in out))
    os.replace(tmp, hw_path)
    print("PASS memhash: %d region(s)%s" % (len(names), (" (" + ", ".join(names) + ")") if names else ""))
    return 0


def keys_script(path):
    """the events per KEY / BURST step of a key script, in order"""
    steps = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            w = line.split("#", 1)[0].split()
            if not w:
                continue
            if w[0] == "KEY":
                steps.append((n, "KEY", [int(w[1], 16), 0]))
            elif w[0] == "BURST":
                steps.append((n, "BURST", [int(x, 16) for x in w[1:]]))
    return steps


def frames_t(path):
    """spi_t.txt: (start, end, cs, MOSI, MISO) per frame"""
    res = []
    with open(path, encoding="latin-1") as f:
        for line in f:
            w = line.split()
            k = w.index("/")
            res.append((int(w[0]), int(w[1]), int(w[2], 16),
                        [int(x, 16) for x in w[3:k]], [int(x, 16) for x in w[k + 1:]]))
    return res


def keys(run):
    sys.path.insert(0, L2)
    import spitrace
    expect = os.path.join(HERE, "osdtext_expect", "keys.txt")
    got = run_log(run, "keys")
    if got is None:
        return 1
    log, lines = got
    script = next((l[len("=== KEYS script "):] for l in lines if l.startswith("=== KEYS script ")), None)
    if script is None or not os.path.isfile(script):
        print("FAIL keys: no '=== KEYS script <file>' line naming a file in %s" % log)
        return 1
    bad = []
    # the bench's steps and events
    steps, evs = [], []
    for line in lines:
        m = re.match(r"=== KEYS step (\d+) (KEY|BURST) ", line)
        if m:
            steps.append((int(m.group(1)), m.group(2), []))
        m = re.match(r"=== KEYS ev (\d+) ([0-9a-f]{2}) at cycle (\d+)$", line)
        if m:
            if not steps:
                bad.append("event %s before the first step" % m.group(1))
                continue
            ev = (int(m.group(2), 16), int(m.group(3)))
            steps[-1][2].append(ev)
            evs.append(ev)
    want = keys_script(script)
    if [(n, k, c) for n, k, c in want] != [(n, k, [e[0] for e in es]) for n, k, es in steps]:
        print("FAIL keys: the bench's steps / events (%d steps) are not the script's (%d steps, %s)"
              % (len(steps), len(want), script))
        return 1
    if not steps:
        print("FAIL keys: no KEY / BURST step in %s" % log)
        return 1
    # the KEYQ frames against the queue
    frames = frames_t(os.path.join(run, "spi_t.txt"))
    kq = [(i, f) for i, f in enumerate(frames) if f[2] == 0x20 and f[3] and f[3][0] == 0x98]
    right = {}            # (cmd, k) -> [right, n]

    def tally(cmd, k, ok):
        r = right.setdefault((cmd, k), [0, 0])
        r[0] += 1 if ok else 0
        r[1] += 1
    queue, nxt, nread, wrong = [], 0, 0, []
    for i, (t0, t1, _, mosi, miso) in kq:
        while nxt < len(evs) and evs[nxt][1] < t0:
            queue.append(evs[nxt][0])
            nxt += 1
        if nxt < len(evs) and evs[nxt][1] <= t1:
            bad.append("event %d (cycle %d) while KEYQ frame %d was open (cycles %d..%d)" % (nxt + 1, evs[nxt][1], i + 1, t0, t1))
        if len(miso) < 2:
            bad.append("KEYQ frame %d has no status byte" % (i + 1))
            continue
        st, keyb = miso[1], miso[2:]
        ok0 = st == min(len(queue), 15)
        tally(0x98, 0, ok0)
        if not ok0:
            wrong.append("frame %d (spi.txt line %d): status %02x, the queue holds %d" % (i + 1, i + 1, st, len(queue)))
        if len(keyb) != st & 0x0F:
            bad.append("KEYQ frame %d: status %02x but %d bytes after it" % (i + 1, st, len(keyb)))
        for k, b in enumerate(keyb, 1):
            head = queue.pop(0) if queue else 0
            nread += 1 if b == head else 0
            tally(0x98, k, b == head)
            if b != head:
                wrong.append("frame %d (spi.txt line %d) byte %d: %02x, the queue's head %02x" % (i + 1, i + 1, k, b, head))
    while nxt < len(evs):
        queue.append(evs[nxt][0])
        nxt += 1
    if queue:
        bad.append("%d event(s) never read (%s)" % (len(queue), " ".join("%02x" % c for c in queue)))
    if wrong:
        bad.append("%d wrong KEYQ reply byte(s): %s" % (len(wrong), "; ".join(wrong[:6])))
    # each step in one frame: the first non-empty KEYQ frame after its last event
    burst = None
    for n, kind, es in steps:
        last = es[-1][1]
        f = next(((i, fr) for i, fr in kq if fr[0] > last and len(fr[4]) >= 2 and fr[4][1] != 0), None)
        codes = [c for c, _ in es]
        if f is None or f[1][4][1] != len(codes) or f[1][4][2:] != codes:
            bad.append("script line %d (%s): its %d events are not one KEYQ frame (%s)"
                       % (n, kind, len(codes), "first one after them: " + " ".join("%02x" % x for x in f[1][4])
                          if f else "no KEYQ frame with events after them"))
        elif kind == "BURST":
            burst = (n, f[0] + 1, len(codes))   # (script line, spi.txt line, count)
    # the version reply
    vwant = None
    with open(os.path.join(HERE, "milestones_boot.txt")) as fm:
        for line in fm:
            m = re.match(r"SPI 20 88 (?:ff )+/ xx ((?:[0-9a-f]{2} ?)+)$", line.strip())
            if m:
                vwant = [int(x, 16) for x in m.group(1).split()]
    ver = [f for f in frames if f[2] == 0x20 and f[3] and f[3][0] == 0x88]
    if vwant is None or not ver:
        bad.append("no version reply (frame or milestone)")
    for f in ver:
        for k, w in enumerate(vwant or []):
            b = f[4][k + 1] if k + 1 < len(f[4]) else None
            tally(0x88, k, b == w)
            if b != w:
                bad.append("version reply byte %d: %s, want %02x" % (k, "none" if b is None else "%02x" % b, w))
    # OSD pages: none before the first event, then = keys.txt
    first = next((i for i, f in enumerate(frames) if f[0] > evs[0][1]), len(frames))
    early = [i for i, f in enumerate(frames[:first]) if f[2] == 0x20 and f[3] and f[3][0] == 0x0C]
    if early:
        bad.append("%d OSD_CMD_OSD_WR frame(s) before the first key (an error page?), the first spi.txt line %d"
                   % (len(early), early[0] + 1))
    glyphs = spitrace.load_charrom(spitrace.CHARROM)
    pages, page, prev = [], 0, None
    for _, _, cs, mosi, _ in frames:
        if cs != 0x20 or not mosi or mosi[0] != 0x0C:
            continue
        row, text = spitrace.osd_line(mosi, glyphs)
        if prev is None or not isinstance(row, int) or not isinstance(prev, int) or row <= prev:
            page += 1
            pages.append("--- page %d" % page)
        prev = row
        pages.append("%s %s" % (row, text) if text else str(row))
    with open(expect, encoding="latin-1") as f:
        want_pages = f.read().splitlines()
    gen = subprocess.run([sys.executable, "-I", os.path.join(HERE, "osdtext_expect", "osdpages.py"), "keys"],
                         capture_output=True, encoding="latin-1")
    if gen.returncode != 0 or gen.stdout.splitlines() != want_pages:
        bad.append("%s is stale: osdpages.py keys writes other lines (exit %d)" % (expect, gen.returncode))
    if pages != want_pages:
        k = next((j for j, (a, b) in enumerate(zip(pages, want_pages)) if a != b), min(len(pages), len(want_pages)))
        bad.append("OSD pages (%d lines) differ from %s (%d lines) at line %d: %r, want %r"
                   % (len(pages), expect, len(want_pages), k + 1,
                      pages[k][:90] if k < len(pages) else "(end)", want_pages[k][:90] if k < len(want_pages) else "(end)"))
    for (cmd, k) in sorted(right):
        r = right[(cmd, k)]
        print("REPLY %02x byte %d: %d of %d right" % (cmd, k, r[0], r[1]))
    for b in bad:
        print("BAD  " + b)
    if bad:
        print("FAIL keys: %d problem(s) (the BAD lines)" % len(bad))
        return 1
    print("PASS keys: %d events of %d steps read back in order from %d KEYQ frames, the BURST (script line %d) "
          "in one frame (spi.txt line %d) with count %d; version reply right; %d OSD pages = %s"
          % (len(evs), len(steps), len(kq), burst[0] if burst else 0, burst[1] if burst else 0,
             burst[2] if burst else 0, page, os.path.relpath(expect, HERE)))
    return 0


def load_mfm():
    import importlib.util
    spec = importlib.util.spec_from_file_location("mfm", os.path.join(GOLD, "mfm.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_hex(path):
    """a hex dump (any line length, no separators) -> bytes"""
    with open(path) as f:
        return bytes.fromhex("".join(f.read().split()))


def cyclic_offset(dump, stream):
    """the offset o at which dump equals stream read cyclically from o,
    or None"""
    if not stream or len(dump) > len(stream):
        return None
    ss = stream + stream
    o = ss.find(dump)
    while 0 <= o < len(stream):
        if o % 2 == 0:
            return o
        o = ss.find(dump, o + 1)
    return None


def fdd_track(mfm, adf, cyl, head, dump):
    """(problems, sectors found, the decoder's start note)"""
    track = cyl * 2 + head
    bad = []
    sync = FDD_SYNC.to_bytes(2, "big")
    stream = b"\xaa\xaa\xaa\xaa" + sync + dump
    w = [int.from_bytes(stream[i:i + 2], "big") for i in range(0, len(stream) - 1, 2)]
    found = set()
    for i in range(2, len(w) - 1):
        if w[i] != FDD_SYNC or w[i + 1] != FDD_SYNC:
            continue
        b = stream[2 * (i - 2):2 * (i - 2) + mfm.SECTOR_BYTES]
        if len(b) < mfm.SECTOR_BYTES:
            continue                  # the last, cut by the end of the DMA
        try:
            t, sec, gap, data = mfm.decode_sector(b, FDD_SYNC)
        except ValueError as e:
            bad.append("sector at dump word %d: %s" % (i - 3, e))
            continue
        if t != track or not 0 <= sec < mfm.SECTORS or gap != mfm.SECTORS - sec:
            bad.append("sector at dump word %d: header track %d sector %d gap %d (want track %d)"
                       % (i - 3, t, sec, gap, track))
            continue
        n = track * mfm.SECTORS + sec
        if data != adf[n * 512:(n + 1) * 512]:
            k = first_diff(data, adf[n * 512:(n + 1) * 512])
            bad.append("sector %d: data byte %d is %02x, TEST.ADF has %02x" % (sec, k, data[k], adf[n * 512 + k]))
            continue
        found.add(sec)
    if len(found) != mfm.SECTORS and not bad:
        bad.append("sectors found: %s (want 0..10)" % sorted(found))
    return bad, found


def fdd_osd(lines, run, bad, notes):
    """the OSD pages of keys/insert_df0.txt around the first track DMA
    (fdd_rd and akiko): problems into bad, notes into notes"""
    sys.path.insert(0, L2)
    import spitrace
    if not os.path.isfile(os.path.join(run, "spi_t.txt")):
        bad.append("no spi_t.txt in %s" % run)
        return
    frames = frames_t(os.path.join(run, "spi_t.txt"))
    evs = [int(m.group(1)) for m in (re.match(r"=== KEYS ev \d+ [0-9a-f]{2} at cycle (\d+)$", l) for l in lines) if m]
    dma0 = next((int(m.group(1)) for m in (re.match(r"=== FDD dma 1 cylinder \d+ head \d+: \d+ words, sync [0-9a-f]+, from cycle (\d+)$", l)
                                           for l in lines) if m), None)
    if not evs or dma0 is None:
        bad.append("no key event or no first track DMA in the run log")
    else:
        glyphs = spitrace.load_charrom(spitrace.CHARROM)
        osd = [(t0, spitrace.osd_line(mosi, glyphs)) for t0, _, cs, mosi, _ in frames
               if cs == 0x20 and mosi and mosi[0] == 0x0C]
        early = [t0 for t0, _ in osd if t0 < evs[0]]
        late = [t0 for t0, _ in osd if t0 > dma0]
        if early:
            bad.append("%d OSD_CMD_OSD_WR frame(s) before the first key (an error page?), the first at cycle %d"
                       % (len(early), early[0]))
        if late:
            bad.append("%d OSD_CMD_OSD_WR frame(s) after the first track DMA started (cycle %d), the first at cycle %d"
                       % (len(late), dma0, late[0]))
        snd = next((t0 for t0, (row, text) in osd if row == 3 and "Floppy disk sounds : on" in text), None)
        ins = next((t0 for t0, (row, text) in osd
                    if row == 0 and re.search(r"df0: TEST\b", text) and snd is not None and t0 > snd), None)
        if snd is None:
            bad.append("no OSD row 3 'Floppy disk sounds : on' (the drive sounds were not turned on)")
        elif ins is None:
            bad.append("no OSD row 0 'df0: TEST' after the sounds were turned on (TEST.ADF not in df0)")
        else:
            notes.append("OSD: 'Floppy disk sounds : on' at cycle %d, 'df0: TEST' at cycle %d" % (snd, ins))


def fdd_rd(run):
    sys.path.insert(0, L2)
    import spitrace
    got = run_log(run, "fdd_rd")
    if got is None:
        return 1
    log, lines = got
    bad, notes = [], []
    adf_path = os.path.join(run, "card", "content", "TEST.ADF")
    if not os.path.isfile(adf_path):
        print("FAIL fdd_rd: no %s" % adf_path)
        return 1
    with open(adf_path, "rb") as f:
        adf = f.read()
    mfm = load_mfm()
    # the bench's track reads, in order
    dmas = []
    for line in lines:
        m = re.match(r"=== FDD dma (\d+) cylinder (\d+) head (\d+): (\d+) words to blckint at cycle (\d+)", line)
        if m:
            dmas.append((int(m.group(2)), int(m.group(3)), int(m.group(4))))
    if [(c, h) for c, h, _ in dmas] != FDD_TRACKS:
        bad.append("the track reads in the log are %s, want %s" % ([(c, h) for c, h, _ in dmas], FDD_TRACKS))
    for c, h, n in dmas:
        if n != FDD_WORDS:
            bad.append("track %d/%d: %d words, want %d" % (c, h, n, FDD_WORDS))
    nsec = nstream = ngold = 0
    for cyl, head in FDD_TRACKS:
        path = os.path.join(run, "fdd_rd_%d_%d.hex" % (cyl, head))
        if not os.path.isfile(path):
            bad.append("no dump %s" % path)
            continue
        dump = read_hex(path)
        if len(dump) != 2 * FDD_WORDS:
            bad.append("%s: %d bytes, want %d" % (path, len(dump), 2 * FDD_WORDS))
            continue
        nbad = len(bad)
        tbad, found = fdd_track(mfm, adf, cyl, head, dump)
        bad += ["track %d/%d: %s" % (cyl, head, b) for b in tbad]
        nsec += len(found)
        note = "track %d/%d: %d sectors decode = TEST.ADF" % (cyl, head, len(found))
        if dump[:2] != FDD_SYNC.to_bytes(2, "big"):
            note += "; decode-only (the dump does not start with the sync word)"
        else:
            ref = mfm.read_track(adf, cyl * 2 + head, FDD_SYNC)
            o = cyclic_offset(dump, ref)
            if o is None:
                bad.append("track %d/%d: the dump is not mfm.py's read_track stream read cyclically from any offset" % (cyl, head))
            else:
                note += "; = read_track from byte %d" % o
                nstream += 1
            if (cyl, head) in FDD_GOLDEN:
                gpath = os.path.join(GOLD, FDD_GOLDEN[(cyl, head)])
                og = cyclic_offset(dump, read_hex(gpath))
                if og is None:
                    bad.append("track %d/%d: the dump is not %s read cyclically from any offset"
                               % (cyl, head, os.path.relpath(gpath, os.path.join(HERE, "..", ".."))))
                else:
                    note += "; = %s from byte %d" % (FDD_GOLDEN[(cyl, head)], og)
                    ngold += 1
        if len(bad) == nbad:
            notes.append(note)
    # OSD and UART
    fdd_osd(lines, run, bad, notes)
    for line in lines:
        if line.startswith("UART: ") and re.search(r"Illegal track|Fatal|Wrong header", line):
            bad.append("UART: %s" % line[6:])
    for n in notes:
        print("ok   " + n)
    for b in bad:
        print("BAD  " + b)
    if bad:
        print("FAIL fdd_rd: %d problem(s) (the BAD lines)" % len(bad))
        return 1
    print("PASS fdd_rd: %d track reads of %d words, %d sectors = TEST.ADF, %d streams = mfm.py's read_track, "
          "%d of the %d golden tracks (0/0, 79/1) = gold/mfm_c*.hex; drive sounds on and df0: TEST on the OSD"
          % (len(dmas), FDD_WORDS, nsec, nstream, ngold, len(FDD_GOLDEN)))
    return 0


def load_mkwrtrack():
    import importlib.util
    spec = importlib.util.spec_from_file_location("mkwrtrack", os.path.join(HERE, "gen", "mkwrtrack.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def card_file(img_path, name, dest):
    """copy <name> out of the card image's first partition with mtools;
    None or the error text"""
    with open(img_path, "rb") as f:
        mbr = f.read(512)
    part = 0
    if len(mbr) == 512 and mbr[510:512] == b"\x55\xaa" and mbr[0x1BE + 4] != 0:
        part = int.from_bytes(mbr[0x1BE + 8:0x1BE + 12], "little")
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    r = subprocess.run(["mcopy", "-n", "-o", "-i", "%s@@%d" % (img_path, part * 512), "::" + name, dest],
                       capture_output=True, encoding="latin-1", env=env)
    if r.returncode != 0:
        return "mcopy %s: exit %d: %s" % (name, r.returncode, (r.stderr or r.stdout).strip()[:200])
    return None


def card_fsck(img_path, tmp):
    """fsck.fat -n of the card image's first partition; None or the error"""
    with open(img_path, "rb") as f:
        img = f.read()
    part = 0
    if img[510:512] == b"\x55\xaa" and img[0x1BE + 4] != 0:
        part = int.from_bytes(img[0x1BE + 8:0x1BE + 12], "little")
    with open(tmp, "wb") as f:
        f.write(img[part * 512:])
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/sbin:/sbin")
    try:
        r = subprocess.run(["fsck.fat", "-n", tmp], capture_output=True, encoding="latin-1", env=env)
    except FileNotFoundError:
        os.remove(tmp)
        return "no fsck.fat (apt package dosfstools)"
    os.remove(tmp)
    if r.returncode != 0:
        return "fsck.fat -n: exit %d: %s" % (r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1][:200])
    return None


def osd_plain(text):
    """an OSD row's text without its stripe and inversion marks"""
    t = re.sub(r"^stripe=[0-9a-f]+ ?", "", text)
    t = re.sub(r"\{inv:([^}]*)\}", r"\1", t)
    return " ".join(t.split())


def fdd_wr_state(run):
    """(problems, notes, the HEADER line, the saved ADF or None)"""
    sys.path.insert(0, L2)
    import spitrace
    bad, notes = [], []
    got = run_log(run, "fdd_wr")
    if got is None:
        return ["no run log"], notes, None, None
    log, lines = got
    mkw = load_mkwrtrack()
    adf_path = os.path.join(run, "card", "content", "TEST.ADF")
    img_path = os.path.join(run, "card_saved.img")
    for p in (adf_path, img_path):
        if not os.path.isfile(p):
            return ["no %s" % p], notes, None, None
    with open(adf_path, "rb") as f:
        adf = f.read()
    # the bench's track writes, in order
    wr, start0, end_last = [], None, None
    for line in lines:
        m = re.match(r"=== FDD wdma (\d+) cylinder (\d+) head (\d+): (\d+) words, from cycle (\d+)", line)
        if m and start0 is None:
            start0 = int(m.group(5))
        m = re.match(r"=== FDD wdma (\d+) cylinder (\d+) head (\d+): (\d+) words to blckint at cycle (\d+)", line)
        if m:
            wr.append((int(m.group(2)), int(m.group(3)), int(m.group(4))))
            end_last = int(m.group(5))
    if [(c, h) for c, h, _ in wr] != FDD_WR_TRACKS:
        bad.append("the track writes in the log are %s, want %s" % ([(c, h) for c, h, _ in wr], FDD_WR_TRACKS))
    for c, h, n in wr:
        if n != FDD_WORDS:
            bad.append("track %d/%d: %d words written, want %d" % (c, h, n, FDD_WORDS))
    # TEST.ADF from the saved card
    saved_path = os.path.join(run, "fdd_wr_saved.adf")
    err = card_file(img_path, "TEST.ADF", saved_path)
    if err:
        return bad + [err], notes, None, None
    with open(saved_path, "rb") as f:
        saved = f.read()
    if len(saved) != len(adf):
        return bad + ["the saved TEST.ADF is %d bytes, the original %d" % (len(saved), len(adf))], notes, None, None
    (bc, bh), bs = FDD_WR_BAD
    bad_lba = (bc * 2 + bh) * 11 + bs
    written = set()
    for c, h in FDD_WR_TRACKS:
        written.update(range((c * 2 + h) * 11, (c * 2 + h) * 11 + 11))
    written.discard(bad_lba)
    nnew = nsame = 0
    for n in range(len(adf) // 512):
        got_s, orig = saved[n * 512:(n + 1) * 512], adf[n * 512:(n + 1) * 512]
        t, sec = divmod(n, 11)
        if n in written:
            want = mkw.new_data(t, sec)
            if got_s == want:
                nnew += 1
            else:
                k = first_diff(got_s, want)
                bad.append("track %d sector %d (LBA %d): %s, byte %d is %02x, the new data's %02x"
                           % (t, sec, n, "the original data (not written)" if got_s == orig else "not the new data",
                              k, got_s[k], want[k]))
        elif n != bad_lba:
            if got_s == orig:
                nsame += 1
            else:
                k = first_diff(got_s, orig)
                bad.append("track %d sector %d (LBA %d) changed, but no write covers it (byte %d: %02x, was %02x)"
                           % (t, sec, n, k, got_s[k], orig[k]))
    got_b = saved[bad_lba * 512:(bad_lba + 1) * 512]
    if got_b == adf[bad_lba * 512:(bad_lba + 1) * 512]:
        fate = "skipped"
    elif got_b == mkw.new_data(bad_lba // 11, bad_lba % 11):
        fate = "written"
    else:
        fate = "other"
        bad.append("the bad-header sector (LBA %d) is neither the original nor its new data" % bad_lba)
    notes.append("TEST.ADF from the saved card: %d sectors hold their new data, %d unchanged (of %d)"
                 % (nnew, nsame, len(adf) // 512))
    err = card_fsck(img_path, os.path.join(run, "fdd_wr_part.img"))
    if err:
        bad.append("saved card: " + err)
    else:
        notes.append("saved card: fsck.fat -n clean")
    # OSD and UART
    frames = frames_t(os.path.join(run, "spi_t.txt"))
    evs = [int(m.group(1)) for m in (re.match(r"=== KEYS ev \d+ [0-9a-f]{2} at cycle (\d+)$", l) for l in lines) if m]
    page = {}
    if not evs or start0 is None or end_last is None:
        bad.append("no key event or no track write in %s" % log)
    else:
        glyphs = spitrace.load_charrom(spitrace.CHARROM)
        osd = [(t0, spitrace.osd_line(mosi, glyphs)) for t0, _, cs, mosi, _ in frames
               if cs == 0x20 and mosi and mosi[0] == 0x0C]
        early = [t0 for t0, _ in osd if t0 < evs[0]]
        during = [t0 for t0, _ in osd if start0 < t0 < end_last]
        if early:
            bad.append("%d OSD_CMD_OSD_WR frame(s) before the first key (an error page?), the first at cycle %d"
                       % (len(early), early[0]))
        if during:
            bad.append("%d OSD_CMD_OSD_WR frame(s) during the track writes (cycles %d..%d), the first at cycle %d"
                       % (len(during), start0, end_last, during[0]))
        snd = next((t0 for t0, (row, text) in osd if row == 3 and "Floppy disk sounds : on" in text), None)
        ins = next((t0 for t0, (row, text) in osd
                    if row == 0 and re.search(r"df0: TEST\b", text) and snd is not None and t0 > snd), None)
        if snd is None:
            bad.append("no OSD row 3 'Floppy disk sounds : on' (the drive sounds were not turned on)")
        elif ins is None:
            bad.append("no OSD row 0 'df0: TEST' after the sounds were turned on (TEST.ADF not in df0)")
        else:
            notes.append("OSD: 'Floppy disk sounds : on' at cycle %d, 'df0: TEST' at cycle %d" % (snd, ins))
        for t0, (row, text) in osd:
            if t0 > end_last and isinstance(row, int) and row not in page:
                page[row] = osd_plain(text)
    for line in lines:
        if line.startswith("UART: ") and re.search(r"Illegal track|Wrong header|Second sync", line):
            bad.append("UART: %s" % line[6:])
    errpage = " / ".join("'%s'" % page.get(r, "") for r in (0, 2, 3, 4)) if page else "none"
    badhdr = "HEADER track %d sector %d (LBA %d): %s; error page: %s" % (bad_lba // 11, bs, bad_lba, fate, errpage)
    return bad, notes, badhdr, saved


def fdd_wr(run, ref):
    bad, notes, badhdr, saved = fdd_wr_state(run)
    if ref is not None and badhdr is not None:
        rbad, _, rbadhdr, rsaved = fdd_wr_state(ref)
        if rbad or rbadhdr is None:
            bad.append("the reference run %s fails its own check (%d problem(s): %s)"
                       % (ref, len(rbad), "; ".join(rbad[:3])))
        else:
            if rbadhdr != badhdr:
                bad.append("the bad-header path differs from the reference's: %s, the reference %s"
                           % (badhdr[len("HEADER "):], rbadhdr[len("HEADER "):]))
            if rsaved != saved:
                k = first_diff(saved, rsaved)
                bad.append("the saved TEST.ADF differs from the reference's from byte %d (LBA %d)" % (k, k // 512))
            else:
                notes.append("= the reference run %s: the same saved TEST.ADF and bad-header path" % ref)
    for n in notes:
        print("ok   " + n)
    if badhdr is not None:
        print(badhdr)
    for b in bad:
        print("BAD  " + b)
    if bad:
        print("FAIL fdd_wr: %d problem(s) (the BAD lines)" % len(bad))
        return 1
    print("PASS fdd_wr: %d track writes of %d words; TEST.ADF on the saved card = the original with the %d written "
          "sectors' new data; the bad-header sector %s"
          % (len(FDD_WR_TRACKS), FDD_WORDS, len(FDD_WR_TRACKS) * 11 - 1, badhdr.split(": ", 1)[1].split(";")[0]))
    return 0


def load_gold(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(GOLD, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wpattern(lba, kind):
    """bfm_ide.v's write pattern of the sector at drive LBA lba (kind 'S' / 'M')"""
    b = bytearray((lba * 29 + j * 7 + 0x5A) & 255 for j in range(512))
    b[0:4] = bytes((0x57, ord(kind), (lba >> 8) & 255, lba & 255))
    return bytes(b)


def chs_lba(geo, c, h, s):
    _, _, heads, spt, _, _ = geo
    return (c * heads + h) * spt + s - 1


def chs_last(geo, c, h, s, count):
    """hdd.c ATA_ReadSectors / ATA_WriteSectors: the CHS of the last sector"""
    _, _, heads, spt, _, _ = geo
    for _ in range(count - 1):
        if s == spt:
            s = 1
            h += 1
            if h == heads:
                h = 0
                c += 1
        else:
            s += 1
    return c, h, s


def hdd(run):
    """the hdd scenario's data (README "hdd")"""
    sys.path.insert(0, L2)
    import spitrace
    rdb = load_gold("rdb")
    ident = load_gold("identify")
    got = run_log(run, "hdd")
    if got is None:
        return 1
    log, lines = got
    bad, notes = [], []
    files = {}
    for geo in HDD_GEO.values():
        path = os.path.join(run, "card", "content", geo[0])
        if not os.path.isfile(path):
            print("FAIL hdd: no %s" % path)
            return 1
        with open(path, "rb") as f:
            files[geo[0]] = f.read()
        for n in range(len(files[geo[0]]) // 512):
            blk = files[geo[0]][512 * n:512 * n + 512]
            if blk[:4] not in (b"RDSK", b"PART") and blk[:4] != bytes((ord("H"), geo[5], n >> 8, n & 255)):
                print("FAIL hdd: %s block %d is not tagged H %d %d %d" % (geo[0], n, geo[5], n >> 8, n & 255))
                return 1

    # what each drive holds, block by block (drive LBA); writes update it
    written = {}

    def drive_block(port, dev, lba):
        geo = HDD_GEO[(port, dev)]
        if (port, dev, lba) in written:
            return written[(port, dev, lba)], "written"
        n = lba - geo[4]
        if n < 0:       # the synthesised RDB cylinder (hdd.c FakeRDB)
            if lba == 0:
                return bytes(rdb.rdsk(geo[1], geo[2], geo[3])), "rdb.py rdsk"
            if lba == 1:
                return bytes(rdb.part(geo[1], geo[2], geo[3])), "rdb.py part"
            return bytes(512), "zeros"
        blk = files[geo[0]][512 * n:512 * n + 512]
        if len(blk) != 512:
            return None, "past the end of %s" % geo[0]
        if n == 0 and (port, dev) == (0, 0) and geo[4] == 0:
            # unit 0, a plain HDF: hdd.c patches rdb_Flags to 0x12 and its
            # checksum; expected here from scratch with rdb.py's checksum,
            # and that equals hdd.c's ChkSum + Flags - 0x12
            p = bytearray(blk)
            rdb.put32(p, 20, 0x12)
            rdb.checksum(p)
            ck, fl = int.from_bytes(blk[8:12], "big"), int.from_bytes(blk[20:24], "big")
            if int.from_bytes(p[8:12], "big") != (ck + fl - 0x12) & 0xFFFFFFFF:
                bad.append("%s block 0: rdb.py's checksum differs from hdd.c's incremental one (the file's checksum is not valid?)" % geo[0])
            return bytes(p), "patched %s block 0 (rdb_Flags 0x12, rdb_ChkSum)" % geo[0]
        return blk, "%s block %d" % (geo[0], n)

    cmds, ends = {}, {}
    for line in lines:
        m = re.match(r"=== IDE cmd (\d+) (\S+) port (\d+) dev (\d+) chs (\d+)/(\d+)/(\d+) lba (-?\d+) count (\d+) at cycle (\d+)$", line)
        if m:
            cmds[int(m.group(1))] = (m.group(2),) + tuple(int(m.group(i)) for i in (3, 4, 5, 6, 7, 9))
        m = re.match(r"=== IDE end (\d+) (\S+): status ([0-9a-f]{2}) error ([0-9a-f]{2}) tf ([0-9a-f]{2}) ([0-9a-f]{2}) "
                     r"([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}), (\d+) words in, (\d+) out, file (\S+), waits (\d+) "
                     r"\(irq (\d+), poll (\d+), nrdy (\d+)\) min/median/max (\d+)/(\d+)/(\d+) clk_114, total (\d+), "
                     r"(\d+) cycles, at cycle (\d+)$", line)
        if m:
            ends[int(m.group(1))] = m
    plan = [cmds[k] for k in sorted(cmds)]
    if plan != HDD_PLAN or sorted(cmds) != list(range(1, len(HDD_PLAN) + 1)):
        bad.append("the IDE commands in the log are %s, want %s" % (plan, HDD_PLAN))
    nsec = nwr = 0
    for k, (name, port, dev, c, h, s, count) in enumerate(HDD_PLAN, 1):
        e = ends.get(k)
        if e is None:
            bad.append("command %d %s: no '=== IDE end %d' line" % (k, name, k))
            continue
        geo = HDD_GEO[(port, dev)]
        what = "command %d %s %d/%d/%d count %d on %s" % (k, name, c, h, s, count, geo[0])
        st, er = int(e.group(3), 16), int(e.group(4), 16)
        tfr = [int(e.group(i), 16) for i in range(5, 10)]
        win, wout, fname = int(e.group(10)), int(e.group(11)), e.group(12)
        if st != 0x40 or er != 0:
            bad.append("%s: status %02x error %02x at the end, want 40 00" % (what, st, er))
        nirq, nnrdy = int(e.group(14)), int(e.group(16))
        if nirq + nnrdy < 1:
            # every command of the plan waits for the firmware's interrupt
            # (bfm_ide records a wait only when the 68k waited)
            bad.append("%s: no interrupt or nrdy wait recorded (item 8): irq %d, nrdy %d" % (what, nirq, nnrdy))
        dh = 0xA0 | (dev << 4)
        if name in ("IDENTIFY", "SET_MULT"):
            want_tf = [count & 255, s, c & 255, c >> 8, dh | h]
        else:
            lc, lh, ls = chs_last(geo, c, h, s, count)
            want_tf = [count & 255, ls, lc & 255, lc >> 8, dh | lh]
        if tfr != want_tf:
            bad.append("%s: task file at the end %s, want %s (count, sector, cylinder low, high, device/head)"
                       % (what, " ".join("%02x" % x for x in tfr), " ".join("%02x" % x for x in want_tf)))
        want_in = 256 * count if name in ("READ", "READ_MULT") else 256 if name == "IDENTIFY" else 0
        want_out = 256 * count if name in ("WRITE", "WRITE_MULT") else 0
        if (win, wout) != (want_in, want_out):
            bad.append("%s: %d words in, %d out, want %d, %d" % (what, win, wout, want_in, want_out))
        if want_in + want_out == 0:
            notes.append("%s: status 40, task file %s" % (what, " ".join("%02x" % x for x in tfr)))
            continue
        path = os.path.join(run, fname)
        if fname == "-" or not os.path.isfile(path):
            bad.append("%s: no dump file %s" % (what, path))
            continue
        dump = read_hex(path)
        if len(dump) != 2 * (want_in + want_out):
            bad.append("%s: %s is %d bytes, want %d" % (what, fname, len(dump), 2 * (want_in + want_out)))
            continue
        if name == "IDENTIFY":
            want = ident.stream(HDF_FILE | HDF_SYNTHRDB, 0, geo[1], geo[2], geo[3], b"SYNTH   ", b"")
            # ATA words go low byte first, the first byte of a word into
            # bits 15:8 of the 68k's word: in the 68k's memory each ATA word
            # is little-endian (the Amiga IDE drivers swap them)
            words = [int.from_bytes(dump[2 * i:2 * i + 2], "little") for i in (1, 3, 6)]
            if words != [geo[1], geo[2], geo[3]]:
                bad.append("%s: IDENTIFY words 1, 3, 6 (C, H, S) are %s, the bench's geometry %s"
                           % (what, words, list(geo[1:4])))
            k0 = first_diff(dump, want)
            if k0 >= 0:
                bad.append("%s: differs from identify.py's stream at byte %d (%02x, want %02x)"
                           % (what, k0, dump[k0], want[k0]))
            else:
                notes.append("%s: = fw/ctrl/test/gold/identify.py (HDF_SYNTHRDB, CHS %d.%d.%d)" % ((what,) + geo[1:4]))
            continue
        lba = chs_lba(geo, c, h, s)
        nb = 0
        kinds = {}
        for i in range(count):
            blk = dump[512 * i:512 * i + 512]
            if name in ("WRITE", "WRITE_MULT"):
                want, src = wpattern(lba + i, "S" if name == "WRITE" else "M"), "the write pattern"
                written[(port, dev, lba + i)] = want
            else:
                want, src = drive_block(port, dev, lba + i)
            if want is None:
                bad.append("%s: LBA %d: %s" % (what, lba + i, src))
                nb += 1
                continue
            k0 = first_diff(blk, want)
            if k0 >= 0:
                nb += 1
                if nb <= 4:
                    bad.append("%s: LBA %d (%s) differs at byte %d (%02x, want %02x)" % (what, lba + i, src, k0, blk[k0], want[k0]))
            kinds[src.split(" block")[0]] = kinds.get(src.split(" block")[0], 0) + 1
        if nb > 4:
            bad.append("%s: %d of %d sectors differ" % (what, nb, count))
        if nb == 0:
            notes.append("%s: LBA %d..%d = %s" % (what, lba, lba + count - 1,
                                                    ", ".join("%s %d" % (x, n) for x, n in sorted(kinds.items()))))
            if name in ("WRITE", "WRITE_MULT"):
                nwr += count
            else:
                nsec += count

    # the card as the run left it: every written sector in SYNTH.HDF's
    # clusters at its block, no other sector changed
    orig_p, saved_p = os.path.join(run, "card", "hdd.img"), os.path.join(run, "card_saved.img")
    missing = [p for p in (orig_p, saved_p) if not os.path.isfile(p)]
    if missing:
        bad.append("no card image %s" % " ".join(missing))
    else:
        with open(orig_p, "rb") as f:
            orig = f.read()
        with open(saved_p, "rb") as f:
            saved = f.read()
        card = spitrace.Card(orig_p)
        want_lbas = {}
        for (port, dev, lba), data in written.items():
            geo = HDD_GEO[(port, dev)]
            n = lba - geo[4]
            lbas = card.file_lbas(geo[0])
            if not 0 <= n < len(lbas):
                bad.append("a write to %s LBA %d is outside the file" % (geo[0], lba))
                continue
            want_lbas[lbas[n]] = (data, "%s block %d (drive LBA %d)" % (geo[0], n, lba))
        if len(saved) != len(orig):
            bad.append("card_saved.img is %d bytes, the card %d" % (len(saved), len(orig)))
        else:
            changed = [i for i in range(len(orig) // 512) if orig[512 * i:512 * i + 512] != saved[512 * i:512 * i + 512]]
            stray = [i for i in changed if i not in want_lbas]
            if stray:
                bad.append("%d card sector(s) changed that no IDE write addressed, the first: %s"
                           % (len(stray), stray[:8]))
            wrong = [(i, what, first_diff(saved[512 * i:512 * i + 512], data))
                     for i, (data, what) in sorted(want_lbas.items())
                     if saved[512 * i:512 * i + 512] != data]
            for i, what, k0 in wrong[:4]:
                bad.append("card sector %d (%s) is not the written data (byte %d)" % (i, what, k0))
            if len(wrong) > 4:
                bad.append("%d of the %d written card sectors are not the written data" % (len(wrong), len(want_lbas)))
            if not stray and not wrong:
                notes.append("card_saved.img: the %d written sectors in SYNTH.HDF's clusters, no other sector changed"
                             % len(want_lbas))

    for b in bad:
        print("BAD  " + b)
    for n in notes:
        print("ok   " + n)
    if bad:
        print("FAIL hdd: %d problem(s)" % len(bad))
        return 1
    print("PASS hdd: %d IDE commands, %d sectors read = the drives, %d written and read back, on the saved card "
          "and nowhere else; IDENTIFY and the RDB blocks = the goldens" % (len(HDD_PLAN), nsec, nwr))
    return 0


def cue_disc(cue_path, bin_path):
    """TEST.CUE as the CUE sheet standard reads it (FILE, TRACK, PREGAP,
    INDEX 01; one BINARY file of 2352-byte sectors): the tracks (number,
    type, LBA of INDEX 01, the file sector of LBA 0's track), the lead-out
    LBA.  Independent of fw/ctrl/cue.c"""
    def msf(t):
        m, sec, f = (int(x) for x in t.split(":"))
        return (m * 60 + sec) * 75 + f
    tracks, gaps, cur = [], 0, None
    with open(cue_path) as f:
        for line in f:
            w = line.split()
            if not w:
                continue
            if w[0] == "FILE":
                if w[-1] != "BINARY":
                    raise ValueError("FILE is not BINARY")
            elif w[0] == "TRACK":
                cur = {"number": int(w[1]), "type": w[2]}
                tracks.append(cur)
            elif w[0] == "PREGAP":
                gaps += msf(w[1])
            elif w[0] == "INDEX" and int(w[1]) == 1:
                cur["file_sector"] = msf(w[2])
                cur["lba"] = msf(w[2]) + gaps
    size = os.path.getsize(bin_path)
    if size % 2352:
        raise ValueError("%s is not whole 2352-byte sectors" % bin_path)
    return tracks, size // 2352 + gaps


def cd_identify_words(src, name):
    """atapi_identify() of the C source src, field by field: the words it
    sets (id[n] = v; ata_string(id + n, "s", len) with the disc name for
    disc_name(u); the loop "for (i = 84; i <= 87; i++) id[i] = v"), the
    rest 0.  Returns the 256 words and the fields as (first word, words,
    what)"""
    with open(src) as f:
        text = f.read()
    m = re.search(r"\nvoid atapi_identify\(uint16_t \*id, const struct atapi_unit \*u\)\n\{\n(.*?)\n\}\n", text, re.S)
    if not m:
        raise ValueError("no atapi_identify() in %s" % src)
    words, fields = [0] * 256, []
    for line in m.group(1).splitlines():
        line = line.split("/*")[0].strip()
        if not line or line in ("int i;", "memset(id, 0, 256 * sizeof(uint16_t));"):
            continue
        a = re.match(r"id\[(\d+)\] = (0x[0-9A-Fa-f]+);$", line)
        b = re.match(r'ata_string\(id \+ (\d+), (?:"([^"]*)"|(disc_name\(u\))), (\d+|ATAPI_NAME_LEN)\);$', line)
        c = re.match(r"for \(i = (\d+); i <= (\d+); i\+\+\)$", line)
        d = re.match(r"id\[i\] = (0x[0-9A-Fa-f]+);$", line)
        if a:
            words[int(a.group(1))] = int(a.group(2), 16)
            fields.append((int(a.group(1)), 1, "id[%s] = %s" % (a.group(1), a.group(2))))
        elif b:
            n = 40 if b.group(4) == "ATAPI_NAME_LEN" else int(b.group(4))
            sv = b.group(2) if b.group(2) is not None else name
            st = (sv.encode("latin-1") + b" " * n)[:n]
            for i in range(0, n, 2):
                words[int(b.group(1)) + i // 2] = (st[i] << 8) | st[i + 1]
            fields.append((int(b.group(1)), n // 2, "ata_string %r (%d bytes)" % (st.decode("latin-1"), n)))
        elif c:
            loop = (int(c.group(1)), int(c.group(2)))
        elif d:
            for i in range(loop[0], loop[1] + 1):
                words[i] = int(d.group(1), 16)
            fields.append((loop[0], loop[1] - loop[0] + 1, "id[%d..%d] = %s" % (loop[0], loop[1], d.group(1))))
        else:
            raise ValueError("atapi_identify(): a line this check cannot read: %r" % line)
    return words, fields


def cd_sense(key, asc, ascq):
    """atapi.c request_sense(): fixed format, 18 bytes"""
    b = bytearray(18)
    b[0], b[2], b[7], b[12], b[13] = 0x70, key, 18 - 8, asc, ascq
    return bytes(b)


def cd(run):
    """the cd scenario's answers and data (README "cd")"""
    got = run_log(run, "cd")
    if got is None:
        return 1
    log, lines = got
    bad, notes, info = [], [], []
    cfg = [ln.split()[3] for ln in lines if ln.startswith("=== CD config ")]
    cpu = [ln.split()[2] for ln in lines if ln.startswith("=== CPU ")]
    if len(cfg) != 1 or cfg[0] not in ("cue", "iso") or cpu != ["rv"]:
        print("FAIL cd: want one '=== CD config <cue|iso>' and one '=== CPU rv' line in %s" % log)
        return 1
    cfg, cpu = cfg[0], cpu[0]
    content = os.path.join(run, "card", "content")
    img = os.path.join(run, "card", "cd.img" if cfg == "cue" else "cd_iso.img")
    other = os.path.join(run, "card", "cd_iso.img" if cfg == "cue" else "cd.img")
    check = os.path.join(run, "card", "cfg_" + cfg, "MINMGAA.check")
    for p in (img, check):
        if not os.path.isfile(p):
            print("FAIL cd: CD config %s, but no %s" % (cfg, p))
            return 1
    if os.path.exists(other):
        print("FAIL cd: CD config %s, but the run has %s too" % (cfg, other))
        return 1
    hf = {}
    with open(check) as f:
        for line in f:
            m = re.match(r"secondaryhardfile\[0\]\.(\w+) = (.*)$", line.rstrip("\n"))
            if m:
                hf[m.group(1)] = m.group(2)
    want_present = "2" if cfg == "cue" else "1"
    if hf.get("enabled") != "7" or hf.get("present") != want_present or hf.get("name") != '"TEST    "':
        print("FAIL cd: %s's CD slot (secondaryhardfile[0]) is %s, want enabled 7, present %s, name \"TEST    \""
              % (check, hf, want_present))
        return 1
    # cdrom.c CD_Open / CD_Insert: the long name if the config has one, else
    # the 8 characters of the name (atapi_insert keeps printable ASCII)
    disc_name = hf["long_name"][1:-1] or hf["name"][1:-1]
    if "\\" in disc_name:
        print("FAIL cd: the disc name %s has escaped bytes (this check does not model them)" % disc_name)
        return 1

    # the disc: (lba -> 2048 bytes), tracks for the TOC, lead-out
    if cfg == "cue":
        cue_p, bin_p = os.path.join(content, "TEST.CUE"), os.path.join(content, "TEST.BIN")
        with open(bin_p, "rb") as f:
            binf = f.read()
        tracks, leadout = cue_disc(cue_p, bin_p)
        data = tracks[0]
        if data["type"] != "MODE1/2352" or data["lba"] != 0 or data["file_sector"] != 0:
            print("FAIL cd: TEST.CUE's track 1 is not MODE1/2352 at LBA 0 (this check reads only that)")
            return 1
        data_end = tracks[1]["lba"] if len(tracks) > 1 else leadout   # gaps of track 2 come before its LBA

        def sector(lba):
            if not 0 <= lba < data_end:
                return None
            raw = binf[2352 * lba:2352 * lba + 2352]
            m, r = divmod(lba + 150, 75 * 60)
            sc, fr = divmod(r, 75)
            bcd = lambda v: ((v // 10) << 4) | (v % 10)
            if raw[:16] != b"\x00" + b"\xff" * 10 + b"\x00" + bytes((bcd(m), bcd(sc), bcd(fr), 1)):
                bad.append("TEST.BIN sector %d has no MODE1 sync / header for its MSF" % lba)
            return raw[16:16 + 2048]
        toc = [(1 if t["type"].startswith("MODE") else 0, t["number"], t["lba"]) for t in tracks]
        src_name = "TEST.BIN (MODE1/2352, user data from byte 16)"
    else:
        iso_p = os.path.join(content, "TEST.ISO")
        with open(iso_p, "rb") as f:
            iso = f.read()
        leadout = len(iso) // 2048      # cue.c cue_single: bytes / 2048

        def sector(lba):
            return iso[2048 * lba:2048 * lba + 2048] if 0 <= lba < leadout else None
        toc = [(1, 1, 0)]
        src_name = "TEST.ISO"

    def adr_ctrl(is_data):
        return 0x14 if is_data else 0x10

    def put32(v):
        return bytes(((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255))

    def pad(t, n):
        return (t.encode("latin-1") + b" " * n)[:n]

    # the answers (atapi.c), by plan index
    toc_b = bytearray()
    for is_data, num, lba in toc:
        toc_b += bytes((0, adr_ctrl(is_data), num, 0)) + put32(lba)
    toc_b += bytes((0, adr_ctrl(toc[-1][0]), 0xAA, 0)) + put32(leadout)
    toc_b = bytes(((len(toc_b) + 2) >> 8, (len(toc_b) + 2) & 255, 1, len(toc))) + toc_b
    inquiry = bytes((0x05, 0x80, 0x00, 0x21, 36 - 5, 0, 0, 0)) + pad("MINIMIG", 8) + pad(disc_name, 16) + pad("1.00", 4)
    pages = (bytes((0x01, 0x06, 0, 3, 0, 0, 0, 0))                                         # read error recovery
             + bytes((0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0xFF, 0x02, 0xFF, 0, 0, 0, 0))  # audio control, volume FF FF
             + bytes((0x2A, 0x12, 0, 0, 0x01, 0, 0x29, 0, 0x02, 0xC2, 0x01, 0x00, 0x00, 0x40, 0x02, 0xC2,
                      0, 0, 0, 0)))                                                       # capabilities, not locked
    mode = bytes(((len(pages) + 6) >> 8, (len(pages) + 6) & 255, 0, 0, 0, 0, 0, 0)) + pages

    def sectors(lba, n):
        out = bytearray()
        for i in range(n):
            blk = sector(lba + i)
            if blk is None:
                return None
            out += blk
        return bytes(out)
    answers = {
        1: (0x60, b""),                                  # UNIT ATTENTION 06/29/00
        2: (0, cd_sense(0x06, 0x29, 0x00)),
        3: (0, b""),
        4: (0, inquiry),
        5: (0, put32(leadout - 1) + put32(2048)),
        6: (0, toc_b),
        7: (0, sectors(16, 32)),
        8: (0, sectors(56, 8)),
        9: (0, mode),
        10: (0x54, b""),                                 # ILLEGAL REQUEST 05/20/00: 0x50 | ABRT
        11: (0, cd_sense(0x05, 0x20, 0x00)),
    }
    if answers[7][1] is None or answers[8][1] is None:
        print("FAIL cd: the READ(10) / READ(12) range is outside the disc's data track (%s)" % src_name)
        return 1

    # the log
    cmds, ends, phases = {}, {}, {}
    for line in lines:
        m = re.match(r"=== IDE cmd (\d+) ID_PACKET port (\d+) dev (\d+) chs 0/0/0 lba -?\d+ count 0 at cycle (\d+)$", line)
        if m:
            cmds[int(m.group(1))] = ("ID_PACKET", int(m.group(2)), int(m.group(3)), None, None, None, int(m.group(4)))
        m = re.match(r"=== IDE cmd (\d+) PACKET port (\d+) dev (\d+) packet ([0-9a-f]{24}) bytecount (\d+) want ([0-9a-f]{2}) at cycle (\d+)$", line)
        if m:
            cmds[int(m.group(1))] = ("PACKET", int(m.group(2)), int(m.group(3)), m.group(4), int(m.group(5)),
                                     int(m.group(6), 16), int(m.group(7)))
        m = re.match(r"=== IDE phase (\d+) (\d+): reason ([0-9a-f]{2}), (\d+) bytes at cycle (\d+)$", line)
        if m:
            phases.setdefault(int(m.group(1)), []).append((int(m.group(3), 16), int(m.group(4))))
        m = re.match(r"=== IDE end (\d+) (\S+): status ([0-9a-f]{2}) error ([0-9a-f]{2}) tf ([0-9a-f]{2}) ([0-9a-f]{2}) "
                     r"([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}), (\d+) words in, (\d+) out, file (\S+), waits (\d+) "
                     r"\(irq (\d+), poll (\d+), nrdy (\d+)\) min/median/max (\d+)/(\d+)/(\d+) clk_114, total (\d+), "
                     r"(\d+) cycles, at cycle (\d+)$", line)
        if m:
            ends[int(m.group(1))] = m
    if sorted(cmds) != list(range(1, len(CD_PLAN) + 1)):
        print("FAIL cd: the IDE commands in the log are %s, want 1..%d (CD_PLAN)" % (sorted(cmds), len(CD_PLAN)))
        return 1

    id_src = os.path.join(CD_FW, "ctrl", "atapi.c")
    ndata = nphase = 0
    for k, (name, pkt, lim, chk) in enumerate(CD_PLAN, 1):
        c, e = cmds[k], ends.get(k)
        what = "command %d %s" % (k, name)
        if e is None:
            bad.append("%s: no '=== IDE end %d' line" % (what, k))
            continue
        if (c[1], c[2]) != (CD_PORT, CD_DEV):
            bad.append("%s: on port %d dev %d, want %d %d (IDE port 2 master)" % (what, c[1], c[2], CD_PORT, CD_DEV))
        st, er = int(e.group(3), 16), int(e.group(4), 16)
        tfr = [int(e.group(i), 16) for i in range(5, 10)]
        win, wout, fname = int(e.group(10)), int(e.group(11)), e.group(12)
        path = os.path.join(run, fname)
        dump = read_hex(path) if fname != "-" and os.path.isfile(path) else None
        if pkt is None:
            if c[0] != "ID_PACKET" or e.group(2) != "ID_PACKET":
                bad.append("%s: the log has %s" % (what, c[0]))
                continue
            if (st, er, tfr) != (0x40, 0, [0, 0, 0, 0, 0xA0]):
                bad.append("%s: status %02x error %02x tf %s at the end, want 40 00 tf 00 00 00 00 a0"
                           % (what, st, er, " ".join("%02x" % x for x in tfr)))
            if (win, wout) != (256, 0) or dump is None or len(dump) != 512:
                bad.append("%s: %d words in, %d out, dump %s: want 256 words" % (what, win, wout, fname))
                continue
            words, fields = cd_identify_words(id_src, disc_name)
            got_w = [int.from_bytes(dump[2 * i:2 * i + 2], "little") for i in range(256)]
            nf = 0
            for first, n, desc in fields:
                if got_w[first:first + n] != words[first:first + n]:
                    bad.append("%s: IDENTIFY PACKET words %d..%d (%s, %s) are %s" % (
                        what, first, first + n - 1, desc, os.path.relpath(id_src, HERE),
                        " ".join("%04x" % x for x in got_w[first:first + n])))
                else:
                    nf += 1
            rest = [i for i in range(256) if got_w[i] != words[i]]
            if rest:
                bad.append("%s: IDENTIFY PACKET words %s differ from atapi_identify()" % (what, rest[:8]))
            w0 = got_w[0]
            dec = ("ATAPI" if w0 >> 14 == 2 else "not ATAPI", "CD-ROM" if (w0 >> 8) & 0x1F == 5 else "type %d" % ((w0 >> 8) & 0x1F),
                   "removable" if w0 & 0x80 else "fixed", "12-byte packets" if w0 & 3 == 0 else "16-byte packets" if w0 & 3 == 1 else "packet size %d" % (w0 & 3))
            model = bytes(b for w in got_w[27:47] for b in (w >> 8, w & 255)).decode("latin-1").rstrip()
            if dec != ("ATAPI", "CD-ROM", "removable", "12-byte packets"):
                bad.append("%s: word 0 %04x is %s" % (what, w0, ", ".join(dec)))
            if not rest:
                notes.append("%s: = atapi_identify() of %s, %d fields (%s); word 0 %04x: %s; model %r"
                             % (what, os.path.relpath(id_src, os.path.join(HERE, "..", "..")), nf,
                                "; ".join(d for _, _, d in fields), w0, ", ".join(dec), model))
            continue
        if c[0] != "PACKET" or c[3] != pkt or c[4] != lim:
            bad.append("%s: the log has %s packet %s limit %s, want %s %s" % (what, c[0], c[3], c[4], pkt, lim))
            continue
        want_st = 0x41 if chk else 0x40
        want_er, want = answers[k - 1]
        if c[5] != want_st:
            bad.append("%s: the bench expected status %02x, the plan %02x" % (what, c[5], want_st))
        want_tf = [0x03, 0x00, lim & 255, lim >> 8, 0xA0]
        if (st, er, tfr) != (want_st, want_er, want_tf):
            bad.append("%s: status %02x error %02x tf %s at the end, want %02x %02x tf %s" % (
                what, st, er, " ".join("%02x" % x for x in tfr), want_st, want_er, " ".join("%02x" % x for x in want_tf)))
        ph = phases.get(k, [])
        nphase += 1 + len(ph)
        tot = sum(n for _, n in ph)
        for i, (reason, n) in enumerate(ph):
            if reason != 0x02 or n <= 0 or n > min(lim, CD_FIFO) or n % 2:
                bad.append("%s: data phase %d is reason %02x, %d bytes (want 02, even, 1..%d)"
                           % (what, i, reason, n, min(lim, CD_FIFO)))
        if tot != len(want) or (win, wout) != ((len(want) + 1) // 2, 6):
            bad.append("%s: %d data bytes in %d phases (%d words in, %d out), want %d bytes (%d words in, 6 out)"
                       % (what, tot, len(ph), win, wout, len(want), (len(want) + 1) // 2))
            continue
        if not want:
            notes.append("%s: status %02x error %02x, no data" % (what, st, er))
            continue
        if dump is None or len(dump) != len(want):
            bad.append("%s: dump %s is %s bytes, want %d" % (what, fname, None if dump is None else len(dump), len(want)))
            continue
        k0 = first_diff(dump, want)
        if k0 >= 0:
            where = ""
            if name in ("READ10", "READ12"):
                lba0 = 16 if name == "READ10" else 56
                where = " (LBA %d byte %d of %s)" % (lba0 + k0 // 2048, k0 % 2048, src_name)
            bad.append("%s: differs at byte %d%s (%02x, want %02x)" % (what, k0, where, dump[k0], want[k0]))
            continue
        sizes = {}
        for _, n in ph:
            sizes[n] = sizes.get(n, 0) + 1
        split = ", ".join("%d x %d" % (sizes[n], n) for n in sorted(sizes, reverse=True))
        if name in ("READ10", "READ12"):
            lba0, n = (16, 32) if name == "READ10" else (56, 8)
            ndata += n
            notes.append("%s: LBA %d..%d = %s, in %s bytes" % (what, lba0, lba0 + n - 1, src_name, split))
        else:
            notes.append("%s: %d bytes = atapi.c's (%s)" % (what, len(want), " ".join("%02x" % b for b in want[:20])
                                                           + (" ..." if len(want) > 20 else "")))
    if cfg == "cue":
        notes.append("TOC = TEST.CUE: %s, lead-out %d" % (", ".join("track %d %s LBA %d" % (t["number"], t["type"], t["lba"])
                                                                   for t in tracks), leadout))
    else:
        notes.append("TOC = one data track at LBA 0, lead-out %d (TEST.ISO, %d bytes)" % (leadout, leadout * 2048))

    # item 9 (mon_l3.vh) and the service times
    hdr = [ln for ln in lines if ln.startswith("L3 bench: ")]
    if len(hdr) != 1 or " TICKDIV=%d TICKDIV_AT=scenario " % CD_TICKDIV not in hdr[0]:
        bad.append("the run is not at TICKDIV %d from the scenario's start: %s" % (CD_TICKDIV, hdr))
    m9 = [re.match(r"=== MARGIN 9 cd_timeout_left min ([0-9.]+) clk_114 \(bound 0, (\w+)\) over (\d+) phases$", ln)
          for ln in lines if ln.startswith("=== MARGIN 9 ")]
    i9 = [re.match(r"=== MARGIN \(info\) 9 cd longest phase window (\d+) clk_114 = ([0-9.]+) TIMER counts at TICKDIV (\d+) "
                   r"\(CD_TIMEOUT (\d+) counts = (\d+) clk_114\), ended at cycle (\d+), over (\d+) phases ?$", ln)
          for ln in lines if ln.startswith("=== MARGIN (info) 9 ")]
    if len(m9) != 1 or not m9[0] or len(i9) != 1 or not i9[0]:
        # (mon_l3.vh prints an empty %0s as one space: "phases " when every
        # window closed; "; one window still open at the end" fails here)
        bad.append("want one '=== MARGIN 9 cd_timeout_left' and one '=== MARGIN (info) 9' line, all windows closed")
    else:
        m9, i9 = m9[0], i9[0]
        if m9.group(2) != "ok" or int(m9.group(3)) != nphase or int(i9.group(7)) != nphase:
            bad.append("MARGIN 9: %s over %s phases, want ok over %d (one per packet and per data phase)"
                       % (m9.group(2), m9.group(3), nphase))
        w, at = int(i9.group(1)), int(i9.group(6))
        inside = [k for k in cmds if k in ends and cmds[k][-1] <= at <= int(ends[k].group(22))]
        info.append("longest phase window %d clk_114 = %s TIMER counts at TICKDIV %s, %.6f of CD_TIMEOUT (%s counts = %s clk_114), in %s"
                    % (w, i9.group(2), i9.group(3), w / float(i9.group(5)), i9.group(4), i9.group(5),
                       ", ".join("command %d %s" % (k, CD_PLAN[k - 1][0]) for k in inside) or "no command"))
    srv = []
    for k in sorted(ends):
        e = ends[k]
        srv.append("%d %s irq %s max %s" % (k, CD_PLAN[k - 1][0], e.group(14), e.group(19)))
    longest = max(sorted(ends), key=lambda k: int(ends[k].group(19)))
    info.append("the firmware's longest service time (the longest 68k-side wait on it: interrupt, BSY poll or nrdy): %s clk_114 in command %d %s"
                % (ends[longest].group(19), longest, CD_PLAN[longest - 1][0]))
    info.append("per command (interrupt waits; the longest wait of any kind, clk_114): " + "; ".join(srv))

    for b in bad:
        print("BAD  " + b)
    for n in notes:
        print("ok   " + n)
    for n in info:
        print("INFO " + n)
    if bad:
        print("FAIL cd: %d problem(s)" % len(bad))
        return 1
    print("PASS cd: %s, CPU %s: %d commands, IDENTIFY PACKET = atapi.c, INQUIRY / sense / capacity / TOC / MODE SENSE "
          "= atapi.c's for the disc, %d sectors = %s, CHECK CONDITION 06/29/00 and 05/20/00, %d phase windows under CD_TIMEOUT"
          % (cfg, cpu, len(CD_PLAN), ndata, src_name, nphase))
    return 0


def cdda_volume(src):
    """cda_init()'s volume in the C source src (cdaudio.c), and that fill()
    scales only when it is not 255 / 255"""
    with open(src) as f:
        text = f.read()
    v = [re.search(r"\n\tcda\.vol\[%d\] = (\d+);\n" % i, text) for i in (0, 1)]
    rule = "if (cda.vol[0] != 255 || cda.vol[1] != 255)\n\t\tscale(dst, CDA_HALF_FRAMES);" in text
    if not all(v) or not rule:
        raise ValueError("%s: cda_init's volume or fill()'s scale rule not found" % src)
    return int(v[0].group(1)), int(v[1].group(1))


def cdda_scale(buf, vol):
    """cdaudio.c scale(): each 16-bit LE sample times vol / 256, rounded
    toward zero (left vol[0], right vol[1])"""
    if vol == (255, 255):
        return bytes(buf)
    out = bytearray(buf)
    for i in range(0, len(out), 2):
        v = vol[(i >> 1) & 1]
        x = int.from_bytes(out[i:i + 2], "little", signed=True)
        x = -((-x * v) >> 8) if x < 0 else (x * v) >> 8
        out[i:i + 2] = (x & 0xFFFF).to_bytes(2, "little")
    return bytes(out)


def cdda(run):
    """the cdda / cdda_load scenario (README "cdda")"""
    got = run_log(run, "cdda")
    if got is None:
        return 1
    log, lines = got
    bad, notes, info = [], [], []
    hdr = [ln for ln in lines if ln.startswith("L3 bench: ")]
    cpu = [ln.split()[2] for ln in lines if ln.startswith("=== CPU ")]
    m = re.search(r" SCENARIO=(\S+) ", hdr[0]) if len(hdr) == 1 else None
    if not m or m.group(1) not in ("cdda", "cdda_load") or cpu != ["rv"]:
        print("FAIL cdda: want one 'L3 bench: ... SCENARIO=cdda|cdda_load' and one '=== CPU rv' line in %s" % log)
        return 1
    scen, cpu = m.group(1), cpu[0]
    load = scen == "cdda_load"
    if " TICKDIV=%d TICKDIV_AT=scenario " % CD_TICKDIV not in hdr[0]:
        bad.append("the run is not at TICKDIV %d from the scenario's start: %s" % (CD_TICKDIV, hdr[0]))
    content = os.path.join(run, "card", "content")
    img = os.path.join(run, "card", "cdhdd.img" if load else "cd.img")
    check = os.path.join(run, "card", "cfg_cue", "MINMGAA.check")
    for p in (img, check):
        if not os.path.isfile(p):
            print("FAIL cdda: scenario %s, but no %s" % (scen, p))
            return 1
    hf = {}
    with open(check) as f:
        for line in f:
            mm = re.match(r"secondaryhardfile\[0\]\.(\w+) = (.*)$", line.rstrip("\n"))
            if mm:
                hf[mm.group(1)] = mm.group(2)
    if hf.get("enabled") != "7" or hf.get("present") != "2" or hf.get("name") != '"TEST    "':
        print("FAIL cdda: %s's CD slot is %s, want enabled 7, present 2 (TEST.CUE), name \"TEST    \"" % (check, hf))
        return 1

    # the disc: TEST.CUE's tracks (an independent reader), TEST.BIN
    bin_p = os.path.join(content, "TEST.BIN")
    with open(bin_p, "rb") as f:
        binf = f.read()
    tracks, leadout = cue_disc(os.path.join(content, "TEST.CUE"), bin_p)
    vol_src = os.path.join(CD_FW, "ctrl", "cdaudio.c")
    vol = cdda_volume(vol_src)
    total = (CDDA_END - CDDA_START) * 588
    t2 = [t for t in tracks if t["lba"] <= CDDA_START][-1]
    if t2["type"] != "AUDIO" or t2["lba"] != CDDA_START:
        print("FAIL cdda: LBA %d is not the INDEX 01 of an audio track in TEST.CUE (%s)" % (CDDA_START, tracks))
        return 1

    def produce(f0, n):
        """cdaudio.c produce() + fill(): n frames of the range from range
        frame f0, then scale()"""
        out = bytearray()
        for f in range(f0, f0 + n):
            if f >= total:
                out += bytes(4)
                continue
            lba = CDDA_START + f // 588
            t = [x for x in tracks if x["lba"] <= lba][-1]
            if t["type"] != "AUDIO" or lba >= leadout:
                out += bytes(4)
                continue
            off = (t["file_sector"] + lba - t["lba"]) * 2352 + (f % 588) * 4
            out += (binf[off:off + 4] + bytes(4))[:4]
        return cdda_scale(out, vol)

    # the IDE commands
    plan = CDDA_PLAN[:2] + (CDDA_LOAD if load else []) + CDDA_PLAN[2:]
    cmds, ends = {}, {}
    for line in lines:
        mm = re.match(r"=== IDE cmd (\d+) PACKET port (\d+) dev (\d+) packet ([0-9a-f]{24}) bytecount (\d+) want ([0-9a-f]{2}) at cycle (\d+)$", line)
        if mm:
            cmds[int(mm.group(1))] = ("PACKET", int(mm.group(2)), int(mm.group(3)), mm.group(4), int(mm.group(5)))
        mm = re.match(r"=== IDE cmd (\d+) (\S+) port (\d+) dev (\d+) chs (\d+)/(\d+)/(\d+) lba (-?\d+) count (\d+) at cycle (\d+)$", line)
        if mm:
            cmds[int(mm.group(1))] = (mm.group(2), int(mm.group(3)), int(mm.group(4))) + tuple(int(mm.group(i)) for i in (5, 6, 7, 8, 9))
        mm = re.match(r"=== IDE end (\d+) (\S+): status ([0-9a-f]{2}) error ([0-9a-f]{2}) tf ([0-9a-f]{2}) ([0-9a-f]{2}) "
                      r"([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}), (\d+) words in, (\d+) out, file (\S+), waits (\d+) "
                      r"\(irq (\d+), poll (\d+), nrdy (\d+)\) min/median/max (\d+)/(\d+)/(\d+) clk_114, total (\d+), "
                      r"(\d+) cycles, at cycle (\d+)$", line)
        if mm:
            ends[int(mm.group(1))] = mm
    if sorted(cmds) != list(range(1, len(plan) + 1)):
        print("FAIL cdda: the IDE commands in the log are %s, want 1..%d (CDDA_PLAN)" % (sorted(cmds), len(plan)))
        return 1
    subch = None
    hdf_geo = HDD_GEO[(0, 1)]
    for k, (name, pkt, want_st, want_er, nbytes) in enumerate(plan, 1):
        c, e = cmds[k], ends.get(k)
        what = "command %d %s" % (k, name)
        if e is None:
            bad.append("%s: no '=== IDE end %d' line" % (what, k))
            continue
        st, er = int(e.group(3), 16), int(e.group(4), 16)
        tfr = [int(e.group(i), 16) for i in range(5, 10)]
        win, wout, fname = int(e.group(10)), int(e.group(11)), e.group(12)
        path = os.path.join(run, fname)
        dump = read_hex(path) if fname != "-" and os.path.isfile(path) else None
        if pkt is not None:
            if c[0] != "PACKET" or (c[1], c[2]) != (CD_PORT, CD_DEV) or c[3] != pkt or c[4] != 0xFFFE:
                bad.append("%s: the log has %s, want PACKET %s on port %d dev %d limit 65534" % (what, c, pkt, CD_PORT, CD_DEV))
                continue
            want_tf = [0x03, 0x00, 0xFE, 0xFF, 0xA0]
            if (st, er, tfr) != (want_st, want_er, want_tf):
                bad.append("%s: status %02x error %02x tf %s at the end, want %02x %02x tf %s" % (
                    what, st, er, " ".join("%02x" % x for x in tfr), want_st, want_er, " ".join("%02x" % x for x in want_tf)))
            if (win, wout) != ((nbytes + 1) // 2, 6):
                bad.append("%s: %d words in, %d out, want %d in, 6 out" % (what, win, wout, (nbytes + 1) // 2))
            if nbytes:
                if dump is None or len(dump) != nbytes:
                    bad.append("%s: dump %s has %s bytes, want %d" % (what, fname, None if dump is None else len(dump), nbytes))
                elif name == "READ_SUBCHANNEL":
                    subch = dump
            continue
        # cdda_load's ATA commands on SYNTH.HDF (port 0 slave)
        if c[0] != name or (c[1], c[2]) != (0, 1):
            bad.append("%s: the log has %s, want %s on port 0 dev 1 (SYNTH.HDF)" % (what, c, name))
            continue
        if (st, er) != (want_st, want_er):
            bad.append("%s: status %02x error %02x at the end, want %02x %02x" % (what, st, er, want_st, want_er))
        if name == "READ_MULT":
            cc, hh, ss = c[3], c[4], c[5]
            lba = chs_lba(hdf_geo, cc, hh, ss)
            lc, lh, ls = chs_last(hdf_geo, cc, hh, ss, CDDA_HDF_N)
            if lba != CDDA_HDF_LBA or tfr != [0, ls, lc & 255, lc >> 8, 0xB0 | lh]:
                bad.append("%s: LBA %d, task file at the end %s, want LBA %d and 00 %02x %02x %02x %02x"
                           % (what, lba, " ".join("%02x" % x for x in tfr), CDDA_HDF_LBA, ls, lc & 255, lc >> 8, 0xB0 | lh))
            with open(os.path.join(content, "SYNTH.HDF"), "rb") as f:
                hdf = f.read()
            n0 = CDDA_HDF_LBA - hdf_geo[4]
            want = hdf[512 * n0:512 * (n0 + CDDA_HDF_N)]
            if win != CDDA_HDF_N * 256 or dump is None or len(want) != CDDA_HDF_N * 512:
                bad.append("%s: %d words in, dump %s: want %d sectors" % (what, win, fname, CDDA_HDF_N))
            else:
                k0 = first_diff(dump, want)
                if k0 >= 0:
                    bad.append("%s: differs at byte %d (SYNTH.HDF block %d byte %d) (%02x, want %02x)"
                               % (what, k0, n0 + k0 // 512, k0 % 512, dump[k0], want[k0]))
                else:
                    notes.append("%s: drive LBA %d..%d = SYNTH.HDF blocks %d..%d, %d waits, the longest %s clk_114"
                                 % (what, CDDA_HDF_LBA, CDDA_HDF_LBA + CDDA_HDF_N - 1, n0, n0 + CDDA_HDF_N - 1,
                                    int(e.group(13)), e.group(19)))

    # the player's runs and halves (bfm_audio.v).  Only the runs from the
    # PLAY command on count: the boot's audio_clear() (main.c: the ring
    # zeroed, ENA for one TIMER count, CLEAR) is a run of its own before
    # the scenario; they are numbered from 0 at the PLAY's here
    play_at = [int(mm.group(1)) for mm in (re.match(r"=== IDE cmd \d+ PACKET port \d+ dev \d+ packet 47[0-9a-f]{22} "
                                                     r"bytecount \d+ want [0-9a-f]{2} at cycle (\d+)$", ln) for ln in lines) if mm]
    if len(play_at) != 1:
        print("FAIL cdda: want one PLAY AUDIO MSF command line in %s" % log)
        return 1
    play_at = play_at[0]
    starts = {}
    for line in lines:
        mm = re.match(r"=== CDDA run (\d+) start at cycle (\d+)$", line)
        if mm:
            starts[int(mm.group(1))] = int(mm.group(2))
    r0 = min([r for r in starts if starts[r] >= play_at] or [None]) if starts else None
    early = sorted(r for r in starts if starts[r] < play_at)
    if r0 is None:
        print("FAIL cdda: no player run after the PLAY command (cycle %d)" % play_at)
        return 1
    if early:
        notes.append("player run(s) %s before the PLAY (the boot's audio_clear()) not counted; the PLAY's run is bfm_audio's run %d"
                     % (early, r0))
    halves, runs = [], {}
    for line in lines:
        mm = re.match(r"=== CDDA half (\d+) run (\d+) k (\d+) ring half (\d) at cycle (\d+): (\S+)$", line)
        if mm and int(mm.group(2)) >= r0:
            halves.append((int(mm.group(1)), int(mm.group(2)) - r0) + tuple(int(mm.group(i)) for i in range(3, 6)) + (mm.group(6),))
        mm = re.match(r"=== CDDA run (\d+) end at cycle (\d+): (\d+) frames played, (\d+) halves$", line)
        if mm and int(mm.group(1)) >= r0:
            runs[int(mm.group(1)) - r0] = (int(mm.group(3)), int(mm.group(4)), int(mm.group(2)))
    n_first = halves[0][0] if halves else 1
    want_hk = [(r, k) for r, n in enumerate(CDDA_RUNS) for k in range(n)]
    if [(h[1], h[2]) for h in halves] != want_hk or [h[0] for h in halves] != list(range(n_first, n_first + len(halves))):
        print("BAD  the player's halves (run, k) are %s, want %s" % ([(h[1], h[2]) for h in halves], want_hk))
        print("FAIL cdda: the halves are not the plan's (two runs of %s halves)" % (CDDA_RUNS,))
        return 1
    if sorted(runs) != [0, 1] or [runs[r][1] for r in (0, 1)] != list(CDDA_RUNS):
        bad.append("the '=== CDDA run <r> end' lines are %s, want runs 0 and 1 with %s halves" % (runs, CDDA_RUNS))
    snaps = {}
    for n, r, k, rh, at, fname in halves:
        if rh != k % 2:
            bad.append("half %d (run %d k %d): ring half %d, want %d" % (n, r, k, rh, k % 2))
        p = os.path.join(run, fname)
        if not os.path.isfile(p) or os.path.getsize(p) != CDDA_HALF * 4:
            bad.append("half %d: no %d-byte snapshot %s" % (n, CDDA_HALF * 4, p))
            continue
        with open(p, "rb") as f:
            snaps[(r, k)] = f.read()
    if sorted(runs) != [0, 1] or len(snaps) != len(halves):
        for b in bad:
            print("BAD  " + b)
        print("FAIL cdda: %d problem(s)" % len(bad))
        return 1

    # the paused position: READ SUB-CHANNEL, the RESUME's first half, the player
    played0 = runs[0][0]
    pos = None
    if subch is not None:
        lba = int.from_bytes(subch[8:12], "big")
        rel = int.from_bytes(subch[12:16], "big", signed=True)
        want_head = bytes((0x00, 0x12, 0x00, 0x0C, 0x01, 0x10, 0x02, 0x01))
        if subch[:8] != want_head or rel != lba - CDDA_START:
            bad.append("READ SUB-CHANNEL: %s, want %s, LBA, LBA - %d (paused, audio, track 2 index 1)"
                       % (subch.hex(), want_head.hex(), CDDA_START))
        cands = [p for p in range(0, total, CDDA_UNIT) if CDDA_START + p // 588 == lba]
        hit = [p for p in cands if produce(p, CDDA_HALF) == snaps[(1, 0)]]
        if len(hit) != 1:
            bad.append("the RESUME's first half is the range from none of the TIMER-unit positions %s of LBA %d "
                       "(READ SUB-CHANNEL)" % (cands, lba))
        else:
            pos = hit[0]
            if abs(pos - played0) > CDDA_HALF:
                bad.append("the paused position %d frames is more than one half (%d) from the %d frames the player played"
                           % (pos, CDDA_HALF, played0))
            if abs((lba - CDDA_START) * 588 - played0) > CDDA_HALF + 588:
                bad.append("READ SUB-CHANNEL LBA %d is more than one half from the player (%d frames)" % (lba, played0))
            notes.append("READ SUB-CHANNEL: paused at LBA %d (relative %d); the RESUME starts at range frame %d = %d "
                         "TIMER units; the player had played %d frames (%+d)" % (lba, rel, pos, pos // CDDA_UNIT, played0,
                                                                                 pos - played0))
    if pos is None:
        bad.append("no paused position: the RESUME's halves are not checked")

    # every half
    late, wrong, nzero = [], [], 0
    for n, r, k, rh, at, fname in halves:
        base = 0 if r == 0 else pos
        if base is None:
            continue
        want = produce(base + k * CDDA_HALF, CDDA_HALF)
        got = snaps[(r, k)]
        if got == want:
            continue
        if not any(got):
            nzero += 1
        # a run's first two halves are filled before its ENA (cdaudio.c
        # run()): they cannot be late
        stale = snaps.get((r, k - 2))
        frames_bad = [i for i in range(0, len(got), 4)
                      if stale is None or got[i:i + 4] not in (want[i:i + 4], stale[i:i + 4], bytes(4))]
        k0 = first_diff(got, want)
        desc = "half %d (run %d k %d, range frames %d..%d, cycle %d): differs from byte %d (%02x, want %02x)" % (
            n, r, k, base + k * CDDA_HALF, base + (k + 1) * CDDA_HALF - 1, at, k0, got[k0], want[k0])
        if stale is None:
            wrong.append(desc + "; a half the run filled before it started")
        elif frames_bad:
            wrong.append(desc + "; frame %d is neither the expected, the half's earlier content nor zero" % (frames_bad[0] // 4))
        else:
            late.append(desc + "; a late refill (every frame expected, earlier or zero)")
    for w in wrong:
        bad.append("WRONG " + w)
    if not load:
        for w in late:
            bad.append("UNDERRUN " + w)
    else:
        for w in late:
            info.append("UNDERRUN " + w)

    # the refills (mon_l3.vh)
    fills = [re.match(r"=== CDDA fill (\d+) start (\d+) done (\d+|none)", ln) for ln in lines if ln.startswith("=== CDDA fill ")]
    nflip = sum(n - 1 for n in CDDA_RUNS)
    if not all(fills):
        bad.append("an '=== CDDA fill' line this check cannot read")
    fills = [f for f in fills if f and int(f.group(2)) >= play_at]
    if len(fills) != nflip or [int(f.group(1)) for f in fills] != list(range(int(fills[0].group(1)) if fills else 1,
                                                                               (int(fills[0].group(1)) if fills else 1) + nflip)):
        bad.append("the '=== CDDA fill' lines after the PLAY are for flips %s, want %d consecutive" % ([f.group(1) for f in fills], nflip))
    elif any(f.group(3) == "none" for f in fills):
        bad.append("a flip without a refill write: flips %s" % [f.group(1) for f in fills if f.group(3) == "none"])
    # the ring after the STOP: release() zeroes both halves (cdaudio.c)
    sdram = os.path.join(run, "sdram.bin")
    if not os.path.isfile(sdram):
        bad.append("no %s (the SDRAM at the end of the run)" % sdram)
    else:
        with open(sdram, "rb") as f:
            f.seek(CDDA_RING)
            ring = f.read(0x10000)
        nz = [i for i, x in enumerate(ring) if x]
        if len(ring) != 0x10000:
            bad.append("%s ends inside the ring (%d of 65536 bytes)" % (sdram, len(ring)))
        elif nz:
            bad.append("the ring is not zero after the STOP (release()): %d nonzero bytes, the first at host %06x (%02x)"
                       % (len(nz), CDDA_RING + nz[0], ring[nz[0]]))
        else:
            notes.append("the ring (host %06x..%06x) is all zero after the STOP (release())" % (CDDA_RING, CDDA_RING + 0xFFFF))
    pw = [ln for ln in lines if ln.startswith("=== CDDA writes into the playing half: ")]
    npw = int(pw[0].split()[-1]) if len(pw) == 1 else None
    if npw is None:
        bad.append("no '=== CDDA writes into the playing half' line")
    elif npw and not load:
        bad.append("%d writes into the playing half (the firmware's underrun response)" % npw)
    for key in ("=== CDDA fills ", "=== CDDA main loop while playing: ", "=== CDDA start fill "):
        for ln in lines:
            if ln.startswith(key):
                info.append(ln[4:])
    nh = len(halves)
    info.append("%s, CPU %s: %d halves, %d underrun(s) (late refills), %d zero-filled, %s writes into the playing half"
                % (scen, cpu, nh, len(late), nzero, npw))

    for b in bad:
        print("BAD  " + b)
    for n in notes:
        print("ok   " + n)
    for n in info:
        print("INFO " + n)
    if bad:
        print("FAIL cdda: %d problem(s)" % len(bad))
        return 1
    print("PASS cdda: %s, CPU %s: %d commands, %d halves of 2 runs (%d flips) = TEST.BIN's track 2 at the firmware's "
          "position (volume %d/%d), %d underrun(s)%s, READ SUB-CHANNEL within one half of the player%s"
          % (scen, cpu, len(plan), nh, nflip, vol[0], vol[1], len(late), " (counted)" if load else "",
             ", %d HDF sectors = SYNTH.HDF" % CDDA_HDF_N if load else ""))
    return 0


AKI_N = 32
AKI_DATA_REG = "ffff84"          # 0xFFFFFF84: the Akiko DATA register (hw.txt prints the low 24 bits)


def aki_pattern(b, i):
    """the bench's request pattern (bfm_akiko.v): (addr, data) of write i /
    the addr of read i of block b"""
    return 0x20 + 0x80 * b + i, (((i + 1) * 0x9E37) & 0xFFFF) ^ (0xC3A5 if b == 1 else 0)


def aki_expected(b, k, upper):
    """(kind, addr, data, UART text) of request k (0..63) of block b"""
    fmt = "%X" if upper else "%x"
    if k < AKI_N:
        addr, data = aki_pattern(b, k)
        return "W", addr, data, ("Akiko write: " + fmt + ", " + fmt) % (0xC000 | addr, data)
    addr, _ = aki_pattern(b, k - AKI_N)
    return "R", addr, 0, ("Akiko read: " + fmt) % (0x8000 | addr)


def stats(v):
    v = sorted(v)
    return "n %d min %d median %d max %d" % (len(v), v[0], v[len(v) // 2], v[-1]) if v else "n 0"


def akiko(run):
    got = run_log(run, "akiko")
    if got is None:
        return 1
    log, lines = got
    bad, notes = [], []
    # the firmware prints upper-case hex (%X)
    upper = True
    # the bench's requests
    reqs = []
    for l in lines:
        m = re.match(r"=== AKIKO req (\d+) (\d+) ([WR]) addr ([0-9a-f]{2}) d ([0-9a-f]{4}) q ([0-9a-fx]{4}) "
                     r"req (\d+) ack (\d+) lat (-?\d+) rearm (-?\d+) dma ([01])$", l)
        if m:
            reqs.append((int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4), 16), int(m.group(5), 16),
                         m.group(6), int(m.group(7)), int(m.group(8)), int(m.group(9)), int(m.group(10)), int(m.group(11))))
    want = [(b, k) for b in (0, 1) for k in range(2 * AKI_N)]
    if [(r[0], r[1]) for r in reqs] != want:
        bad.append("the requests in the log are %s ..., want blocks 0 and 1 of 64 in order (none lost, none repeated): %d found"
                   % ([(r[0], r[1]) for r in reqs[:3]], len(reqs)))
    exp_uart = []
    for r in reqs:
        b, k, kind, addr, data, q, t_req, t_ack, lat, rearm, dma = r
        ekind, eaddr, edata, etext = aki_expected(b, k, upper)
        if (kind, addr) != (ekind, eaddr) or (kind == "W" and data != edata):
            bad.append("request %d/%d: %s addr %02x data %04x, want %s addr %02x data %04x"
                       % (b, k, kind, addr, data, ekind, eaddr, edata if kind == "W" else 0))
        if q != "0000":
            bad.append("request %d/%d: the answer (amiga_q) is %s, the host answers 0" % (b, k, q))
        if lat <= 0 or t_ack <= t_req:
            bad.append("request %d/%d: not acked (lat %d)" % (b, k, lat))
        if rearm <= 0:
            bad.append("request %d/%d: no EnableInterrupts after the ack (rearm %d)" % (b, k, rearm))
        exp_uart.append(etext)
    # the UART, as the firmware prints the requests
    # (a line may start with earlier text that ended in \r, not \n: from "Akiko" on)
    uart = [l[l.index("Akiko"):] for l in lines if l.startswith("UART: ") and "Akiko" in l]
    if uart != exp_uart:
        i = first_diff(uart, exp_uart)
        bad.append("the UART Akiko lines differ from the pattern at line %d (of %d, want %d): got %r, want %r"
                   % (i, len(uart), len(exp_uart), uart[i] if i < len(uart) else None,
                      exp_uart[i] if i < len(exp_uart) else None))
    # one DATA write (the ack) per request
    hw = os.path.join(run, "hw.txt")
    nw = 0
    if os.path.isfile(hw):
        with open(hw) as f:
            for l in f:
                w = l.split()
                if len(w) == 4 and w[2] == AKI_DATA_REG:
                    nw += 1
                    if int(w[3], 16) != 0:
                        bad.append("hw.txt: Akiko DATA written with %s (want 0): %s" % (w[3], l.strip()))
        if nw != 2 * 2 * AKI_N:
            bad.append("hw.txt: %d Akiko DATA writes, want %d (one ack per request)" % (nw, 4 * AKI_N))
    else:
        bad.append("no %s" % hw)
    # block 1 inside the track DMA
    b1 = [r for r in reqs if r[0] == 1]
    ndma = sum(r[10] for r in b1)
    if b1 and (b1[0][10] != 1 or ndma < 16):
        bad.append("block 1: first request in the DMA %d, %d of %d requests acked inside it (want the first and >= 16)"
                   % (b1[0][10], ndma, len(b1)))
    # the two track reads
    adf_path = os.path.join(run, "card", "content", "TEST.ADF")
    if not os.path.isfile(adf_path):
        bad.append("no %s" % adf_path)
    else:
        with open(adf_path, "rb") as f:
            adf = f.read()
        mfm = load_mfm()
        dmas = [(int(m.group(2)), int(m.group(3)), int(m.group(4)))
                for m in (re.match(r"=== FDD dma (\d+) cylinder (\d+) head (\d+): (\d+) words to blckint at cycle (\d+)", l)
                          for l in lines) if m]
        if [(c, h) for c, h, _ in dmas] != [(0, 0), (1, 0)] or any(n != FDD_WORDS for _, _, n in dmas):
            bad.append("the track reads in the log are %s, want (0, 0) and (1, 0) of %d words" % (dmas, FDD_WORDS))
        for cyl, head in ((0, 0), (1, 0)):
            path = os.path.join(run, "akiko_%d_%d.hex" % (cyl, head))
            if not os.path.isfile(path):
                bad.append("no dump %s" % path)
                continue
            dump = read_hex(path)
            tbad, found = fdd_track(mfm, adf, cyl, head, dump)
            bad += ["track %d/%d: %s" % (cyl, head, b) for b in tbad]
            if not tbad:
                notes.append("track %d/%d read during the Akiko traffic: %d sectors decode = TEST.ADF" % (cyl, head, len(found)))
    fdd_osd(lines, run, bad, notes)
    for line in lines:
        if line.startswith("UART: ") and re.search(r"Illegal track|Fatal|Wrong header", line):
            bad.append("UART: %s" % line[6:])
    # the latency table
    for b in (0, 1):
        for kind, name in (("W", "write"), ("R", "read")):
            sel = [r for r in reqs if r[0] == b and r[2] == kind]
            notes.append("LAT block %d %-5s amiga_req to amiga_ack (clk_114): %s; ack to EnableInterrupts: %s"
                         % (b, name, stats([r[8] for r in sel]), stats([r[9] for r in sel])))
    notes.append("block 1: %d of %d requests acked inside the track DMA" % (ndma, len(b1)))
    for n in notes:
        print("ok   " + n)
    for b in bad:
        print("BAD  " + b)
    if bad:
        print("FAIL akiko: %d problem(s) (the BAD lines)" % len(bad))
        return 1
    print("PASS akiko: %d requests in 2 blocks, every UART line = the pattern, every read 0, %d DATA writes = %d acks, "
          "%d of block 1 inside the track DMA" % (len(reqs), nw, len(reqs), ndma))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "kick":
        return kick(argv[2])
    if len(argv) == 3 and argv[1] == "order":
        return order(argv[2])
    if len(argv) in (3, 4) and argv[1] == "mmc":
        golden = argv[3] if len(argv) == 4 else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                             "gold", "mmc_init_rv.txt")
        return mmc(argv[2], golden)
    if len(argv) == 3 and argv[1] == "memhash":
        return memhash(argv[2])
    if len(argv) == 3 and argv[1] == "keys":
        return keys(argv[2])
    if len(argv) == 3 and argv[1] == "fdd_rd":
        return fdd_rd(argv[2])
    if len(argv) in (3, 4) and argv[1] == "fdd_wr":
        return fdd_wr(argv[2], argv[3] if len(argv) == 4 else None)
    if len(argv) == 3 and argv[1] == "hdd":
        return hdd(argv[2])
    if len(argv) == 3 and argv[1] == "cd":
        return cd(argv[2])
    if len(argv) == 3 and argv[1] == "cdda":
        return cdda(argv[2])
    if len(argv) == 3 and argv[1] == "akiko":
        return akiko(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
