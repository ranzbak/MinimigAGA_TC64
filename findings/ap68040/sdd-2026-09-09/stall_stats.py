#!/usr/bin/env python3
"""Stall accounting from a CPU-ILA capture of the AP68040.

Usage: stall_stats.py <capture.csv> [more.csv ...]

The probe is tg68_cpustate, laid out in rtl/soc/TG68K.vhd as

    cpustate <= longword_pair & clkena & slower(1 downto 0) & ramcs & bstate(1 downto 0)
       bit 6      bit 5        bits 4:3                       bit 2   bits 1:0

so one capture in "busy" mode (CAPTURE_MODE ALWAYS) is a run of consecutive
clk_114 samples and every number below is a straight count over them.

  core advanced      bit 5 set          -- the kernel actually stepped
  bus request        bits 1:0 /= "01"   -- the core wants the bus (01 = idle)
  memory selected    bit 2 clear        -- a controller has the access
  throttled          bits 4:3 /= "00"   -- slower is holding the select off

The pre-x3 baseline, measured the same way over 144 us while a demo ran:
core advanced 14.4 %, bus request pending 44.8 %, stalled on memory 44.2 %.
The enable ceiling is 25 % (four phases of sixteen).
"""
import csv, sys

def load(path):
    rows = list(csv.reader(open(path)))
    hdr = [c.split('/')[-1].split('[')[0].split('.')[-1].strip() for c in rows[0]]
    col = next((i for i, n in enumerate(hdr) if n.startswith('tg68_cpustate')), None)
    if col is None:
        sys.exit(f"{path}: no tg68_cpustate probe -- wrong ILA or wrong bitstream")
    return [int(r[col], 16) for r in rows[2:] if r[col].strip()]

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    vals = []
    for p in sys.argv[1:]:
        v = load(p)
        print(f"{p}: {len(v)} samples ({len(v) * 8.815e-3:.1f} us)")
        vals += v
    n = len(vals)
    if not n:
        sys.exit("no samples")
    adv   = sum(1 for v in vals if v & 0x20)
    req   = sum(1 for v in vals if (v & 0x03) != 0x01)
    mem   = sum(1 for v in vals if not (v & 0x04))
    throt = sum(1 for v in vals if (v & 0x18))
    both  = sum(1 for v in vals if (v & 0x03) != 0x01 and not (v & 0x04))
    print(f"\ntotal {n} samples = {n * 8.815e-3:.1f} us of clk_114\n")
    for label, c in (("core advanced (clkena)", adv),
                     ("bus request pending", req),
                     ("memory select active", mem),
                     ("  of which both", both),
                     ("select throttled (slower)", throt)):
        print(f"  {label:28s} {c:6d}  {100.0*c/n:5.1f} %")
    print(f"\n  enable ceiling                     25.0 %  (four phases of sixteen)")
    if adv:
        print(f"  clk_114 per core advance    {n/adv:6.2f}")
    print("\n  baseline, pre-x3, 144 us: advanced 14.4 %, request 44.8 %, "
          "stalled on memory 44.2 %")

main()
