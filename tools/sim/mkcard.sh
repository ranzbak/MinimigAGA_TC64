#!/bin/bash
# mkcard.sh <img> <size_MB> <file>...
# Raw SD card image: MBR, one FAT16 partition at LBA 2048, files in the root
# directory.  No root, no loop devices: sfdisk + mkfs.fat --offset + mtools.
set -euo pipefail
if [ $# -lt 2 ]; then
    echo "usage: $0 <img> <size_MB> [file...]" >&2
    exit 2
fi
img=$1; mb=$2; shift 2
start=2048
total=$((mb * 2048))                    # 512-byte sectors
if [ "$total" -le $((start + 8192)) ]; then
    echo "mkcard: size_MB too small (need >= 5)" >&2; exit 2
fi
PATH=$PATH:/usr/sbin:/sbin
for t in sfdisk mkfs.fat mcopy truncate; do
    command -v "$t" >/dev/null 2>&1 || { echo "mkcard: $t not found" >&2; exit 2; }
done
rm -f "$img"
truncate -s "$((total * 512))" "$img"
printf 'label: dos\nunit: sectors\n%s : start=%d, size=%d, type=6\n' \
    "$img" "$start" "$((total - start))" | sfdisk --quiet "$img" >/dev/null
# FAT16 needs >= 4085 clusters: largest cluster size (sectors) that keeps >= 4200
spc=1
while [ $(((total - start) / (spc * 2))) -ge 4200 ] && [ "$spc" -lt 64 ]; do spc=$((spc * 2)); done
# mkfs.fat takes the size in 1 KiB blocks
mkfs.fat -F 16 -s "$spc" -n MINIMIG --offset="$start" "$img" "$(((total - start) / 2))" >/dev/null
# mkfs.fat leaves "hidden sectors" (BPB offset 28) at 0: set it to the partition start
printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((start & 255)) $((start >> 8 & 255)) 0 0)" |
    dd of="$img" bs=1 seek=$((start * 512 + 28)) conv=notrunc status=none
export MTOOLS_SKIP_CHECK=1
for f in "$@"; do
    mcopy -i "$img@@$((start * 512))" -o "$f" ::
done
echo "mkcard: $img ${mb} MB, FAT16 at LBA $start, $# file(s)"
