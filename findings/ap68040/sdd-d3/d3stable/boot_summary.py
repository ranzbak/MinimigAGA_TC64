#!/usr/bin/env python3
"""Judge boot-check.tcl windows: per CSV, the dbg_flags seen, the share of
samples with the core halted (flags bit 1 = halted, as in E = fault+in_exc+halted),
the number of distinct PCs, the top PCs, and whether the Exec idle loop ($F815D2)
is among them.  Usage: boot_summary.py <prefix>_NN.csv ..."""
import csv, sys, collections
for path in sys.argv[1:]:
    with open(path) as f:
        r = csv.reader(f); hdr = next(r)
        def col(name):
            for i, h in enumerate(hdr):
                if name in h: return i
            raise SystemExit("no column " + name)
        ipc, ifl = col("dbg_pc"), col("dbg_flags")
        pcs, flags, halted, n = collections.Counter(), collections.Counter(), 0, 0
        for row in r:
            if len(row) <= max(ipc, ifl) or not row[ipc].strip(): continue
            n += 1
            pc, fl = row[ipc].strip().lower(), row[ifl].strip().lower()
            try: flv = int(fl, 16)
            except ValueError: n -= 1; continue          # the radix row
            pcs[pc] += 1; flags[fl] += 1
            if flv & 0x2: halted += 1
    top = ", ".join(f"{p}x{c}" for p, c in pcs.most_common(4))
    idle = "idle-loop seen" if "00f815d2" in pcs else "idle-loop NOT seen"
    verdict = "HALTED" if halted == n and n else ("healthy" if halted == 0 else "mixed")
    print(f"{path}: {verdict}; flags {dict(flags)}; {len(pcs)} distinct PCs; {idle}; top {top}")
