#!/usr/bin/env python3
"""The margin table of the L3 runs (plan 7.1 items 1-15 x grid point).

    python3 -I sim/l3/margins.py [--long] <run dir>...

Reads every run directory's tb_*.log (the "=== MARGIN" lines of mon_l3.vh,
"=== OSD GAP" / "=== OSD EARLY", the CD-DA fill line) and its l3check
outputs (cdda.txt: underruns; akiko.txt: the request latency; keys.txt).
The grid point of a run comes from its log's "L3 bench:" line: the CPU,
EXTRA_WS, SCKDLY / C28DLY, SLAT / SJIT (SLAT 2 SJIT 0 is +FAST_HW=1, the only
point with SLAT 2).  A run without a verdict line, or one that ended at its
TIMEOUT, is listed as incomplete and left out of the table.

The table (markdown): one row per measurement, one column per grid point;
a cell is the worst value over that point's runs (counts, LOW above the
bound: the largest; times and spacings: the smallest), its verdict (LOW
if any run is LOW, else ok, rec, n/a) and the scenario it came from.
--long also prints one line per run and measurement.  Exit 0.
"""
import glob
import os
import re
import sys

# row order: (item, name, kind); kind "count" = larger is worse
ROWS = [
    ("1", "stale_acks", "count"),
    ("2", "osd_gap", "min"),
    ("2", "osd_early", "count"),
    ("3", "dmode_release", "min"),
    ("3", "dmode_L", "min"),
    ("4", "paula_cs_release", "min"),
    ("4", "userio_cs_release", "min"),
    ("4", "paula_word_spacing", "min"),
    ("4", "userio_byte_spacing", "min"),
    ("5", "spi_write_busy", "count"),
    ("6", "fdd_fifo_empty_dma", "count"),
    ("6", "fdd_fifo_min_words", "min"),
    ("7", "fdd_fifo_full_write", "count"),
    ("7", "fdd_wr_word_gap", "min"),
    ("8", "ide_wait", "min"),
    ("9", "cd_timeout_left", "min"),
    ("CD-DA", "cdda_underruns", "count"),
    ("CD-DA", "cdda_fill_max_ms", "max"),
    ("12", "rtc_cs_high", "min"),
    ("13", "akiko_req_ack_max", "max"),
    ("14", "kick_order", "min"),
    ("15", "keys_check", "pass"),
]
NOTES = {
    "10": "SD protocol waits: closed in Phase 3 (TIMER waits); no L3 monitor",
    "11": "SPIN / delays: grep gate (Phase 3, Task 11); no L3 monitor",
}
VERDICT_RANK = {"LOW": 3, "ok": 2, "rec": 1, "n/a": 0}

RE_HDR = re.compile(r"^L3 bench: CPU=(\S+) SCENARIO=(\S+) SLAT=(\d+) SJIT=(\d+) EXTRA_WS=(\d+) "
                    r"TICKDIV=\S+ TICKDIV_AT=\S+ SCKDLY=([0-9.]+) C28DLY=([0-9.]+)")
RE_MARGIN = re.compile(r"^=== MARGIN (\d+) (\S+) min (\S+) (\S+) \(bound (-?[0-9.]+), ([a-zA-Z/]+)\) over (\d+) (.*)$")
RE_GAP = re.compile(r"^=== OSD GAP min (\d+) over (\d+) bytes")
RE_EARLY = re.compile(r"^=== OSD EARLY (\d+) of (\d+) reply bytes")
RE_FIFO6 = re.compile(r"^=== MARGIN \(info\) 6 fdd \d+ tracks: fifo min (\d+) words")
RE_GAP7 = re.compile(r"^=== MARGIN \(info\) 7 fdd write FIFO word gap min ([0-9.]+) clk_114 over (\d+) words \(bound (\d+)\), (\d+) below")
RE_FILLS = re.compile(r"^=== CDDA fills (\d+) .*min/median/max ([0-9.]+)/([0-9.]+)/([0-9.]+) ms")
RE_UNDER = re.compile(r"^INFO cdda, CPU \S+: \d+ halves, (\d+) underrun")
RE_LAT = re.compile(r"amiga_req to amiga_ack \(clk_114\): n (\d+) min (\d+) median (\d+) max (\d+)")
RE_CDCFG = re.compile(r"^=== CD config (\S+)")


def point_of(cpu, slat, sjit, ws, sck, c28):
    parts = [cpu]
    if ws:
        parts.append("ws%d" % ws)
    if (sck, c28) != (1.5, 0.3):
        parts.append("sk %g/%g" % (sck, c28))
    if slat == 2 and sjit == 0:
        parts.append("FAST_HW")
    elif sjit:
        parts.append("SJIT %d" % sjit)
    elif slat != 8:
        parts.append("SLAT %d" % slat)
    if len(parts) == 1:
        parts.append("default")
    return " ".join(parts)


def read(path):
    try:
        with open(path, encoding="latin-1") as f:
            return f.read().splitlines()
    except OSError:
        return []


