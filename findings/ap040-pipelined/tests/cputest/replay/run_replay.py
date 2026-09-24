#!/usr/bin/env python3
"""Replay WinUAE cputest corpus slices on the PIPELINED AP68040 core.

For every selected slice: expand the .daz container, run apolkosnik's
replay_gen.py (imported read-only from the Minimig tree) into an APR2 job in
the work directory, run tb_dat_replay_pipe.v on it, print one line per slice
and a total.

  ./run_replay.py --work /tmp/w --instruction 'MOVE.*' --instruction 'ADD.B'
  ./run_replay.py --work /tmp/w --preset m2          # the M0.4 deliverable list
  ./run_replay.py --work /tmp/w --instruction MOVE.L --slice 0003 --plusarg +dump=10
  ./run_replay.py --work /tmp/w --instruction MOVE.L --slice 0001 --plusarg +mutate_reg=3

The core is built from a snapshot of the committed tree (git archive HEAD rtl
of --pipe-repo) unless --rtl names an already extracted rtl/ directory.  The
repository itself is never modified.
"""

from __future__ import annotations

import argparse
import fnmatch
import gzip
import hashlib
import os
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent / "data040"
REF_DIFF = Path.home() / "work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer/tests/ap040/diff"
PIPE_REPO = Path.home() / "work/fpga/Xilinx/artix7/AP68040-pipelined"
sys.path.insert(0, str(REF_DIFF))
from replay_gen import generate  # noqa: E402

GROUPS = {"Basic": "4_BASIC", "Default": "4_Default", "IRQ": "4_IRQ", "AE": "4_AE",
          "FFEXT_SRC": "4_EXTSRC", "FFEXT_DST": "4_EXTDST", "ODD_STK": "4_ODDSTK",
          "ODD_EXC": "4_ODDEXC", "ODD_IRQ": "4_ODDIRQ"}

# M0.4 deliverable: integer Basic slices of instructions the core implements (M2)
PRESET_M2 = ["MOVE.B", "MOVE.W", "MOVE.L", "MOVEA.W", "MOVEA.L",
             "ADD.B", "ADD.W", "ADD.L", "ADDA.W", "ADDA.L", "ADDX.B", "ADDX.W", "ADDX.L",
             "SUB.B", "SUB.W", "SUB.L", "SUBA.W", "SUBA.L", "SUBX.B", "SUBX.W", "SUBX.L",
             "CMP.B", "CMP.W", "CMP.L", "CMPA.W", "CMPA.L", "CMPM.B", "CMPM.W", "CMPM.L",
             "AND.B", "AND.W", "AND.L", "OR.B", "OR.W", "OR.L", "EOR.B", "EOR.W", "EOR.L",
             "NOT.B", "NOT.W", "NOT.L", "NEG.B", "NEG.W", "NEG.L", "NEGX.B", "NEGX.W", "NEGX.L",
             "CLR.B", "CLR.W", "CLR.L", "TST.B", "TST.W", "TST.L",
             "EXT.B", "EXT.W", "EXT.L", "SWAP.W",
             "Bcc.B", "Bcc.W", "Bcc.L", "Scc.B", "LEA.L", "PEA.L"]
# the rest of what M2 implements (not part of the deliverable bar)
PRESET_M2_EXTRA = ["ANDSR.B", "ANDSR.W", "ORSR.B", "ORSR.W", "EORSR.B", "EORSR.W",
                   "MV2SR.B", "MV2SR.W", "MVSR2.B", "MVSR2.W", "MOVEC2",
                   "DBcc.W", "BSR.B", "BSR.W", "BSR.L", "JMP", "JSR", "RTS", "RTD", "RTR", "RTE",
                   "LINK.W", "LINK.L", "UNLK.L", "EXG.L", "TRAP", "NOP", "ILLEGAL"]


