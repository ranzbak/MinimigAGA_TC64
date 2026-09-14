#!/usr/bin/env python3
"""Decode chip-RAM acknowledge phase histograms captured by ila_phase_hist.tcl.

    tools/vivado/phase_hist.py <csv> [<csv> ...]

Each CSV holds ila_cpu040's samples; dbg_phist (probe9, 384 bits) carries a
snapshot of one ~37 ms window, laid out as TG68K.vhd documents it:

    bits 127:0    8 x 16  clk cycles from a chip-RAM acknowledge to clkena_r
    bits 383:128  16 x 16 SDRAM round phase the acknowledge landed on

Prints both histograms per file and the sum over all files.  Compare a ratio-3
capture against a ratio-4 one: bins that ratio 3 fills and ratio 4 leaves empty
are the candidates.
"""
import csv
import sys


def decode(value):
    """Return (phase16, delay8) lists from the probe's hex or binary string."""
    v = value.strip().replace("_", "").replace(" ", "")
    if v.lower().startswith("0x"):
        v = v[2:]
    if set(v) <= {"0", "1"} and len(v) == 384:
        n = int(v, 2)
    else:
        n = int(v, 16)
    field = lambda lo: (n >> lo) & 0xFFFF
    delay = [field(16 * i) for i in range(8)]
    phase = [field(128 + 16 * i) for i in range(16)]
    return phase, delay


def last_sample(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    head = rows[0]
    col = next(i for i, h in enumerate(head) if "dbg_phist" in h)
    for row in reversed(rows[1:]):
        if len(row) > col and row[col].strip():
            return row[col]
    raise ValueError(f"{path}: no dbg_phist sample")


def show(title, phase, delay):
    tp, td = sum(phase), sum(delay)
    print(f"--- {title}: {tp} chip-RAM acknowledges, {td} releases timed")
    print("  ack phase : " + " ".join(f"{i:>2}:{c:<6}" for i, c in enumerate(phase)))
    print("  ack->rel  : " + " ".join(f"{i}{'+' if i == 7 else ' '}:{c:<6}" for i, c in enumerate(delay)))


def main(paths):
    sp, sd = [0] * 16, [0] * 8
    for p in paths:
        try:
            phase, delay = decode(last_sample(p))
        except (ValueError, StopIteration) as e:
            print(f"skip {p}: {e}")
            continue
        show(p, phase, delay)
        sp = [a + b for a, b in zip(sp, phase)]
        sd = [a + b for a, b in zip(sd, delay)]
    if len(paths) > 1:
        show("SUM", sp, sd)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
