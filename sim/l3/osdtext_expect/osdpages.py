#!/usr/bin/env python3
r"""osdpages.py <tour> [--charrom <charrom.h>]: the expected OSD pages of an
L3 scenario, written from the firmware's sources, in the format of
`spitrace.py osd` (sim/host_bridge/spitrace.py: "--- page <k>", then
"<row> <text>" per OSD_CMD_OSD_WR frame).

    python3 -I sim/l3/osdtext_expect/osdpages.py keys > sim/l3/osdtext_expect/keys.txt

Two models, both of fw/ctrl:
  - osd.c: OsdSetTitle (the title condensed, centred and rotated into the
    side stripe), OsdWriteOffset (stripe, left arrow on row 7, the
    characters with invert / stipple, the fill, right arrow on row 7) and
    OsdClear; each row's MOSI bytes are decoded with spitrace.py's own
    osd_line, so this file and the run are decoded alike
  - menu.c: the pages (title, arrows, the eight rows with the selected line
    inverted and the greyed-out ones stippled) of the states a tour visits,
    with the line numbers of fw/ctrl/menu.c they come from, and the
    boot card's configuration (sim/l3/gen/mkcfg.py: two floppy drives, no
    disk; IDE on, hardfile 0 RDB (HDF_FILE), hardfile 1 SYNTH (HDF_FILE |
    HDF_SYNTHRDB), the CD on IDE port 2; none of the three files on the
    boot card, no DRIVESND.BIN) and the core's (CORE_CAPS 0xFD: two IDE
    ports, the FPGA's floppy count 1: fdd.c "drives")

Tours: keys (sim/l3/keys/menu_tour.txt).  Python 3 standard library only.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "sim", "host_bridge"))
import spitrace  # noqa: E402  (the decoder of the runs)

CHARROM = os.path.join(ROOT, "fw", "ctrl", "charrom.h")
OSDLINELEN = 256            # osd.h
OSD_ARROW_LEFT, OSD_ARROW_RIGHT = 1, 2
STD_EXIT = "            exit"   # menu.c:199
STD_BACK = "            back"   # menu.c:200


def load_font(path):
    with open(path, encoding="latin-1") as f:
        text = f.read()
    k = text.find("charfont[256][8]")
    rows = re.findall(r"\{((?:\s*0x[0-9A-Fa-f]{1,2}\s*,){7}\s*0x[0-9A-Fa-f]{1,2}\s*)\}", text[k:])
    if k < 0 or len(rows) != 256:
        raise SystemExit("%s: no charfont[256][8]" % path)
    return [[int(x, 16) for x in r.split(",")] for r in rows]


class Osd:
    def __init__(self, font):
        self.font = font
        self.title = [0] * 64
        self.arrow = 0

    def set_title(self, s, a):
        """osd.c OsdSetTitle"""
        self.arrow = a
        tb, zeros, outp = [0] * 64, 0, 0
        for ch in s:
            c = ord(ch)
            if outp >= 64:
                break
            for nc in self.font[c]:
                if nc:
                    zeros = 0
                    tb[outp] = nc
                    outp += 1
                elif zeros == 0 or (zeros < 5 and c == 32):
                    tb[outp] = 0
                    outp += 1
                    zeros += 1
                if outp > 63:
                    break
        c = int((63 - outp) / 2)          # C division (truncates toward 0)
        for i in range(63 - c, -1, -1):
            tb[i + c] = tb[i]
        for i in range(c):
            tb[i] = 0
        for i in range(0, 64, 8):
            src = tb[i:i + 8]
            tb[i:i + 8] = [sum(((src[j] >> b) & 1) << (7 - j) for j in range(8)) for b in range(8)]
        self.title = tb

    def write(self, n, s, invert=0, stipple=0, offset=0):
        """osd.c OsdWriteOffset: the frame's MOSI bytes"""
        out = [0x0C, 0, 0, 0, n]
        linelimit = OSDLINELEN - 22 if n == 7 and self.arrow & OSD_ARROW_RIGHT else OSDLINELEN
        arrowmask = self.arrow
        smask, stip = (0x55, 0xFF) if stipple else (0xFF, 0)
        inv = 255 if invert else 0
        f = self.font
        b = [ord(ch) for ch in s] + [0]
        k = i = 0
        while True:
            if i == 0:
                p = self.title[(7 - n) * 8:(7 - n) * 8 + 8]
                out += [0xFF, 0xFF]
                for x in p:
                    out += [255 ^ x, 255 ^ x]
                out += [0xFF, 0xFF, 0, 0]
                i += 22
            elif n == 7 and arrowmask & OSD_ARROW_LEFT:
                out += [0, 0, 0] + [(x << offset) & 0xFF for x in f[0x10] + f[0x14]] + [0, 0, 0, inv, inv]
                i += 24
                arrowmask &= ~OSD_ARROW_LEFT
                stop = False
                for _ in range(3):         # the arrow takes three characters' place
                    ch = b[k]
                    k += 1
                    if ch == 0:
                        stop = True
                        break
                if stop:
                    break
            else:
                ch = b[k]
                k += 1
                if ch == 0:
                    break
                if ch in (0x0D, 0x0A):
                    raise SystemExit("osdpages.py: line breaks are not modelled")
                if i < linelimit - 8:
                    for x in f[ch]:
                        out.append((((x << offset) & 0xFF) & smask) ^ inv)
                        smask ^= stip
                    i += 8
        while i < linelimit:
            out.append(inv)
            i += 1
        if n == 7 and arrowmask & OSD_ARROW_RIGHT:
            out += [0, 0, 0] + [(x << offset) & 0xFF for x in f[0x15] + f[0x11]] + [0, 0, 0]
        return out

    @staticmethod
    def clear():
        """osd.c OsdClear"""
        return [0x0C, 0, 0, 0, 0x18] + [0] * (OSDLINELEN * 8)


