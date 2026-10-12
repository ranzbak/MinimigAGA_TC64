#!/usr/bin/env bash
# Plumbing test for IrqLat, run under vamos (amitools, python3.10 only here).
#
# vamos has no custom chips, no CIA and no ROM: reads of $DFFxxx/$BFxxxx give 0
# and every access is logged.  IrqLat built with -DVAMOS skips the calls that
# need graphics.library / ciab.resource, runs each load loop for one pass, and
# replaces the interrupt samples with a fixed synthetic set.  This checks:
#   * ReadArgs: the options are understood, bad values are refused (rc 10)
#   * the report: the statistics printed for the synthetic samples match an
#     independent Python model of the post-processing (CIA-B timer count
#     reconstruction across a borrow and a reload, beam position to latency
#     across V8 and the frame wrap, histogram, worst samples, missed counts)
#   * register access order: INTENAR/DMACONR saved before anything is written,
#     the takeover and the restore in the right order, CIA-B timer A stopped
#     before its latch is written (low byte, then high, then START|LOAD),
#     the blitter load writes BLTSIZE last
# It does NOT check timing: only the board can (see README.md).
#
#   ./test_irqlat.sh            builds the VAMOS variant itself
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
vasmm68k_mot -quiet -m68040 -Fhunkexe -kick1hunks -nosym -DVAMOS=1 -o "$TMP/IrqLat" IrqLat.asm || { echo "test_irqlat: FAIL (assembly)"; exit 1; }

run() {   # run <name> <args...>: output in $TMP/<name>.out, rc in $TMP/<name>.rc
  local name=$1; shift
  (cd "$TMP" && timeout 120 python3.10 -c "from amitools.tools.vamos import main; import sys; sys.argv=['vamos','--vols-base-dir','vols','-C','68040','IrqLat']+sys.argv[1:]; sys.exit(main())" "$@" >"$name.out" 2>&1; echo $? >"$name.rc")
}
run direct
run os OS
run blit LOAD=BLIT NASTY BPL FMODE=0
run chipwr LOAD=CHIPWR BPL
run badload LOAD=BOGUS
run badrate RATE=5

python3.10 - "$TMP" <<'EOF'
import re, sys
tmp = sys.argv[1]
fail = []
def out(n): return open(f"{tmp}/{n}.out").read()
def rc(n): return int(open(f"{tmp}/{n}.rc").read())

