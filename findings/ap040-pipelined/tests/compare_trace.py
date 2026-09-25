#!/usr/bin/env python3
"""Compare a pipelined retire trace against a reference decode trace.

Both files: one line per instruction, columns
  pc sr d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7   (hex, 'xxxxxxxx' = not observable)
Pipelined lines are sampled AFTER the instruction commits; reference lines
are sampled AT DECODE of the instruction, so by default pipelined record k
is compared with reference record k+1 (--lag 1).

Reports: the first PC-sequence divergence (control-flow parity) and the
first register/SR divergence at a matched position (dataflow parity).
Exit status 0 = parity over the compared window, 1 = divergence, 2 = usage.

usage: compare_trace.py pipe_trace.txt ref_trace.txt [--lag N] [--ignore-sr-bits MASK]
"""
import sys, argparse

COLS = "pc sr d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7".split()


n_locked_wb = 0


def load(path, writes=None, excs=None):
    """State rows; W lines are appended to `writes` as (addr, size, data),
    X lines to `excs` as tuples of their hex fields."""
    rows = []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        f = ln.split()
        if f[0] == "W":
            if writes is not None:
                writes.append((int(f[1], 16), int(f[2]), int(f[3], 16)))
            continue
        if f[0] == "L":           # locked write-back (CAS/CAS2 mismatch, PLAN D6): counted, not compared
            global n_locked_wb
            n_locked_wb += 1
            continue
        if f[0] == "X":
            if excs is not None:
                excs.append(tuple(x.lower() for x in f[1:]))
            continue
        if len(f) != len(COLS):
            sys.exit(f"{path}: bad line: {ln}")
        rows.append(dict(zip(COLS, f)))
    return rows


def byte_writes(writes):
    """Expand (addr, size, data) big-endian writes into per-byte-address value
    sequences.  Timing and bus width independent: a long written as one 32-bit
    beat, two 16-bit bus cycles or three misaligned pieces gives the same
    per-address sequence."""
    seq = {}
    for addr, size, data in writes:
        for i in range(size):
            b = (data >> (8 * (size - 1 - i))) & 0xFF
            seq.setdefault((addr + i) & 0xFFFFFFFF, []).append(b)
    return seq


def compare_mem(wp, wr, ignore_below=None):
    """0 = identical per-address write sequences, else number of addresses that differ."""
    sp, sr = byte_writes(wp), byte_writes(wr)
    bad = 0
    for a in sorted(set(sp) | set(sr)):
        if ignore_below is not None and a < ignore_below:
            continue
        vp, vr = sp.get(a, []), sr.get(a, [])
        if vp != vr:
            if bad < 8:
                print(f"MEMORY-WRITE DIVERGENCE at {a:08x}: pipelined wrote "
                      f"[{' '.join('%02x' % v for v in vp) or 'nothing'}] reference wrote "
                      f"[{' '.join('%02x' % v for v in vr) or 'nothing'}]")
            bad += 1
    if bad > 8:
        print(f"   ... {bad} addresses differ in total")
    return bad


