#!/usr/bin/env python3
"""l3check.py: offline data checks of an L3 run directory (sim/l3/run.sh).

    python3 -I l3check.py kick <run>
    python3 -I l3check.py order <run>
    python3 -I l3check.py mmc <run> [<golden>]
    python3 -I l3check.py memhash <run>
    python3 -I l3check.py keys <run>

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
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