# ---------------------------------------------------------------- menu.c
# A page: (title, arrows, [(text, invert, stipple)] for rows 0..7).

def main_page(sub):
    """MENU_MAIN1, menu.c:693-778.  Floppy lines (menu.c:703-736): the FPGA
    reports drives = 1 and config.floppy.drives = 1, so rows 0 and 1 are
    df0 / df1 with no disk, row 2 (= config.floppy.drives + 1) the help
    text, row 3 empty; greyed out when i > drives or i > config.floppy.drives.
    The CD line (menu.c:739-773): the CD slot is set (CD_SLOT() >= 0), no
    disc (TEST.CUE is not on the boot card), no message."""
    rows = []
    for i in range(4):
        grey = 1 if i > 1 else 0
        if i == 2:
            rows.append((" KP +/- to add/remove drives", 0, 1))
        elif i <= 1:
            rows.append((" df%d: * no disk *" % i, sub == i, grey))
        else:
            rows.append(("", sub == i, grey))
    rows += [(" Floppy disk settings \x16", sub == 4, 0),
             (" Hard disk settings \x16", sub == 5, 0),
             (" CD-ROM: * no disc *", sub == 6, 0),
             (STD_EXIT, sub == 7, 0)]
    return ("Minimig", OSD_ARROW_RIGHT, rows)


def floppy_page(sub):
    """MENU_FLOPPY1, menu.c:858-879: two drives (config.floppy.drives + 1),
    normal speed, drive sounds off (config.drivesounds 0) and greyed out
    (no DRIVESND.BIN: !drivesounds_loaded())"""
    return ("Floppy", 0, [("", 0, 0),
                          (" Floppy drives : 2", sub == 0, 0),
                          (" Floppy disk turbo : off", sub == 1, 0),
                          (" Floppy disk sounds : off", sub == 2, 1),
                          ("", 0, 0), ("", 0, 0), ("", 0, 0),
                          (STD_EXIT, sub == 3, 0)])


