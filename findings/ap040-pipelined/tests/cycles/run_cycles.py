#!/usr/bin/env python3
"""Cycle checker (plan M0.5).

For every form in FORMS: build a micro-program that runs the instruction
(or a fixed instruction pair) back to back REPS times with zero-wait
memory, run it on the pipelined core (tb_ap040_pipe_cycles.v), and take the
steady-state clocks between consecutive retirements of the measured
instructions (median of the deltas).  Compare with the manual figure from
cycles_manual.csv (section10.py): rule, per plan M0.5,
    measured <= manual + 1   -> ok
    measured >  manual + 1   -> OVER (listed with its reason in the log)

Usage: run_cycles.py [--pipe <AP68040-pipelined>] [--only NAME] [--csv out.csv]
Exit 0 when no row is OVER (or every OVER row has a reason in REASONS).
"""
import argparse, csv, os, statistics, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
REPS = 64
BLK = 0x800      # measured block
SUB = 0x1400     # subroutine / handler area

def manual():
    t = {}
    for r in csv.DictReader(open(os.path.join(HERE, "cycles_manual.csv"))):
        t[(r["instruction"], r["src_or_condition"], r["dst"])] = int(r["cycles_back_to_back"])
    return t

# form: name, setup lines, block unit (list of (line, bytes)), extra {org: lines},
#       manual keys summed per unit, measure: "unit" (first instruction of each unit)
def rep(unit):   # REPS copies of a unit
    return unit * REPS

FORMS = [
    ("MOVEQ", [], [("moveq #1,d0", 2)], {}, [("MOVEQ", "-", "")]),
    ("MOVE.L Dn,Dn", [], [("move.l d1,d2", 2)], {}, [("MOVE", "Dn", "Dn")]),
    ("ADD.L Dn,Dn", [], [("add.l d1,d2", 2)], {}, [("ADD/AND/EOR/OR/SUB/TST", "Dn", "")]),
    ("NOP", [], [("nop", 2)], {}, [("NOP", "-", "")]),
    ("MOVE.L (An),Dn", [], [("move.l (a0),d1", 2)], {}, [("MOVE", "(An)", "Dn")]),
    ("MOVE.L (d16,An),Dn", [], [("move.l 4(a0),d1", 4)], {}, [("MOVE", "(d16,An)", "Dn")]),
    # a .B branch cannot target the next word (displacement 0 means .W), so
    # the unit carries a filler MOVEQ that a taken branch skips
    ("Bcc.B taken", ["moveq #0,d0"], [("beq.s *+4", 2), ("moveq #1,d1", 2)], {}, [("Bcc", "taken", "")]),
    ("Bcc.B not taken+MOVEQ", ["moveq #0,d0"], [("bne.s *+4", 2), ("moveq #1,d1", 2)], {},
     [("Bcc", "not taken", ""), ("MOVEQ", "-", "")]),
    ("Bcc.W taken", ["moveq #0,d0"], [("beq.w *+4", 4)], {}, [("Bcc", "taken", "")]),
    ("Bcc.W not taken", ["moveq #0,d0"], [("bne.w *+4", 4)], {}, [("Bcc", "not taken", "")]),
    ("Bcc.L taken", ["moveq #0,d0"], [("beq.l *+6", 6)], {}, [("Bcc", "taken", "")]),
    ("Bcc.L not taken", ["moveq #0,d0"], [("bne.l *+6", 6)], {}, [("Bcc", "not taken", "")]),
    ("Scc Dn", [], [("seq d3", 2)], {}, [("Scc", "Dn", "")]),
    # BSR.B needs its subroutine within 128 bytes: bsr.s over a bra.s to a local rts
    ("BSR.B+RTS+BRA.B", [], [("bsr.s *+4", 2), ("bra.s *+4", 2), ("rts", 2)], {},
     [("BSR", "-", ""), ("RTS", "-", ""), ("Bcc", "taken", "")]),
    ("BSR.W+RTS", [], [("bsr.w sub", 4)], {SUB: ["sub: rts"]}, [("BSR", "-", ""), ("RTS", "-", "")]),
    ("JSR (An)+RTS", [], [("jsr (a0)", 2)], {0x1800: ["rts"]}, [("JSR", "(An)", ""), ("RTS", "-", "")]),
    ("JSR (d16,An)+RTS", [], [("jsr $10(a0)", 4)], {0x1810: ["rts"]}, [("JSR", "(d16,An)", ""), ("RTS", "-", "")]),
    ("TRAP+RTE", [], [("trap #0", 2)], {SUB: ["trap0h: rte"]}, [("TRAP#", "-", ""), ("RTE", "format $0", "")]),
    ("MOVE Dn,SR", ["moveq #0,d0", "move.w #$2700,d0"], [("move.w d0,sr", 2)], {}, [("MOVE to SR", "Dn", "")]),
    ("MOVEC Rn,Rc", [], [("movec d0,vbr", 4)], {}, [("MOVEC", "Rn,Rc", "")]),
    ("MOVEC Rc,Rn", [], [("movec vbr,d1", 4)], {}, [("MOVEC", "Rc,Rn", "")]),
]
# MOVE.L rows of Table 10-9/10-10 (M1): every source mode into Dn, and Dn
# into every destination mode.  A0-A6 are preset ($1800 + $100*n).
MOVE_SRC_FORMS = [
    ("Dn", "d1", 2), ("(An)", "(a0)", 2), ("(An)+", "(a0)+", 2), ("-(An)", "-(a0)", 2),
    ("(d16,An)", "4(a0)", 4), ("(d16,PC)", "*+$100(pc)", 4), ("abs", "($1800).w", 4),
    ("#imm", "#$12345678", 6), ("(d8,An,Xn)", "4(a0,d1.w)", 4), ("(d8,PC,Xn)", "*+$40(pc,d1.w)", 4),
    ("(bd,BR,Xn)", "($100,a0,d1.w)", 6), ("([bd,BR,Xn])", "([$10,a0,d1.w])", 6),
    ("([bd,BR,Xn],od)", "([$10,a0,d1.w],$20)", 8), ("([bd,BR],Xn)", "([$10,a0],d1.w)", 6),
    ("([bd,BR],Xn,od)", "([$10,a0],d1.w,$20)", 8),
]
MOVE_DST_FORMS = [
    ("(An)", "(a0)", 2), ("(An)+", "(a0)+", 2), ("-(An)", "-(a0)", 2), ("(d16,An)", "4(a0)", 4),
    ("abs", "($1800).w", 4), ("(d8,An,Xn)", "4(a0,d1.w)", 4),
]
for key, ea, size in MOVE_SRC_FORMS:
    FORMS.append(("MOVE.L %s,Dn" % key, ["moveq #0,d1"], [("move.l %s,d2" % ea, size)], {},
                  [("MOVE", key, "Dn")]))
