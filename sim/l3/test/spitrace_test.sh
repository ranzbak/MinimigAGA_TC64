#!/bin/bash
# Fixtures for the differential tools (sim/host_bridge/spitrace.py norm /
# diff / osd, sim/l3 README "Differential"):
#   (a) the same frames with other poll counts (and other firmware / config
#       file names, sizes and printf forms, covered by the fixture's rules;
#       and the timing of a floppy read DMA, as sim/l3 fdd_rd p4t13 / p4t13c:
#       other countdown bytes in the status and sector frames, other numbers
#       of AUDIO rewrites and of HandleRTC units, a FLOAT group elsewhere
#       among the frames, another audio ring; and the timing of a floppy
#       write DMA, as sim/l3 fdd_wr p4t14 / p4t14c: the FIFO read in other
#       pieces, other polls while it fills; the head positions seen during
#       a seek; and as sim/l3 hdd p4t15 / p4t15c, one more poll without a
#       request after an IDE request was served; and as sim/l3 cd p4t16 /
#       p4t16c, an IDE flag poll whose MISO byte 0 has the IDE command bit
#       clear in one run and set in the other; and as sim/l3 cdda p4t17 /
#       p4t17c, more repeated IDE flag polls (CD_AudioPoll, one per
#       main-loop pass, an RTC frame among them) and another paused position
#       inside the READ SUB-CHANNEL .. ENA block) -> an empty diff
#   (b) one changed byte in an SD read, an FPGA data frame, an OSD text
#       line, a hw write, a UART line, a KEYQ event, a status frame with a
#       request, a changed drive status, a deselect frame that is not all
#       ff, and the lines just before and after a DROPBLOCK block -> each a
#       diff line: the normaliser hides no content; a DROPBLOCK start
#       without its end -> norm fails.  Task 13: a changed sector data
#       byte, a changed track byte in a status frame whose DMA bytes are
#       masked, a changed AUDIO (ffffb0) value among its rewrites, a changed
#       SD-init speed write (ffffe8, the RTC unit's addresses but no RTC
#       frame), a changed, an extra and a missing write of the FLOAT group,
#       (final review I1) an INTERRUPT-register write (DisableInterrupts)
#       moved across an Akiko ack or across a frame,
#       a repeated HandleRTC unit with a changed RTC value or a changed
#       closing speed write -> each a diff line.  Task 14: a changed word
#       read from the write FIFO, a changed track byte in a write frame, a
#       missing write frame, a seek that ends elsewhere, a head position
#       that goes back or flips the head bit during a seek -> each a diff
#       line.  Task 15: a changed track byte in that poll after the served
#       IDE request -> a diff line.  Task 16: in the IDE flag poll a changed
#       flags byte (MISO 8) and a changed other bit of MISO byte 0 -> each a
#       diff line.  Task 17: a changed flags byte in one of the repeated flag
#       polls, the lines just before and after the READ SUB-CHANNEL .. ENA
#       block -> each a diff line; that block without its ENA write -> norm
#       fails
#   (c) each rule of the fixture's expected-diff list removed in turn -> its
#       difference comes back; an unused rule -> diff --unused-rules reports it;
#       a SUBST after the FLOAT rewrites the floated writes too, a DEDUP after
#       it that matches a floated write -> norm fails
# The card is built with tools/sim/mkcard.sh (sfdisk, mkfs.fat, mtools), the
# frames by the generator below.  Run from anywhere:
#   bash sim/l3/test/spitrace_test.sh
# Prints "PASS <case>" / "FAIL <case>" lines and "=== spitrace_test PASS"
# (exit 0) or "=== spitrace_test FAILED" (exit 1).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ST=${SPITRACE:-$ROOT/sim/host_bridge/spitrace.py}   # SPITRACE: another spitrace.py (the RED run)
CHARROM="$ROOT/fw/ctrl_rv/charrom.h"
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
        trk = 0x02 if change == "track" and npoll == 3 else 0x01     # no request, track changed
        mot = 0x01 if change == "motor" and npoll == 3 else 0x00     # no request, motor on
        frame(0x10, [0] * 6, [st, trk, 0x44, 0x89, mot, 0])
        frame(0x10, [0x10, 0x01 if change == "uds" and npoll == 3 else 0x00], [0x10, 0x01])
        frame(0x20, [0x00], [0x50 if change == "level" and npoll == 3 else 0x00])   # OSD_CMD_READ level
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
hwrite("ffffe8", 0x003F)                  # SPI_slow: the RTC unit's addresses, no RTC frame
sd(0, 0, 0x01)
sd(8, 0x1AA, 0x01, (0, 0, 1, 0xAA))
sd(58, 0, 0x00, (0xC0, 0xFF, 0x80, 0x00))
hwrite("ffffe8", 0x0002 if change == "sdspeed" else 0x0001)
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
# a floppy read DMA (sim/l3 fdd_rd): paula's countdown bytes, the AUDIO
# rewrites and the HandleRTC units differ by variant (timing), the FLOAT
# group sits elsewhere (variant b: at the end)
trk = 0x05
frame(0x10, [0] * 6, [0x10, trk, 0x44, 0x89, 0x00, 0x01])            # motor on, no DMA yet
for k, cnt in enumerate([0xBE, 0xBC, 0xBA] if b else [0xBE]):        # DMA on, no request yet
    frame(0x10, [0] * 6, [0x10, 0x06 if change == "dmatrack" and k == 0 else trk, 0x44, 0x89, 0x98, cnt])