def run_values(d):
    """(point, scenario, {row name: (value, verdict)}, problem or None)"""
    logs = sorted(glob.glob(os.path.join(d, "tb_*.log")))
    if not logs:
        return None, None, {}, "no tb_*.log"
    lines = read(logs[0])
    hdr = next((RE_HDR.match(l) for l in lines if RE_HDR.match(l)), None)
    if not hdr:
        return None, None, {}, "no 'L3 bench:' line"
    cpu, scen = hdr.group(1), hdr.group(2)
    slat, sjit, ws = int(hdr.group(3)), int(hdr.group(4)), int(hdr.group(5))
    point = point_of(cpu, slat, sjit, ws, float(hdr.group(6)), float(hdr.group(7)))
    v = {}
    end = None
    for l in lines:
        m = RE_CDCFG.match(l)
        if m and scen == "cd":
            scen = "cd " + m.group(1)
        m = RE_MARGIN.match(l)
        if m:
            name, val, verdict = m.group(2), m.group(3), m.group(6)
            if val == "none":
                v[name] = (None, "n/a")
            else:
                v[name] = (float(val), verdict)
            continue
        m = RE_GAP.match(l)
        if m:
            v["osd_gap"] = (float(m.group(1)), "ok" if int(m.group(1)) >= 40 else "LOW")
        m = RE_EARLY.match(l)
        if m:
            n, tot = int(m.group(1)), int(m.group(2))
            v["osd_early"] = (float(n), ("ok" if n == 0 else "LOW") if tot else "n/a")
        m = RE_FIFO6.match(l)
        if m:
            v["fdd_fifo_min_words"] = (float(m.group(1)), "rec")
        m = RE_GAP7.match(l)
        if m:
            v["fdd_wr_word_gap"] = (float(m.group(1)), "ok" if int(m.group(4)) == 0 else "LOW")
        m = RE_FILLS.match(l)
        if m:
            v["cdda_fill_max_ms"] = (float(m.group(4)), "rec")
        if l.startswith("=== PASS") or l.startswith("=== FAIL"):
            end = end or l
        if l.startswith("=== cycle limit"):
            end = l
    for l in read(os.path.join(d, "cdda.txt")):
        m = RE_UNDER.match(l)
        if m:
            n = int(m.group(1))
            v["cdda_underruns"] = (float(n), "ok" if n == 0 else "LOW")
    lat = [int(m.group(4)) for m in (RE_LAT.search(l) for l in read(os.path.join(d, "akiko.txt"))) if m]
    if lat:
        v["akiko_req_ack_max"] = (float(max(lat)), "rec")
    if scen == "keys":
        k = read(os.path.join(d, "keys.txt"))
        v["keys_check"] = (None, "ok" if any(l.startswith("PASS keys:") for l in k) else "LOW")
    problem = None
    if end is None:
        problem = "no verdict line (still running?)"
    elif end.startswith("=== cycle limit"):
        problem = end
    return point, scen, v, problem


def worse(kind, a, b):
    """is value a worse than b"""
    if a is None:
        return False
    if b is None:
        return True
    return a > b if kind in ("count", "max") else a < b


def fmt(x):
    if x is None:
        return "none"
    if x == int(x):
        return "{:,}".format(int(x))
    return "{:,.3f}".format(x).rstrip("0").rstrip(".")


def main(argv):
    long_ = False
    if argv and argv[0] == "--long":
        long_, argv = True, argv[1:]
    if not argv:
        print(__doc__.strip())
        return 2
    runs = []
    for d in argv:
        if not os.path.isdir(d):
            continue
        point, scen, v, problem = run_values(d)
        name = os.path.basename(os.path.normpath(d))
        if problem:
            print("# incomplete: %s: %s" % (name, problem))
            continue
        runs.append((name, point, scen, v))
    points = []
    for _, p, _, _ in runs:
        if p not in points:
            points.append(p)
    # the default point first, then in order of appearance
    seen = list(points)
    points.sort(key=lambda p: ("default" not in p, seen.index(p)))
    print("| item | measurement | " + " | ".join(points) + " |")
    print("|---|---|" + "---|" * len(points))
    for item, row, kind in ROWS:
        cells = []
        for p in points:
            best = None  # (value, verdict, scenario)
            verdict = None
            for name, rp, scen, v in runs:
                if rp != p or row not in v:
                    continue
                val, vd = v[row]
                if verdict is None or VERDICT_RANK[vd] > VERDICT_RANK[verdict]:
                    verdict = vd
                if vd == "n/a":
                    continue
                if best is None or worse(kind, val, best[0]) or (kind == "pass" and vd == "LOW"):
                    best = (val, vd, scen)
            if verdict is None:
                cells.append("-")
            elif best is None:
                cells.append("n/a")
            elif kind == "pass":
                cells.append("%s (%s)" % ("PASS" if verdict != "LOW" else "**FAIL**", best[2]))
            else:
                vtxt = "**LOW**" if verdict == "LOW" else verdict
                cells.append("%s %s (%s)" % (fmt(best[0]), vtxt, best[2]))
        print("| %s | %s | %s |" % (item, row, " | ".join(cells)))
    for item, note in sorted(NOTES.items()):
        print("| %s | - | %s |" % (item, note))
    low = [(name, row) for name, _, _, v in runs for row, (_, vd) in sorted(v.items()) if vd == "LOW"]
    print()
    print("runs: %d; LOW: %s" % (len(runs), ", ".join("%s %s" % x for x in low) if low else "none"))
    if long_:
        print()
        for name, p, scen, v in runs:
            for item, row, kind in ROWS:
                if row in v:
                    print("%s | %s | %s | %s %s | %s" % (name, p, scen, item, row, "%s %s" % (fmt(v[row][0]), v[row][1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
