#!/usr/bin/env bash
# Plumbing test for SerRx, run under vamos (amitools, python3.10 only here).
#
# vamos has no serial.device, so the receive path itself cannot run here.  This
# checks everything around it:
#   * ReadArgs: the options are understood, bad values are refused (rc 10)
#   * SELFTEST: the built-in stream (3 bytes lost at 100, bit 7 flipped at
#     expected 300, bit 2 at 700, $11/$13 dropped in expected 1024..2047, one
#     extra $55 before expected 2500, the last 10 missing) is classified as
#     exactly that -- checked against the injections, not against a model
#   * FROM=file: random damaged streams (skips, bit flips, XON/XOFF filtering,
#     extra bytes, short tails) give the same report, line for line, as an
#     independent Python model of the comparison; a clean stream is PERFECT, rc 0
#   * SAVE=file writes exactly the received bytes
# It does NOT check serial.device: only the board can (see README.md).
#
#   ./test_serrx.sh            builds its own copy
set -u
cd "$(dirname "$0")"
HERE=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
vasmm68k_mot -quiet -m68020 -Fhunkexe -kick1hunks -nosym -o "$TMP/SerRx" SerRx.s || { echo "test_serrx: FAIL (assembly)"; exit 1; }

python3.10 - "$TMP" "$HERE" <<'EOF'
import os, random, re, subprocess, sys
tmp, here = sys.argv[1], sys.argv[2]
fail = []

