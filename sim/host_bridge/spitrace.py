#!/usr/bin/env python3
r"""spitrace.py: the SPI frame log of the L2 firmware boot (tb_host_bridge.v
+SPI_LOG, run.sh fwboot) and of the L3 bench (sim/l3) -- summary, milestone
check, and the 832-vs-RV differential.

    python3 -I spitrace.py summary <spi.txt>
    python3 -I spitrace.py check <milestones.txt> <run log> <spi.txt>
    python3 -I spitrace.py count <spi.txt> <pattern>
    python3 -I spitrace.py norm <spi.txt> <hw.txt> <uart.txt> -r <expected_diff.txt>
                                [--card <card image>] [--charrom <charrom.h>]
    python3 -I spitrace.py diff [--unused-rules] <norm a> <norm b>
    python3 -I spitrace.py osd <spi.txt> [--charrom <charrom.h>]

spi.txt: one SPI frame per line, "<cs> <MOSI bytes> / <MISO bytes>", hex,
no timestamps (cs = ~sd_cs without bit 0, the Enable value: 20 OSD, 10 FPGA,
02 card, 00 none).

milestones.txt, one per line ('#' starts a comment line, blank lines
ignored), each checked in order within its own stream (an ordered
subsequence: other lines may come in between):
    UART <text>            a "UART: " line of the run log containing <text>
                           (several milestones may match in one line, in
                           order along it)
    SPI <cs> <pattern>     a frame with that cs whose bytes match
    SPI>=<n> <cs> <pattern>  n such frames, in order
<pattern> = <MOSI tokens> [/ <MISO tokens>]; a token is a hex byte, "xx"
(any byte) or ".." (any number of further bytes, last token only).
Without "..", the frame has exactly as many bytes as tokens; without a
MISO part, MISO is not checked.

Exit status: 0 = every milestone found (check), 1 = not, 2 = usage.

norm: one normalised stream of a run, in frame order, one item per line
"<STREAM> <text>" (STREAM = SPI, SD, OSD, HW, UART), for diff:
  - the poll frames, whose number depends on the CPU's speed, are dropped:
    FPGA status frames (10, six 00 bytes) without a request (MISO 0 bits
    3..0 = 0: no track read / write, no IDE command / data) whose MISO
    equals the previous status frame's: HandleFDD also acts on the other
    bytes (drive count, track, motor: fdd.c), so a changed one is kept,
    and a request is always kept.  After an IDE request frame (MISO 0
    bits 3..2: command / data; sim/l3 hdd, runs p4t15 / p4t15c) a frame
    without a request that equals it but for those two bits is a poll too:
    the firmware served the request, and whether its wait loop polls once
    before the 68k has emptied or filled the FIFO follows the CPU's speed
    (the IDE bits going to 0 drive nothing; every other byte stays
    compared); the FPGA drive-status frames (10 10 <s>: UpdateDriveStatus
    after every HandleFpga) whose <s> equals the previous one, OSD_CMD_READ
    frames (20 00) whose level (MISO) equals the previous one, OSD_CMD_KEYQ
    frames (20 98) whose status byte (MISO 1) is 00 (no event, no
    overflow), every RTC frame (80); each run of them leaves nothing
  - the IDE flag polls (hdd.c ReadIDEFlags(): 10, MOSI 80 or 81 and nine
    00 bytes; sim/l3 cd, runs p4t16 / p4t16c and p4t16i / p4t16ci, Task
    16 ruling): MISO byte 0's IDE request bits (3..2) are printed as 0.
    The firmware keeps only MISO byte 8 (the flags) of that frame; byte 0
    is clocked out during the command byte, and whether the 68k has read
    the last word of a data phase by then follows the CPU's speed.  Byte 8,
    the other bits of byte 0 and the poll count stay compared, except:
    a flag poll equal (after that mask) to the previous flag poll, with no
    kept item between them, is a repeat and dropped (sim/l3 cdda, runs
    p4t17 / p4t17c and p4t17l / p4t17lc, Task 17 ruling: CD_AudioPoll()
    reads the CD port's flags on every main-loop pass while the player
    runs, RV 17,174 frames, 832 7,228).  "Kept" is decided on the
    finished stream: after every drop above (the poll frames, the RTC
    frames and their HandleRTC unit's hw writes) and every rule of the
    list (DROP, DEDUP, DROPBLOCK, SUBST; FLOAT lines have no place among
    the frames).  So any line of any stream that is printed between two
    equal flag polls (an SPI, SD or OSD frame, a hw write, a UART line)
    keeps the second one; cd_wait()'s polls between data phases stay
    compared
  - paula's floppy DMA progress (sim/l3 fdd_rd, runs p4t13 / p4t13c: the
    FIFO is filled by the firmware and emptied at Agnus's rate, so these
    bytes depend on the CPU's speed) is masked by byte position, as "--":
    in a status frame (10, six 00 bytes) whose MISO byte 4 has bit 7 set
    (word 2 = {dmaen, dsklen} or the write FIFO status: DMA on), MISO bytes
    4 and 5; in a sector frame (10, six 00 bytes, then the data the
    firmware sends; MISO byte 0 bits 1..0 = 01, a track read without
    write) whose MISO byte 4 has bit 7 set, MISO bytes 4 to the end (word 2
    and every word 3: the countdown).  MOSI (the sector data) and MISO
    bytes 0..3 (request, track, sync) and the motor bits stay compared; the
    identical-repeat drop of status frames compares the masked bytes
  - a seek in progress (sim/l3 fdd_wr, runs p4t14f / p4t14fc: bfm_floppy
    steps the head every 3 ms right after a track write's blckint, and the
    RV polls again after 2 to 5 ms, the 832 after 11 to 20 ms, so the
    intermediate head positions a CPU sees depend on its speed): of a run
    of consecutive status frames without a request and without masked DMA
    bytes (10, six 00 bytes, MISO 0 bits 3..0 = 0) whose MISO differs from
    the previous one's in byte 1 (the track) only, by whole cylinders (an
    even step: the head bit unchanged) and always in the same direction
    (a slower CPU sees fewer of the positions), with no kept
    frame and no hw / UART line in between, only the last is kept; the
    position the seek ends at, a track byte that jumps or goes back, every
    request and every other changed byte stay compared.  Applied to the
    normalised lines after the rules below (so a rewrite the DEDUP rule
    drops does not cut the run; any line left in between does)
  - paula's floppy write FIFO (sim/l3 fdd_wr, runs p4t14 / p4t14c: Agnus
    fills it at its rate, the firmware's FindSync / GetHeader / GetData
    empty it in pieces whose size is the FIFO's count when each frame
    starts, so how the stream is cut into frames, and the number of polls
    while it fills, depend on the CPU's speed): consecutive write frames
    (10, every MOSI byte 00, at least six bytes, MISO byte 0 bit 1 set: a
    track write, CMD_WRTRK) with no other frame and no hw / UART line
    between them and the same MISO bytes 0..3 (request, track, sync) become
    one line "SPI 10 wrfifo <bytes 0..3> / <n> <the n FIFO bytes, in
    order>": the MISO bytes after the six header bytes of each frame,
    concatenated (bytes 4..5, the FIFO count, are dropped).  Every word the firmware
    read from the FIFO stays compared, in order; the line ends where
    anything else happens (the SD write of a sector, a 2-byte frame), so
    the cut points the firmware chooses by content stay too
  - the HandleRTC unit (fw/ctrl_rv/rtc.c HandleRTC, every 8,192 main-loop
    passes, so their number depends on the CPU's speed: p4t13 4, p4t13c
    2): an RTC frame (80) together with exactly the hw writes of that call,
    when they have exactly this shape: "ffffe8" (SPI_slow), "ffff7c",
    "ffff78", "ffff74", "ffff70" (HW_RTC) logged before the frame, and
    "ffffe8" (SPI_fast) as the next hw write after it, and whose six
    (address, value) pairs equal the previous kept unit's: a repeat, as
    the status-frame collapse.  The first unit's writes stay, and so do a
    unit's with another value (another RTC time, another speed) and every
    hw write of another shape (the frame itself is always dropped, as every
    RTC frame)
  - SD card frames (cs 02) become one "SD CMD<n> ..." line per command: the
    argument (CMD17/18/24/25: the block, "lba"), "R<r1>" (CMD8 / CMD58 with
    their four response bytes) and the sha256 of each data block (read: the
    512 bytes after the FE token on MISO; write: after the FE / FC token on
    MOSI); the deselect clocks (cs 00, every MOSI byte ff: no device
    selected) are not printed
  - OSD_CMD_OSD_WR frames (20 0c 00 00 00 <row> ...) become "OSD <row>
    <text>", the 8-byte columns decoded with fw/ctrl_rv/charrom.h:
    "stripe=<hash>" for the side stripe, {inv:...} for inverted
    characters, {xx ...} for columns that are no character; trailing
    spaces dropped
  - other frames: "SPI <cs> <MOSI> / <MISO>"
  - hw.txt (sim/common/hostmon.vh +HW_LOG; "<frames> <ev> <addr> <value16>")
    -> "HW <addr> <value16>" after spi.txt line <frames>, its "MEM <region>
    <sha256>" lines (l3check.py memhash) -> "HW MEM ..." at the end;
    uart.txt (+UART_LOG; "<frames> <ev> <text>") -> "UART <text>"; within
    one gap between frames in <ev> order
  - then the rules of <expected_diff.txt> (below), in file order
  - last, one "# rule <line> used <n>: <rule>" line per rule ('#' lines are
    not compared) and a "# dropped ..." count line
Every file is read as latin-1 (byte for byte: a UART byte >= 0x80 stays
itself) and norm writes latin-1.
<card image> (the run's card/boot.img) is needed by SDFILE rules: the FAT16
file's clusters are read from it.

expected_diff.txt: '#' comment lines and rules; every rule has a comment
line (its source) directly above it or above the rules before it in one
block, blank lines end a block:
    SUBST <stream> <python-regex> <replacement>
    DROP <stream> <python-regex>
    DROPBLOCK <stream> <start-regex> <end-regex>
    SDFILE <8.3 name> <alias>
    DEDUP hw <addr-regex>
    FLOAT hw <addr-regex>
<stream> = uart, osd, hw, sd, spi or all; the regex (no blanks: \x20 or
\s) is searched in the text after "<STREAM> "; <replacement> is the rest
of the line, Python re.sub syntax, "" for the empty string.  DROPBLOCK:
from a line of <stream> matching <start-regex> up to and including the next
line of <stream> matching <end-regex>, every line (of any stream) is
dropped; a start without its end is an error (exit 1).  SDFILE: every
SD access inside the file's clusters is printed "CMD<n> <alias>+<offset>"
without its data hash, and a run of such accesses (same alias, same
command) is one line: so RV32OSDA.BIN and 832OSDAD.BIN are both
"FIRMWARE+00000000 .." whatever their sizes.  DEDUP: a hw write to an
address matching <addr-regex> whose value equals the previous write to
that address is dropped (a no-op rewrite; a changed value stays).  FLOAT:
the hw writes to addresses matching <addr-regex> leave their place among
the frames and are printed, in their own order, after everything else
("HW <addr> <value>" lines): their order among themselves is compared,
their position is not.

diff: unified diff of two norm outputs without their '#' lines; exit 0
only when it is empty.  --unused-rules: also "UNUSED <line>: <rule>" for
each rule that neither run used (exit 1 when there is one).

osd: the OSD pages of a spi.txt, "--- page <k>" before each redraw (a row
number not above the previous one) and "<row> <text>" per OSD_CMD_OSD_WR
frame as norm decodes it.

Python 3 standard library only.
"""
import difflib
import hashlib
import os
import re
import sys
from collections import Counter