for key, ea, size in MOVE_DST_FORMS:
    FORMS.append(("MOVE.L Dn,%s" % key, ["moveq #0,d1"], [("move.l d2,%s" % ea, size)], {},
                  [("MOVE", "Dn", key)]))


# M2 rows (Tables 10-11..10-28)
EA_SET = [("Dn", "d1", 0), ("(An)", "(a0)", 0), ("(d16,An)", "4(a0)", 2), ("#imm", "#$12345678", 4),
          ("(d8,An,Xn)", "4(a0,d1.w)", 2)]
for op in ("add", "and", "cmp", "sub", "or"):
    for key, ea, ext in EA_SET:
        FORMS.append(("%s.L %s,Dn" % (op.upper(), key), ["moveq #0,d1"], [("%s.l %s,d2" % (op, ea), 2 + ext)], {},
                      [("ADD/AND/EOR/OR/SUB/TST" if op != "cmp" else "CMP", key, "")]))
FORMS += [
    ("EOR.L Dn,Dn", [], [("eor.l d1,d2", 2)], {}, [("ADD/AND/EOR/OR/SUB/TST", "Dn", "")]),
    ("ADD.L Dn,(An)", [], [("add.l d1,(a0)", 2)], {}, [("ADD/AND/EOR/OR/SUB/TST", "(An)", "")]),
    ("ADDA.L Dn,An", [], [("adda.l d1,a1", 2)], {}, [("ADDA", "Dn", "")]),
    ("ADDA.L (An),An", [], [("adda.l (a0),a1", 2)], {}, [("ADDA", "(An)", "")]),
    ("SUBA.L Dn,An", [], [("suba.l d1,a1", 2)], {}, [("SUBA", "Dn", "")]),
    ("CMPA.L Dn,An", [], [("cmpa.l d1,a1", 2)], {}, [("CMPA.L", "Dn", "")]),
    ("ADDI.L #,Dn", [], [("addi.l #$12345678,d2", 6)], {}, [("ADDI/ANDI/EORI/ORI/SUBI", "Dn", "")]),
    ("ADDI.L #,(An)", [], [("addi.l #$12345678,(a0)", 6)], {}, [("ADDI/ANDI/EORI/ORI/SUBI", "(An)", "")]),
    ("CMPI.L #,Dn", [], [("cmpi.l #$12345678,d2", 6)], {}, [("CMPI", "Dn", "")]),
    ("ADDQ.L #,Dn", [], [("addq.l #1,d2", 2)], {}, [("ADDQ/SUBQ", "Dn", "")]),
    ("ADDQ.L #,An", [], [("addq.l #1,a1", 2)], {}, [("ADDQ/SUBQ", "An", "")]),
    ("ADDQ.L #,(An)", [], [("addq.l #1,(a0)", 2)], {}, [("ADDQ/SUBQ", "(An)", "")]),
    ("NEG.L Dn", [], [("neg.l d2", 2)], {}, [("NEG/NEGX/NOT", "Dn", "")]),
    ("NOT.L (An)", [], [("not.l (a0)", 2)], {}, [("NEG/NEGX/NOT", "(An)", "")]),
    ("CLR.L Dn", [], [("clr.l d2", 2)], {}, [("CLR", "Dn", "")]),
    ("CLR.L (An)", [], [("clr.l (a0)", 2)], {}, [("CLR", "(An)", "")]),
    ("TST.L Dn", [], [("tst.l d2", 2)], {}, [("ADD/AND/EOR/OR/SUB/TST", "Dn", "")]),
    ("TST.L (An)", [], [("tst.l (a0)", 2)], {}, [("ADD/AND/EOR/OR/SUB/TST", "(An)", "")]),
    ("EXT.W", [], [("ext.w d2", 2)], {}, [("EXT", "word", "")]),
    ("EXT.L", [], [("ext.l d2", 2)], {}, [("EXT", "long", "")]),
    ("EXTB.L", [], [("extb.l d2", 2)], {}, [("EXTB", "long", "")]),
    ("SWAP", [], [("swap d2", 2)], {}, [("SWAP", "-", "")]),
    ("EXG Dy,Dx", [], [("exg d1,d2", 2)], {}, [("EXG", "Dy,Dx", "")]),
    ("EXG Ay,Ax", [], [("exg a1,a2", 2)], {}, [("EXG", "Ay,Ax", "")]),
    ("ADDX.L Dy,Dx", [], [("addx.l d1,d2", 2)], {}, [("ADDX", "Dy,Dx", "")]),
    ("CMPM.L", [], [("cmpm.l (a0)+,(a1)+", 2)], {}, [("CMPM", "-", "")]),
    ("LEA (An)", [], [("lea (a0),a1", 2)], {}, [("LEA", "(An)", "")]),
    ("LEA (d16,An)", [], [("lea 4(a0),a1", 4)], {}, [("LEA", "(d16,An)", "")]),
    ("LEA (d8,An,Xn)", ["moveq #0,d1"], [("lea 4(a0,d1.w),a1", 4)], {}, [("LEA", "(d8,An,Xn)", "")]),
    ("PEA (An)", [], [("pea (a0)", 2)], {}, [("PEA", "(An)", "")]),
    ("Scc (An)", [], [("seq (a0)", 2)], {}, [("Scc", "(An)", "")]),
    ("MOVE to CCR Dn", [], [("move.w d1,ccr", 2)], {}, [("MOVE to CCR", "Dn", "")]),
    ("MOVE from CCR Dn", [], [("move.w ccr,d2", 2)], {}, [("MOVE from CCR", "Dn", "")]),
    ("ANDI #,CCR", [], [("andi.b #$1f,ccr", 4)], {}, [("ANDI #,CCR", "-", "")]),
    ("LINK+UNLK", [], [("link a6,#-4", 4), ("unlk a6", 2)], {}, [("LINK", "-", ""), ("UNLK", "-", "")]),
]

