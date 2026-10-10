#!/usr/bin/env bash
# Plumbing test for AdvPat, run under vamos (amitools, python3.10 only here).
#
# vamos has no display.  AdvPat built with -DVAMOS skips graphics.library,
# does not wait for the beam, and instead of reading the mouse and keyboard
# shows every pattern from PAT on once, with four frames each, then exits.
# Every custom register write is logged, so the test can rebuild what the
# hardware would have been given.  Checks:
#   * LIST: 24 patterns, names; DUMP=n: each palette against a Python model
#   * the AGA palette upload: from the logged BPLCON3 (bank, LOCT) and
#     COLORxx writes, the 256 24-bit colours each pattern loads must equal
#     the model (high nibbles with LOCT=0 first, then low nibbles)
#   * flash patterns: COLOR00 changes every 1, 2, 4 frames
#   * takeover/restore order: DMACONR read first, sprites off, our DMA on,
#     one COP1LC + COPJMP1 per pattern, the OS's COP1LC at the end, DMACON
#     restored; BPLCON3 left at $0C00
#   * PAT=n starts there; bad PAT/DUMP refused (rc 10)
# Only the board (and a monitor) can show the pictures, see README.md.
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
vasmm68k_mot -quiet -m68040 -Fhunkexe -kick1hunks -nosym -DVAMOS=1 -o "$TMP/AdvPat" AdvPat.asm || { echo "test_advpat: FAIL (assembly)"; exit 1; }
run() {   # run <name> <args...>
  local name=$1; shift
  (cd "$TMP" && timeout 300 python3.10 -c "from amitools.tools.vamos import main; import sys; sys.argv=['vamos','--vols-base-dir','vols','-C','68040','AdvPat']+sys.argv[1:]; sys.exit(main())" "$@" >"$name.out" 2>&1; echo $? >"$name.rc")
}
run list LIST
for p in $(seq 0 23); do run dump$p DUMP=$p; done
run show
run show20 PAT=20
run badpat PAT=24
run baddump DUMP=99

python3.10 - "$TMP" <<'EOF'
import re, sys
tmp = sys.argv[1]
fail = []
def out(n): return open(f"{tmp}/{n}.out").read()
def text(n): return [l for l in out(n).splitlines() if not re.match(r"^\d\d:\d\d:\d\d", l)]
def rc(n): return int(open(f"{tmp}/{n}.rc").read())

GREY, R, G, B = 0x010101, 0x010000, 0x000100, 0x000001
BARS = [0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000]
SEQ8 = [0x000000, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0xFF00FF]
def pad(l): return l + [0] * (256 - len(l))
model = [
    [(i & 63) * GREY for i in range(256)],
    [(i & 63) * [R, G, B, GREY][i >> 6] for i in range(256)],
    [i * GREY for i in range(256)],
    [i * R for i in range(256)],
    [i * G for i in range(256)],
    [i * B for i in range(256)],
    [BARS[(i & 63) >> 3] for i in range(256)],
]
for pair in ((0x555555, 0xAAAAAA), (0x00FF00, 0xFF00FF), (0xFFF000, 0x000FFF)):
    model += [pad(list(pair))] * 3
model += [pad([0xFFF000]), pad([0x000FFF])]
model += [pad([0, 0xFFFFFF])] * 3 + [pad(SEQ8)] * 3
FLASH = {18: (2, 1), 19: (2, 2), 20: (2, 4), 21: (8, 1), 22: (8, 2), 23: (8, 4)}
NAMES = {0: "dark grey 0-63, 4 strips", 6: "colour bars", 9: "stripes 555555/AAAAAA superhires",
         16: "solid FFF000: all 12 pins toggle each edge", 23: "flash 8 colours every 4th frame"}

# LIST
t = [l for l in text("list") if re.match(r"^ *\d+  ", l)]
if len(t) != 24: fail.append(f"LIST: {len(t)} patterns")
for n, name in NAMES.items():
    if f"{n:3d}  {name}" not in t: fail.append(f"LIST: no '{n:3d}  {name}'")