frame(0x10, [0] * 6, [0x11, trk, 0x44, 0x89, 0x98, 0xBA if b else 0xBE])   # the request
sec = [0xAA] * 4 + [0x44, 0x89, 0x44, 0x89] + [(0x55 + 3 * i) & 0xFF for i in range(40)]
if change == "sector":
    sec[20] ^= 0x01
miso = [0x11, trk, 0x44, 0x89] + [x for i in range(len(sec) // 2 + 1) for x in (0x98, (0xBE - i // (3 if b else 2)) & 0xFF)]
frame(0x10, [0] * 6 + sec, miso[:6 + len(sec)])
# a floppy write DMA (sim/l3 fdd_wr): the FIFO's words read in other pieces
# and other polls while it fills (variant b), a hw write between two
# sectors (the SD write's place): FindSync / GetHeader / GetData frames
wtrk = 0x07
wst = [(0x2A + 5 * i) & 0xFF for i in range(64)]                      # 32 FIFO words
if change == "wrdata":
    wst[34] ^= 0x01
frame(0x10, [0] * 6, [0x10, wtrk, 0x44, 0x89, 0x00, 0x01])           # motor on, no write yet
for part, cuts in enumerate(([0, 0, 4, 10, 30], [30, 30, 46, 64]) if b else ([0, 12, 30], [30, 40, 64])):
    for k, (lo, hi) in enumerate(zip(cuts, cuts[1:])):
        if change == "wrmiss" and part == 1 and k == len(cuts) - 2:
            continue
        t = 0x08 if change == "wrhdr" and part == 0 and k == 0 else wtrk
        frame(0x10, [0] * (6 + hi - lo), [0x12, t, 0x44, 0x89, 0x80, (hi - lo) // 2] + wst[lo:hi])
    if part == 0:
        hwrite("ffffe8", 0x0101)                                      # between two sectors
frame(0x10, [0, 0], [0x10, wtrk])                                     # FindSync: the write is over
# a seek right after the write (sim/l3 fdd_wr): the head steps 3 ms apart,
# variant a polls once per step, variant b sees only some positions; the
# seek ends at track 0x30 (change seekend: 0x32; seekback: one position
# goes back; seekhead: the head bit flips during the seek)
for t in ([0x20, 0x22, 0x24, 0x26, 0x28, 0x2a, 0x2c, 0x2e, 0x30] if not b else [0x26, 0x2c, 0x30]):
    if change == "seekend" and t == 0x30:
        t = 0x32
    if change == "seekback" and t == 0x2c:
        t = 0x24
    if change == "seekhead" and t == 0x2c:
        t = 0x2d
    frame(0x10, [0] * 6, [0x10, t, 0x44, 0x89, 0x00, 0x01])
    frame(0x10, [0x10, 0x00], [0x10, 0x01])                          # UpdateDriveStatus (dropped)
for k in range(4 if b else 2):                                       # AUDIO = ENA, rewritten every pass
    hwrite("ffffb0", 0x0005 if change == "audio" and k == 1 else 0x0001)
def rtc_unit(last):                                                  # HandleRTC: speed, RTC regs, frame, speed
    hwrite("ffffe8", 0x003F)
    for a, v in (("ffff7c", 0x0000), ("ffff78", 0x0100), ("ffff74", 0x2601), ("ffff70", 0x4004)):
        hwrite(a, 0x4005 if change == "rtcval" and last and a == "ffff70" else v)
    frame(0x80, [0x92] + [0xFF] * 7, [0xFF, 0, 0, 0, 1, 4, 1, 0x26])
    hwrite("ffffe8", 0x0002 if change == "rtcspeed" and last else 0x0001)
n_rtc = 2 if b else 1
for k in range(n_rtc):                    # the changes are in b's second (a repeated) unit
    rtc_unit(k == n_rtc - 1 and k > 0)
    polls(1)
def float_group():
    hwrite("ffff60", 0x0b72)
    if change != "floatmiss":
        hwrite("ffff60", 0x0243 if change == "float" else 0x0242)
    if change == "floatextra":
        hwrite("ffff60", 0x1100)
    hwrite("ffffa0", 0x0000)
if not b:
    float_group()
data = bytearray(sector(c.file_lbas("DATA.BIN")[1]))
if change == "sd":
    data[100] ^= 0x01
sd(17, c.file_lbas("DATA.BIN")[1], 0x00, data=bytes(data))
frame(0x00, [0xFE if change == "desel" else 0xFF], [0xFF])     # cs 00, not all ff: kept
frame(0x10, [0x00, 0x05 if change == "fpga" else 0x04, 0x00], [0x10, 0x00, 0x00])
# an IDE command served (sim/l3 hdd, p4t15 / p4t15c): the request frame,
# the register read, then the firmware's wait loop: variant b (the faster
# CPU) polls once before the 68k has emptied the FIFO (no request), a not
frame(0x10, [0] * 6, [0x14, 0x01, 0x44, 0x89, 0x00, 0x00])
frame(0x10, [0x80] + [0] * 5, [0x14, 0x01, 0x44, 0x89, 0x00, 0x00])
if b:
    frame(0x10, [0] * 6, [0x10, 0x02 if change == "idetrack" else 0x01, 0x44, 0x89, 0x00, 0x00])
frame(0x10, [0] * 6, [0x14, 0x01, 0x44, 0x89, 0x00, 0x00])
# the Akiko ISR (sim/l3 akiko; main.c inthandler(): DisableInterrupts, the
# request's UART line, its ack, c64keys' KEYBOARD_OUT, EnableInterrupts)
# right after a frame and not next to an I2C write: the FLOAT rule (anchor
# ffff60) leaves it in its place.  change irqack: the DisableInterrupts
# after the ack; irqframe: before the frame
if change == "irqframe":
    hwrite("ffffa0", 0x0000)
frame(0x20, [0x28, 0x00], [0x00, 0x00])
if change not in ("irqframe", "irqack"):
    hwrite("ffffa0", 0x0000)
say("Akiko write: C020, 9E37")
hwrite("ffff84", 0x0000)
if change == "irqack":
    hwrite("ffffa0", 0x0000)
hwrite("ffff90", 0x009b)
hwrite("ffffa0", 0x0001)
# an IDE flag poll (hdd.c ReadIDEFlags(1), cdrom.c cd_wait(); sim/l3 cd,
# p4t16 / p4t16c): variant b (the faster CPU) starts it before the 68k has
# read the data phase's last word, so MISO byte 0's IDE command bit (0x04)
# is still clear; MISO byte 8 is the flags byte the firmware reads
b0 = (0x11 if change == "cdbit" else 0x10) if b else 0x14
frame(0x10, [0x81] + [0] * 9, [b0, 0x01, 0x44, 0x89, 0x00, 0x00, 0x20, 0x20, 0x51 if change == "cdflags" else 0x53, 0x00])
osd(0, "Minimig " + ("Lead" if change == "osd" else "Load"))
polls(1 if b else 4)
frame(0x20, [0x98, 0xFF, 0xFF], [0x00, 0x01, 0x46 if change == "keyq" else 0x45])
# CD audio (sim/l3 cdda, p4t17 / p4t17c): while the player runs,
# CD_AudioPoll reads the CD port's flags on every main-loop pass, so
# variant b (the faster CPU) makes more of these polls, with a repeated
# HandleRTC unit among them (its frame and hw writes are dropped: they do
# not end the run of repeats); change cdpoll: one of them sees other
# flags; cdpollhw / cdpolluart: an AUDIO write / a UART line between two
# of them (kept, so the next poll is kept too)
for k in range(6 if b else 2):
    frame(0x10, [0] * 6, [0x10, 0x01, 0x44, 0x89, 0x00, 0x00])
    if b and k == 3:
        rtc_unit(False)
    if b and k == 2 and change == "cdpollhw":
        hwrite("ffffb0", 0x0009)
    if b and k == 2 and change == "cdpolluart":
        say("CDA: underrun 1")
    frame(0x10, [0x81] + [0] * 9, [0x10, 0x01, 0x44, 0x89, 0x00, 0x00, 0x00, 0x00,
                                   0x11 if change == "cdpoll" and k == 3 else 0x13, 0x00])
# the PAUSE's READ SUB-CHANNEL reply up to the RESUME's ENA (Task 17 P2):
# another paused LBA and other TEST.BIN blocks per variant; changes subpre /
# subpost: the frames just before and after the block; subunterm: no ENA
frame(0x10, [0xF1, 0x09 if change == "subpre" else 0x08, 0, 0, 0, 0], [0x14, 0x01, 0x44, 0x89, 0x00, 0x00])
pos = 0x2C if b else 0x30
frame(0x10, [0xA1, 0, 0, 0, 0, 0, 0, 0x12, 0, 0x0C, 0x01, 0x10, 0x02, 0x01, 0, 0, 0x01, pos, 0, 0, 0, pos - 0xD6 + 0x100 if pos < 0xD6 else pos - 0xD6],
      [0x14, 0x01, 0x44, 0x89, 0x00, 0x00] + [0] * 16)
hwrite("ffffb0", 0x0002)                  # CLEAR (the RESUME's run())
for lba in ((c.root + 3, c.root + 4) if b else (c.root + 4,)):
    sd(17, lba, 0x00, data=sector(lba))
if change != "subunterm":
    hwrite("ffffb0", 0x0001)              # ENA
frame(0x10, [0x91] + [0] * 9 + [0x03, 0, 0, 0, 0xFE if change != "subpost" else 0xFC, 0, 0xFF, 0, 0xA0],
      [0x14, 0x01, 0x44, 0x89, 0x00, 0x00] + [0] * 13)
say("Kickstart " + ("okay" if change == "uart" else "ok"))
say("caf" + ("\xea" if change == "hibyte" else "\xe9"))           # a UART byte >= 0x80
frame(0x20, [0x24, 0x06 if change == "pre" else 0x05], [0x00, 0x00])   # just before the block
if b:                                     # a block only variant b has (DROPBLOCK)
    say("Overriding screenmode.")
    frame(0x20, [0x14, 0x00], [0x00, 0x00])
    hwrite("ffffc0", 0x0001)
    if change != "unterm":
        say("##End result : 0")
say("Loading kickstart" + ("s" if change == "post" else ""))      # just after it
polls(7 if b else 3)
if b:
    float_group()
hw.append("MEM kickstart " + "ab" * 32)
hw.append("MEM audio_ring " + ("cd" if b else "ef") * 32)
for name, lines in (("spi.txt", frames), ("hw.txt", hw), ("uart.txt", uart)):
    with open(os.path.join(d, name), "w", encoding="latin-1") as f:
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

# fixture (sim/l3 fdd_rd, p4t13 / p4t13c): AUDIO rewritten every pass
DEDUP hw ^ffffb0$

# fixture: a write group at another place among the frames
FLOAT hw ^ffff(60|90|a0)$ ^ffff60$

# fixture: the drive sounds' ring
DROP hw ^MEM\x20audio_ring\x20

# fixture (sim/l3 cdda, p4t17 / p4t17c): the paused position's block
DROPBLOCK all ^10\x20a1\x2000\x2000\x2000\x2000\x2000\x2000\x2012\x2000\x200c\x2001\x20 ^ffffb0\x200001$
EOR

bad=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; bad=1; }
norm() {   # norm <run dir> <rules> -> <run dir>/norm.txt
	python3 -I "$ST" norm "$1/spi.txt" "$1/hw.txt" "$1/uart.txt" -r "$2" --card "$OUT/card.img" --charrom "$CHARROM" > "$1/norm.txt"
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
lines = open(src + "/spi.txt", encoding="latin-1").read().splitlines()
out, idx = [], []
def is_poll(l):
    # a status frame with a request (MISO byte 0 bits 3..0) is no poll
    if l.startswith("10 00 00 00 00 00 00 /"):
        return int(l.split("/")[1].split()[0], 16) & 0x0F == 0
    return l.startswith(poll)
for l in lines:
    idx.append(len(out))
    out += [l] * (3 if is_poll(l) else 1)
open(dst + "/spi.txt", "w", encoding="latin-1").write("".join(l + "\n" for l in out))
for name in ("hw.txt", "uart.txt"):
    res = []
    for l in open(src + "/" + name, encoding="latin-1").read().splitlines():
        w = l.split(" ", 1)
        if w[0].isdigit():
            n = int(w[0])
            l = "%d %s" % (idx[n] if n < len(idx) else len(out), w[1])
        res.append(l)
    open(dst + "/" + name, "w", encoding="latin-1").write("".join(l + "\n" for l in res))
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
	&& ! grep -qE '^SPI (80|20 98 ff / 00 00$)' "$OUT/b/norm.txt" \
	&& [ "$(grep -c '^SPI 10 00 00 00 00 00 00 / 10 01 44 89 00 00$' "$OUT/b/norm.txt")" = 2 ] \
	&& [ "$(grep -c '^SPI 20 00 / 00$' "$OUT/b/norm.txt")" = 1 ] && [ "$(grep -c '^SPI 10 10 00 / 10 01$' "$OUT/b/norm.txt")" = 1 ]; then
	pass "(a) norm: OSD text decoded, FIRMWARE run collapsed, poll frames dropped"
else fail "(a) norm content: $(head -40 "$OUT/b/norm.txt")"; fi

# (b) one content change against b: exactly one - line and one + line
for ch in sd fpga osd hw uart keyq status uds desel pre post track motor level hibyte \
	sector dmatrack audio sdspeed float floatextra floatmiss irqack irqframe rtcval rtcspeed wrdata wrhdr wrmiss \
	seekend seekback seekhead idetrack cdflags cdbit cdpoll subpre subpost; do
	gen "$OUT/b_$ch" b "$ch" || exit 1
	norm "$OUT/b_$ch" "$OUT/rules.txt"
	if dodiff "$OUT/b/norm.txt" "$OUT/b_$ch/norm.txt"; then fail "(b) $ch: the change is hidden (empty diff)"; continue; fi
	m=$(grep -c '^-[^-]' "$OUT/diff.txt"); p=$(grep -c '^+[^+]' "$OUT/diff.txt")
	case "$ch" in
		status) want='^\+SPI 10 00 00 00 00 00 00 / 11 ' ;;   # a request: kept, not a poll
		uds) want='^\+SPI 10 10 01 / 10 01$' ;;               # a new drive status: kept
		track) want='^\+SPI 10 00 00 00 00 00 00 / 10 02 44 89 00 00$' ;;   # no request, other track: kept
		motor) want='^\+SPI 10 00 00 00 00 00 00 / 10 01 44 89 01 00$' ;;   # no request, motor on: kept
		level) want='^\+SPI 20 00 / 50$' ;;                   # another key level: kept
		hibyte) want=$'^\\+UART caf\xea$' ;;
		desel) want='^\+SPI 00 fe / ff$' ;;                   # not deselect clocks: kept
		pre) want='^\+SPI 20 24 06 / 00 00$' ;;
		post) want='^\+UART Loading kickstarts$' ;;
		dmatrack) want='^\+SPI 10 00 00 00 00 00 00 / 10 06 44 89 -- --$' ;;   # masked DMA bytes, other track: kept
		audio) want='^\+HW ffffb0 0005$' ;;
		sdspeed) want='^\+HW ffffe8 0002$' ;;
		float) want='^\+HW float ffff60 0b72 ffff60 0243 ffffa0 0000$' ;;   # a floated run: one line
		floatextra) want='^\+HW float ffff60 0b72 ffff60 0242 ffff60 1100 ffffa0 0000$' ;;
		floatmiss) want='^\+HW float ffff60 0b72 ffffa0 0000$' ;;
		irqack|irqframe) want='^\+HW ffffa0 0000$' ;;   # the DisableInterrupts in its new place
		rtcval) want='^\+HW ffff70 4005$' ;;      # a repeated HandleRTC unit with another value: kept
		rtcspeed) want='^\+HW ffffe8 0002$' ;;
		wrdata) want='^\+SPI 10 wrfifo 12 07 44 89 / 34 ' ;;      # the second sector's words, one changed
		wrhdr) want='^\+SPI 10 wrfifo 12 08 44 89 / ' ;;           # another track byte: its own line
		wrmiss) want='^\+SPI 10 wrfifo 12 07 44 89 / 16 ' ;;       # the second sector's bytes, the last 18 missing
		seekend) want='^\+SPI 10 00 00 00 00 00 00 / 10 32 44 89 00 01$' ;;   # the seek ends elsewhere
		seekback) want='^\+SPI 10 00 00 00 00 00 00 / 10 24 44 89 00 01$' ;;  # a position that goes back: kept
		seekhead) want='^\+SPI 10 00 00 00 00 00 00 / 10 2d 44 89 00 01$' ;;  # the head bit flips: kept
		idetrack) want='^\+SPI 10 00 00 00 00 00 00 / 10 02 44 89 00 00$' ;;   # served IDE request, other track: kept
		cdflags) want='^\+SPI 10 81 00 00 00 00 00 00 00 00 00 / 10 01 44 89 00 00 20 20 51 00$' ;;   # IDE flag poll, other flags: kept
		cdbit) want='^\+SPI 10 81 00 00 00 00 00 00 00 00 00 / 11 01 44 89 00 00 20 20 53 00$' ;;    # other bit of MISO byte 0: kept
		cdpoll) want='^\+SPI 10 81 00 00 00 00 00 00 00 00 00 / 10 01 44 89 00 00 00 00 11 00$' ;;   # a repeated flag poll, other flags: kept
		subpre) want='^\+SPI 10 f1 09 ' ;;        # just before the READ SUB-CHANNEL block
		subpost) want='^\+SPI 10 91 .* fc 00 ff 00 a0 /' ;;   # just after it
		*) want='^\+' ;;
	esac
	case "$ch" in status|uds|desel|track|motor|level|dmatrack|audio|floatextra|floatmiss|rtcval|rtcspeed|wrhdr|seekback|seekhead|idetrack|cdpoll) one=1 ;; *) one=0 ;; esac
	if grep -qE "$want" "$OUT/diff.txt" && { [ "$one" = 1 ] || { [ "$m" = 1 ] && [ "$p" = 1 ]; }; }; then
		pass "(b) $ch: $(grep -E '^\+[^+]' "$OUT/diff.txt" | head -1 | cut -c1-100)"
	else fail "(b) $ch: $m - / $p + lines: $(cat "$OUT/diff.txt" | head -12)"; fi