def unpack_daz(daz: Path, cache: Path) -> Path:
    """Split a v24 .daz ("\\xafMRG" + u32 len + gzip member)* into NNNN.dat."""
    key = hashlib.sha256(daz.read_bytes()).hexdigest()[:16]
    target = cache / key
    if (target / ".complete").exists():
        return target
    data = daz.read_bytes()
    target.mkdir(parents=True, exist_ok=True)
    off = index = 0
    while off + 8 <= len(data) and data[off:off + 4] == b"\xafMRG":
        length = struct.unpack(">I", data[off + 4:off + 8])[0]
        if length == 0:
            break
        (target / ("%04d.dat" % index)).write_bytes(gzip.decompress(data[off + 8:off + 8 + length]))
        off += 8 + length
        index += 1
    (target / ".complete").write_text("%d\n" % index)
    return target


def snapshot_rtl(work: Path, repo: Path) -> Path:
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"],
                          check=True, text=True, capture_output=True).stdout.strip()
    snap = work / ("snap-" + head)
    if not (snap / "rtl" / "ap040_pipe_core.v").exists():
        snap.mkdir(parents=True, exist_ok=True)
        arch = subprocess.run(["git", "-C", str(repo), "archive", "HEAD", "rtl"],
                              check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", str(snap)], input=arch, check=True)
    print("core: %s HEAD %s -> %s" % (repo, head, snap / "rtl"))
    return snap / "rtl"


def build(work: Path, rtl: Path, sim: str) -> list[str]:
    """Compile the bench; return the command prefix that runs it."""
    srcs = [rtl / "ap040_pipe_pkg.sv"]
    srcs += sorted(p for p in rtl.glob("ap040_*.v") if p.name != "ap040_pipe_l1.v")
    srcs += [HERE / "ap040_pipe_l1_replay.v", HERE / "tb_dat_replay_pipe.v"]
    tag = hashlib.sha1(str(rtl).encode()).hexdigest()[:8]
    if sim == "iverilog":
        out = work / ("tb_dat_replay_pipe-%s.vvp" % tag)
        cmd = ["iverilog", "-g2012", "-I", str(rtl), "-o", str(out)] + [str(p) for p in srcs]
        run = ["vvp", "-n", str(out)]
    else:
        mdir = work / ("obj-%s" % tag)
        out = mdir / "Vtb_dat_replay_pipe"
        cmd = ["verilator", "--binary", "--timing", "-j", "4", "--top-module", "tb_dat_replay_pipe",
               "--Mdir", str(mdir), "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-TIMESCALEMOD",
               "-I" + str(rtl)] + [str(p) for p in srcs]
        run = [str(out)]
    if out.exists() and out.stat().st_mtime >= max(p.stat().st_mtime for p in srcs):
        return run
    print("compile (%s): %s" % (sim, rtl), flush=True)
    r = subprocess.run(cmd, text=True, capture_output=True)
    if r.returncode != 0 or not out.exists():
        print("\n".join(l for l in (r.stdout + r.stderr).splitlines()
                        if "sorry: constant selects" not in l and "%Warning" not in l)[-4000:])
        raise SystemExit("compile failed")
    return run


SUMMARY = re.compile(r"dat replay: (\d+) rounds run, (\d+) failing rounds, (\d+) mismatches, (\d+) harness errors")
SKIPS = re.compile(r"skipped: (\d+) ignore/maintenance, (\d+) trace, (\d+) interrupt, (\d+) bus error, (\d+) odd-vector")
EXTRA = re.compile(r"extra writes .*?: (\d+) bytes in (\d+) rounds")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--group", default="Basic", choices=sorted(GROUPS))
    ap.add_argument("--instruction", action="append", default=[], help="fnmatch pattern, repeatable")
    ap.add_argument("--preset", choices=["m2", "m2extra", "m2all"])
    ap.add_argument("--slice", action="append", default=[], help="slice number pattern, e.g. 0001")
    ap.add_argument("--limit", type=int, help="APR2 records per slice")
    ap.add_argument("--plusarg", action="append", default=[], help="extra vvp plusarg, e.g. +dump=10")
    ap.add_argument("--rtl", type=Path, help="use this extracted rtl/ instead of a HEAD snapshot")
    ap.add_argument("--pipe-repo", type=Path, default=PIPE_REPO)
    ap.add_argument("--corpus", type=Path, default=CORPUS)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--sim", choices=["verilator", "iverilog"], default="verilator",
                    help="verilator is ~30x faster on this core; iverilog gives identical results")
    ap.add_argument("--quiet", action="store_true", help="no mismatch detail for failing slices")
    args = ap.parse_args()

    pats = list(args.instruction)
    if args.preset in ("m2", "m2all"):
        pats += PRESET_M2
    if args.preset in ("m2extra", "m2all"):
        pats += PRESET_M2_EXTRA
    if not pats:
        raise SystemExit("give --instruction or --preset")
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    rtl = args.rtl.resolve() if args.rtl else snapshot_rtl(work, args.pipe_repo)
    runner = build(work, rtl, args.sim)

    gdir = args.corpus / GROUPS[args.group]
    lmem, tmem = gdir / "lmem.dat", gdir / "tmem.dat"
    insns = sorted(p.name for p in gdir.iterdir()
                   if p.is_dir() and any(fnmatch.fnmatchcase(p.name, x) for x in pats))
    missing = [x for x in pats if not any(fnmatch.fnmatchcase(i, x) for i in insns)]
    if missing:
        print("not in corpus group %s: %s" % (args.group, " ".join(missing)))
    (work / "jobs").mkdir(exist_ok=True)
    (work / "logs").mkdir(exist_ok=True)

    tot = dict(slices=0, passed=0, rounds=0, bad=0, skipped=0, extra=0)
    failed = []
    t0 = time.monotonic()
    for insn in insns:
        exp = unpack_daz(gdir / insn / "0000.daz", work / "unpacked")
        for dat in sorted(exp.glob("[0-9][0-9][0-9][0-9].dat")):
            num = dat.name[:4]
            if num == "0000" or (args.slice and not any(fnmatch.fnmatchcase(num, s) for s in args.slice)):
                continue
            name = re.sub(r"[^A-Za-z0-9_.-]+", "_", "%s--%s--%s" % (args.group, insn, num))
            job = work / "jobs" / (name + ".apr2")
            log = work / "logs" / (name + ".log")
            started = time.monotonic()
            meta = generate(str(exp / "0000.dat"), str(dat), str(job), args.limit)
            cmd = runner + ["+job=" + str(job), "+lmem=" + str(lmem),
                   "+tmem=" + str(tmem)] + args.plusarg
            try:
                out = subprocess.run(cmd, text=True, capture_output=True, timeout=args.timeout).stdout
            except subprocess.TimeoutExpired as e:
                out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
                out += "\nTIMEOUT\n"
            log.write_text(out)
            m, s, x = SUMMARY.search(out), SKIPS.search(out), EXTRA.search(out)
            ok = "ALL TESTS PASSED" in out
            ran, bad = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
            skipped = sum(int(v) for v in s.groups()[1:]) if s else 0
            extra = int(x.group(2)) if x else 0
            tot["slices"] += 1
            tot["passed"] += ok
            tot["rounds"] += ran
            tot["bad"] += max(bad, 0)
            tot["skipped"] += skipped
            tot["extra"] += extra
            status = "pass" if ok else ("NORUN" if "NO ROUNDS RUN" in out else "FAIL")
            print("%-5s %-10s %s  rounds %6d  failing %6s  skipped(unsupported) %6d  extra-write-rounds %d  %.0fs"
                  % (status, insn, num, ran, bad if m else "?", skipped, extra, time.monotonic() - started),
                  flush=True)
            if not ok:
                failed.append((insn, num, log))
                if not args.quiet:
                    detail = [l for l in out.splitlines()
                              if l.startswith(("MISMATCH", "  ROUND", "    ", "HARNESS", "FAIL", "TIMEOUT"))]
                    for l in detail[:40]:
                        print("      " + l)
    print("TOTAL: %d/%d slices pass; %d rounds run, %d failing rounds, %d rounds skipped as unsupported, "
          "%d rounds with extra writes; %.0fs"
          % (tot["passed"], tot["slices"], tot["rounds"], tot["bad"], tot["skipped"], tot["extra"],
             time.monotonic() - t0))
    for insn, num, log in failed:
        print("  failing: %s %s  (%s)" % (insn, num, log))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