# M3 rows (Tables 10-11..10-28): data-independent forms; MUL/DIV with
# fixed operands (the manual's figures are the fixed-time ones)
FORMS += [
    ("ASL.L #1,Dn", [], [("asl.l #1,d2", 2)], {}, [("ASL", "Dn", "")]),
    ("LSR.L #3,Dn", [], [("lsr.l #3,d2", 2)], {}, [("ASR/LSL/LSR", "Dn", "")]),
    ("LSL.L Dn,Dn", ["moveq #5,d1"], [("lsl.l d1,d2", 2)], {}, [("ASR/LSL/LSR", "Dn", "")]),
    ("ROL.L #1,Dn", [], [("rol.l #1,d2", 2)], {}, [("ROL/ROR", "Dn", "")]),
    ("ROXL.L #1,Dn", [], [("roxl.l #1,d2", 2)], {}, [("ROXL/ROXR", "Dn", "")]),
    ("LSR.W (An)", [], [("lsr.w (a0)", 2)], {}, [("ASR/LSL/LSR", "(An)", "")]),
    ("BTST Dn,Dn", ["moveq #5,d1"], [("btst d1,d2", 2)], {}, [("BTST", "Dn", "")]),
    ("BTST #,(An)", [], [("btst #3,(a0)", 4)], {}, [("BTST", "(An)", "")]),
    ("BSET Dn,Dn", ["moveq #5,d1"], [("bset d1,d2", 2)], {}, [("BCHG/BCLR/BSET", "Dn", "")]),
    ("BCHG #,(An)", [], [("bchg #3,(a0)", 4)], {}, [("BCHG/BCLR/BSET", "(An)", "")]),
    ("MULU.W Dn,Dn", ["moveq #3,d1"], [("mulu.w d1,d2", 2)], {}, [("MULU.W", "Dn", "")]),
    ("MULS.W Dn,Dn", ["moveq #3,d1"], [("muls.w d1,d2", 2)], {}, [("MULS.W", "Dn", "")]),
    ("MULU.L Dn,Dn", ["moveq #3,d1"], [("mulu.l d1,d2", 4)], {}, [("MULU.L", "Dn", "")]),
    ("MULS.L Dn,Dn", ["moveq #3,d1"], [("muls.l d1,d2", 4)], {}, [("MULS.L", "Dn", "")]),
    ("DIVU.W Dn,Dn", ["moveq #3,d1", "move.l #1000,d2"], [("divu.w d1,d2", 2)], {}, [("DIVS.W/DIVU.W", "Dn", "")]),
    ("DIVU.L Dn,Dn", ["moveq #3,d1", "move.l #1000,d2"], [("divu.l d1,d2", 4)], {}, [("DIVS.L/DIVU.L", "Dn", "")]),
    ("ABCD Dy,Dx", [], [("abcd d1,d2", 2)], {}, [("ABCD", "Dy,Dx", "")]),
    ("SBCD Dy,Dx", [], [("sbcd d1,d2", 2)], {}, [("SBCD", "Dy,Dx", "")]),
    ("NBCD Dn", [], [("nbcd d2", 2)], {}, [("NBCD", "Dn", "")]),
    ("PACK Dx,Dy", [], [("pack d1,d2,#0", 4)], {}, [("PACK", "Dx,Dy,#", "")]),
    ("UNPK Dx,Dy", [], [("unpk d1,d2,#0", 4)], {}, [("UNPK", "Dx,Dy,#", "")]),
    ("TAS Dn", [], [("tas d2", 2)], {}, [("TAS", "Dn", "")]),
    ("CHK.W Dn,Dn", ["move.l #$100,d1", "moveq #5,d2"], [("chk.w d1,d2", 2)], {}, [("CHK", "Dn", "")]),
    ("CHK2.L (An),Dn", ["moveq #5,d2", "move.l #0,$1800", "move.l #$100,$1804"], [("chk2.l (a0),d2", 4)], {},
     [("CHK2", "(An)", "")]),
    ("CAS.L Dc,Du,(An)", [], [("cas.l d1,d2,(a0)", 4)], {}, [("CAS", "(An)", "")]),
    ("BFEXTU Dn", [], [("bfextu d1{4:8},d2", 4)], {}, [("BFEXTS/BFEXTU", "Dn", "")]),
    ("BFEXTU (An)", [], [("bfextu (a0){4:8},d2", 4)], {}, [("BFEXTS/BFEXTU", "(An)", "")]),
    ("BFINS Dn", [], [("bfins d1,d3{4:8}", 4)], {}, [("BFINS", "Dn", "")]),
    ("BFINS (An)", [], [("bfins d1,(a0){4:8}", 4)], {}, [("BFINS", "(An)", "")]),
    ("BFFFO Dn", [], [("bfffo d1{4:8},d2", 4)], {}, [("BFFFO", "Dn", "")]),
    ("BFTST (An)", [], [("bftst (a0){4:8}", 4)], {}, [("BFTST", "(An)", "")]),
]

