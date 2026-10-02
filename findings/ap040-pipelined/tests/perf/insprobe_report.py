#!/usr/bin/env python3
"""insprobe_report.py -- sum insprobe_ddr3.sv's per-instruction clocks.

  insprobe_report.py <run dir> [<dhry_soc.bin> <dhry_soc.elf>] [--runs N] [--top K]

Groups the clocks charged to each retired instruction by PC and by
instruction (mnemonic + register/memory operand), with the wait buckets of
perf_probe.vh, per Dhrystone run.  Disassembly: capstone, from the program
image linked at $41000000; function names from the ELF's symbols.
"""
import os, subprocess, collections, argparse
import capstone

B = ["FZ", "RET", "ST", "EXB", "XFER", "RD", "EAF", "FE", "Q", "EF", "ED", "EI"]
BASE = 0x41000000

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("bin", nargs="?")
ap.add_argument("elf", nargs="?")
ap.add_argument("--runs", type=int, default=10)
ap.add_argument("--top", type=int, default=40)
a = ap.parse_args()
here = os.path.dirname(os.path.abspath(__file__))
dd = os.path.join(here, "../../../../lib/AP68040-pipelined/tb/perf/dhry")
binf = a.bin or os.path.join(dd, "dhry_soc.bin")
elff = a.elf or os.path.join(dd, "dhry_soc.elf")

img = open(binf, "rb").read()
md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN | capstone.CS_MODE_M68K_040)
dis = {i.address: (i.mnemonic, i.op_str) for i in md.disasm(img, BASE)}
syms = []
for l in subprocess.run(["readelf", "-sW", elff], capture_output=True, text=True).stdout.splitlines():
    f = l.split()
    if len(f) >= 8 and f[3] == "FUNC":
        syms.append((int(f[1], 16), f[7]))
syms.sort()

def func(pc):
    n = "?"
    for s, name in syms:
        if s > pc: break
        n = name
    return n

def cls(pc):
    m, o = dis.get(pc, ("?", ""))
    mem = "(" in o or any(t.strip().startswith("$") for t in o.split(","))
    return f"{m} {'mem' if mem else 'reg'}"

per_pc = {}
tot = [0] * 12; ncyc = 0; nins = 0
for l in open(os.path.join(a.run, "insprobe.txt")):
    f = l.split()
    pc = int(f[1], 16); t = int(f[2]); bs = list(map(int, f[3:15]))
    e = per_pc.setdefault(pc, [0, 0] + [0] * 12)
    e[0] += 1; e[1] += t
    for k in range(12): e[2 + k] += bs[k]; tot[k] += bs[k]
    ncyc += t; nins += 1

R = a.runs
print(f"window: {ncyc} clocks, {nins} instructions; per run ({R} runs): {ncyc/R:.0f} clocks, "
      f"{nins/R:.0f} instructions, CPI {ncyc/max(nins,1):.3f}")
print("buckets per run: " + "  ".join(f"{B[k]} {tot[k]/R:.0f}" for k in range(12) if tot[k]))

def extra(e):
    return "  ".join(f"{B[k]} {e[2+k]/R:.0f}" for k in range(12) if k != 1 and e[2 + k] >= R / 2)

by_cls = collections.defaultdict(lambda: [0, 0] + [0] * 12)
for pc, e in per_pc.items():
    c = by_cls[cls(pc)]
    for k in range(14): c[k] += e[k]
print("\nby instruction (per run): count, clocks, clocks/instr; wait buckets (RET left out)")
for c, e in sorted(by_cls.items(), key=lambda x: -x[1][1])[:a.top]:
    print(f"  {c:20s} {e[0]/R:6.0f} {e[1]/R:7.0f} {e[1]/max(e[0],1):6.2f}   {extra(e)}")

print(f"\ntop {a.top} PCs (per run): pc, function, instruction, count, clocks, clocks/instr; buckets")
for pc, e in sorted(per_pc.items(), key=lambda x: -x[1][1])[:a.top]:
    m, o = dis.get(pc, ("?", ""))
    print(f"  {pc:08x} {func(pc):16s} {m + ' ' + o:34s} {e[0]/R:5.0f} {e[1]/R:6.0f} {e[1]/max(e[0],1):5.2f}  {extra(e)}")