def read_frames(path):
    frames = []
    with open(path, encoding="latin-1") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            left, sep, right = line.partition(" /")
            if not sep:
                raise SystemExit("%s:%d: no ' /' in the frame line" % (path, n))
            toks = left.split()
            cs = int(toks[0], 16)
            out = [int(t, 16) for t in toks[1:]]
            inp = [int(t, 16) for t in right.split()]
            if len(out) != len(inp):
                raise SystemExit("%s:%d: %d MOSI but %d MISO bytes" % (path, n, len(out), len(inp)))
            frames.append((cs, out, inp))
    return frames


def parse_tokens(toks, where):
    pat, more = [], False
    for i, t in enumerate(toks):
        if t == "..":
            if i != len(toks) - 1:
                raise SystemExit("%s: '..' must be the last token" % where)
            more = True
        elif t.lower() == "xx":
            pat.append(None)
        else:
            pat.append(int(t, 16))
    return pat, more


def parse_pattern(words, where):
    """words after the cs: '<out> [/ <in>]' -> (out, out_more, in, in_more)"""
    if "/" in words:
        k = words.index("/")
        o, om = parse_tokens(words[:k], where)
        i, im = parse_tokens(words[k + 1:], where)
        return o, om, i, im
    o, om = parse_tokens(words, where)
    return o, om, None, True


