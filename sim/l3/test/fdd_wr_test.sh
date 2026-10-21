#!/bin/bash
# Offline tests of the floppy write scenario's tools (sim/l3 README "fdd_wr"):
#   (a) sim/l3/gen/mkwrtrack.py round trip: its word stream for a track,
#       read back as big-endian MFM words and decoded with
#       fw/ctrl/test/gold/mfm.py's decode_sector (sync 0x4489 0x4489 at a
#       word boundary, 1,088 bytes), gives the 11 sectors of that track with
#       mfm.py's new_sector() data, in order 0..10, after a gap of zero data;
#       the stream obeys MFM's run-length rules (real clock bits); its
#       length is the Minimig track (6,334 words); --bad-header <s> breaks
#       only sector s's header checksum (its data and data checksum stay
#       right, every other sector decodes)
#   (b) sim/l3/l3check.py fdd_wr on synthetic run directories: a saved card
#       (tools/sim/mkcard.sh) whose TEST.ADF holds the written sectors, the
#       run log's DMA lines and OSD frames (spi_t.txt): PASS; red cases
#       (one written sector wrong, a sector outside the written tracks
#       changed, the bad-header sector neither skipped nor written, a track
#       missing from the log, an OSD page during the writes, the reference
#       run's card differing) each FAIL with their BAD line
# Run from anywhere:
#   bash sim/l3/test/fdd_wr_test.sh
# Prints "PASS <case>" / "FAIL <case>" lines and "=== fdd_wr_test PASS"
# (exit 0) or "=== fdd_wr_test FAILED" (exit 1).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
MKW=${MKWRTRACK:-$ROOT/sim/l3/gen/mkwrtrack.py}
L3CHECK=${L3CHECK:-$ROOT/sim/l3/l3check.py}
OUT="$HERE/build/fdd_wr_test"
rm -rf "$OUT"
mkdir -p "$OUT" || exit 1
export LC_ALL=C
bad=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; bad=1; }

python3 -I "$ROOT/sim/l3/gen/mkadf.py" "$OUT/TEST.ADF" || exit 1

# ---------------------------------------------------------------- (a)
# rt <cyl> <head> [<bad sector>]: generate, then decode independently
rt() {
	local c=$1 h=$2 b=${3:-} hex="$OUT/wr_$1_$2${3:+_bad$3}.hex" opt=()
	[ -n "$b" ] && opt=(--bad-header "$b")
	if [ ! -f "$MKW" ]; then fail "(a) $c/$h${b:+ bad $b}: no $MKW"; return; fi
	python3 -I "$MKW" "$OUT/TEST.ADF" "$c" "$h" "$hex" "${opt[@]}" > "$OUT/mkw.log" 2>&1 \
		|| { fail "(a) $c/$h${b:+ bad $b}: mkwrtrack.py exit $?: $(tail -1 "$OUT/mkw.log")"; return; }
	if python3 -I - "$ROOT" "$OUT/TEST.ADF" "$c" "$h" "$hex" "$b" > "$OUT/rt.txt" 2>&1 <<'EOP'
import importlib.util, os, sys
root, adfp, c, h, hexp, badarg = sys.argv[1:7]
c, h = int(c), int(h)
bad = int(badarg) if badarg else None
spec = importlib.util.spec_from_file_location("mfm", os.path.join(root, "fw", "ctrl", "test", "gold", "mfm.py"))
mfm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mfm)
adf = open(adfp, "rb").read()
words = [int(t, 16) for t in open(hexp).read().split()]
assert all(0 <= w <= 0xFFFF for w in words), "a word out of range"
assert len(words) == 6334, "%d words, want 6334 (the Minimig track)" % len(words)
stream = b"".join(w.to_bytes(2, "big") for w in words)
bits = bin(int.from_bytes(stream, "big"))[2:].zfill(len(stream) * 8)
assert "11" not in bits and "0000" not in bits, "MFM run-length rule broken"
track = c * 2 + h
syncs = [i for i in range(len(words) - 1) if words[i] == 0x4489 and words[i + 1] == 0x4489]
assert len(syncs) == 11, "%d sync pairs, want 11" % len(syncs)
first = syncs[0] - 2                       # the sector starts with its 2-word preamble
assert all(w == 0xAAAA for w in words[:first]), "the gap before sector 0 is not MFM zero data"
assert first == 6334 - 11 * 544, "gap %d words, want %d" % (first, 6334 - 11 * 544)
for k, i in enumerate(syncs):
    p = 2 * (i - 2)
    b = stream[p:p + 1088]
    assert i - 2 == first + 544 * k, "sector %d not back to back" % k
    try:
        t, s, g, d = mfm.decode_sector(b, 0x4489)
    except ValueError as e:
        if k == bad and str(e) == "header checksum":
            # the data block alone must still be right
            L = [int.from_bytes(b[8 + 4 * j:12 + 4 * j], "big") for j in range(270)]
            dsum = 0
            for x in L[14:270]:
                dsum ^= x
            assert (dsum & mfm.M) == (((L[12] & mfm.M) << 1) | (L[13] & mfm.M)), "bad-header sector: data checksum wrong too"
            d = b"".join((((L[14 + j] & mfm.M) << 1) | (L[142 + j] & mfm.M)).to_bytes(4, "big") for j in range(128))
            assert d == mfm.new_sector(track * 11 + k), "bad-header sector: data is not new_sector"
            info = ((L[0] & mfm.M) << 1) | (L[1] & mfm.M)
            assert info == (0xFF << 24) | (track << 16) | (k << 8) | (11 - k), "bad-header sector: header info wrong"
            continue
        raise AssertionError("sector %d: %s" % (k, e))
    assert k != bad, "the bad-header sector decodes"
    assert (t, s, g) == (track, k, 11 - k), "sector %d: header %d/%d/%d" % (k, t, s, g)
    n = track * 11 + k
    assert d == mfm.new_sector(n), "sector %d: data is not mfm.py's new_sector(%d)" % (k, n)
    assert d[:2] == b"WR" and d != adf[n * 512:(n + 1) * 512], "sector %d: not new data" % k
