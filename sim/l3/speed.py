#!/usr/bin/env python3
"""sim/l3/speed.py: speed and I-cache figures of one finished L3 run (Task 20).

    python3 -I sim/l3/speed.py sim/l3/run_<RUNTAG> [more run directories]
    python3 -I sim/l3/speed.py --selftest

Reads only files a run already wrote (no simulation): spi_t.txt, the run's
tb_<scenario>_*.log (run.out as a fallback) and results.txt.  Cycles are
clk_114 (113.4375 MHz, the L3 bench's clock).  One block of "key: value"
lines per run directory:

  spi_byte_ns       SD sector reads that the firmware's byte loop moves (CMD17/18
                    frames on cs 02 that carry >= 512 data bytes): frame duration
                    / frame bytes (command, card wait and data, all included)
  sector_read_us    end to end per sector: CMD17 = its frame (start..end);
                    CMD18 = the command frame start to the end of the direct-mode
                    data frame (cs 42/46) that follows it without a gap, per sector
  ring_fill_ms      "CDDA fill" lines (Task 17): the 32 KB half-ring refill
  menu_redraw_ms    "KEYS ev" key-down event to the end of the last "20 0c" frame
                    before the next key-down event (Task 8's tour)
  icache_*          per STATS window (win_start .. win_end): refills, retired,
                    refills/retired, 8 x refills/retired, busy cycles, refill share
                    estimate.  RV only; the 832 has neither I$ nor STATS lines.

"Refill share of busy cycles" is an ESTIMATE, not a measurement: the STATS lines
carry no refill latency.  share = refills x L / busy cycles with the assumed
latency L (REFILL_LAT_ASSUMED clk_114 per 8-word refill; 20 and 40 are printed
as the bracket).  A line missing from a run is printed as "n/a (... missing in
<run>)", never re-simulated.
"""
import glob
import os
import re
import statistics
import sys
import tempfile

MHZ = 113.4375              # clk_114 in MHz (the "at 113.4375 MHz" in the CDDA lines)
REFILL_LAT_ASSUMED = (30, 20, 40)   # clk_114 per refill: assumption, central first


def ns(cycles):
    return cycles * 1000.0 / MHZ


def stat(vals, scale=1.0, fmt="%.1f"):
    if not vals:
        return None
    v = [x * scale for x in vals]
    return "n=%d median %s min %s max %s" % (
        len(v), fmt % statistics.median(v), fmt % min(v), fmt % max(v))


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def frames(run):
    """[(start, end, cs, mosi bytes list)] from spi_t.txt."""
    out = []
    t = read_text(os.path.join(run, "spi_t.txt"))
    if t is None:
        return None
    for ln in t.splitlines():
        p = ln.split()
        if len(p) < 4:
            continue
        m = p[3:p.index("/")] if "/" in p else p[3:]
        out.append((int(p[0]), int(p[1]), p[2], m))
    return out


def first_cmd(mosi):
    for b in mosi[:4]:
        if b != "ff":
            return b
    return None


