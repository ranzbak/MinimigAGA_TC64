import sys, os, re, glob
root = sys.argv[1]
print("| run | LUT | LUTRAM | SRL | FF | RAMB36 | RAMB18 | DSP | period | WNS | est Fmax MHz |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for d in sorted(glob.glob(root + "/runs/*")):
    n = os.path.basename(d)
    try:
        s = open(d + "/summary.txt").read()
    except OSError:
        print(f"| {n} | FAILED/RUNNING |"); continue
    per = float(re.search(r"period=(\S+)", s).group(1)); wns = float(re.search(r"wns=(\S+)", s).group(1))
    row = None
    for l in open(d + "/util_hier.rpt"):
        c = [x.strip() for x in l.split("|")]
        if len(c) > 9 and c[1] == "u_core": row = c
    lut, logic, lram, srl, ff, b36, b18, dsp = row[3:11]
    print(f"| {n} | {lut} | {lram} | {srl} | {ff} | {b36} | {b18} | {dsp} | {per} | {wns:+.3f} | {1000/(per-wns):.0f} |")