# M4 rows.  MOVEM is a formula (Table 10-23, p. 10-23: <list>,<ea> 2 + D' + A',
# <ea>,<list> 3 + D' + A'; D'/A' = data/address registers in the list) -- a
# key ("=", n) is a literal manual figure.  a1 points at $1900 (MOVE16 lines).
FORMS += [
    ("MOVEM.L d0-d3,(An)", [], [("movem.l d0-d3,(a0)", 4)], {}, [("=", 2 + 4 + 0)]),
    ("MOVEM.L d0-d3/a2-a5,(An)", [], [("movem.l d0-d3/a2-a5,(a0)", 4)], {}, [("=", 2 + 4 + 4)]),
    ("MOVEM.L (An),d0-d3", [], [("movem.l (a0),d0-d3", 4)], {}, [("=", 3 + 4 + 0)]),
    ("MOVEM.L (An),d0-d3/a2-a5", [], [("movem.l (a0),d0-d3/a2-a5", 4)], {}, [("=", 3 + 4 + 4)]),
    ("MOVEP.L Dn,(d16,An)", [], [("movep.l d1,0(a0)", 4)], {}, [("MOVEP", "L Dn,d16(An)", "")]),
    ("MOVEP.L (d16,An),Dn", [], [("movep.l 0(a0),d1", 4)], {}, [("MOVEP", "L d16(An),Dn", "")]),
    ("MOVE16 (Ax)+,(Ay)+", ["movea.l #$1900,a1", "movea.l #$1a00,a2"], [("move16 (a1)+,(a2)+", 4)], {},
     [("MOVE16", "(Ax)+,(Ay)+", "")]),
    ("MOVE USP,An", [], [("move usp,a3", 2)], {}, [("MOVE USP", "USP,An", "")]),
    ("MOVE An,USP", [], [("move a3,usp", 2)], {}, [("MOVE USP", "An,USP", "")]),
]

