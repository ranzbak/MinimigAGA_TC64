#!/bin/bash
# Fixtures for the differential tools (sim/host_bridge/spitrace.py norm /
# diff / osd, sim/l3 README "Differential"):
#   (a) the same frames with other poll counts (and other firmware / config
#       file names, sizes and printf forms, covered by the fixture's rules)
#       -> an empty diff
#   (b) one changed byte in an SD read, an FPGA data frame, an OSD text
#       line, a hw write, a UART line, a KEYQ event, a status frame with a
#       request, a changed drive status, a deselect frame that is not all
#       ff, and the lines just before and after a DROPBLOCK block -> each a
#       diff line: the normaliser hides no content; a DROPBLOCK start
#       without its end -> norm fails
#   (c) each rule of the fixture's expected-diff list removed in turn -> its
#       difference comes back; an unused rule -> diff --unused-rules reports it
# The card is built with tools/sim/mkcard.sh (sfdisk, mkfs.fat, mtools), the
# frames by the generator below.  Run from anywhere:
#   bash sim/l3/test/spitrace_test.sh
# Prints "PASS <case>" / "FAIL <case>" lines and "=== spitrace_test PASS"
# (exit 0) or "=== spitrace_test FAILED" (exit 1).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ST=${SPITRACE:-$ROOT/sim/host_bridge/spitrace.py}   # SPITRACE: another spitrace.py (the RED run)
OUT="$HERE/build/spitrace_test"
rm -rf "$OUT"
mkdir -p "$OUT/content" || exit 1
export LC_ALL=C

# the card: two "firmwares" of different sizes, two configs, a data file
python3 -I - "$OUT/content" <<'EOP' || exit 1
import os, sys
d = sys.argv[1]
def put(name, n, seed):
    with open(os.path.join(d, name), "wb") as f:
        f.write(bytes((seed + 7 * i) & 0xFF for i in range(n)))
put("FWA.BIN", 5 * 512 + 100, 1)
put("FWB.BIN", 9 * 512, 2)
put("CFGA.CFG", 212, 3)
put("CFGB.CFG", 212, 4)
put("DATA.BIN", 3 * 512, 5)
EOP
bash "$ROOT/tools/sim/mkcard.sh" "$OUT/card.img" 6 "$OUT"/content/FWA.BIN "$OUT"/content/FWB.BIN \
	"$OUT"/content/CFGA.CFG "$OUT"/content/CFGB.CFG "$OUT"/content/DATA.BIN > "$OUT/mkcard.log" 2>&1 \
	|| { cat "$OUT/mkcard.log"; echo "=== spitrace_test FAILED (mkcard.sh)"; exit 1; }

