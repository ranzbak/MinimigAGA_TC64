#!/usr/bin/env python3
"""Compare two tb_kick traces (reference vs pipelined), timing-independent.

Streams compared, each in its own order (retirement timing never matters):
  I  retired instructions: pc, then sr and d0-d7/a0-a7 after the instruction
  X  exception frames (vector, format, stacked SR, stacked PC)
  W  bus writes (address, size, data), in order; plus per-byte-address
     write sequences, which stay equal even if two cores order independent
     stores differently
  R  data reads of $A00000-$DFFFFF (value read), in order
  I  interrupts taken out of STOP (instruction count, level), in order
  F  the floppy-register accesses among W and R (CIA-B PRB $BFD100, CIA-A
     PRA $BFE001, DSKPTH/L $DFF020/2, DSKLEN $DFF024, DSKBYTR $DFF01A,
     DSKSYNC $DFF07E, ADKCON/R $DFF09E/$DFF010), in order, each with the
     instruction count at which it happened

usage: compare.py ref_trace pipe_trace [--rom ROM] [--ignore-sr MASK] [--context N]
Exit 0 = identical over the common length, 1 = divergence.
"""
import argparse, sys, collections, itertools
sys.dont_write_bytecode = True
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REGN = "d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7".split()


def streams(path):
    I, X, W, R, Q, F = [], [], [], [], [], []
    with open(path) as f:
        for ln in f:
            if ln[0] == '#':
                continue
            p = ln.split()
            t = p[0]
            if t == 'W':
                W.append((int(p[1]), int(p[2], 16), int(p[3]), int(p[4], 16)))
                if is_floppy(W[-1][1]):
                    F.append((W[-1][0], 'W', W[-1][1], W[-1][3]))
            elif t == 'R':
                R.append((int(p[1]), int(p[2], 16), int(p[3], 16)))
                if is_floppy(R[-1][1]):
                    F.append((R[-1][0], 'R', R[-1][1], R[-1][2]))
            elif t == 'I':
                Q.append((int(p[1]), int(p[2])))
            elif t == 'X':
                X.append((len(I), p[1], p[2], p[3], p[4]))
            else:
                I.append(p[1:])
    return I, X, W, R, Q, F


def is_floppy(a):
    a &= 0xFFFFFF
    if (a & 0xFFF000) == 0xBFD000 and ((a >> 8) & 0xF) == 1 and (a & 1) == 0:
        return True                     # CIA-B PRB (even byte)
    if (a & 0xFFF000) == 0xBFE000 and ((a >> 8) & 0xF) == 0 and (a & 1) == 1:
        return True                     # CIA-A PRA (odd byte)
    if (a & 0xFFF000) == 0xBFE000 and ((a >> 8) & 0xF) == 0 and (a & 1) == 0 and a == 0xBFE000:
        return True                     # a word access covering PRA
    if (a & 0xFF0000) == 0xDF0000 and (a & 0x1FE) in (0x010, 0x01A, 0x020, 0x022, 0x024, 0x07E, 0x09E):
        return True
    return False