done

# Task 17 review I1: a kept hw write or UART line between two equal flag
# polls ends the run of repeats: the line and the poll after it come back
for ch in cdpollhw cdpolluart; do
	gen "$OUT/b_$ch" b "$ch" || exit 1
	norm "$OUT/b_$ch" "$OUT/rules.txt"
	if [ "$ch" = cdpollhw ]; then want='^\+HW ffffb0 0009$'; else want='^\+UART CDA: underrun 1$'; fi
	if ! dodiff "$OUT/b/norm.txt" "$OUT/b_$ch/norm.txt" && grep -qE "$want" "$OUT/diff.txt" \
		&& grep -A1 -E "$want" "$OUT/diff.txt" | tail -n 1 | grep -q '^+SPI 10 81 00 00 00 00 00 00 00 00 00 / 10 01 44 89 00 00 00 00 13 00$' \
		&& [ "$(grep -c '^-[^-]' "$OUT/diff.txt")" = 0 ] && [ "$(grep -c '^+[^+]' "$OUT/diff.txt")" = 2 ]; then
		pass "(b) $ch: $(grep -E '^\+[^+]' "$OUT/diff.txt" | tr '\n' ' ' | cut -c1-120)"
	else fail "(b) $ch: $(head -12 "$OUT/diff.txt")"; fi
