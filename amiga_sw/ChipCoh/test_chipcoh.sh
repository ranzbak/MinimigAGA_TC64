#!/usr/bin/env bash
# Plumbing test for ChipCoh, run under vamos (amitools, python3.10 only here).
#
# vamos has no blitter, copper, caches or MMU.  ChipCoh built with -DVAMOS
# still writes every blitter/copper register (vamos logs them) and then does
# the blit in software, so the checking side runs for real: patterns,
# expected buffers, the compare, the first-mismatch report, the code
# generator.  -DFAULT additionally flips bit 0 of longword 17 of every blit's
# destination: every blitter test must then FAIL and name that longword.
# Checks:
#   * all five cache states on a 68040 (FORCED skipped: no MMU in vamos),
#     AS only on a 68020; ROUNDS and ONLY; a bad ONLY is refused (rc 10)
#   * every test line's format and verdict, the summary line and rc
#     (0 = all pass, 5 = something failed)
#   * the FAULT report: address = dst + $44, got = exp ^ 1, again = got
#   * register order: BLTCON0 before BLTSIZE; for the copper-started blit
#     COPCON = 2 and the COPER request cleared before COP2LC/COPJMP2, COP2LC
#     written again (the OS's list) and COPCON = 0 afterwards
# Only the board can show whether the chipset and the caches are coherent.
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
F="-quiet -m68040 -Fhunkexe -kick1hunks -nosym"
vasmm68k_mot $F -DVAMOS=1 -o "$TMP/ChipCoh" ChipCoh.asm || { echo "test_chipcoh: FAIL (assembly)"; exit 1; }
vasmm68k_mot $F -DVAMOS=1 -DFAULT=1 -o "$TMP/ChipCohF" ChipCoh.asm || { echo "test_chipcoh: FAIL (assembly)"; exit 1; }

run() {   # run <name> <cpu> <binary> <args...>
  local name=$1 cpu=$2 bin=$3; shift 3
  (cd "$TMP" && timeout 300 python3.10 -c "from amitools.tools.vamos import main; import sys; sys.argv=['vamos','-C',sys.argv[1],sys.argv[2]]+sys.argv[3:]; sys.exit(main())" "$cpu" "$bin" "$@" >"$name.out" 2>&1; echo $? >"$name.rc")
}
run all 68040 ChipCoh
run few 68040 ChipCoh ROUNDS=3 ONLY=DCOFF
run fault 68040 ChipCohF ROUNDS=2 ONLY=AS
run c020 68020 ChipCoh ROUNDS=2
run bad 68040 ChipCoh ONLY=XYZ

python3.10 - "$TMP" <<'EOF'
import re, sys
tmp = sys.argv[1]
fail = []
def out(n): return open(f"{tmp}/{n}.out").read()
def text(n): return [l for l in out(n).splitlines() if not re.match(r"^\d\d:\d\d:\d\d", l)]
def rc(n): return int(open(f"{tmp}/{n}.rc").read())
BLIT = ["BLITCPY", "BLITSTALE", "BLITRMW", "STORESIZE", "COPBLIT"]
CODE = ["CODEF-CHIP", "CODEF-FAST"]
INFO = ["CODEN-CHIP", "CODEN-FAST"]
def state_lines(t, st):
    i = t.index(next(l for l in t if l.startswith(f"state {st}:")))
    return t[i:i + 10]
def expect_pass(name, t, st, rounds):
    try:
        b = state_lines(t, st)
    except StopIteration:
        fail.append(f"{name}: no 'state {st}:' line"); return
    if not re.match(rf"state {st}: CACR [0-9A-Fa-f]{{8}}", b[0]):
        fail.append(f"{name}: state line {b[0]!r}")
    for i, tn in enumerate(BLIT + CODE):
        if b[1 + i] != f"  {tn:<10} PASS {rounds} rounds":
            fail.append(f"{name}/{st}: {b[1 + i]!r} (want {tn} PASS {rounds} rounds)")
    for i, tn in enumerate(INFO):
        want = f"  {tn:<10} INFO fresh {256 * rounds} stale 0 other 0"
        if b[8 + i] != want:
            fail.append(f"{name}/{st}: {b[8 + i]!r} (want {want!r})")

t = text("all")
if rc("all") != 0: fail.append(f"all: rc {rc('all')}")
if not any(re.match(r"ChipCoh: CPU 68040 CACR [0-9A-Fa-f]{8} TC [0-9A-Fa-f]{8} ITT0 [0-9A-Fa-f]{8} ITT1 [0-9A-Fa-f]{8} DTT0 [0-9A-Fa-f]{8} DTT1 [0-9A-Fa-f]{8} URP [0-9A-Fa-f]{8}$", l) for l in t):
    fail.append("all: header")