def tok_match(pat, more, data):
    if len(data) < len(pat) or (not more and len(data) != len(pat)):
        return False
    return all(p is None or p == d for p, d in zip(pat, data))


def frame_match(spec, frame):
    cs, (o, om, i, im) = spec
    fcs, out, inp = frame
    if fcs != cs or not tok_match(o, om, out):
        return False
    if i is not None:
        # the MISO part is matched against the same number of bytes as MOSI
        if not tok_match(i, im, inp):
            return False
    return True


def parse_spi_spec(words, where):
    return int(words[0], 16), parse_pattern(words[1:], where)


def count(frames, spec):
    return sum(1 for fr in frames if frame_match(spec, fr))


def summary(path):
    frames = read_frames(path)
    by_cs = Counter(cs for cs, _, _ in frames)
    print("frames %d" % len(frames))
    for cs in sorted(by_cs):
        nbytes = sum(len(o) for c, o, _ in frames if c == cs)
        print("  cs %02x: %d frames, %d bytes" % (cs, by_cs[cs], nbytes))
    osd = Counter(o[0] for c, o, _ in frames if c == 0x20 and o)
    if osd:
        print("OSD commands (first byte): " +
              ", ".join("%02x x%d" % (k, osd[k]) for k in sorted(osd)))
    fpga6 = sum(1 for c, o, _ in frames if c == 0x10 and o == [0] * 6)
    print("FPGA frames 10 00 00 00 00 00 00 (HandleFpga): %d" % fpga6)
    for c, o, i in frames:
        if c == 0x20 and o and o[0] == 0x88:
            print("OSD_CMD_VERSION: out %s / in %s" %
                  (" ".join("%02x" % b for b in o), " ".join("%02x" % b for b in i)))
    return 0


def uart_lines(path):
    lines = []
    with open(path, encoding="latin-1") as f:
        for line in f:
            if line.startswith("UART: "):
                lines.append(line[len("UART: "):].rstrip("\n"))
    return lines


def check(mpath, logpath, spipath):
    frames = read_frames(spipath)
    uart = uart_lines(logpath)
    upos = (0, 0)        # next line, offset in it
    fpos = 0             # next frame
    bad = 0
    nm = 0
    with open(mpath, encoding="latin-1") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            nm += 1
            where = "%s:%d" % (mpath, n)
            kind, _, rest = line.partition(" ")
            if kind == "UART":
                text = rest
                li, off = upos
                found = None
                while li < len(uart):
                    k = uart[li].find(text, off)
                    if k >= 0:
                        found = (li, k + len(text))
                        break
                    li, off = li + 1, 0
                if found:
                    print("ok   UART %s (log UART line %d)" % (text, found[0] + 1))
                    upos = found
                else:
                    print("BAD  UART %s: not found after UART line %d" % (text, upos[0] + 1))
                    bad += 1
            elif kind == "SPI" or kind.startswith("SPI>="):
                need = int(kind[5:]) if kind.startswith("SPI>=") else 1
                spec = parse_spi_spec(rest.split(), where)
                got, k = 0, fpos
                while k < len(frames) and got < need:
                    if frame_match(spec, frames[k]):
                        got += 1
                    k += 1
                if got == need:
                    print("ok   %s %s (frames up to %d)" % (kind, rest, k))
                    fpos = k
                else:
                    print("BAD  %s %s: %d of %d found after frame %d" % (kind, rest, got, need, fpos))
                    bad += 1
            else:
                raise SystemExit("%s: unknown milestone kind %r" % (where, kind))
    if nm == 0:
        print("BAD  no milestones in %s" % mpath)
        return 1
    print("milestones: %d of %d found in order" % (nm - bad, nm))
    return 1 if bad else 0