done

# a DROPBLOCK start without its end: an error, not a drop to the end
gen "$OUT/b_unterm" b unterm || exit 1
if norm "$OUT/b_unterm" "$OUT/rules.txt" 2> "$OUT/norm_err.txt"; then fail "(b) unterminated DROPBLOCK: norm exit 0"
elif grep -q 'DROPBLOCK start .* has no end' "$OUT/norm_err.txt"; then pass "(b) unterminated DROPBLOCK: $(cut -c1-90 "$OUT/norm_err.txt")"
else fail "(b) unterminated DROPBLOCK: $(cat "$OUT/norm_err.txt")"; fi
gen "$OUT/b_subunterm" b subunterm || exit 1
if norm "$OUT/b_subunterm" "$OUT/rules.txt" 2> "$OUT/norm_err.txt"; then fail "(b) READ SUB-CHANNEL block without its ENA: norm exit 0"
elif grep -q 'DROPBLOCK start .* has no end' "$OUT/norm_err.txt"; then pass "(b) READ SUB-CHANNEL block without its ENA: $(cut -c1-90 "$OUT/norm_err.txt")"
else fail "(b) READ SUB-CHANNEL block without its ENA: $(cat "$OUT/norm_err.txt")"; fi
# the repeated flag polls collapse to one line, the block is dropped
if [ "$(grep -c '^SPI 10 81 00 00 00 00 00 00 00 00 00 / 10 01 44 89 00 00 00 00 13 00$' "$OUT/b/norm.txt")" = 1 ] \
	&& grep -q '^# dropped .*flagpoll 5,' "$OUT/b/norm.txt" && ! grep -q '^SPI 10 a1 ' "$OUT/b/norm.txt" \
	&& grep -A1 '^SPI 10 f1 08 ' "$OUT/b/norm.txt" | tail -n 1 | grep -q '^SPI 10 91 .* fe 00 ff 00 a0 /'; then
	pass "(a) flag poll repeats: one line kept (flagpoll 5 dropped); READ SUB-CHANNEL block dropped, its neighbours kept"