# ---- the reference model (mirrors the synthetic table in IrqLat.asm) ----
E, RATE = 709379, 1000
L = (E + RATE // 2) // RATE - 1
k = (10**9 // E) * 64 + ((10**9 % E) * 64) // E      # ns*64 per E tick
kcc = (k + 2) // 5                                   # ns*64 per colour clock
def ns_t(t): return (t * k) >> 6
def ns_c(c): return (c * kcc) >> 6
def count(hA, lo, hB): return ((hB if (hA != hB and lo >= 0x80) else hA) << 8) | lo
cia_raw = [(2,0xC2,2, 2,0xBF,2), (2,0x00,1, 1,0xFD,1), (2,0xFE,1, 1,0xFB,1),
           (2,0xC4,2, 2,0xC1,2), (0,0x08,0, 0,0x05,0), (0,0x01,0, 2,0xC3,2)]
cia = []
for s in cia_raw:
    c1, c2 = count(*s[:3]), count(*s[3:])
    el = max(0, L - c1); rd = c1 - c2
    if rd < 0: rd += L + 1
    cia.append((ns_t(el), ns_t(rd)))
cop_raw = [(0x3014,0xA300,0x3016), (0x7220,0xA300,0x7222), (0x0530,0xA300,0x0532),
           (0x1002,0xA301,0x1005), (0xB010,0xA300,0xB102),
           (0x7000,0xA300,0x7001), (0x33E1,0xA300,0x3300), (0xFF01,0xA301,0x0005)]
REQ = [0x30, 0x70, 0xB0, 0xF0]; FRAME = 313 * 227
def vline(vh):   # VHPOSR's V, one line on at H 0/1 (Agnus counts V up at H 2)
    return (vh >> 8) + (1 if (vh & 0xFF) <= 1 else 0)
cop = []
for h1, v, h2 in cop_raw:
    line = ((v & 1) << 8) | vline(h1); pos = line * 227 + (h1 & 0xFF)
    rs = [r * 227 + 0x10 for r in REQ if r * 227 + 0x10 <= pos]
    lat = pos - rs[-1] if rs else pos + FRAME - (REQ[-1] * 227 + 0x10)
    dl = (vline(h2) - vline(h1)) & 0xFF
    rd = dl * 227 + (h2 & 0xFF) - (h1 & 0xFF)
    assert 0 <= rd < 256 * 227, rd
    cop.append((ns_c(lat), ns_c(rd)))
def us(n): return f"{n // 1000}.{(n % 1000) // 10:02d}"
def block(title, s, taken, exp, readname):
    lat = [a for a, _ in s]; rdv = [b for _, b in s]
    hist = [0] * 12
    for x in lat:
        b = 0
        while b < 11 and x >= 1000 << b: b += 1
        hist[b] += 1
    worst = sorted(range(len(lat)), key=lambda i: (-lat[i], i))[:5]
    lines = [f"{title}: taken {taken} expected {exp} missed {max(0, exp - taken)} stored {len(s)}",
             f"  latency us: min {us(min(lat))} avg {us(sum(lat) // len(lat))} max {us(max(lat))}",
             f"  read ({readname}) us: avg {us(sum(rdv) // len(rdv))} max {us(max(rdv))}",
             "  hist us: " + " ".join(f"{l} {n}" for l, n in zip(
                 ["<1","<2","<4","<8","<16","<32","<64","<128","<256","<512","<1024",">=1024"], hist)),
             "  worst us: " + " ".join(f"{us(lat[i])}#{i}" for i in worst)]
    return lines
cia_exp = (110 * 227 // 5) // (L + 1)
want = block("CIA-B timer A (level 6)", cia, 6, cia_exp, "3 CIA reads") + \
       block("Copper (level 3)", cop, len(cop), 2 * 4, "2 beam reads")

# ---- the report ----
for name in ("direct", "os", "blit", "chipwr"):
    o = out(name)
    if rc(name) != 0: fail.append(f"{name}: rc {rc(name)}")
    got = [l for l in o.splitlines() if not re.match(r"^\d\d:\d\d:\d\d", l)]
    for w in want:
        if w not in got:
            fail.append(f"{name}: missing line '{w}'")
hdr = [l for l in out("direct").splitlines() if l.startswith("IrqLat:")]
if not hdr or not re.match(r"IrqLat: DIRECT load NONE bpl off rate 1000 Hz latch 708 secs 5 E 709379 Hz PAL VBR [0-9A-Fa-f]{8} CACR [0-9A-Fa-f]{8}$", hdr[0]):
    fail.append(f"direct: header {hdr}")
if not any(l.startswith("IrqLat: OS load NONE") for l in out("os").splitlines()):
    fail.append("os: header")
if not any(l.startswith("IrqLat: DIRECT load BLIT bpl 8 FMODE 0 nasty") for l in out("blit").splitlines()):
    fail.append("blit: header")

# ---- register access order ----
def hw(name):
    ev = []
    for l in out(name).splitlines():
        m = re.search(r"(Custom Chip|CIA) (read|write) (?:byte|word) @([0-9a-f]{6})(?:: ([0-9a-f]+))?", l)
        if m: ev.append((m.group(2)[0], m.group(3), m.group(4)))
    return ev
def writes(ev, addr): return [v for r, a, v in ev if r == "w" and a == addr]
def first(ev, pred):
    for i, e in enumerate(ev):
        if pred(e): return i
    return 10**9
d = hw("direct")
fw = first(d, lambda e: e[0] == "w" and e[1] in ("dff09a", "dff096"))
for reg in ("dff002", "dff01c"):
    if first(d, lambda e, reg=reg: e[0] == "r" and e[1] == reg) > fw:
        fail.append(f"direct: {reg} not read before the first INTENA/DMACON write")
if writes(d, "dff09a") != ["7fff", "e010", "7fff", "8000"]:
    fail.append(f"direct: INTENA writes {writes(d, 'dff09a')}")
if writes(d, "dff096") != ["7fff", "82c0", "7fff", "8000"]:
    fail.append(f"direct: DMACON writes {writes(d, 'dff096')}")
if len(writes(d, "dff080")) != 2 or len(writes(d, "dff088")) != 2:
    fail.append("direct: COP1LC/COPJMP1 not written twice (ours, then the OS's)")
ciaseq = [(r, a, v) for r, a, v in d if a.startswith("bfd") and a[3:5] in ("40", "50", "e0", "d0")]
seq = [f"{r}{a}{'=' + v if v else ''}" for r, a, v in ciaseq]
want_seq = ["wbfdd00=7f", "rbfdd00", "rbfde00", "wbfde00=00", "wbfd400=c4", "wbfd500=02",
            "wbfde00=11", "wbfdd00=81", "wbfde00=00", "wbfdd00=7f", "rbfdd00", "wbfdd00=80"]
if seq != want_seq:
    fail.append(f"direct: CIA-B sequence {seq}")
o = hw("os")
if "7fff" in writes(o, "dff09a"):
    fail.append("os: INTENA $7FFF written (the OS path must keep the OS interrupts)")
if writes(o, "dff09a")[:1] != ["8010"]:
    fail.append(f"os: INTENA writes {writes(o, 'dff09a')}")
if any(a == "bfdd00" and r == "w" for r, a, v in o):
    fail.append("os: CIA-B ICR written directly (ciab.resource owns it in the OS path)")
lo = out("os")
if "AddIntServer" not in lo or "RemIntServer" not in lo:
    fail.append("os: AddIntServer/RemIntServer not called")
b = hw("blit")
if writes(b, "dff096")[1:2] != ["87c0"]:
    fail.append(f"blit: DMACON set {writes(b, 'dff096')}")
iw = [i for i, e in enumerate(b) if e[0] == "w" and e[1] in ("dff040", "dff050", "dff054", "dff048", "dff04c")]
iz = [i for i, e in enumerate(b) if e[0] == "w" and e[1] == "dff058"]
if not iz or not iw or max(iw) > iz[0] or writes(b, "dff040")[:1] != ["0fca"] or writes(b, "dff058")[:1] != ["4000"]:
    fail.append("blit: BLTCON0=$0FCA ... BLTSIZE=$4000 last, not seen in that order")
if rc("badload") == 0 or "unknown LOAD" not in out("badload"):
    fail.append("badload: not refused")
if rc("badrate") == 0 or "RATE must be" not in out("badrate"):
    fail.append("badrate: not refused")
# ---- irqlat_table.py over a matrix-style log ----
import subprocess
log = f"{tmp}/matrix.log"
with open(log, "w") as f:
    f.write('=== "test set"\n' + out("direct") + out("blit"))
tab = subprocess.run([sys.executable, "irqlat_table.py", log], capture_output=True, text=True).stdout.splitlines()
cmax = us(max(a for a, _ in cia)); kmax = us(max(a for a, _ in cop))
rows = [r for r in tab if r.startswith("| test set |")]
if len(rows) != 2 or f"| {cmax} | 1 |" not in rows[0] or f"| {kmax} | {max(0, 2 * 4 - len(cop))} |" not in rows[0] \
        or "| BLIT BPL F0 NASTY |" not in rows[1]:
    fail.append(f"irqlat_table.py: {tab}")
for f in fail: print("FAIL:", f)
print("test_irqlat:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