# ------------------------------------------------------------ differential

HERE = os.path.dirname(os.path.abspath(__file__))
CHARROM = os.path.join(HERE, "..", "..", "fw", "ctrl_rv", "charrom.h")
STREAMS = ("uart", "osd", "hw", "sd", "spi", "all")


def hexs(bs):
    return " ".join("--" if b is None else "%02x" % b for b in bs)


def load_charrom(path):
    """charfont[256][8] of charrom.h -> {8 column bytes: character}; of
    several codes with the same glyph the printable one (the space for the
    empty glyph) wins, else the lowest code"""
    with open(path, encoding="latin-1") as f:
        text = f.read()
    k = text.find("charfont[256][8]")
    if k < 0:
        raise SystemExit("%s: no charfont[256][8]" % path)
    rows = re.findall(r"\{((?:\s*0x[0-9A-Fa-f]{1,2}\s*,){7}\s*0x[0-9A-Fa-f]{1,2}\s*)\}", text[k:])
    if len(rows) != 256:
        raise SystemExit("%s: %d glyphs, want 256" % (path, len(rows)))
    glyphs = {}
    for code, row in enumerate(rows):
        g = bytes(int(x, 16) for x in row.split(","))
        ch = chr(code) if 0x20 <= code < 0x7f else "\\x%02x" % code
        old = glyphs.get(g)
        if old is None or (len(old) > 1 and len(ch) == 1):
            glyphs[g] = ch
    return glyphs


def osd_text(data, glyphs):
    """the column bytes of one OSD_CMD_OSD_WR line (after the row) -> text"""
    out, k, inv = [], 0, []

    def flush():
        if inv:
            out.append("{inv:" + "".join(inv) + "}")
            del inv[:]
    if len(data) >= 22 and data[0] == 0xFF and data[1] == 0xFF:
        out.append("stripe=" + hashlib.sha256(bytes(data[:22])).hexdigest()[:12] + " ")
        k = 22
    while k + 8 <= len(data):
        g = bytes(data[k:k + 8])
        k += 8
        if g in glyphs:
            flush()
            out.append(glyphs[g])
            continue
        gi = bytes(b ^ 0xFF for b in g)
        if gi in glyphs:
            inv.append(glyphs[gi])
            continue
        flush()
        out.append("{" + hexs(g) + "}")
    rest = data[k:]
    if rest and any(b != 0 for b in rest) and not (inv and all(b == 0xFF for b in rest)):
        flush()
        out.append("{" + hexs(rest) + "}")
    flush()
    return "".join(out).rstrip(" ")


def osd_line(out, glyphs):
    """OSD_CMD_OSD_WR frame MOSI (0c a2 a1 a0 row ...) -> (row, text)"""
    if len(out) < 5:
        return None, "{short " + hexs(out) + "}"
    row = out[4] if out[1:4] == [0, 0, 0] else "%02x%02x%02x%02x" % tuple(out[1:5])
    return row, osd_text(out[5:], glyphs)


class Card:
    """the FAT16 root-directory files of an SD card image (tools/sim/mkcard.sh):
    name -> set of LBAs of its clusters, in file order"""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.img = f.read()
        mbr = self.img[:512]
        part = 0
        if mbr[510:512] == b"\x55\xaa" and mbr[0x1BE + 4] != 0:
            part = int.from_bytes(mbr[0x1BE + 8:0x1BE + 12], "little")
        b = self.img[part * 512:part * 512 + 512]
        bps = int.from_bytes(b[11:13], "little")
        self.spc = b[13]
        res = int.from_bytes(b[14:16], "little")
        nfat = b[16]
        nroot = int.from_bytes(b[17:19], "little")
        spf = int.from_bytes(b[22:24], "little")
        if bps != 512 or spf == 0 or self.spc == 0:
            raise SystemExit("%s: not a FAT16 card with 512-byte sectors (SDFILE)" % path)
        self.fat = (part + res) * 512
        self.root = part + res + nfat * spf
        self.data = self.root + (nroot * 32 + 511) // 512
        self.nroot = nroot

    def file_lbas(self, name):
        if "." in name:
            base, ext = name.split(".", 1)
        else:
            base, ext = name, ""
        want = (base.ljust(8) + ext.ljust(3)).encode("ascii")
        for i in range(self.nroot):
            e = self.img[self.root * 512 + 32 * i:self.root * 512 + 32 * i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] & 0x08:
                continue
            if e[:11] == want:
                c = int.from_bytes(e[26:28], "little")
                lbas = []
                while 2 <= c < 0xFFF8:
                    first = self.data + (c - 2) * self.spc
                    lbas.extend(range(first, first + self.spc))
                    c = int.from_bytes(self.img[self.fat + 2 * c:self.fat + 2 * c + 2], "little")
                return lbas
        raise SystemExit("%s: no file %s in the root directory (SDFILE)" % (self.path, name))


