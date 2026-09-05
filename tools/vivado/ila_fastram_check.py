#!/usr/bin/env python3
"""Consistency check of an ila_fastram capture (CSV from ila_fastram_capture.tcl).

CPU level: every completed access on the DDR3 port (chip select low, data taken on the LAST
cycle of the access, byte selects nUDS/nLDS active LOW); writes build a word-granular model,
reads are compared against it. Island level: every request seen by the backend (request toggle)
with its byte enables; line reads compared against bytes written earlier in the capture.
usage: ila_fastram_check.py <csv> [max examples]"""
import csv, sys
from collections import Counter
path = sys.argv[1]; nex = int(sys.argv[2]) if len(sys.argv) > 2 else 15
rows = list(csv.reader(open(path))); hdr = rows[0]; data = rows[2:] if not rows[1][0].isdigit() else rows[1:]
def col(n):
    for i, h in enumerate(hdr):
        if h.split("/")[-1].split("[")[0].endswith(n): return i
    raise KeyError(n)
N = ["tg68_ddraddr","tg68_ddrcpustate","tg68_cuds","tg68_clds","tg68_cin","tg68_ddrout","tg68_ddrena","tg68_ddrready",
     "ddr3_dbg_req_rd","ddr3_dbg_req_be","ddr3_dbg_req_addr","ddr3_dbg_req_wdata","ddr3_dbg_resp_rdata","ddr3_dbg_cdc_state"]
c = {n: col(n) for n in N}; g = lambda r, n: r[c[n]]
def hx(v):
    try: return int(v, 16)
    except ValueError: return v
print("samples", len(data), "| ddr_ready low samples:", sum(1 for r in data if g(r,"tg68_ddrready") == "0"))
spans = []; cur = None
for i, r in enumerate(data):
    st = hx(g(r,"tg68_ddrcpustate")); cs = (st >> 2) & 1
    if cs == 0:
        if cur is None: cur = {"i": i, "addr": hx(g(r,"tg68_ddraddr")), "wr": (st & 3) == 3, "st": st, "ena": False}
        cur["ena"] |= g(r,"tg68_ddrena") == "1"
        cur["last"] = (hx(g(r,"tg68_ddrout")), hx(g(r,"tg68_cin")), g(r,"tg68_cuds") == "0", g(r,"tg68_clds") == "0", i)
    else:
        if cur: spans.append(cur); cur = None
if cur: spans.append(cur)
done = [s for s in spans if s["ena"]]
wr = [s for s in done if s["wr"]]; rd = [s for s in done if not s["wr"]]
print("CPU accesses", len(spans), "acknowledged", len(done), "writes", len(wr), "reads", len(rd),
      "| state codes", dict(Counter(s["st"] & 3 for s in spans)))
addrs = [s["addr"]*2 for s in spans]; print("byte address range 0x%06X..0x%06X, distinct words %d" % (min(addrs), max(addrs), len(set(addrs))))
mem = {}; checked = mism = 0; ex = []
for s in done:
    out, cin, hi, lo, last = s["last"]; w = s["addr"]
    if s["wr"]:
        old = mem.get(w)
        if old is None and not (hi and lo): continue
        old = old or 0
        mem[w] = ((cin if hi else old) & 0xFF00) | ((cin if lo else old) & 0x00FF)
    elif w in mem:
        checked += 1
        exp = mem[w]; got = out
        if hi and not lo: exp &= 0xFF00; got &= 0xFF00
        if lo and not hi: exp &= 0x00FF; got &= 0x00FF
        if exp != got:
            mism += 1
            if len(ex) < nex: ex.append((last, w*2, mem[w], out))
print("CPU reads of words written earlier: %d, mismatches: %d" % (checked, mism))
for e in ex: print("  row %5d byte-addr 0x%06X expected %04X read %04X" % e)
lines = {}; lc = lm = 0; lex = []; pend = None; nreq = 0
for i, r in enumerate(data):
    cs_ = hx(g(r,"ddr3_dbg_cdc_state")); req = (cs_ >> 2) & 1; dn = (cs_ >> 1) & 1
    if pend is None and req == 1:
        nreq += 1
        pend = {"rd": g(r,"ddr3_dbg_req_rd") == "1", "addr": hx(g(r,"ddr3_dbg_req_addr")), "be": hx(g(r,"ddr3_dbg_req_be")), "wd": hx(g(r,"ddr3_dbg_req_wdata"))}
    if pend is not None and dn == 1:
        if pend["rd"]:
            rdata = hx(g(r,"ddr3_dbg_resp_rdata")); L = lines.get(pend["addr"])
            if L:
                lc += 1
                for b in range(16):
                    if L[1] >> b & 1 and ((rdata >> (8*b)) & 0xFF) != ((L[0] >> (8*b)) & 0xFF):
                        lm += 1
                        if len(lex) < nex: lex.append((i, pend["addr"], b, (L[0] >> (8*b)) & 0xFF, (rdata >> (8*b)) & 0xFF))
                        break
        else:
            v, m = lines.get(pend["addr"], (0, 0))
            for b in range(16):
                if pend["be"] >> b & 1: v = (v & ~(0xFF << (8*b))) | (pend["wd"] & (0xFF << (8*b))); m |= 1 << b
            lines[pend["addr"]] = (v, m)
        pend = None
print("island requests %d | line reads with earlier-written bytes %d | mismatching lines %d" % (nreq, lc, lm))
for e in lex: print("  row %5d line 0x%08X byte %d expected %02X got %02X" % e)
