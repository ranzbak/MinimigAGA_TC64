#!/bin/bash
# Tooth (g), offline: one SD data byte changed in the 832 run's spi.txt (the
# first data byte after the token of the run's last single-block read,
# CMD17), then the differential of the two runs: it must not be empty.
#   bash sim/l3/teeth/sdbyte.sh <RUNTAG rv> <RUNTAG 832> <out dir>
# The out dir gets a copy of the 832 run's spi.txt / hw.txt / uart.txt with
# the change, both norm files and the diff (diff.txt).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
rv="$HERE/run_$1" c="$HERE/run_$2" out=$(realpath -m -- "$3")
mkdir -p "$out" || exit 2
cp "$c/hw.txt" "$c/uart.txt" "$out/" || exit 2
python3 -I - "$c/spi.txt" "$out/spi.txt" <<'EOP' || exit 2
import sys
lines = open(sys.argv[1], encoding="latin-1").read().split("\n")
k = max(i for i, l in enumerate(lines) if l.startswith("02 ff 51 "))
mosi, miso = lines[k].split(" / ")
b = miso.split(" ")
t = b.index("fe", 8)             # the data token (after the command's R1)
old = b[t + 1]
b[t + 1] = "%02x" % (int(old, 16) ^ 0x01)
lines[k] = mosi + " / " + " ".join(b)
open(sys.argv[2], "w", encoding="latin-1").write("\n".join(lines))
print("sdbyte: spi.txt line %d (CMD17 %s), data byte 0: %s -> %s" % (k + 1, " ".join(mosi.split()[3:7]), old, b[t + 1]))
EOP
card() { sed -n 's/^card: \([^ ]*\).*/\1/p' "$1/results.txt" | head -1; }
python3 -I "$HERE/../host_bridge/spitrace.py" norm "$rv/spi.txt" "$rv/hw.txt" "$rv/uart.txt" \
	-r "$HERE/expected_diff.txt" --card "$(card "$rv")" > "$out/norm_rv.txt" || exit 2
python3 -I "$HERE/../host_bridge/spitrace.py" norm "$out/spi.txt" "$out/hw.txt" "$out/uart.txt" \
	-r "$HERE/expected_diff.txt" --card "$(card "$c")" > "$out/norm_832.txt" || exit 2
python3 -I "$HERE/../host_bridge/spitrace.py" diff "$out/norm_rv.txt" "$out/norm_832.txt" > "$out/diff.txt"
rc=$?
grep -E '^[-+][A-Z]' "$out/diff.txt" | cut -c1-160
if [ "$rc" != 0 ] && grep -qE '^[-+][A-Z]' "$out/diff.txt"; then echo "=== sdbyte FAILS as required (diff not empty)"; exit 0; fi
echo "=== sdbyte: the diff is empty: the change was not seen"; exit 1