# gen <dir> <variant> [<change>]: spi.txt, hw.txt, uart.txt of one run.
# variant a: firmware FWA.BIN / config CFGA.CFG, few polls, "0x0";
# variant b: FWB.BIN / CFGB.CFG, more polls, "0x00".  change: one content
# difference against variant b (sd, fpga, osd, hw, uart, keyq, status).
gen() {
	python3 -I - "$ROOT" "$OUT/card.img" "$@" <<'EOP'
import os, sys
root, card, d, var = sys.argv[1:5]
change = sys.argv[5] if len(sys.argv) > 5 else ""
sys.path.insert(0, os.path.join(root, "sim", "host_bridge"))
import spitrace
os.makedirs(d, exist_ok=True)
c = spitrace.Card(card)
glyph = {}
for g, ch in spitrace.load_charrom(spitrace.CHARROM).items():
    if len(ch) == 1:
        glyph[ch] = list(g)
img = open(card, "rb").read()
frames, hw, uart = [], [], []
def frame(cs, out, inp):
    frames.append("%02x %s /%s" % (cs, " ".join("%02x" % b for b in out),
                                   "".join(" %02x" % b for b in inp)))
def sd(cmd, arg, r1, extra=(), data=None):
    out = [0xFF, 0x40 | cmd] + list(arg.to_bytes(4, "big")) + [0x95, 0xFF, 0xFF]
    inp = [0xFF] * 8
    out += [0xFF] * len(extra)
    inp += [r1] + list(extra)
    if data is not None:
        out += [0xFF] * (3 + 512 + 2)
        inp += [0xFF, 0xFF, 0xFE] + list(data) + [0x12, 0x34]
    frame(0x02, out, inp)
    frame(0x00, [0xFF], [0xFF])           # deselect clocks
def sector(lba):
    return img[lba * 512:lba * 512 + 512]
def hwrite(addr, v):
    hw.append("%d %d %s %04x" % (len(frames), len(hw) + len(uart), addr, v))
def say(text):
    uart.append("%d %d %s" % (len(frames), len(hw) + len(uart), text))
npoll = 0
def polls(n):
    global npoll
    for _ in range(n):
        npoll += 1
        st = 0x11 if change == "status" and _ == 1 else 0x10
        frame(0x10, [0] * 6, [st, 0x01, 0x44, 0x89, 0, 0])
        frame(0x10, [0x10, 0x01 if change == "uds" and npoll == 3 else 0x00], [0x10, 0x01])
        frame(0x20, [0x00], [0x00])
        frame(0x20, [0x98, 0xFF], [0x00, 0x00])
        frame(0x80, [0x92] + [0xFF] * 7, [0xFF, 0, 0, 0, 1, 4, 1, 0x26])
def osd(row, text):
    out = [0x0C, 0, 0, 0, row] + [0xFF, 0xFF] + [0xAA] * 16 + [0xFF, 0xFF, 0, 0]
    for ch in text:
        out += glyph[ch]
    out += [0] * (256 - 22 - 8 * len(text))
    frame(0x20, out, [0] * len(out))
b = var == "b"
fw, cfg = ("FWB.BIN", "CFGB.CFG") if b else ("FWA.BIN", "CFGA.CFG")
say("Initializing SD card")
sd(0, 0, 0x01)
sd(8, 0x1AA, 0x01, (0, 0, 1, 0xAA))
sd(58, 0, 0x00, (0xC0, 0xFF, 0x80, 0x00))
sd(17, 0, 0x00, data=sector(0))
sd(17, c.root, 0x00, data=sector(c.root))
say('file "%s" found' % (fw.split(".")[0].ljust(8) + fw.split(".")[1]))
for k, lba in enumerate(c.file_lbas(fw)):
    hwrite("ffffe8", 0x0101)              # a hw write before each sector
    if k == 2:
        sd(17, c.fat // 512, 0x00, data=sector(c.fat // 512))   # the FAT, once
    sd(17, lba, 0x00, data=sector(lba))
say("partition type: " + ("0x00" if b else "0x0") + " (FAT16)")
for lba in c.file_lbas(cfg):
    sd(17, lba, 0x00, data=sector(lba))
hwrite("ffffc0", 0x0001)
hwrite("ffffb0", 0x0003 if change == "hw" else 0x0002)
polls(5 if b else 2)
data = bytearray(sector(c.file_lbas("DATA.BIN")[1]))
if change == "sd":
    data[100] ^= 0x01
sd(17, c.file_lbas("DATA.BIN")[1], 0x00, data=bytes(data))
frame(0x00, [0xFE if change == "desel" else 0xFF], [0xFF])     # cs 00, not all ff: kept
frame(0x10, [0x00, 0x05 if change == "fpga" else 0x04, 0x00], [0x10, 0x00, 0x00])
osd(0, "Minimig " + ("Lead" if change == "osd" else "Load"))
polls(1 if b else 4)
frame(0x20, [0x98, 0xFF, 0xFF], [0x00, 0x01, 0x46 if change == "keyq" else 0x45])
say("Kickstart " + ("okay" if change == "uart" else "ok"))
frame(0x20, [0x24, 0x06 if change == "pre" else 0x05], [0x00, 0x00])   # just before the block
if b:                                     # a block only variant b has (DROPBLOCK)
    say("Overriding screenmode.")
    frame(0x20, [0x14, 0x00], [0x00, 0x00])
    hwrite("ffffc0", 0x0001)
    if change != "unterm":
        say("##End result : 0")
say("Loading kickstart" + ("s" if change == "post" else ""))      # just after it
polls(7 if b else 3)
hw.append("MEM kickstart " + "ab" * 32)
for name, lines in (("spi.txt", frames), ("hw.txt", hw), ("uart.txt", uart)):
    with open(os.path.join(d, name), "w") as f:
        f.write("".join(l + "\n" for l in lines))
EOP
}

# the fixture's rules: one per difference between variants a and b
cat > "$OUT/rules.txt" <<'EOR'
# fixture: the firmware file differs (name, size)
SDFILE FWA.BIN FIRMWARE
SDFILE FWB.BIN FIRMWARE
SUBST uart FW[AB]\x20+BIN FW?     BIN

# fixture: the config file
SDFILE CFGA.CFG CONFIG
SDFILE CFGB.CFG CONFIG

# fixture: a printf difference (%02X of 0)
SUBST uart partition\x20type:\x200x0+\b partition type: 0x00

# fixture: a block only variant b has
DROPBLOCK uart ^Overriding\x20screenmode\.$ ^##End\x20result\x20:\x200$
EOR

bad=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; bad=1; }
norm() {   # norm <run dir> <rules> -> <run dir>/norm.txt
	python3 -I "$ST" norm "$1/spi.txt" "$1/hw.txt" "$1/uart.txt" -r "$2" --card "$OUT/card.img" > "$1/norm.txt"
}
dodiff() { python3 -I "$ST" diff "$@" > "$OUT/diff.txt" 2>&1; }