else fail "(a) flag polls / READ SUB-CHANNEL block: $(grep -nE '^(SPI 10 (81|a1|f1|91)|HW ffffb0|# dropped)' "$OUT/b/norm.txt")"; fi
if grep -q '^UART Overriding' "$OUT/b/norm.txt" || ! grep -q '^UART Loading kickstart$' "$OUT/b/norm.txt" || ! grep -q '^SPI 20 24 05 / 00 00$' "$OUT/b/norm.txt"; then
	fail "(a) DROPBLOCK: the block is not dropped, or a line around it is: $(grep -n -A3 -B3 'Kickstart ok' "$OUT/b/norm.txt")"
else pass "(a) DROPBLOCK: the block is dropped, the lines around it stay"; fi

# (c) every rule removed in turn: a difference comes back
n=0
while IFS= read -r line; do
	n=$((n + 1))
	case "$line" in SUBST*|SDFILE*|DROP*|DEDUP*|FLOAT*) ;; *) continue ;; esac
	sed "${n}d" "$OUT/rules.txt" > "$OUT/rules_minus.txt"
	norm "$OUT/a" "$OUT/rules_minus.txt" 2> "$OUT/norm_err.txt"; ra=$?
	norm "$OUT/b" "$OUT/rules_minus.txt" 2>> "$OUT/norm_err.txt"; rb=$?
	if [ "$ra" -ne 0 ] || [ "$rb" -ne 0 ]; then fail "(c) without line $n ($line): norm failed: $(cat "$OUT/norm_err.txt")"; continue; fi
	if dodiff "$OUT/a/norm.txt" "$OUT/b/norm.txt"; then fail "(c) without line $n ($line): still an empty diff"
	else pass "(c) without line $n ($line): $(grep -cE '^[-+][^-+]' "$OUT/diff.txt") diff lines come back"; fi
