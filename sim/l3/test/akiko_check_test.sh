#!/usr/bin/env bash
# sim/l3/test/akiko_check_test.sh: the request/UART/hw.txt part of
# `l3check.py akiko` (Task 18 "test first"): a synthetic run directory with
# the log lines bfm_akiko.v and the firmware would produce, passes that part;
# each mutant (one wrong UART word, a lost request, a repeated one, a read
# that returned data, a missing DATA write, a lower-case line, an
# unacked request) makes it fail with its own BAD line.  The fixture has no
# card, dump or OSD frames, so the checks of those print their own BAD lines;
# only the BAD lines about requests, UART, answers and hw.txt are judged.
#   bash sim/l3/test/akiko_check_test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
L3=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

python3 -I - "$T" "$L3" <<'PY'
import os, sys
T, L3 = sys.argv[1:3]
sys.path.insert(0, L3)
import l3check as c

def build(name, cpu="rv", mut=None):
    d = os.path.join(T, name)
    os.makedirs(d)
    log, hw, cyc = ["=== CPU %s" % cpu], [], 1000
    n = 0
    upper = True
    for b in (0, 1):
        for k in range(64):
            kind, addr, data, text = c.aki_expected(b, k, upper)
            q = "0000"
            ack = True
            if mut == "wrongword" and (b, k) == (1, 7):
                text = text.replace("Akiko write: ", "Akiko write: ")[:-1] + ("0" if text[-1] != "0" else "1")
            if mut == "lost" and (b, k) == (0, 5):
                continue
            if mut == "repeat" and (b, k) == (0, 5):
                log.append("UART: " + text)
            if mut == "readdata" and (b, k) == (0, 40):
                q = "00ff"
            if mut == "lowercase_rv" and (b, k) == (0, 3):
                text = text.lower()
            if mut == "noack" and (b, k) == (0, 9):
                ack = False
            lat = 250000 + 7 * k if ack else 0
            log.append("=== AKIKO req %d %d %s addr %02x d %04x q %s req %d ack %d lat %d rearm %d dma %d"
                       % (b, k, kind, addr, data if kind == "W" else 0x5A5A, q, cyc, cyc + lat, lat, 900 if ack else -1, int(b == 1)))
            log.append("UART: " + text)
            if not (mut == "nodata" and (b, k) == (1, 60)):
                hw.append("%d %d ffff84 0000" % (n, n))
            n += 1
            cyc += lat + 5000
    open(os.path.join(d, "tb_akiko_x0_s8_j0.log"), "w").write("\n".join(log) + "\n")
    open(os.path.join(d, "hw.txt"), "w").write("\n".join(hw) + "\n")

build("good")
build("good832", cpu="832")
for m in ("wrongword", "lost", "repeat", "readdata", "lowercase_rv", "noack", "nodata"):
    build(m, mut=m)
PY

fail=0
judged() { python3 -I "$L3/l3check.py" akiko "$1" | grep -E '^BAD ' | grep -E 'requests in the log|request [01]/|UART Akiko|DATA|hw.txt|answer' ; }
for g in good good832; do
	out=$(judged "$T/$g")
	if [ -n "$out" ]; then echo "FAIL $g: unexpected BAD lines:"; echo "$out"; fail=1; else echo "ok   $g: no request/UART/hw BAD line"; fi
done
for m in wrongword lost repeat readdata lowercase_rv noack nodata; do
	out=$(judged "$T/$m")
	if [ -z "$out" ]; then echo "FAIL mutant $m: not detected"; fail=1; else echo "ok   mutant $m red: $(echo "$out" | head -1)"; fi
done
[ $fail = 0 ] && echo "=== akiko_check_test PASS" || echo "=== akiko_check_test FAIL"
exit $fail