class Rule:
    def __init__(self, lineno, text, words, comment):
        self.lineno, self.text, self.used = lineno, text, 0
        self.kind = words[0]
        self.comment = comment
        if self.kind in ("SUBST", "DROP"):
            if len(words) < (4 if self.kind == "SUBST" else 3):
                raise SystemExit("line %d: %s <stream> <regex>%s" % (lineno, self.kind,
                                 " <replacement>" if self.kind == "SUBST" else ""))
            self.stream = words[1]
            if self.stream not in STREAMS:
                raise SystemExit("line %d: stream %r is not one of %s" % (lineno, self.stream, "|".join(STREAMS)))
            try:
                self.re = re.compile(words[2])
            except re.error as e:
                raise SystemExit("line %d: regex %r: %s" % (lineno, words[2], e))
            if self.kind == "SUBST":
                self.repl = "" if words[3] == '""' else words[3]
            elif len(words) > 3:
                raise SystemExit("line %d: DROP <stream> <regex> (the regex has no blanks)" % lineno)
        elif self.kind == "DROPBLOCK":
            if len(words) != 4:
                raise SystemExit("line %d: DROPBLOCK <stream> <start-regex> <end-regex> (no blanks in them)" % lineno)
            self.stream = words[1]
            if self.stream not in STREAMS:
                raise SystemExit("line %d: stream %r is not one of %s" % (lineno, self.stream, "|".join(STREAMS)))
            try:
                self.re, self.end = re.compile(words[2]), re.compile(words[3])
            except re.error as e:
                raise SystemExit("line %d: regex: %s" % (lineno, e))
        elif self.kind in ("DEDUP", "FLOAT"):
            if len(words) != 3 or words[1] != "hw":
                raise SystemExit("line %d: %s hw <addr-regex> (no blanks)" % (lineno, self.kind))
            self.stream = "hw"
            try:
                self.re = re.compile(words[2])
            except re.error as e:
                raise SystemExit("line %d: regex %r: %s" % (lineno, words[2], e))
        elif self.kind == "SDFILE":
            if len(words) != 3:
                raise SystemExit("line %d: SDFILE <8.3 name> <alias>" % lineno)
            self.name, self.alias = words[1], words[2]
        else:
            raise SystemExit("line %d: unknown rule %r" % (lineno, self.kind))

    def applies(self, stream):
        return self.stream == "all" or self.stream == stream


def read_rules(path):
    rules, comment = [], None
    with open(path, encoding="latin-1") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip():
                comment = None
                continue
            if line.lstrip().startswith("#"):
                comment = line.strip()
                continue
            kind, _, rest = line.partition(" ")
            if kind == "SUBST":
                words = [kind] + rest.split(None, 2)
            else:
                words = line.split()
            if comment is None:
                raise SystemExit("%s:%d: a rule without a '#' comment line (its source) above it" % (path, n))
            rules.append(Rule(n, line, words, comment))
    return rules


def read_events(path, kind):
    """hw.txt / uart.txt lines -> [(frames, ev, text)], MEM lines -> [text]"""
    ev, mem = [], []
    with open(path, encoding="latin-1") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if kind == "hw" and line.startswith("MEM "):
                w = line.split()
                if len(w) != 3:
                    raise SystemExit("%s:%d: a MEM line not yet hashed (sim/l3/l3check.py memhash)" % (path, n))
                mem.append(line)
                continue
            w = line.split(" ", 2)
            if len(w) < 2 or not w[0].isdigit() or not w[1].isdigit():
                raise SystemExit("%s:%d: not '<frames> <ev> ...'" % (path, n))
            ev.append((int(w[0]), int(w[1]), w[2] if len(w) > 2 else ""))
    return ev, mem


def sd_commands(out, inp, st):
    """the commands of one card frame -> [(cmd, arg, r1, extra, [blocks], dir)];
    st carries the card's addressing (CMD58's CCS bit) across frames"""
    cmds, k, n = [], 0, len(out)
    while k < n:
        if out[k] == 0xFF:
            k += 1
            continue
        if out[k] & 0xC0 != 0x40 or k + 6 > n:
            cmds.append(("junk", hexs(out[k:k + 16]), None, [], [], ""))
            break
        cmd = out[k] & 0x3F
        arg = int.from_bytes(bytes(out[k + 1:k + 5]), "big")
        k += 6
        if cmd == 12 and k < n:
            k += 1                      # CMD12's stuff byte
        j = k
        while j < n and inp[j] == 0xFF and out[j] == 0xFF and j < k + 64:
            j += 1
        r1 = inp[j] if j < n and out[j] == 0xFF and inp[j] != 0xFF else None
        k = j + 1 if r1 is not None else j
        extra = []
        if cmd in (8, 58) and r1 is not None:
            extra = inp[k:k + 4]
            k += 4
            if cmd == 58 and len(extra) == 4 and r1 & 0xFE == 0:
                st["ccs"] = bool(extra[0] & 0x40)
        blocks, d = [], ""
        if cmd in (17, 18) and r1 == 0:
            d = "rd"
            while k < n and out[k] == 0xFF:
                if inp[k] == 0xFE:
                    blocks.append(bytes(inp[k + 1:k + 513]))
                    k += 515
                    if cmd == 17:
                        break
                else:
                    k += 1
        elif cmd in (24, 25) and r1 == 0:
            d = "wr"
            while k < n:
                if out[k] in (0xFE, 0xFC):
                    blocks.append(bytes(out[k + 1:k + 513]))
                    k += 515
                    # the data response (xxx0sss1) and the busy 00s: kept
                    # in the line as "D<response>"
                    resp = None
                    while k < n and out[k] == 0xFF and inp[k] != 0xFF:
                        if resp is None:
                            resp = inp[k]
                        k += 1
                    extra.append(resp)
                    if cmd == 24:
                        break
                elif out[k] == 0xFD:
                    k += 1
                    while k < n and out[k] == 0xFF and inp[k] != 0xFF:
                        k += 1
                    break
                elif out[k] == 0xFF:
                    k += 1
                else:
                    break
        lba = arg if st.get("ccs", True) else arg >> 9
        cmds.append((cmd, lba if cmd in (17, 18, 24, 25) else arg, r1, extra, blocks, d))
    return cmds