# DUMP
for p in range(24):
    t = text(f"dump{p}")
    vals = [int(x, 16) for l in t if re.match(r"^[0-9A-Fa-f]{6}( [0-9A-Fa-f]{6}){7}$", l) for x in l.split()]
    if rc(f"dump{p}") != 0 or vals != model[p]:
        fail.append(f"DUMP={p}: rc {rc(f'dump{p}')}, {len(vals)} values, first diff at "
                    f"{next((i for i in range(min(len(vals), 256)) if vals[i] != model[p][i]), len(vals))}")
    if not any(l.startswith(f"pattern {p}: ") for l in t): fail.append(f"DUMP={p}: title")

# the uploads, rebuilt from the register writes
def writes(name):
    w = []
    for l in out(name).splitlines():
        m = re.search(r"Custom Chip (read|write) word @([0-9a-f]{6})(?:: ([0-9a-f]{4}))?", l)
        if m: w.append((m.group(1)[0], int(m.group(2), 16), int(m.group(3), 16) if m.group(3) else None))
    return w
def rgb(hi, lo):
    c = 0
    for sh in (8, 4, 0):
        c = (c << 8) | (((hi >> sh) & 15) << 4) | ((lo >> sh) & 15)
    return c
def replay(name):
    hi, lo = [0] * 256, [0] * 256
    bank = loct = 0
    shows, ncol, cop, bplcon3 = [], None, 0, None
    for r, a, v in writes(name):
        if r != "w": continue
        if a == 0xdff080:
            cop += 1; ncol = 0; shows.append({"pal": None, "c0": []})
        elif a == 0xdff106:
            bank, loct, bplcon3 = v >> 13, (v >> 9) & 1, v
        elif 0xdff180 <= a <= 0xdff1be:
            i = bank * 32 + (a - 0xdff180) // 2
            if loct: lo[i] = v
            else: hi[i] = lo[i] = v
            if ncol is not None:
                ncol += 1
                if ncol == 512: shows[-1]["pal"] = [rgb(hi[k], lo[k]) for k in range(256)]
                elif ncol > 512 and i == 0 and loct: shows[-1]["c0"].append(rgb(hi[0], lo[0]))
    return shows, cop, bplcon3
shows, cop, b3 = replay("show")
if rc("show") != 0: fail.append(f"show: rc {rc('show')}")
if len(shows) != 25: fail.append(f"show: {len(shows)} COP1LC writes (want 24 + the OS's)")
for p in range(min(24, len(shows))):
    if shows[p]["pal"] != model[p]:
        got = shows[p]["pal"]
        fail.append(f"show: pattern {p} upload differs" + (f" at {next(i for i in range(256) if got[i] != model[p][i])}" if got else " (incomplete)"))
    if p in FLASH:
        n, per = FLASH[p]
        want = [SEQ8[k % n] if n == 8 else [0, 0xFFFFFF][k % 2] for k in range(1, 4 // per + 1)]
        if shows[p]["c0"] != want: fail.append(f"show: flash {p} COLOR00 {[hex(x) for x in shows[p]['c0']]} want {[hex(x) for x in want]}")
    elif shows[p]["c0"]:
        fail.append(f"show: pattern {p} changed COLOR00 between frames")
if b3 != 0x0c00: fail.append(f"show: BPLCON3 left at {b3}")
w = [(a, v) for r, a, v in writes("show")]
if w[:1] != [(0xdff002, None)]: fail.append("show: DMACONR not read first")
dm = [v for a, v in w if a == 0xdff096]
if dm[:2] != [0x0020, 0x8380] or len(dm) != 4: fail.append(f"show: DMACON writes {[hex(x) for x in dm]}")
if len([1 for a, v in w if a == 0xdff088]) != 25: fail.append("show: COPJMP1 strobes")
s20, _, _ = replay("show20")
if len(s20) != 5 or s20[0]["pal"] != model[20]: fail.append("PAT=20: did not start at pattern 20")
for n in ("badpat", "baddump"):
    if rc(n) != 10 or not any("must be 0..23" in l for l in text(n)): fail.append(f"{n}: not refused")
for f in fail: print("FAIL:", f)
print("test_advpat:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
