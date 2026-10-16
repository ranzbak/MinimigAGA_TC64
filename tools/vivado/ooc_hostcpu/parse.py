#!/usr/bin/env python3
"""Markdown table of every runs/<name>: u_core resources (util_hier.rpt) and WNS (summary.txt)."""
import glob, os, re, sys
root = os.path.dirname(os.path.abspath(__file__))
print("| run | LUT | LUTRAM | SRL | FF | RAMB36 | RAMB18 | DSP | period | WNS | est Fmax MHz |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for d in sorted(glob.glob(root + "/runs/*")):
    n = os.path.basename(d)
    try:
        s = open(d + "/summary.txt").read()
        per = float(re.search(r"period=(\S+)", s).group(1)); wns = float(re.search(r"wns=(\S+)", s).group(1))
        row = None
        for l in open(d + "/util_hier.rpt"):
            c = [x.strip() for x in l.split("|")]
            if len(c) > 9 and c[1] == "u_core": row = c
        lut, logic, lram, srl, ff, b36, b18, dsp = row[3:11]
    except (OSError, AttributeError, TypeError):
        print(f"| {n} | FAILED/RUNNING |"); continue
    print(f"| {n} | {lut} | {lram} | {srl} | {ff} | {b36} | {b18} | {dsp} | {per} | {wns:+.3f} | {1000/(per-wns):.0f} |")