def compare_exc(xp, xr, ignore=()):
    """Exception frames, in order, field for field."""
    for i in range(min(len(xp), len(xr))):
        if i in ignore:
            continue
        if xp[i] != xr[i]:
            print(f"EXCEPTION-FRAME DIVERGENCE at exception #{i}:")
            print(f"   pipelined X {' '.join(xp[i])}")
            print(f"   reference X {' '.join(xr[i])}")
            return 1
    if len(xp) != len(xr):
        print(f"EXCEPTION COUNT differs: pipelined {len(xp)} reference {len(xr)}")
        k = min(len(xp), len(xr))
        extra = xp[k:k + 1] or xr[k:k + 1]
        print(f"   first unmatched: {' '.join(extra[0])} ({'pipelined' if len(xp) > len(xr) else 'reference'})")
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pipe")
    ap.add_argument("ref")
    ap.add_argument("--lag", type=int, default=1, help="reference index = pipelined index + lag")
    ap.add_argument("--mode", choices=["events", "lagged"], default="events",
                    help="events: per-register value-order + final state (timing independent); lagged: per-instruction snapshot with --lag")
    ap.add_argument("--ignore-sr-bits", type=lambda s: int(s, 16), default=0x0000,
                    help="hex mask of SR bits to ignore (e.g. 8000 for T1 while trace is unimplemented)")
    ap.add_argument("--from-pc", type=lambda s: s.lower().zfill(8), default=None,
                    help="compare state only from after the instruction at this PC (both sides); "
                         "use it to start past a known reset-state difference")
    ap.add_argument("--no-mem", action="store_true", help="skip the W (memory write) comparison")
    ap.add_argument("--no-exc", action="store_true", help="skip the X (exception frame) comparison")
    ap.add_argument("--ignore-exc", default="",
                    help="comma list of exception indices to skip (expected divergences; cite the PLAN 7.1 row)")
    a = ap.parse_args()
    wp, wr, xp, xr = [], [], [], []
    p, r = load(a.pipe, wp, xp), load(a.ref, wr, xr)
    streams_bad = 0
    if not a.no_mem:
        if compare_mem(wp, wr):
            streams_bad += 1
        else:
            print(f"W stream: per-address write sequences identical "
                  f"({len(byte_writes(wp))} byte addresses, {len(wp)} pipelined / {len(wr)} reference writes)")
        if n_locked_wb:
            print(f"W stream: {n_locked_wb} CAS/CAS2 locked write-backs on the pipelined side not compared (PLAN D6)")
    if not a.no_exc:
        ign = {int(x) for x in a.ignore_exc.split(",") if x}
        if compare_exc(xp, xr, ign):
            streams_bad += 1
        else:
            print(f"X stream: {len(xp)} exception frames identical")
    if a.from_pc:
        ip = next((i for i, x in enumerate(p) if x["pc"] == a.from_pc), None)
        ir = next((i for i, x in enumerate(r) if x["pc"] == a.from_pc), None)
        if ip is None or ir is None:
            print(f"--from-pc {a.from_pc}: not retired on {'pipelined' if ip is None else 'reference'} side")
            return 2
        p = p[ip:]          # state AFTER the instruction at from_pc
        r = r[ir + 1:]      # decode of the following instruction = state after from_pc
        pc_rows_p = p[1:]   # the from_pc record itself is state only; its PC precedes r's first decode
    else:
        pc_rows_p = [x for x in p if x["pc"] != "ffffffff"]   # the reset-state record carries no PC
    n = min(len(p), len(r) - a.lag)
    if n <= 0:
        print(f"nothing to compare: pipelined {len(p)} records, reference {len(r)} records, lag {a.lag}")
        return 2

    # 1. control flow: the sequence of retired PCs must match exactly
    def dedup(seq):   # a self-loop (BRA *) shows once on the pipelined side, many times on the reference
        out = []
        for v in seq:
            if not out or out[-1] != v:
                out.append(v)
        return out
    pcs_p = dedup([x["pc"] for x in pc_rows_p])
    pcs_r = dedup([x["pc"] for x in r])
    for i in range(min(len(pcs_p), len(pcs_r))):
        if pcs_p[i] != pcs_r[i]:
            print(f"CONTROL-FLOW DIVERGENCE at instruction #{i}: pipelined retired pc={pcs_p[i]}, reference decoded pc={pcs_r[i]}")
            print("  pipelined context:", " ".join(pcs_p[max(0, i - 3):i + 3]))
            print("  reference context:", " ".join(pcs_r[max(0, i - 3):i + 3]))
            return 1
    if len(pcs_p) != len(pcs_r):
        print(f"note: PC sequences agree over {min(len(pcs_p), len(pcs_r))} instructions; "
              f"lengths differ ({len(pcs_p)} pipelined vs {len(pcs_r)} reference) -- cycle budget or halt, not a fault")

    # 2. data flow, event-order mode (default): for every register and the SR, the
    #    ordered sequence of DISTINCT values it takes must be identical in both
    #    traces. This is timing-independent -- the reference samples at decode
    #    and can lag a writeback by one instruction depending on fetch timing,
    #    which a fixed lag cannot absorb -- yet any wrong value, wrong order,
    #    missing or extra write still shows up. Final state is compared too.
    if a.mode == "events":
        bad = 0
        for c in COLS[1:]:
            def seq(rows):
                out = []
                for x in rows:
                    v = x[c]
                    if "x" in v:
                        return None
                    if c == "sr":
                        v = "%04x" % (int(v, 16) & ~a.ignore_sr_bits & 0xFFFF)
                    if not out or out[-1] != v:
                        out.append(v)
                return out
            sp, sr_ = seq(p), seq(r)
            if sp is None or sr_ is None:
                continue
            if sp != sr_:
                k = next((j for j in range(min(len(sp), len(sr_))) if sp[j] != sr_[j]), min(len(sp), len(sr_)))
                print(f"EVENT DIVERGENCE in {c}: value #{k} differs -- pipelined {sp[k] if k < len(sp) else '(none)'} "
                      f"reference {sr_[k] if k < len(sr_) else '(none)'}")
                print(f"   pipelined {c} sequence: {' '.join(sp[:k + 3])}")
                print(f"   reference {c} sequence: {' '.join(sr_[:k + 3])}")
                bad += 1
        # final state at the last common PC
        fp, fr = p[-1], r[-1]
        if fp["pc"] != fr["pc"]:
            print(f"FINAL PC differs: pipelined {fp['pc']} reference {fr['pc']}")
            bad += 1
        for c in COLS[1:]:
            if "x" in fp[c] or "x" in fr[c]:
                continue
            vp, vr = int(fp[c], 16), int(fr[c], 16)
            if c == "sr":
                vp &= ~a.ignore_sr_bits & 0xFFFF; vr &= ~a.ignore_sr_bits & 0xFFFF
            if vp != vr:
                print(f"FINAL STATE differs in {c}: pipelined {fp[c]} reference {fr[c]}")
                bad += 1
        if bad or streams_bad:
            return 1
        observed = [c for c in COLS[1:] if all("x" not in x[c] for x in r)]
        print(f"PARITY over {len(pcs_p)} retired PCs; register event order and final state identical "
              f"for {', '.join(observed)} (columns not observable on the reference were skipped)")
        return 0

    # 2b. data flow, lagged mode: state after pipelined instruction k == state at reference decode of k+lag
    bad = 0
    for i in range(n):
        pp, rr = p[i], r[i + a.lag]
        diffs = []
        for c in COLS[1:]:
            if "x" in pp[c] or "x" in rr[c]:
                continue
            vp, vr = int(pp[c], 16), int(rr[c], 16)
            if c == "sr":
                vp &= ~a.ignore_sr_bits & 0xFFFF
                vr &= ~a.ignore_sr_bits & 0xFFFF
            if vp != vr:
                diffs.append(f"{c}: pipelined {pp[c]} reference {rr[c]}")
        if diffs:
            print(f"STATE DIVERGENCE after instruction #{i} (pc={pp['pc']}):")
            for d in diffs:
                print("   ", d)
            bad += 1
            if bad >= 5:
                print("    ... stopping after 5 divergent instructions")
                break
    if bad or streams_bad:
        return 1
    print(f"PARITY over {n} instructions ({len(pcs_p)} retired PCs matched), lag={a.lag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