def sd_reads(fr):
    """-> (ns/byte list, CMD17 sector us list, CMD18 sector us list)"""
    nsb, c17, c18 = [], [], []
    for i, (s, e, cs, m) in enumerate(fr):
        if cs != "02":
            continue
        c = first_cmd(m)
        if c not in ("51", "52"):
            continue
        if len(m) >= 512:                       # the data moves inside this frame
            nsb.append(ns(e - s) / len(m))
            sec = max(1, (len(m) - 14) // 514)
            (c17 if c == "51" else c18).append(ns(e - s) / 1000.0 / sec)
        elif c == "52" and i + 1 < len(fr):     # data follows in a direct-mode frame
            s2, e2, cs2, m2 = fr[i + 1]
            if cs2 in ("42", "46") and s2 == e and len(m2) >= 512:
                c18.append(ns(e2 - s) / 1000.0 / (len(m2) // 512))
    return nsb, c17, c18


def ring_fills(logtxt):
    return [float(x) for x in re.findall(r"CDDA fill \d+ start \d+ done \d+ \(([\d.]+) ms", logtxt)]


def menu_redraws(fr, logtxt):
    ev = [int(c) for code, c in re.findall(r"KEYS ev \d+ ([0-9a-f]{2}) at cycle (\d+)", logtxt)
          if code != "00"]
    ev_all = sorted(ev)
    draws = [(s, e) for (s, e, cs, m) in fr if cs == "20" and m and m[0] == "0c"]
    out = []
    for i, t0 in enumerate(ev_all):
        t1 = ev_all[i + 1] if i + 1 < len(ev_all) else None
        ends = [e for (s, e) in draws if s >= t0 and (t1 is None or s < t1)]
        if ends:
            out.append(ns(max(ends) - t0) / 1e6)
    return out


def stats_window(logtxt):
    """-> (start, end) dicts or None; keys irefill dread dwrite busy retired cycle"""
    res = []
    for k in ("win_start", "win_end"):
        m = re.search(r"STATS@%s irefill (\d+) dread (\d+) dwrite (\d+) busy_cycles (\d+) "
                      r"\(rv_hostcpu, to cycle (\d+)\)" % k, logtxt)
        r = re.search(r"RETIRED (\d+) \(STATS@%s," % k, logtxt)
        if not m or not r:
            return None
        res.append(dict(irefill=int(m.group(1)), dread=int(m.group(2)), dwrite=int(m.group(3)),
                        busy=int(m.group(4)), cycle=int(m.group(5)), retired=int(r.group(1))))
    return res


def analyse(run):
    name = os.path.basename(os.path.normpath(run))
    res = read_text(os.path.join(run, "results.txt")) or ""
    cpu = "rv" if re.search(r"^=== CPU rv", res, re.M) else ("832" if re.search(r"^=== CPU 832", res, re.M) else "?")
    logs = sorted(glob.glob(os.path.join(run, "tb_*.log")))
    logtxt = read_text(logs[0]) if logs else None
    if logtxt is None:
        logtxt = read_text(os.path.join(run, "run.out")) or ""
    m = re.match(r"tb_(.+?)_x\d", os.path.basename(logs[0])) if logs else None
    scen = m.group(1) if m else "?"
    fr = frames(run)
    L = ["run: %s" % name, "cpu: %s" % cpu, "scenario: %s" % scen]
    if fr is None:
        L.append("spi_byte_ns: n/a (spi_t.txt missing in %s)" % name)
        L.append("sector_read_us: n/a (spi_t.txt missing in %s)" % name)
        L.append("menu_redraw_ms: n/a (spi_t.txt missing in %s)" % name)
    else:
        nsb, c17, c18 = sd_reads(fr)
        L.append("spi_byte_ns: " + (stat(nsb) or "n/a (no firmware-loop SD read in %s)" % name))
        L.append("sector_read_us CMD17: " + (stat(c17) or "n/a (none in %s)" % name))
        L.append("sector_read_us CMD18: " + (stat(c18) or "n/a (none in %s)" % name))
        mr = menu_redraws(fr, logtxt)
        L.append("menu_redraw_ms: " + (stat(mr, fmt="%.3f") or "n/a (no key redraw in %s)" % name))
    rf = ring_fills(logtxt)
    L.append("ring_fill_ms: " + (stat(rf, fmt="%.2f") or "n/a (no CDDA fill line in %s)" % name))
    if cpu == "832":
        L.append("icache: n/a (the 832 has no I-cache and no STATS lines)")
    else:
        w = stats_window(logtxt)
        if w is None:
            L.append("icache: n/a (window line missing in %s)" % name)
        else:
            a, b = w
            d = {k: b[k] - a[k] for k in b}
            ratio = d["irefill"] / d["retired"] if d["retired"] else float("nan")
            L.append("icache_refills: %d" % d["irefill"])
            L.append("icache_retired: %d" % d["retired"])
            L.append("icache_miss_ratio_pct: %.2f" % (100 * ratio))
            L.append("icache_words_per_instr: %.3f" % (8 * ratio))
            L.append("icache_window_cycles: %d" % d["cycle"])
            L.append("icache_busy_cycles: %d" % d["busy"])
            sh = ", ".join("L=%d: %.1f %%" % (lat, 100.0 * d["irefill"] * lat / d["busy"] if d["busy"] else float("nan"))
                           for lat in REFILL_LAT_ASSUMED)
            L.append("icache_refill_share_ESTIMATE (assumed latency, not measured): " + sh)
    return L


def selftest():
    with tempfile.TemporaryDirectory() as d:
        run = os.path.join(d, "run_x")
        os.mkdir(run)
        data = " ".join(["ff"] * 520)
        sp = [
            "1000 1000000 02 ff 51 00 00 00 08 ff %s / %s" % (data, data),
            "2000000 2000100 02 ff 52 00 00 00 08 7d ff / ff 00 ff fe",
            "2000100 2040100 42 %s / %s" % (" ".join(["00"] * 512), " ".join(["11"] * 512)),
            "3000000 3001000 20 0c 00 00 / 00",
            "3100000 3200000 20 0c 00 01 / 00",
            "3300000 3400000 20 98 ff / 00 00",
        ]
        open(os.path.join(run, "spi_t.txt"), "w").write("\n".join(sp) + "\n")
        open(os.path.join(run, "results.txt"), "w").write("=== CPU rv\n")
        log = "\n".join([
            "=== KEYS ev 1 69 at cycle 2900000", "=== KEYS ev 2 00 at cycle 2900080",
            "=== KEYS ev 3 4d at cycle 3300000",
            "=== CDDA fill 1 start 1 done 2 (42.80 ms at 113.4375 MHz), 32768 writes",
            "=== STATS@win_start irefill 100 dread 5 dwrite 6 busy_cycles 1000 (rv_hostcpu, to cycle 10)",
            "=== RETIRED 1000 (STATS@win_start, to cycle 10)",
            "=== STATS@win_end irefill 150 dread 9 dwrite 9 busy_cycles 3000 (rv_hostcpu, to cycle 410)",
            "=== RETIRED 2000 (STATS@win_end, to cycle 410)"]) + "\n"
        open(os.path.join(run, "tb_x_x0_s8_j0.log"), "w").write(log)
        out = "\n".join(analyse(run))
        for want in ("icache_refills: 50", "icache_retired: 1000", "icache_miss_ratio_pct: 5.00",
                     "icache_words_per_instr: 0.400", "icache_window_cycles: 400",
                     "ring_fill_ms: n=1 median 42.80", "spi_byte_ns: n=1",
                     "sector_read_us CMD17: n=1", "sector_read_us CMD18: n=1 median 353.5"):
            assert want in out, (want, out)
        # key 1 (cycle 2.9 M) -> last 0c frame ends 3200000: 300000 cycles = 2.645 ms
        assert "menu_redraw_ms: n=1 median 2.645" in out, out
        # window line missing -> n/a with the run name
        open(os.path.join(run, "tb_x_x0_s8_j0.log"), "w").write("=== nothing\n")
        assert "icache: n/a (window line missing in run_x)" in "\n".join(analyse(run))
    print("speed.py selftest: PASS")


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
    if not argv or argv[0].startswith("-"):
        sys.stderr.write(__doc__)
        return 2
    for i, r in enumerate(argv):
        if i:
            print()
        print("\n".join(analyse(r)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