def byteseq(W):
    seq = collections.defaultdict(list)
    for n, a, sz, d in W:
        for i in range(sz):
            seq[a + i].append(((d >> (8 * (sz - 1 - i))) & 0xFF, n))
    return seq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref"); ap.add_argument("pipe")
    ap.add_argument("--rom")
    ap.add_argument("--ignore-sr", type=lambda s: int(s, 16), default=0)
    ap.add_argument("--context", type=int, default=6)
    ap.add_argument("--regions", type=int, default=40, help="divergent regions the resync walk reports (0 = off)")
    ap.add_argument("--window", type=int, default=3000)
    ap.add_argument("--match", type=int, default=64)
    ap.add_argument("--floppy-log", help="write the reference's floppy-register accesses here")
    ap.add_argument("--streams-all", action="store_true",
                    help="compare the W/R/I/F streams over the whole trace, not only up to the "
                         "first instruction divergence (use when a known divergence is tolerated)")
    a = ap.parse_args()
    dis = None
    if a.rom:
        import romdis
        rom = romdis.load(a.rom)
        dis = lambda pc: romdis.dis1(rom, pc)[1] if (pc >> 19) == 0x1F else "(not ROM)"
    Ir, Xr, Wr, Rr, Qr, Fr = streams(a.ref)
    Ip, Xp, Wp, Rp, Qp, Fp = streams(a.pipe)
    print(f"reference: {len(Ir)} instructions, {len(Xr)} exceptions, {len(Wr)} writes, {len(Rr)} IO reads")
    print(f"pipelined: {len(Ip)} instructions, {len(Xp)} exceptions, {len(Wp)} writes, {len(Rp)} IO reads")
    bad = 0
    n = min(len(Ir), len(Ip))
    first = None
    for i in range(n):
        r, p = Ir[i], Ip[i]
        if r[0] != p[0]:
            first = (i, "PC sequence", r, p); break
        srr, srp = int(r[1], 16) & ~a.ignore_sr, int(p[1], 16) & ~a.ignore_sr
        diffs = []
        if srr != srp:
            diffs.append(f"sr ref={r[1]} pipe={p[1]}")
        for k in range(min(len(r), len(p)) - 2):
            if r[2 + k] != p[2 + k]:
                diffs.append(f"{REGN[k]} ref={r[2 + k]} pipe={p[2 + k]}")
        if diffs:
            first = (i, "state after instruction: " + ", ".join(diffs), r, p); break
    if first:
        bad += 1
        i, what, r, p = first
        pc = int(r[0], 16)
        print(f"\nFIRST INSTRUCTION DIVERGENCE at instruction #{i}, pc {r[0]}"
              + (f"  [{dis(pc)}]" if dis else "") + f": {what}")
        lo = max(0, i - a.context)
        for j in range(lo, min(i + 3, n)):
            for tag, I in (("ref ", Ir), ("pipe", Ip)):
                q = I[j]
                d = f"  {dis(int(q[0], 16))}" if dis else ""
                print(f"  {tag} #{j:<8} {' '.join(q)}{d}")
    else:
        print(f"\ninstruction streams IDENTICAL (pc, sr, d0-d7, a0-a7) through {n} instructions")
    # ---- resynchronising walk: every divergent region, not only the first
    if first and a.regions:
        print(f"\nRESYNC WALK (window {a.window}, match length {a.match}):")
        i = j = 0
        conv = True
        regions = 0
        pcr = [q[0] for q in Ir]; pcp = [q[0] for q in Ip]
        while i < len(Ir) and j < len(Ip) and regions < a.regions:
            if pcr[i] == pcp[j]:
                same = Ir[i][1:] == Ip[j][1:]
                if not same and conv:
                    regions += 1
                    r, p = Ir[i], Ip[j]
                    d = [f"sr {r[1]}/{p[1]}"] if r[1] != p[1] else []
                    d += [f"{REGN[k]} {r[2 + k]}/{p[2 + k]}" for k in range(16) if r[2 + k] != p[2 + k]]
                    print(f"  state diverges  ref#{i} pipe#{j} pc {r[0]}"
                          + (f" [{dis(int(r[0], 16))}]" if dis else "") + ": " + ", ".join(d) + "  (ref/pipe)")
                    conv = False
                elif same and not conv:
                    print(f"  state reconverges ref#{i} pipe#{j} pc {Ir[i][0]}")
                    conv = True
                i += 1; j += 1
                continue
            regions += 1
            print(f"  PC diverges  ref#{i} {pcr[i]}" + (f" [{dis(int(pcr[i], 16))}]" if dis else "")
                  + f"   pipe#{j} {pcp[j]}" + (f" [{dis(int(pcp[j], 16))}]" if dis else ""))
            found = None
            for tot in range(1, 2 * a.window):
                for dr in range(0, min(tot, a.window) + 1):
                    dp = tot - dr
                    if dp > a.window:
                        continue
                    if pcr[i + dr:i + dr + a.match] == pcp[j + dp:j + dp + a.match] and \
                       len(pcr[i + dr:i + dr + a.match]) == a.match:
                        found = (dr, dp); break
                if found:
                    break
            if not found:
                print(f"    no resync within {a.window} instructions: streams separate for good")
                break
            dr, dp = found
            print(f"    resync after ref +{dr} / pipe +{dp} instructions at ref#{i + dr} pipe#{j + dp} pc {pcr[i + dr]}")
            print(f"      ref only : {' '.join(pcr[i:i + min(dr, 12)])}{' ...' if dr > 12 else ''}")
            print(f"      pipe only: {' '.join(pcp[j:j + min(dp, 12)])}{' ...' if dp > 12 else ''}")
            i += dr; j += dp
        print(f"  walk ended at ref#{i} pipe#{j} ({regions} regions reported)")

    # exceptions
    for k in range(min(len(Xr), len(Xp))):
        if Xr[k][1:] != Xp[k][1:]:
            bad += 1
            print(f"EXCEPTION DIVERGENCE #{k}: ref (at insn {Xr[k][0]}) vec/fmt/sr/pc {' '.join(Xr[k][1:])}"
                  f"  pipe (at insn {Xp[k][0]}) {' '.join(Xp[k][1:])}")
            break
    xs = [x for x in Xr[:20]]
    if xs:
        print("reference exceptions (first 20): " + "; ".join(f"#{x[0]} vec {x[1]} pc {x[4]}" for x in xs))
    xs = [x for x in Xp[:20]]
    if xs:
        print("pipelined exceptions (first 20): " + "; ".join(f"#{x[0]} vec {x[1]} pc {x[4]}" for x in xs))
    # writes in order, limited to the instruction window both reached
    lim = n if (first is None or a.streams_all) else first[0]
    wr = [w for w in Wr if w[0] < lim]
    wp = [w for w in Wp if w[0] < lim]
    wfirst = None
    for k in range(min(len(wr), len(wp))):
        if wr[k][1:] != wp[k][1:]:
            wfirst = k; break
    if wfirst is not None:
        bad += 1
        print(f"WRITE-ORDER DIVERGENCE at write #{wfirst}: ref insn#{wr[wfirst][0]} {wr[wfirst][1]:08x}/{wr[wfirst][2]}={wr[wfirst][3]:x}"
              f"  pipe insn#{wp[wfirst][0]} {wp[wfirst][1]:08x}/{wp[wfirst][2]}={wp[wfirst][3]:x}")
    elif len(wr) != len(wp):
        print(f"write counts before instruction {lim}: ref {len(wr)} pipe {len(wp)}")
    else:
        print(f"bus writes IDENTICAL in order: {len(wr)} writes before instruction #{lim}")
    sr_, sp_ = byteseq(wr), byteseq(wp)
    nb = 0
    for adr in sorted(set(sr_) | set(sp_)):
        vr = [v for v, _ in sr_.get(adr, [])]
        vp = [v for v, _ in sp_.get(adr, [])]
        if vr != vp:
            if nb < 5:
                print(f"  per-address write sequence differs at {adr:08x}: ref {vr[:8]} pipe {vp[:8]}")
            nb += 1
    if nb:
        bad += 1
        print(f"  {nb} byte addresses have different write sequences")
    rr = [x for x in Rr if x[0] < lim]
    rp = [x for x in Rp if x[0] < lim]
    for k in range(min(len(rr), len(rp))):
        if rr[k][1:] != rp[k][1:]:
            bad += 1
            print(f"IO-READ DIVERGENCE at read #{k}: ref insn#{rr[k][0]} {rr[k][1]:08x}={rr[k][2]:04x}"
                  f"  pipe insn#{rp[k][0]} {rp[k][1]:08x}={rp[k][2]:04x}")
            break
    else:
        print(f"IO reads {'IDENTICAL' if len(rr) == len(rp) else 'differ in count'}: ref {len(rr)} pipe {len(rp)} before instruction #{lim}")
    # interrupts out of STOP
    qr = [q for q in Qr if q[0] < lim]
    qp = [q for q in Qp if q[0] < lim]
    for k in range(min(len(qr), len(qp))):
        if qr[k] != qp[k]:
            bad += 1
            print(f"INTERRUPT DIVERGENCE at interrupt #{k}: ref insn#{qr[k][0]} level {qr[k][1]}"
                  f"  pipe insn#{qp[k][0]} level {qp[k][1]}")
            break
    else:
        print(f"interrupts out of STOP {'IDENTICAL' if len(qr) == len(qp) else 'differ in count'}: ref {len(qr)} pipe {len(qp)} before instruction #{lim}")
    # floppy registers, in bus order (the trace file's order); the instruction
    # count is shown, not compared (a read can go out before the older
    # instruction's retirement line)
    fr = [f for f in Fr if f[0] < lim]
    fp = [f for f in Fp if f[0] < lim]
    for k in range(min(len(fr), len(fp))):
        if fr[k][1:] != fp[k][1:]:
            bad += 1
            print(f"FLOPPY-REGISTER DIVERGENCE at access #{k}: ref {fr[k][0]} {fr[k][1]} {fr[k][2]:08x}={fr[k][3]:x}"
                  f"  pipe {fp[k][0]} {fp[k][1]} {fp[k][2]:08x}={fp[k][3]:x}")
            break
    else:
        print(f"floppy-register accesses {'IDENTICAL' if len(fr) == len(fp) else 'differ in count'}: ref {len(fr)} pipe {len(fp)} before instruction #{lim}")
    if a.floppy_log:
        with open(a.floppy_log, "w") as f:
            f.write("# insn R/W address value   (reference trace; the pipelined one is compared above)\n")
            for n_, t_, ad, d in fr:
                f.write(f"{n_} {t_} {ad:08x} {d:04x}\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
