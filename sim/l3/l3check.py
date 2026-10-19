#!/usr/bin/env python3
"""l3check.py: offline data checks of an L3 run directory (sim/l3/run.sh).

    python3 -I l3check.py kick <run>
    python3 -I l3check.py order <run>
    python3 -I l3check.py mmc <run> [<golden>]
    python3 -I l3check.py memhash <run>
    python3 -I l3check.py keys <run>
    python3 -I l3check.py fdd_rd <run>
    python3 -I l3check.py hdd <run>

kick: the 256 KB kickstart the firmware uploaded equals the card's KICK.ROM
byte for byte.  UploadKickstart (fw/ctrl_rv/config.c) sends a 0x40000-byte
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
place (spitrace.py norm reads them; a line already hashed stays).

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
    (spitrace.py osd) after the osd / all SUBST and DROP rules of
    expected_diff.txt = osdtext_expect/keys.txt, which must equal what
    osdtext_expect/osdpages.py keys writes (not stale)
It prints "REPLY <cmd> byte <k>: <right> of <n> right" per reply byte
(VERSION 88 bytes 0-5, KEYQ 98 byte 0 = the status, 1.. the per-key bytes)
before its verdict.

fdd_rd (scenario fdd_rd): the floppy reads of bfm_floppy against TEST.ADF.
The run log's "=== FDD dma <k> cylinder <c> head <h>: <n> words to
blckint" lines must be the 10 track reads of the scenario (FDD_TRACKS
below, in order, FDD_WORDS words each), and each dump
<run>/fdd_rd_<c>_<h>.hex (the words Agnus moved, in order) must:
  - decode with fw/ctrl_rv/test/gold/mfm.py's decode_sector: the read runs
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
    (fw/ctrl_rv/test/gold/mfm_c00_s0.hex, mfm_c79_s1.hex)
and the OSD and UART:
  - no OSD_CMD_OSD_WR frame before the first key event (an error page) and
    none after the first track DMA started (the OSD is closed; fdd.c's
    FatalError would draw one)
  - after the first key event, an OSD row 3 "Floppy disk sounds : on" and
    then an OSD row 0 "df0: TEST" (keys/insert_df0.txt: sounds on, TEST.ADF
    in df0), decoded as spitrace.py osd
  - no UART line with "Illegal track", "Fatal" or "Wrong header"

hdd (scenario hdd, bfm_ide.v): from the run log's "=== IDE cmd" / "=== IDE
end" lines and the dumps <run>/hdd_<k>.hex (the 68k's words, first word
first = the bytes in its memory order):
  - the commands are HDD_PLAN below, in order, each ending with status 40
    (DRDY, no ERR), error 00, at least one wait (item 8), the words in /
    out of its kind, and the task file the firmware leaves: the CHS of the
    last sector (hdd.c's CHS advance; the cylinder > 255 reads), the host's
    own registers for IDENTIFY / SET MULTIPLE
  - IDENTIFY of SYNTH.HDF = fw/ctrl_rv/test/gold/identify.py's stream for
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

GOLD = os.path.join(HERE, "..", "..", "fw", "ctrl_rv", "test", "gold")

# scenario fdd_rd (scenarios.vh FDD_PLAN): (cylinder, head) in order
FDD_TRACKS = [(0, 0), (1, 0), (2, 0), (39, 0), (40, 0), (41, 0), (77, 0), (78, 0), (79, 0), (79, 1)]
FDD_WORDS = 6334
FDD_SYNC = 0x4489
FDD_GOLDEN = {(0, 0): "mfm_c00_s0.hex", (79, 1): "mfm_c79_s1.hex"}

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
    rules = [r for r in spitrace.read_rules(os.path.join(HERE, "expected_diff.txt"))
             if r.kind in ("SUBST", "DROP") and r.applies("osd")]
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
        t = "%s %s" % (row, text) if text else str(row)
        for r in rules:
            if r.kind == "DROP" and r.re.search(t):
                t = None
                break
            if r.kind == "SUBST":
                t = r.re.sub(r.repl, t)
        if t is not None:
            pages.append(t)
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
    frames = frames_t(os.path.join(run, "spi_t.txt"))
    evs = [int(m.group(1)) for m in (re.match(r"=== KEYS ev \d+ [0-9a-f]{2} at cycle (\d+)$", l) for l in lines) if m]
    dma0 = next((int(m.group(1)) for m in (re.match(r"=== FDD dma 1 cylinder \d+ head \d+: \d+ words, sync [0-9a-f]+, from cycle (\d+)$", l)
                                           for l in lines) if m), None)
    if not evs or dma0 is None:
        bad.append("no key event or no first track DMA in %s" % log)
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
        win, wout, fname, nwait = int(e.group(10)), int(e.group(11)), e.group(12), int(e.group(13))
        if st != 0x40 or er != 0:
            bad.append("%s: status %02x error %02x at the end, want 40 00" % (what, st, er))
        if nwait < 1:
            bad.append("%s: no wait recorded (item 8)" % what)
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
                notes.append("%s: = fw/ctrl_rv/test/gold/identify.py (HDF_SYNTHRDB, CHS %d.%d.%d)" % ((what,) + geo[1:4]))
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
    if len(argv) == 3 and argv[1] == "hdd":
        return hdd(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
