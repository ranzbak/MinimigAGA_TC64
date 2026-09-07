#!/usr/bin/env python3
"""Turn an ila_cpu040 CSV into a list of 68k chipset bus transfers.

    tools/vivado/ila_bus_decode.py /tmp/bus.csv [--longs] [--pc]

The ILA samples clk_114 (8.8 ns) while a chipset cycle lasts about 140 ns, so
one transfer spans many identical rows even with storage qualification on !as.
This collapses each cycle to one line and, with --longs, pairs consecutive word
transfers at A and A+2 back into the longword the CPU actually asked for.

Why it exists: the AP68040 boot failure (findings/ap68040/plan-v2-with-ddr3.md)
looks identical in an address-only trace whether the memory region is too
small, the free list is empty, or a longword read returns a stale first word.
Only the data tells them apart, so read the data.

Columns come from the probe names, not their order, so adding a probe does not
break this.  bus_ctl is {as, rw, uds, lds}, all active low.

STALE markers are a heuristic, not a verdict: a read whose data equals the
previous transfer's is flagged because that is what a stale latch looks like,
but repeated values are perfectly normal in a zeroed list or a memset.  Treat a
marker as somewhere to look, and confirm against what the ROM says should be
there.
"""
import csv
import sys


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        sys.exit(f"{path}: no samples")
    # row 0 = probe names, row 1 = radix, rest = samples.  A probe declared
    # inside a generate block arrives as "top/g_cpu040_ila.bus_ctl[3:0]", so
    # strip the hierarchy on both separators, not just the slash.
    names = [c.split("/")[-1].split("[")[0].split(".")[-1].strip()
             for c in rows[0]]
    idx = {}
    for i, n in enumerate(names):
        idx.setdefault(n, i)
    return idx, rows[2:]


def col(idx, row, *cands):
    for c in cands:
        if c in idx:
            v = row[idx[c]].strip()
            return int(v, 16) if v else 0
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        print(__doc__)
        return 2
    idx, rows = load(args[0])

    xfers = []
    prev_key = None
    for r in rows:
        ctl = col(idx, r, "bus_ctl")
        if ctl is None:
            sys.exit("no bus_ctl probe in this CSV -- wrong bitstream?")
        if ctl & 0b1000:            # as high: no cycle in progress
            prev_key = None
            continue
        adr = col(idx, r, "tg68_adr")
        rw = (ctl >> 2) & 1         # 1 = read
        uds = (ctl >> 1) & 1
        lds = ctl & 1
        key = (adr, rw, uds, lds)
        if key == prev_key:         # same cycle, still asserted
            xfers[-1]["din"] = col(idx, r, "tg68_dat_in")
            continue
        prev_key = key
        xfers.append({
            "adr": adr, "rd": rw, "uds": uds, "lds": lds,
            "din": col(idx, r, "tg68_dat_in"),
            "dout": col(idx, r, "tg68_dat_out"),
            "pc": col(idx, r, "dbg_pc"),
        })

    if not xfers:
        print("# no bus cycles captured (as never low)")
        return 1

    print(f"# {len(xfers)} bus transfers")
    if "--longs" in opts:
        i = 0
        while i < len(xfers):
            a, b = xfers[i], (xfers[i + 1] if i + 1 < len(xfers) else None)
            if b and b["adr"] == a["adr"] + 2 and b["rd"] == a["rd"]:
                d = ((a["din"] if a["rd"] else a["dout"]) << 16) | \
                    (b["din"] if b["rd"] else b["dout"])
                print(f"  ${a['adr']:08X}  {'RD' if a['rd'] else 'WR'}.l  "
                      f"${d:08X}" + (f"   pc=${a['pc']:06X}" if "--pc" in opts else ""))
                i += 2
                continue
            d = a["din"] if a["rd"] else a["dout"]
            print(f"  ${a['adr']:08X}  {'RD' if a['rd'] else 'WR'}.w  "
                  f"    ${d:04X}" + (f"   pc=${a['pc']:06X}" if "--pc" in opts else ""))
            i += 1
    else:
        last = None
        for x in xfers:
            d = x["din"] if x["rd"] else x["dout"]
            mark = "  <-- same data as previous" if (x["rd"] and d == last) else ""
            print(f"  ${x['adr']:08X}  {'RD' if x['rd'] else 'WR'}  "
                  f"uds={x['uds']} lds={x['lds']}  ${d:04X}"
                  + (f"  pc=${x['pc']:06X}" if "--pc" in opts else "") + mark)
            last = d
    return 0


if __name__ == "__main__":
    sys.exit(main())