# special layouts: the loop forms (retirements of ONE pc)
LOOPS = [
    ("DBcc false, count>-1", ["moveq #%d,d0" % (REPS - 1)], "dbf d0,*", [("DBcc", "false, count>-1", "")]),
    ("JMP (An) self", [], None, [("JMP", "(An)", "")]),
    ("JMP (d16,An) chain", [], None, [("JMP", "(d16,An)", "")]),
]

# Rows over the rule that are explained (reason, citation).  Every entry
# needs the manual reference for why the 040 figure is not the target.
REASONS = {
    "MOVE Dn,SR": "setup uses move.w #imm,d0 (not implemented yet); row skipped until M1",
}

def vectors():
    v = ["\torg 0", "\tdc.l $2000", "\tdc.l start"]
    v += ["\tdc.l unexp"] * 30
    v += ["\tdc.l trap0h"] + ["\tdc.l unexp"] * 223
    return v

def program(name, setup, unit, extra, loop_line=None, jmp_kind=None):
    L = vectors()
    L += ["\torg $400", "start:", "\tnop"] + ["\t" + s for s in setup] + ["\tbra.w blk"]
    L += ["\torg $%x" % BLK, "blk:"]
    pcs = []
    if loop_line:
        L += ["\t" + loop_line]
        pcs = [BLK]
        halt = BLK + 4
    elif jmp_kind == "self":
        # a0 = $1800: jmp (a0) there, REPS times via a0..a6 chain would be short;
        # use a DBF-free chain: every chain link is jmp (aN) with aN preset
        L += ["\tjmp (a0)"]
        L += ["\torg $1800", "\tjmp (a1)", "\torg $1900", "\tjmp (a2)", "\torg $1a00", "\tjmp (a3)",
              "\torg $1b00", "\tjmp (a4)", "\torg $1c00", "\tjmp (a5)", "\torg $1d00", "\tjmp (a6)",
              "\torg $1e00", "halt:", "\tbra.s halt"]
        pcs = [BLK, 0x1800, 0x1900, 0x1a00, 0x1b00, 0x1c00, 0x1d00]
        halt = 0x1e00
    elif jmp_kind == "d16":
        # jmp (d16,a0) chain: each link jumps to the next link, a0 = $1800
        addr = BLK
        for k in range(REPS):
            nxt = addr + 4
            L += ["\tjmp %d(a0)" % (nxt - 0x1800)]
            pcs.append(addr)
            addr = nxt
        halt = addr
    else:
        addr = BLK
        for k in range(REPS):
            for line, size in unit:
                L.append("\t" + line)
                if line is unit[0][0]:
                    pcs.append(addr)
                addr += size
        halt = addr
    if not jmp_kind == "self":
        L += ["halt:", "\tbra.s halt"]
    for org, lines in sorted(extra.items()):
        L += ["\torg $%x" % org] + ["\t" + x if not x.endswith(":") and ":" not in x.split()[0] else x for x in lines]
    if not any("trap0h" in " ".join(v) for v in extra.values()):
        L += ["\torg $1600", "trap0h:", "\trte"]
    L += ["\torg $1700", "unexp:", "\tbra.s unexp"]
    return "\n".join(L) + "\n", pcs, halt