def hdd_page(sub):
    """MENU_SETTINGS_HARDFILE1, menu.c:1906-1935 with hdf_slot_lines
    (menu.c:326-360): IDE on; slot 0 HDF_FILE ("Hardfile (disk img)",
    config_hdf_msg), slot 1 HDF_FILE | HDF_SYNTHRDB ("Hardfile (filesys)"),
    neither file present (OpenHardfile failed at boot: "** file not
    found **", selectable: a file slot); HDD sounds off; the IDE port 2 line
    and the title's right arrow (CORE_CAPS_IDE2); row 7 STD_BACK"""
    nf = "       ** file not found **"
    return ("Harddisks", OSD_ARROW_RIGHT, [("    IDE : on ", sub == 0, 0),
                                           (" Master : Hardfile (disk img)", sub == 1, 0),
                                           (nf, sub == 2, 0),
                                           ("  Slave : Hardfile (filesys)", sub == 3, 0),
                                           (nf, sub == 4, 0),
                                           (" Sounds : off", sub == 5, 0),
                                           (" IDE port 2 \x16", sub == 6, 0),
                                           (STD_BACK, sub == 7, 0)])


# The tour of sim/l3/keys/menu_tour.txt, one item per redraw, with the
# menu.c logic that leads there.  Up / down move menusub over menumask's set
# bits (menu.c:633-656) and redraw in the same HandleUI call; main page
# menumask 0xb0 | df0 | df1 | CD = 0xf3 (menu.c:695, 713, 744); Floppy page
# 0x0f without line 2 (no drive sounds) = 0x0b (menu.c:861, 871).
TOURS = {
    "keys": [
        "clear",              # KEY_MENU in MENU_NONE2: OsdClear (menu.c:678-691)
        ("main", 0),          # MENU_MAIN1, menusub 0
        ("main", 1), ("main", 4), ("main", 5), ("main", 6), ("main", 7),   # five downs
        ("main", 6), ("main", 5), ("main", 4), ("main", 1), ("main", 0),   # five ups
        ("main", 1), ("main", 4),                                          # two downs
        ("floppy", 0),        # enter on menusub 4: MENU_FLOPPY1 (menu.c:813-818)
        ("floppy", 1), ("floppy", 3),                                      # two downs
        ("main", 4),          # enter on exit: MENU_MAIN1, menusub = parentsub (menu.c:906-909)
        ("main", 5),          # down
        ("hdd", 0),           # enter on menusub 5: MENU_SETTINGS_HARDFILE1 (menu.c:819-828)
        ("main", 5),          # escape: MENU_HARDFILE_EXIT, nothing changed (menu.c:2088-2105)
        ("main", 4), ("main", 5), ("main", 4),                             # the BURST: up, down, up
        # KEY_MENU: MENU_NONE1, OsdHide: no OSD_CMD_OSD_WR frame
    ],
}
PAGES = {"main": main_page, "floppy": floppy_page, "hdd": hdd_page}


def tour_frames(name, font):
    osd = Osd(font)
    frames = []
    for item in TOURS[name]:
        if item == "clear":
            frames.append(osd.clear())
            continue
        title, arrow, rows = PAGES[item[0]](item[1])
        osd.set_title(title, arrow)
        for n, (text, inv, stip) in enumerate(rows):
            frames.append(osd.write(n, text, 1 if inv else 0, stip))
    return frames


def pages_text(frames, charrom):
    """spitrace.py osd_pages over these frames' MOSI"""
    glyphs = spitrace.load_charrom(charrom)
    lines, page, prev = [], 0, None
    for out in frames:
        row, text = spitrace.osd_line(out, glyphs)
        if prev is None or not isinstance(row, int) or not isinstance(prev, int) or row <= prev:
            page += 1
            lines.append("--- page %d" % page)
        prev = row
        lines.append("%s %s" % (row, text) if text else str(row))
    return lines


def main(argv):
    args = argv[1:]
    charrom = CHARROM
    if "--charrom" in args:
        k = args.index("--charrom")
        charrom = args[k + 1]
        del args[k:k + 2]
    if len(args) != 1 or args[0] not in TOURS:
        sys.stderr.write(__doc__)
        return 2
    sys.stdout.reconfigure(encoding="latin-1")
    for line in pages_text(tour_frames(args[0], load_font(charrom)), charrom):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