def sd_lines(frame_cmds, sdfiles):
    """[(cmd, ...)] -> [(text, alias key or None)]"""
    res = []
    for cmd, arg, r1, extra, blocks, d in frame_cmds:
        if cmd == "junk":
            res.append(("junk " + arg, None))
            continue
        r = "R--" if r1 is None else "R%02x" % r1
        if d == "wr":
            r += "".join(" D--" if x is None else " D%02x" % x for x in extra)
        elif extra:
            r += " " + hexs(extra)
        hit = sdfiles.get(arg) if cmd in (17, 18, 24, 25) else None
        if hit is not None:
            rule, off = hit
            rule.used += 1
            res.append(("CMD%d %s+%08x .. %s" % (cmd, rule.alias, off, r), (rule.alias, cmd)))
            continue
        a = ("%08x" % arg) if cmd in (17, 18, 24, 25) else ("arg=%08x" % arg)
        h = " ".join(hashlib.sha256(b).hexdigest() + ("" if len(b) == 512 else "/short%d" % len(b))
                     for b in blocks)
        if d and not blocks:
            h = "no data"
        res.append(("CMD%d %s %s%s" % (cmd, a, r, (" " + d + " " + h) if d else ""), None))
    return res


# an IDE flag poll as norm prints it (hdd.c ReadIDEFlags: cs 10, MOSI 80 or
# 81 and nine 00 bytes)
FLAGPOLL = re.compile(r"10 8[01]( 00){9} / ")