def run(*args):
    r = subprocess.run([sys.executable, "-c",
        "from amitools.tools.vamos import main; import sys; "
        "sys.argv=['vamos','--vols-base-dir','vols','-C','68020','SerRx']+sys.argv[1:]; sys.exit(main())",
        *args], cwd=tmp, capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr

# ---- the reference model of the comparison ----
def model(got, C):
    n = len(got)
    out = [f"received {n} expected {C}"]
    dm = [(i, i & 255, got[i]) for i in range(min(n, C)) if got[i] != i & 255]
    out.append(f"same-offset mismatches {len(dm)}")
    for i, e, g in dm[:16]:
        out.append(f"  @{i} exp ${e:02x} got ${g:02x} xor ${e ^ g:02x}")
    def match(s, v, ln):
        return all(got[s + j] == (v + j) & 255 for j in range(ln))
    i = e = 0
    ev = []; nchg = nmiss = ngap = nins = ninsb = 0
    xb = [0] * 8; miss = [0] * 256
    while i < n:
        if got[i] == e & 255:
            i += 1; e += 1; continue
        m = min(4, n - i)
        if match(i + 1, e + 1, m - 1):
            kind = ("chg",)
        else:
            kind = None
            for k in range(1, 256):
                if match(i, e + k, m):
                    kind = ("skip", k); break
            if kind is None:
                for j in range(1, 9):
                    if i + j >= n: break
                    if match(i + j, e, min(4, n - i - j)):
                        kind = ("ins", j); break
            if kind is None:   # fallback, two gaps in the window ($11/$13 filtered)
                k = (got[i] - e) & 255
                st = (got[i + 1] - got[i]) & 255
                if got[i + 1] != (e + 1) & 255 and k <= 64 and 1 <= st <= 64:
                    kind = ("skip", k)
                else:
                    kind = ("chg",)
        if kind[0] == "chg":
            x = (e & 255) ^ got[i]
            ev.append(f"  @{i} changed exp ${e & 255:02x} got ${got[i]:02x} xor ${x:02x}")
            for b in range(8):
                if x >> b & 1: xb[b] += 1
            nchg += 1; i += 1; e += 1
        elif kind[0] == "skip":
            k = kind[1]
            ev.append(f"  @{i} lost {k} exp ${e & 255:02x} got ${got[i]:02x}")
            for t in range(k): miss[(e + t) & 255] += 1
            ngap += 1; nmiss += k; e += k
        else:
            j = kind[1]
            ev.append(f"  @{i} extra {j} exp ${e & 255:02x} got ${got[i]:02x}")
            nins += 1; ninsb += j; i += j
    tail = max(0, C - e)
    out.append(f"aligned: changed {nchg}, lost {nmiss} in {ngap} gaps, extra {ninsb} in {nins} places, tail missing {tail}")
    out += ev[:16]
    out.append("xor bits b7..b0: " + " ".join(str(xb[b]) for b in range(7, -1, -1)))
    oth = nmiss - miss[0x11] - miss[0x13]
    out.append(f"lost values: $11 {miss[0x11]}, $13 {miss[0x13]}, other {oth}")
    v = []
    if nmiss: v.append(f"verdict: LOST {nmiss} bytes in {ngap} gaps")
    if nmiss and not oth: v.append("verdict: FILTERED -- every lost byte is $11/$13 (XON/XOFF)")
    if nchg: v.append(f"verdict: CHANGED {nchg} bytes (bit errors, see xor bits)")
    if nins: v.append(f"verdict: EXTRA {ninsb} bytes in {nins} places")
    if tail: v.append(f"verdict: SHORT {tail} bytes missing at the end")
    if not v and n == C: v.append("verdict: PERFECT")
    out += v
    return out, (0 if v == ["verdict: PERFECT"] else 5)

def report(o):   # the analysis part of the output, hex case folded
    ls = o.splitlines()
    for k, l in enumerate(ls):
        if l.startswith("received "):
            return [x.lower() if x.startswith("  @") else x for x in ls[k:]]
    return []
def lower(ls): return [x.lower() if x.startswith("  @") else x for x in ls]

# ---- the built-in self test stream, from its injections ----
def selftest_stream():
    s = []
    for e in range(4096 - 10):
        if e == 2500: s.append(0x55)
        if 100 <= e < 103: continue
        if 1024 <= e < 2048 and (e & 255) in (0x11, 0x13): continue
        v = e & 255
        if e == 300: v ^= 0x80
        if e == 700: v ^= 0x04
        s.append(v)
    return bytes(s)

rc, o = run("SELFTEST", "SAVE=st.bin")
st = selftest_stream()
want, wrc = model(st, 4096)
if rc != 5: fail.append(f"selftest: rc {rc}")
if report(o) != lower(want):
    fail.append("selftest: report differs from the model:\n" + "\n".join(report(o)) + "\n--- model ---\n" + "\n".join(want))
# ground truth, independent of the model
r = "\n".join(report(o))
for w in ["received 4076 expected 4096",
          "aligned: changed 2, lost 11 in 9 gaps, extra 1 in 1 places, tail missing 10",
          "  @100 lost 3 exp $64 got $67",
          "  @297 changed exp $2c got $ac xor $80",
          "  @697 changed exp $bc got $b8 xor $04",
          "  @1038 lost 1 exp $11 got $12",
          "  @1039 lost 1 exp $13 got $14",
          "  @2489 extra 1 exp $c4 got $55",
          "xor bits b7..b0: 1 0 0 0 0 1 0 0",
          "lost values: $11 4, $13 4, other 3",
          "verdict: LOST 11 bytes in 9 gaps",
          "verdict: CHANGED 2 bytes (bit errors, see xor bits)",
          "verdict: EXTRA 1 bytes in 1 places",
          "verdict: SHORT 10 bytes missing at the end"]:
    if w not in r.splitlines(): fail.append(f"selftest: missing line '{w}'")
if "FILTERED" in r: fail.append("selftest: FILTERED although 3 other bytes were lost")
try:
    if open(f"{tmp}/st.bin", "rb").read() != st: fail.append("selftest: SAVE file differs from the stream")
except OSError as x:
    fail.append(f"selftest: SAVE file: {x}")

# ---- FROM=file: clean, filtered-only, and random damage ----
def damage(rng, C):
    s = []; e = 0
    xon = rng.random() < 0.3
    end = C - (rng.randrange(0, 40) if rng.random() < 0.5 else 0)
    while e < end:
        r = rng.random()
        if r < 0.004: e += rng.randrange(1, 60); continue          # lost run
        if xon and (e & 255) in (0x11, 0x13): e += 1; continue     # filtered
        v = e & 255
        if r < 0.007: v ^= 1 << rng.randrange(8)                   # bit error
        if r > 0.997: s.append(rng.randrange(256))                 # extra byte
        s.append(v); e += 1
    return bytes(s[:C])

cases = [("clean", bytes(i & 255 for i in range(4096)), 4096),
         ("xononly", bytes(i & 255 for i in range(4096) if i & 255 not in (0x11, 0x13)), 4096),
         ("short", bytes(i & 255 for i in range(1000)), 4096),
         ("late", bytes(i & 255 for i in range(37, 2000)), 2000)]
rng = random.Random(1234)
for k in range(30):
    C = rng.choice([512, 4096, 9000])
    cases.append((f"rand{k}", damage(rng, C), C))
for name, data, C in cases:
    open(f"{tmp}/{name}.bin", "wb").write(data)
    rc, o = run(f"FROM={name}.bin", f"COUNT={C}")
    want, wrc = model(data, C)
    if rc != wrc: fail.append(f"{name}: rc {rc}, want {wrc}")
    if report(o) != lower(want):
        fail.append(f"{name}: report differs from the model:\n" + "\n".join(report(o)) + "\n--- model ---\n" + "\n".join(want))
r = run("FROM=clean.bin")[1]
if "verdict: PERFECT" not in r: fail.append("clean: not PERFECT")
r = run("FROM=xononly.bin")[1]
if "verdict: FILTERED -- every lost byte is $11/$13 (XON/XOFF)" not in r: fail.append("xononly: not FILTERED")

# ---- argument checking ----
for args, msg in [(["BAUD=50"], "BAUD must be"), (["COUNT=0"], "COUNT must be"),
                  (["BOOGIE", "NOBOOGIE"], "BOOGIE and NOBOOGIE"), (["BUF=10"], "BUF must be"),
                  (["TIMEOUT=0"], "TIMEOUT must be"), (["FROM=nonexistent.bin"], "cannot read")]:
    rc, o = run(*args)
    if rc != 10 or msg not in o: fail.append(f"args {args}: rc {rc}, output {o[-300:]!r}")
# no serial.device under vamos: the receive path must say so and give rc 10
rc, o = run("BAUD=115200")
if rc != 10 or "OpenDevice serial.device unit 0 failed" not in o or "received" in o:
    fail.append(f"no device: rc {rc}, output {o[-300:]!r}")
for f in fail: print("FAIL:", f)
print("test_serrx:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