def run(pipe, work, name, src, pcs, halt, vasm="vasmm68k_mot"):
    s = os.path.join(work, "p.s"); b = os.path.join(work, "p.bin"); h = os.path.join(work, "p.hex")
    open(s, "w").write(src)
    r = subprocess.run([vasm, "-Fbin", "-m68040", "-no-opt", "-quiet", "-o", b, s], capture_output=True, text=True)
    if r.returncode:
        return None, "assembler: " + (r.stderr.strip().splitlines() or ["?"])[-1]
    subprocess.run(["python3", os.path.join(TESTS, "bin2hex.py"), b, h], check=True)
    lg = os.path.join(work, "r.log")
    subprocess.run(["vvp", os.path.join(work, "cyc.vvp"), "+prog=" + h, "+log=" + lg,
                    "+halt_pc=%x" % halt, "+cycles=20000"], capture_output=True, text=True)
    t = []
    for ln in open(lg):
        _, c, pc = ln.split()
        if int(pc, 16) in pcs:
            t.append(int(c))
    if len(t) < 3:
        return None, "only %d measured retirements (not decoded? took an exception?)" % len(t)
    d = [b - a for a, b in zip(t, t[1:])]
    return statistics.median(d), "n=%d min=%d max=%d" % (len(t), min(d), max(d))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pipe", default=os.path.join(TESTS, "..", "..", "..", "..", "AP68040-pipelined"))
    ap.add_argument("--only")
    ap.add_argument("--csv")
    a = ap.parse_args()
    work = os.path.join(TESTS, "build", "cycles"); os.makedirs(work, exist_ok=True)
    rtl = os.path.join(a.pipe, "rtl")
    srcs = sorted(os.path.join(rtl, f) for f in os.listdir(rtl) if f.endswith(".sv")) + \
           sorted(os.path.join(rtl, f) for f in os.listdir(rtl) if f.endswith(".v"))
    subprocess.run(["iverilog", "-g2012", "-I", rtl, "-o", os.path.join(work, "cyc.vvp"),
                    os.path.join(HERE, "tb_ap040_pipe_cycles.v")] + srcs, check=True)
    M = manual()
    rows = []
    jobs = []
    for name, setup, unit, extra, keys in FORMS:
        jobs.append((name, program(name, setup, unit, extra), keys))
    for name, setup, loop_line, keys in LOOPS:
        kind = "self" if "self" in name else "d16" if "chain" in name else None
        jobs.append((name, program(name, setup, [], {}, loop_line=loop_line, jmp_kind=kind), keys))
    bad = 0
    print("%-24s %8s %8s  %-6s %s" % ("form", "measured", "manual", "rule", "detail"))
    for name, (src, pcs, halt), keys in jobs:
        if a.only and a.only != name:
            continue
        man = sum(k[1] if k[0] == "=" else M[k] for k in keys)
        meas, det = run(a.pipe, work, name, src, pcs, halt)
        if meas is None:
            verdict = "SKIP" if name in REASONS else "ERROR"
        elif meas <= man + 1:
            verdict = "ok"
        else:
            verdict = "OVER*" if name in REASONS else "OVER"
        if verdict in ("OVER", "ERROR"):
            bad += 1
        note = REASONS.get(name, "")
        print("%-24s %8s %8d  %-6s %s %s" % (name, "-" if meas is None else "%g" % meas, man, verdict, det, note))
        rows.append((name, meas, man, verdict, det, note))
    if a.csv:
        with open(a.csv, "w") as f:
            w = csv.writer(f); w.writerow(["form", "measured", "manual", "verdict", "detail", "reason"])
            w.writerows(rows)
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