gen "$OUT/a" a || exit 1
gen "$OUT/b" b || exit 1
norm "$OUT/a" "$OUT/rules.txt" && norm "$OUT/b" "$OUT/rules.txt" || { echo "=== spitrace_test FAILED (norm)"; exit 1; }

# (a) poll counts only: a and a copy of a with other poll counts
gen "$OUT/a2" a || exit 1
python3 -I - "$OUT/a" "$OUT/a2" <<'EOP'
import sys
# a2: every poll frame repeated three times (the frames of polls())
src, dst = sys.argv[1], sys.argv[2]
poll = ("10 00 00 00 00 00 00 /", "10 10 00 /", "20 00 /", "20 98 ff /", "80 ")
lines = open(src + "/spi.txt").read().splitlines()
out, idx = [], []
for l in lines:
    idx.append(len(out))
    out += [l] * (3 if l.startswith(poll) else 1)
open(dst + "/spi.txt", "w").write("".join(l + "\n" for l in out))
for name in ("hw.txt", "uart.txt"):
    res = []
    for l in open(src + "/" + name).read().splitlines():
        w = l.split(" ", 1)
        if w[0].isdigit():
            n = int(w[0])
            l = "%d %s" % (idx[n] if n < len(idx) else len(out), w[1])
        res.append(l)
    open(dst + "/" + name, "w").write("".join(l + "\n" for l in res))
EOP
norm "$OUT/a2" "$OUT/rules.txt"
if [ "$(wc -l < "$OUT/a2/spi.txt")" -gt "$(wc -l < "$OUT/a/spi.txt")" ] && dodiff "$OUT/a/norm.txt" "$OUT/a2/norm.txt"; then
	pass "(a) other poll counts: empty diff ($(wc -l < "$OUT/a/spi.txt") / $(wc -l < "$OUT/a2/spi.txt") frames)"
else fail "(a) other poll counts: $(head -20 "$OUT/diff.txt")"; fi
if dodiff "$OUT/a/norm.txt" "$OUT/b/norm.txt"; then
	pass "(a) variant a vs b (poll counts, file names and sizes, %02X) with the rules: empty diff"
else fail "(a) variant a vs b: $(head -20 "$OUT/diff.txt")"; fi
# the poll frames really were dropped and the content kept
if grep -q '^OSD 0 stripe=[0-9a-f]* Minimig Load$' "$OUT/b/norm.txt" && grep -q '^SD CMD17 FIRMWARE+00000000 .. R00$' "$OUT/b/norm.txt" \
	&& ! grep -qE '^SPI (80|10 00 00 00 00 00 00 |20 98 ff / 00 00$)' "$OUT/b/norm.txt" \
	&& [ "$(grep -c '^SPI 20 00 / 00$' "$OUT/b/norm.txt")" = 1 ] && [ "$(grep -c '^SPI 10 10 00 / 10 01$' "$OUT/b/norm.txt")" = 1 ]; then
	pass "(a) norm: OSD text decoded, FIRMWARE run collapsed, poll frames dropped"
else fail "(a) norm content: $(head -40 "$OUT/b/norm.txt")"; fi

# (b) one content change against b: exactly one - line and one + line
for ch in sd fpga osd hw uart keyq status uds desel pre post; do
	gen "$OUT/b_$ch" b "$ch" || exit 1
	norm "$OUT/b_$ch" "$OUT/rules.txt"
	if dodiff "$OUT/b/norm.txt" "$OUT/b_$ch/norm.txt"; then fail "(b) $ch: the change is hidden (empty diff)"; continue; fi
	m=$(grep -c '^-[^-]' "$OUT/diff.txt"); p=$(grep -c '^+[^+]' "$OUT/diff.txt")
	case "$ch" in
		status) want='^\+SPI 10 00 00 00 00 00 00 / 11 ' ;;   # a request: kept, not a poll
		uds) want='^\+SPI 10 10 01 / 10 01$' ;;               # a new drive status: kept
		desel) want='^\+SPI 00 fe / ff$' ;;                   # not deselect clocks: kept
		pre) want='^\+SPI 20 24 06 / 00 00$' ;;
		post) want='^\+UART Loading kickstarts$' ;;
		*) want='^\+' ;;
	esac
	case "$ch" in status|uds|desel) one=1 ;; *) one=0 ;; esac
	if grep -qE "$want" "$OUT/diff.txt" && { [ "$one" = 1 ] || { [ "$m" = 1 ] && [ "$p" = 1 ]; }; }; then
		pass "(b) $ch: $(grep -E '^\+[^+]' "$OUT/diff.txt" | head -1 | cut -c1-100)"
	else fail "(b) $ch: $m - / $p + lines: $(cat "$OUT/diff.txt" | head -12)"; fi