print("ok %d words, gap %d, 11 sectors" % (len(words), first))
EOP
	then pass "(a) $c/$h${b:+ --bad-header $b}: $(cat "$OUT/rt.txt")"
	else fail "(a) $c/$h${b:+ --bad-header $b}: $(tail -1 "$OUT/rt.txt")"; fi
}
rt 0 0
rt 79 1
rt 40 0 3

# a bad sector number is refused
if [ -f "$MKW" ] && python3 -I "$MKW" "$OUT/TEST.ADF" 1 0 "$OUT/x.hex" --bad-header 11 > /dev/null 2>&1; then
	fail "(a) --bad-header 11: accepted"
else pass "(a) --bad-header 11: refused"; fi

# ---------------------------------------------------------------- (b)
# fix <dir> <variant>: a synthetic fdd_wr run directory.  Variants: good
# (bad-header sector skipped, error page), goodw (that sector written),
# wrong (a written sector's byte flipped), outside (a sector no write
# covers changed), other (the bad-header sector garbage), missing (the
# last track's DMA lines missing), osd (an OSD page during the writes)
fix() {
	python3 -I - "$ROOT" "$OUT" "$1" "$2" <<'EOP2' || return 1
import importlib.util, os, subprocess, sys
root, out, d, var = sys.argv[1:5]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
mkw = load("mkwrtrack", os.path.join(root, "sim", "l3", "gen", "mkwrtrack.py"))
sys.path.insert(0, os.path.join(root, "sim", "host_bridge"))
import spitrace
tracks = [(0, 0), (1, 0), (2, 0), (39, 0), (41, 0), (77, 0), (78, 0), (79, 0), (79, 1), (40, 0)]
os.makedirs(os.path.join(d, "card", "content"), exist_ok=True)
adf = open(os.path.join(out, "TEST.ADF"), "rb").read()
open(os.path.join(d, "card", "content", "TEST.ADF"), "wb").write(adf)
new = bytearray(adf)
for c, h in tracks:
    t = c * 2 + h
    for s in range(11):
        if (c, h, s) == (40, 0, 3) and var != "goodw":
            continue
        new[(t * 11 + s) * 512:(t * 11 + s + 1) * 512] = mkw.new_data(t, s)
if var == "wrong":
    new[(158 * 11 + 4) * 512 + 100] ^= 0x01
if var == "outside":
    new[(10 * 11 + 2) * 512 + 7] ^= 0x80
if var == "other":
    new[(80 * 11 + 3) * 512 + 9] ^= 0x01
os.makedirs(os.path.join(d, "content"), exist_ok=True)
open(os.path.join(d, "content", "TEST.ADF"), "wb").write(bytes(new))
r = subprocess.run(["bash", os.path.join(root, "tools", "sim", "mkcard.sh"), os.path.join(d, "card_saved.img"), "6",
                    os.path.join(d, "content", "TEST.ADF")], capture_output=True, encoding="latin-1")
assert r.returncode == 0, r.stdout + r.stderr
log = ["=== KEYS ev 1 69 at cycle 100"]
cyc = 1000
for k, (c, h) in enumerate(tracks, 1):
    if var == "missing" and k == len(tracks):
        break
    log.append("=== FDD wdma %d cylinder %d head %d: 6334 words, from cycle %d, x.hex" % (k, c, h, cyc))
    log.append("=== FDD wdma %d cylinder %d head %d: 6334 words to blckint at cycle %d (500 cycles)" % (k, c, h, cyc + 500))
    cyc += 1000
open(os.path.join(d, "tb_fdd_wr_x0_s8_j0.log"), "w").write("\n".join(log) + "\n")
glyph = {}
for g, ch in spitrace.load_charrom(spitrace.CHARROM).items():
    if len(ch) == 1:
        glyph[ch] = list(g)
fr = []
def osd(t0, row, text):
    mosi = [0x0C, 0, 0, 0, row] + [0xFF, 0xFF] + [0xAA] * 16 + [0xFF, 0xFF, 0, 0]
    for ch in text:
        mosi += glyph[ch]
    fr.append("%d %d 20 %s / %s" % (t0, t0 + 10, " ".join("%02x" % b for b in mosi), " ".join("00" for _ in mosi)))
osd(200, 3, "Floppy disk sounds : on")
osd(300, 0, "df0: TEST")
if var == "osd":
    osd(3000, 0, "df0: TEST")
for row, text in ((0, "*** FATAL ERROR ***"), (2, "Floppy emulation"), (3, "Bad checksum"), (4, "1A"), (7, "Reboot")):
    osd(cyc + 100 + row, row, text)
open(os.path.join(d, "spi_t.txt"), "w").write("\n".join(fr) + "\n")
EOP2
}
chk() {   # chk <case> <want PASS|FAIL> <BAD regex> <run> [<ref>]
	local name=$1 want=$2 re=$3; shift 3
	python3 -I "$L3CHECK" fdd_wr "$@" > "$OUT/chk.txt" 2>&1; local rc=$?
	if [ "$want" = PASS ] && [ "$rc" = 0 ] && grep -q '^PASS fdd_wr: ' "$OUT/chk.txt"; then
		pass "(b) $name: $(grep -E '^HEADER' "$OUT/chk.txt")"
	elif [ "$want" = FAIL ] && [ "$rc" = 1 ] && grep -q '^FAIL fdd_wr: ' "$OUT/chk.txt" && grep -qE -- "$re" "$OUT/chk.txt"; then
		pass "(b) $name: $(grep -E -m1 -- "$re" "$OUT/chk.txt" | cut -c1-150)"
	else fail "(b) $name: exit $rc, want $want: $(cat "$OUT/chk.txt" | head -8)"; fi
}
if [ -f "$MKW" ]; then
	for v in good goodw wrong outside other missing osd; do
		fix "$OUT/run_$v" "$v" || { fail "(b) fixture $v"; continue; }
	done
	chk good PASS '' "$OUT/run_good"
	if ! grep -qx "HEADER track 80 sector 3 (LBA 883): skipped; error page: '\*\*\* FATAL ERROR \*\*\*' / 'Floppy emulation' / 'Bad checksum' / '1A'" "$OUT/chk.txt"; then
		fail "(b) good: HEADER line: $(grep HEADER "$OUT/chk.txt")"
	fi
	chk goodw PASS '' "$OUT/run_goodw"
	grep -q '^HEADER .*: written;' "$OUT/chk.txt" || fail "(b) goodw: not classified written: $(grep HEADER "$OUT/chk.txt")"
	chk wrong FAIL '^BAD  track 158 sector 4 \(LBA 1742\): not the new data' "$OUT/run_wrong"
	chk outside FAIL '^BAD  track 10 sector 2 \(LBA 112\) changed, but no write covers it' "$OUT/run_outside"
	chk other FAIL '^BAD  the bad-header sector \(LBA 883\) is neither' "$OUT/run_other"
	chk missing FAIL '^BAD  the track writes in the log are' "$OUT/run_missing"
	chk osd FAIL '^BAD  1 OSD_CMD_OSD_WR frame\(s\) during the track writes' "$OUT/run_osd"
	chk "ref equal" PASS '' "$OUT/run_good" "$OUT/run_good"
	grep -q '^ok   = the reference run' "$OUT/chk.txt" || fail "(b) ref equal: no '= the reference run' line"
	chk "ref differs" FAIL '^BAD  the bad-header path differs from the reference' "$OUT/run_good" "$OUT/run_goodw"
fi

if [ "$bad" = 0 ]; then echo "=== fdd_wr_test PASS"; exit 0; fi
echo "=== fdd_wr_test FAILED"
exit 1