done < "$OUT/rules.txt"

# (c) an unused rule is reported; with all rules used, none is
norm "$OUT/a" "$OUT/rules.txt"; norm "$OUT/b" "$OUT/rules.txt"
if dodiff --unused-rules "$OUT/a/norm.txt" "$OUT/b/norm.txt" && grep -q '^rules: all 11 used$' "$OUT/diff.txt"; then
	pass "(c) --unused-rules: all 11 rules used"
else fail "(c) --unused-rules: $(cat "$OUT/diff.txt")"; fi
{ cat "$OUT/rules.txt"; printf '\n# fixture: a rule no difference needs\nDROP uart nothing\\x20matches\\x20this\n'; } > "$OUT/rules_extra.txt"
norm "$OUT/a" "$OUT/rules_extra.txt"; norm "$OUT/b" "$OUT/rules_extra.txt"
if dodiff --unused-rules "$OUT/a/norm.txt" "$OUT/b/norm.txt"; then fail "(c) an unused rule: exit 0"
elif grep -q '^UNUSED 29: DROP uart nothing' "$OUT/diff.txt" && [ "$(grep -c '^UNUSED' "$OUT/diff.txt")" = 1 ]; then
	pass "(c) an unused rule: $(grep '^UNUSED' "$OUT/diff.txt")"