def norm(spi, hw, uart, rules_path, card_path, charrom):
    rules = read_rules(rules_path)
    glyphs = load_charrom(charrom)
    frames = read_frames(spi)
    hw_ev, mem = read_events(hw, "hw")
    uart_ev, _ = read_events(uart, "uart")
    sdfiles = {}
    sdrules = [r for r in rules if r.kind == "SDFILE"]
    if sdrules:
        if not card_path:
            raise SystemExit("SDFILE rules need --card <card image>")
        card = Card(card_path)
        for r in sdrules:
            for i, lba in enumerate(card.file_lbas(r.name)):
                sdfiles[lba] = (r, i * 512)
    # items: (key, stream, text, collapse key)
    items = []
    wr_runs = []
    for fr, ev, text in hw_ev:
        items.append(((fr, 0, ev), "hw", text, None))
    for fr, ev, text in uart_ev:
        items.append(((fr, 0, ev), "uart", text, None))
    drop = Counter()
    prev_read = prev_uds = prev_status = None
    st = {}
    rtc_at = []                   # item indices of the RTC frames' markers
    ev_at = {k[0][0] for k in items}   # frame counts with a hw / UART line before that frame
    wr_run = None                 # the open write-FIFO line: [item index, bytes 0..3, words, last frame]
    for i, (cs, out, inp) in enumerate(frames):
        key = (i, 1, 0)
        # paula's write FIFO (the doc above): merged into one line
        if cs == 0x10 and len(out) >= 6 and not any(out) and len(inp) == len(out) and inp[0] & 0x02:
            hdr = tuple(inp[:4])
            if wr_run is not None and wr_run[3] == i - 1 and wr_run[1] == hdr and i not in ev_at:
                wr_run[2].extend(inp[6:])
                wr_run[3] = i
                drop["wrfifo"] += 1
                continue
            items.append((key, "spi", None, None))
            wr_run = [len(items) - 1, hdr, list(inp[6:]), i]
            wr_runs.append(wr_run)
            continue
        # paula's DMA progress bytes (the doc above): masked, None = "--"
        if cs == 0x10 and len(out) >= 6 and not any(out[:6]) and len(inp) >= 6 and inp[4] & 0x80:
            if len(out) == 6:
                inp = inp[:4] + [None, None]
            elif inp[0] & 0x03 == 0x01:
                inp = inp[:4] + [None] * (len(inp) - 4)
        # the IDE flag polls (the doc above; cdrom.c cd_wait(), runs p4t16 /
        # p4t16c, p4t16i / p4t16ci: the first poll after the INQUIRY and
        # MODE SENSE data phases, RV 10 01 ..., 832 14 01 ..., byte 8 53 in
        # both): MISO byte 0's IDE request bits not compared
        if cs == 0x10 and len(out) == 10 and out[0] in (0x80, 0x81) and not any(out[1:]) and inp and inp[0] is not None:
            inp = [inp[0] & ~0x0C] + list(inp[1:])
        if cs == 0x10 and len(out) == 6 and not any(out):
            # a masked frame without a request whose bytes 0..3 equal the
            # previous status frame's is a repeat too: its bytes 4..5 hold no
            # motor bits, only the DMA progress (the trigger frame's word 2
            # shows it or not by the CPU's timing: p4t13 / p4t13c)
            if inp[0] & 0x0F == 0 and (tuple(inp) == prev_status or
                                       (inp[4] is None and prev_status is not None and
                                        tuple(inp[:4]) == prev_status[:4])):
                drop["status"] += 1
                continue
            # the first polls after an IDE request was served (the doc
            # above): the request frame's bytes without its IDE bits
            if (inp[0] & 0x0F == 0 and prev_status is not None and prev_status[0] & 0x0C and
                    (prev_status[0] & ~0x0C,) + prev_status[1:] == tuple(inp)):
                drop["ide_served"] += 1
                continue
            prev_status = tuple(inp)
        if cs == 0x10 and len(out) == 2 and out[0] == 0x10:
            if out[1] == prev_uds:
                drop["drivestatus"] += 1
                continue
            prev_uds = out[1]
        if cs == 0x20 and out and out[0] == 0x00:
            if tuple(inp) == prev_read:
                drop["read"] += 1
                continue
            prev_read = tuple(inp)
        if cs == 0x20 and len(out) >= 2 and out[0] == 0x98 and inp[1] == 0x00:
            drop["keyq"] += 1
            continue
        if cs == 0x80:
            drop["rtc"] += 1
            items.append((key, "rtc", "", None))     # a marker for the HandleRTC unit
            continue
        if cs == 0x00 and all(b == 0xFF for b in out):
            drop["sd_deselect"] += 1
            continue
        if cs == 0x02:
            for n, (text, ck) in enumerate(sd_lines(sd_commands(out, inp, st), sdfiles)):
                items.append(((i, 1, n), "sd", text, ck))
            continue
        if cs == 0x20 and out and out[0] == 0x0C:
            row, text = osd_line(out, glyphs)
            items.append((key, "osd", "%s %s" % (row, text) if text else str(row), None))
            continue
        items.append((key, "spi", " ".join(x for x in ("%02x" % cs, hexs(out), "/", hexs(inp)) if x), None))
    for idx, hdr, words, _ in wr_runs:
        items[idx] = (items[idx][0], "spi", "10 wrfifo %s / %d %s" % (hexs(hdr), len(words), hexs(words)), None)
    items.sort(key=lambda t: t[0])
    # the HandleRTC unit (the doc above): the marker with exactly its hw writes
    keep = [True] * len(items)
    shape = ("ffffe8", "ffff7c", "ffff78", "ffff74", "ffff70")
    prev_unit = None
    for k, (key, stream, _, _) in enumerate(items):
        if stream != "rtc":
            continue
        keep[k] = False
        before = items[k - 5:k] if k >= 5 else []
        after = next((j for j in range(k + 1, len(items)) if items[j][1] != "rtc"), None)
        if (len(before) == 5 and all(b[1] == "hw" and b[0][0] == key[0] and b[2].split()[0] == a
                                     for b, a in zip(before, shape))
                and after is not None and items[after][1] == "hw" and items[after][2].split()[0] == "ffffe8"):
            unit = tuple(items[j][2] for j in list(range(k - 5, k)) + [after])
            if unit == prev_unit:
                for j in list(range(k - 5, k)) + [after]:
                    keep[j] = False
                drop["rtc_unit"] += 1
            prev_unit = unit
    items = [t for t, kp in zip(items, keep) if kp]
    for m in mem:
        items.append(((len(frames) + 1, 0, 0), "hw", m, None))
    # SDFILE runs: one line per run of accesses with the same alias and
    # command.  Inside a run, the hw writes and other card accesses between
    # them (the SPI speed write before each sector, the FAT sector at a
    # cluster boundary) are printed once, the first time; a UART line or
    # any other frame ends the run
    lines, run_key, run_seen = [], None, set()
    for _, stream, text, ck in items:
        if ck is not None:
            if ck == run_key:
                drop["sdfile_run"] += 1
                continue
            run_key, run_seen = ck, set()
        elif run_key is not None and stream in ("hw", "sd"):
            if (stream, text) in run_seen:
                drop["sdfile_run"] += 1
                continue
            run_seen.add((stream, text))
        else:
            run_key = None
        lines.append([stream, text])
    # the text rules, in file order
    floated = []
    for r in rules:
        if r.kind == "SDFILE":
            continue
        if r.kind in ("DEDUP", "FLOAT"):
            kept, last = [], {}
            for ln in lines:
                w = ln[1].split()
                if ln[0] != "hw" or len(w) != 2 or not r.re.search(w[0]):
                    kept.append(ln)
                    continue
                if r.kind == "FLOAT":
                    r.used += 1
                    floated.append(ln)
                    continue
                if last.get(w[0]) == w[1]:
                    r.used += 1
                    continue
                last[w[0]] = w[1]
                kept.append(ln)
            lines = kept
            continue
        kept = []
        if r.kind == "DROPBLOCK":
            k = 0
            while k < len(lines):
                ln = lines[k]
                if r.applies(ln[0]) and r.re.search(ln[1]):
                    e = k + 1
                    while e < len(lines) and not (r.applies(lines[e][0]) and r.end.search(lines[e][1])):
                        e += 1
                    if e >= len(lines):
                        raise SystemExit("rule line %d: DROPBLOCK start at normalised line %d (%s %s) has no end"
                                         % (r.lineno, k + 1, ln[0].upper(), ln[1][:60]))
                    r.used += 1
                    k = e + 1
                    continue
                kept.append(ln)
                k += 1
            lines = kept
            continue
        for ln in lines:
            if not r.applies(ln[0]):
                kept.append(ln)
                continue
            if r.kind == "DROP":
                if r.re.search(ln[1]):
                    r.used += 1
                    continue
            else:
                t, k = r.re.subn(r.repl, ln[1])
                if k and t != ln[1]:
                    r.used += 1
                    ln[1] = t
            kept.append(ln)
        lines = kept
    # a seek in progress (the doc above), on the normalised lines: adjacent
    # unmasked no-request status lines that differ in the track byte only,
    # by an even step in one direction, keep only the last
    def status_of(ln):
        if ln[0] != "spi":
            return None
        m = re.match(r"10 00 00 00 00 00 00 / ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2})$", ln[1])
        if not m:
            return None
        v = [int(x, 16) for x in m.groups()]
        return v if v[0] & 0x0F == 0 else None
    kept, run_dir = [], 0
    for ln in lines:
        v = status_of(ln)
        pv = status_of(kept[-1]) if kept else None
        if v is not None and pv is not None:
            step = v[1] - pv[1]
            if (step != 0 and step % 2 == 0 and v[:1] + v[2:] == pv[:1] + pv[2:]
                    and (run_dir == 0 or (run_dir > 0) == (step > 0))):
                kept[-1] = ln
                run_dir = step
                drop["seek"] += 1
                continue
        run_dir = 0
        kept.append(ln)
    lines = kept
    # the flag poll repeats (the doc above; Task 17), on the finished
    # stream: a flag poll line equal to the line printed just before it
    kept = []
    for ln in lines:
        if ln[0] == "spi" and FLAGPOLL.match(ln[1]) and kept and kept[-1] == ln:
            drop["flagpoll"] += 1
            continue
        kept.append(ln)
    lines = kept + floated
    w = sys.stdout.write
    for stream, text in lines:
        w("%s %s\n" % (stream.upper(), text))
    for r in rules:
        w("# rule %d used %d: %s\n" % (r.lineno, r.used, r.text))
    w("# dropped " + ", ".join("%s %d" % (k, drop[k]) for k in
                                ("status", "ide_served", "flagpoll", "drivestatus", "read", "keyq", "rtc", "rtc_unit", "sd_deselect",
                                 "sdfile_run", "wrfifo", "seek")) + "\n")
    return 0