done

# a DROPBLOCK start without its end: an error, not a drop to the end
gen "$OUT/b_unterm" b unterm || exit 1
if norm "$OUT/b_unterm" "$OUT/rules.txt" 2> "$OUT/norm_err.txt"; then fail "(b) unterminated DROPBLOCK: norm exit 0"
elif grep -q 'DROPBLOCK start .* has no end' "$OUT/norm_err.txt"; then pass "(b) unterminated DROPBLOCK: $(cut -c1-90 "$OUT/norm_err.txt")"
else fail "(b) unterminated DROPBLOCK: $(cat "$OUT/norm_err.txt")"; fi
if grep -q '^UART Overriding' "$OUT/b/norm.txt" || ! grep -q '^UART Loading kickstart$' "$OUT/b/norm.txt" || ! grep -q '^SPI 20 24 05 / 00 00$' "$OUT/b/norm.txt"; then
	fail "(a) DROPBLOCK: the block is not dropped, or a line around it is: $(grep -n -A3 -B3 'Kickstart ok' "$OUT/b/norm.txt")"
else pass "(a) DROPBLOCK: the block is dropped, the lines around it stay"; fi

# (c) every rule removed in turn: a difference comes back
n=0
while IFS= read -r line; do
	n=$((n + 1))
	case "$line" in SUBST*|SDFILE*|DROP*) ;; *) continue ;; esac
	sed "${n}d" "$OUT/rules.txt" > "$OUT/rules_minus.txt"
	norm "$OUT/a" "$OUT/rules_minus.txt" 2> "$OUT/norm_err.txt"; ra=$?
	norm "$OUT/b" "$OUT/rules_minus.txt" 2>> "$OUT/norm_err.txt"; rb=$?
	if [ "$ra" -ne 0 ] || [ "$rb" -ne 0 ]; then fail "(c) without line $n ($line): norm failed: $(cat "$OUT/norm_err.txt")"; continue; fi
	if dodiff "$OUT/a/norm.txt" "$OUT/b/norm.txt"; then fail "(c) without line $n ($line): still an empty diff"
	else pass "(c) without line $n ($line): $(grep -cE '^[-+][^-+]' "$OUT/diff.txt") diff lines come back"; fi
done < "$OUT/rules.txt"

# (c) an unused rule is reported; with all rules used, none is
norm "$OUT/a" "$OUT/rules.txt"; norm "$OUT/b" "$OUT/rules.txt"
if dodiff --unused-rules "$OUT/a/norm.txt" "$OUT/b/norm.txt" && grep -q '^rules: all 7 used$' "$OUT/diff.txt"; then
	pass "(c) --unused-rules: all 7 rules used"
else fail "(c) --unused-rules: $(cat "$OUT/diff.txt")"; fi
{ cat "$OUT/rules.txt"; printf '\n# fixture: a rule no difference needs\nDROP uart nothing\\x20matches\\x20this\n'; } > "$OUT/rules_extra.txt"
norm "$OUT/a" "$OUT/rules_extra.txt"; norm "$OUT/b" "$OUT/rules_extra.txt"
if dodiff --unused-rules "$OUT/a/norm.txt" "$OUT/b/norm.txt"; then fail "(c) an unused rule: exit 0"
elif grep -q '^UNUSED 17: DROP uart nothing' "$OUT/diff.txt" && [ "$(grep -c '^UNUSED' "$OUT/diff.txt")" = 1 ]; then
	pass "(c) an unused rule: $(grep '^UNUSED' "$OUT/diff.txt")"
else fail "(c) an unused rule: $(cat "$OUT/diff.txt")"; fi

# a rule without a comment line is refused
printf 'SDFILE FWA.BIN FIRMWARE\n' > "$OUT/rules_nocomment.txt"
if norm "$OUT/a" "$OUT/rules_nocomment.txt" 2> "$OUT/norm_err.txt"; then fail "a rule without a comment: accepted"
else pass "a rule without a comment: refused ($(cut -c1-80 "$OUT/norm_err.txt"))"; fi

# osd: the page text, as norm decodes it
norm "$OUT/b" "$OUT/rules.txt"
python3 -I "$ST" osd "$OUT/b/spi.txt" > "$OUT/osd.txt"
if [ "$(cat "$OUT/osd.txt")" = "$(printf -- '--- page 1\n0 stripe=%s Minimig Load' "$(sed -n 's/^OSD 0 stripe=\([0-9a-f]*\) .*/\1/p' "$OUT/b/norm.txt")")" ]; then
	pass "osd: $(tail -1 "$OUT/osd.txt")"
else fail "osd: $(cat "$OUT/osd.txt")"; fi

if [ "$bad" = 0 ]; then echo "=== spitrace_test PASS"; exit 0; fi
echo "=== spitrace_test FAILED"
exit 1