else fail "(c) an unused rule: $(cat "$OUT/diff.txt")"; fi

# rules after the FLOAT (final review I1): a SUBST rewrites the floated
# writes too; a DEDUP that matches a floated write is an error
{ cat "$OUT/rules.txt"; printf '\n# fixture: a SUBST after the FLOAT\nSUBST hw ^ffffa0\\x200000$ ffffa0 dis\n'; } > "$OUT/rules_fsubst.txt"
norm "$OUT/b" "$OUT/rules_fsubst.txt"
if grep -q '^HW float ffff60 0b72 ffff60 0242 ffffa0 dis$' "$OUT/b/norm.txt" && grep -q '^HW ffffa0 dis$' "$OUT/b/norm.txt" \
	&& grep -q '^# rule 29 used [2-9]' "$OUT/b/norm.txt"; then
	pass "(c) a SUBST after the FLOAT: the floated run and the in-place write rewritten"
else fail "(c) a SUBST after the FLOAT: $(grep -E '^(HW (float|ffffa0)|# rule 29)' "$OUT/b/norm.txt")"; fi
{ cat "$OUT/rules.txt"; printf '\n# fixture: a DEDUP after the FLOAT\nDEDUP hw ^ffffa0$\n'; } > "$OUT/rules_fdedup.txt"
if norm "$OUT/b" "$OUT/rules_fdedup.txt" 2> "$OUT/norm_err.txt"; then fail "(c) a DEDUP after the FLOAT matching a floated write: norm exit 0"
elif grep -q 'DEDUP matches the floated line HW ffffa0 0000' "$OUT/norm_err.txt"; then pass "(c) a DEDUP after the FLOAT: $(cut -c1-90 "$OUT/norm_err.txt")"
else fail "(c) a DEDUP after the FLOAT: $(cat "$OUT/norm_err.txt")"; fi

# a rule without a comment line is refused
printf 'SDFILE FWA.BIN FIRMWARE\n' > "$OUT/rules_nocomment.txt"
if norm "$OUT/a" "$OUT/rules_nocomment.txt" 2> "$OUT/norm_err.txt"; then fail "a rule without a comment: accepted"
else pass "a rule without a comment: refused ($(cut -c1-80 "$OUT/norm_err.txt"))"; fi

# osd: the page text, as norm decodes it
norm "$OUT/b" "$OUT/rules.txt"
python3 -I "$ST" osd "$OUT/b/spi.txt" --charrom "$CHARROM" > "$OUT/osd.txt"
if [ "$(cat "$OUT/osd.txt")" = "$(printf -- '--- page 1\n0 stripe=%s Minimig Load' "$(sed -n 's/^OSD 0 stripe=\([0-9a-f]*\) .*/\1/p' "$OUT/b/norm.txt")")" ]; then
	pass "osd: $(tail -1 "$OUT/osd.txt")"
else fail "osd: $(cat "$OUT/osd.txt")"; fi

if [ "$bad" = 0 ]; then echo "=== spitrace_test PASS"; exit 0; fi
echo "=== spitrace_test FAILED"
exit 1