def read_norm(path):
    body, rules = [], []
    with open(path, encoding="latin-1") as f:
        for line in f:
            if line.startswith("#"):
                m = re.match(r"# rule (\d+) used (\d+): (.*)$", line.rstrip("\n"))
                if m:
                    rules.append((int(m.group(1)), int(m.group(2)), m.group(3)))
                continue
            body.append(line)
    return body, rules


def diff(a, b, unused):
    ba, ra = read_norm(a)
    bb, rb = read_norm(b)
    d = list(difflib.unified_diff(ba, bb, a, b))
    sys.stdout.writelines(d)
    rc = 1 if d else 0
    if unused:
        if [(n, t) for n, _, t in ra] != [(n, t) for n, _, t in rb]:
            print("BAD  %s and %s were normalised with other rules" % (a, b))
            return 2
        for (n, ua, t), (_, ub, _) in zip(ra, rb):
            if ua == 0 and ub == 0:
                print("UNUSED %d: %s" % (n, t))
                rc = 1
        if not any(ua == 0 and ub == 0 for (_, ua, _), (_, ub, _) in zip(ra, rb)):
            print("rules: all %d used" % len(ra))
    return rc


def osd_pages(spi, charrom):
    glyphs = load_charrom(charrom)
    page, prev = 0, None
    for cs, out, inp in read_frames(spi):
        if cs != 0x20 or not out or out[0] != 0x0C:
            continue
        row, text = osd_line(out, glyphs)
        if prev is None or not isinstance(row, int) or not isinstance(prev, int) or row <= prev:
            page += 1
            print("--- page %d" % page)
        prev = row
        print("%s %s" % (row, text) if text else str(row))
    return 0


def opt(args, name, default=None):
    if name in args:
        k = args.index(name)
        if k + 1 >= len(args):
            raise SystemExit("%s needs a value" % name)
        v = args[k + 1]
        del args[k:k + 2]
        return v
    return default


def main(argv):
    # the traces are latin-1 (byte for byte), and so is what norm / diff / osd print
    sys.stdout.reconfigure(encoding="latin-1")
    if len(argv) >= 2 and argv[1] in ("norm", "diff", "osd"):
        args = argv[2:]
        if argv[1] == "norm":
            rules = opt(args, "-r")
            card = opt(args, "--card")
            charrom = opt(args, "--charrom", CHARROM)
            if len(args) == 3 and rules:
                return norm(args[0], args[1], args[2], rules, card, charrom)
        elif argv[1] == "diff":
            unused = "--unused-rules" in args
            args = [a for a in args if a != "--unused-rules"]
            if len(args) == 2:
                return diff(args[0], args[1], unused)
        else:
            charrom = opt(args, "--charrom", CHARROM)
            if len(args) == 1:
                return osd_pages(args[0], charrom)
        sys.stderr.write(__doc__)
        return 2
    if len(argv) == 3 and argv[1] == "summary":
        return summary(argv[2])
    if len(argv) == 5 and argv[1] == "check":
        return check(argv[2], argv[3], argv[4])
    if len(argv) >= 4 and argv[1] == "count":
        print(count(read_frames(argv[2]), parse_spi_spec(argv[3:], "argument")))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
