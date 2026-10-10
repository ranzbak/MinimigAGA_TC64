#!/usr/bin/env python3
"""Tabulate IrqLat logs (from IrqLatMatrix or single runs) as Markdown.

    ./irqlat_table.py irqlat.log [more.log ...]

One row per run: the '=== label' line IrqLatMatrix writes before its runs,
the run (load, bitplanes, nasty, OS path), and per source the average and
maximum latency in us and the missed count, plus the average read cost.
"""
import re
import sys

HDR = re.compile(r"^IrqLat: (\S+) load (\S+) bpl (off|8 FMODE \d)( nasty)? rate")
SRC = re.compile(r"^(CIA-B timer A|Copper) \(level \d\): taken (\d+) expected (\d+) missed (\d+)")
LAT = re.compile(r"^  latency us: min (\S+) avg (\S+) max (\S+)")
RD = re.compile(r"^  read \(.*\) us: avg (\S+) max (\S+)")


def runs(lines):
    label, run, src = "", None, None
    for line in lines:
        line = line.rstrip("\n")
        if line.startswith("=== "):
            label = line[4:].strip().strip('"')
            continue
        m = HDR.match(line)
        if m:
            if run:
                yield run
            mode, load, bpl, nasty = m.groups()
            name = load
            if bpl != "off":
                name += " BPL F" + bpl[-1]
            if nasty:
                name += " NASTY"
            if mode == "OS":
                name += " OS"
            run, src = {"label": label, "run": name}, None
            continue
        if run is None:
            continue
        m = SRC.match(line)
        if m:
            src = "cia" if m.group(1).startswith("CIA") else "cop"
            run[src + "_missed"] = m.group(4)
            continue
        m = LAT.match(line)
        if m and src:
            run[src + "_avg"], run[src + "_max"] = m.group(2), m.group(3)
            continue
        m = RD.match(line)
        if m and src:
            run[src + "_rd"] = m.group(1)
    if run:
        yield run


def main(paths):
    cols = ["label", "run", "cia_avg", "cia_max", "cia_missed", "cia_rd",
            "cop_avg", "cop_max", "cop_missed", "cop_rd"]
    head = ["set", "run", "CIA avg", "CIA max", "CIA miss", "3 CIA rd",
            "cop avg", "cop max", "cop miss", "2 beam rd"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for p in paths:
        with open(p, errors="replace") as f:
            for r in runs(f):
                print("| " + " | ".join(r.get(c, "-") for c in cols) + " |")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
