#!/bin/bash
# cdcard.sh <img> <dir> <mkcard.sh>: cdpath_test's card (findings/sdcard-engine
# Task 11b) from gold/cdcard.py's files in <dir>: a 32 MB mkcard.sh card
# (FAT16, 4 KB clusters) with FILL1.BIN and FILL2.BIN; FILL1.BIN deleted, then
# TEST.ISO, DISC.CUE and TRACK2.WAV copied: TEST.ISO fills FILL1's three
# clusters first and goes on after FILL2's, a gap in its chain.  The check
# at the end refuses an image whose TEST.ISO chain has no gap.  Byte for
# byte the same for the same files (mkcard.sh's rules, SOURCE_DATE_EPOCH).
set -euo pipefail
img=$1; dir=$2; mkcard=$3
bash "$mkcard" "$img" 32 "$dir/FILL1.BIN" "$dir/FILL2.BIN" > /dev/null
export MTOOLS_SKIP_CHECK=1
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600} TZ=UTC
off=$((2048 * 512))
mdel -i "$img@@$off" ::FILL1.BIN
for f in TEST.ISO DISC.CUE TRACK2.WAV; do
    mcopy -i "$img@@$off" -o "$dir/$f" ::
done
chain=$(mshowfat -i "$img@@$off" ::TEST.ISO)
case "$chain" in
    *"> <"*) ;;
    *) echo "cdcard: TEST.ISO is not fragmented: $chain" >&2; exit 1 ;;
esac
echo "cdcard: $img, TEST.ISO $chain"