if "chip data caching as found: MMU off, no TT match: cacheable write-through by default" not in t:
    fail.append("all: caching summary")
if not any(re.match(r"buffers: src [0-9A-Fa-f]{8} dst [0-9A-Fa-f]{8} chip code [0-9A-Fa-f]{8} fast code [0-9A-Fa-f]{8} expect [0-9A-Fa-f]{8}$", l) for l in t):
    fail.append("all: buffers line")
for st in ("AS", "DCOFF", "ICOFF", "OFF"):
    expect_pass("all", t, st, 20)
if not any(l.startswith("state FORCED: skipped (MMU off") for l in t):
    fail.append("all: FORCED not skipped")
if "ChipCoh: done, 0 failed" not in t: fail.append("all: summary line")

t = text("few")
expect_pass("few", t, "DCOFF", 3)
if any(l.startswith(("state AS:", "state ICOFF:", "state OFF:", "state FORCED")) for l in t):
    fail.append("few: ONLY=DCOFF ran other states")

t = text("fault")
if rc("fault") != 5: fail.append(f"fault: rc {rc('fault')} (want 5)")
dst = int(next(re.search(r"dst ([0-9A-Fa-f]{8})", l).group(1) for l in t if l.startswith("buffers:")), 16)
b = state_lines(t, "AS")
for i, tn in enumerate(BLIT):
    m = re.match(rf"  {tn:<10} FAIL 2/2 rounds, (\d+) longs; first @([0-9A-Fa-f]{{8}}) exp ([0-9A-Fa-f]{{8}}) got ([0-9A-Fa-f]{{8}}) again ([0-9A-Fa-f]{{8}})$", b[1 + i])
    if not m:
        fail.append(f"fault: {b[1 + i]!r}"); continue
    n, a, e, g, ag = int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16), int(m.group(5), 16)
    if n != 2 or a != dst + 0x44 or g != e ^ 1 or ag != g:
        fail.append(f"fault: {tn} reports n={n} @{a:08x} (want {dst + 0x44:08x}) exp {e:08x} got {g:08x} again {ag:08x}")
for i, tn in enumerate(CODE):
    if b[6 + i] != f"  {tn:<10} PASS 2 rounds": fail.append(f"fault: {b[6 + i]!r}")
if "ChipCoh: done, 5 failed" not in t: fail.append("fault: summary line")

t = text("c020")
if not any(re.match(r"ChipCoh: CPU 68020 CACR [0-9A-Fa-f]{8}$", l) for l in t): fail.append("c020: header")
if "states: AS only (CACR and MMU states need a 68040)" not in t: fail.append("c020: AS-only note")
expect_pass("c020", t, "AS", 2)
if any(l.startswith(("state DCOFF", "state FORCED")) for l in t): fail.append("c020: ran 040 states")

if rc("bad") != 10 or not any("unknown ONLY" in l for l in text("bad")): fail.append("bad: ONLY=XYZ not refused")

# register order, from the full run's log
ev = []
for l in out("all").splitlines():
    m = re.search(r"Custom Chip (read|write) word @([0-9a-f]{6})(?:: ([0-9a-f]{4}))?", l)
    if m: ev.append((m.group(1)[0], m.group(2), m.group(3)))
w = [(a, v) for r, a, v in ev if r == "w"]
blits = [i for i, (a, v) in enumerate(w) if a == "dff058"]
if not blits: fail.append("no BLTSIZE write")
prev = -1
for i in blits:
    seg = [a for a, v in w[prev + 1:i]]
    if "dff040" not in seg and "dff08a" not in seg:
        fail.append(f"BLTSIZE write #{blits.index(i)} without BLTCON0 before it"); break
    prev = i
jumps = [i for i, (a, v) in enumerate(w) if a == "dff08a"]
if len(jumps) != 4 * 20: fail.append(f"COPJMP2 strobes: {len(jumps)} (want 80)")
for j in jumps[:1]:
    before = w[max(0, j - 6):j]
    if ("dff02e", "0002") not in before or ("dff09c", "0010") not in before or not any(a == "dff084" for a, v in before):
        fail.append(f"COPBLIT set-up before COPJMP2: {before}")
    after = w[j + 1:j + 8]
    if ("dff02e", "0000") not in after or not any(a == "dff084" for a, v in after):
        fail.append(f"COPBLIT restore after COPJMP2: {after}")
for f in fail: print("FAIL:", f)
print("test_chipcoh:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
