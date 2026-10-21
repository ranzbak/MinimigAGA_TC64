#!/bin/bash
# mkcard.sh <img> <size_MB> <file>...
# Raw SD card image: MBR, one FAT16 partition at LBA 2048, files in the root
# directory.  No root, no loop devices: sfdisk + mkfs.fat --offset + mtools.
# Refused: a size above 2048 MB (FAT16 holds at most 65524 clusters of 32 KB)
# and a file whose name is not an upper-case 8.3 name (the boot ROM and the
# firmware compare the short directory name; mcopy would store a lower-case
# or long name under another short name).
# The image is the same byte for byte for the same arguments and file
# contents: fixed disk identifier (sfdisk label-id), mkfs.fat --invariant
# (volume ID, label time), and the file times from SOURCE_DATE_EPOCH
# (default 2026-01-01 00:00 UTC) in UTC, so two runs of a bench (xsim and
# Verilator, run.sh compare) read the same card.
set -euo pipefail
if [ $# -lt 2 ]; then
    echo "usage: $0 <img> <size_MB> [file...]" >&2
    exit 2
fi
img=$1; mb=$2; shift 2
case "$mb" in
    ''|*[!0-9]*) echo "mkcard: size_MB must be a number: $mb" >&2; exit 2 ;;
esac
start=2048
total=$((mb * 2048))                    # 512-byte sectors
if [ "$total" -le $((start + 8192)) ]; then
    echo "mkcard: size_MB too small (need >= 5)" >&2; exit 2
fi
if [ "$mb" -gt 2048 ]; then
    echo "mkcard: size_MB $mb above the FAT16 limit (2048 MB)" >&2; exit 2
fi
name83='^[A-Z0-9_~!#%&@^$-]{1,8}([.][A-Z0-9_~!#%&@^$-]{1,3})?$'
for f in "$@"; do
    n=$(basename -- "$f")
    if ! [[ "$n" =~ $name83 ]]; then
        echo "mkcard: $n is not an upper-case 8.3 file name" >&2; exit 2
    fi
done
PATH=$PATH:/usr/sbin:/sbin
for t in sfdisk mkfs.fat mcopy truncate; do
    command -v "$t" >/dev/null 2>&1 || { echo "mkcard: $t not found" >&2; exit 2; }
done
rm -f "$img"
truncate -s "$((total * 512))" "$img"
printf 'label: dos\nlabel-id: 0x4d494e49\nunit: sectors\n%s : start=%d, size=%d, type=6\n' \
    "$img" "$start" "$((total - start))" | sfdisk --quiet "$img" >/dev/null
# FAT16 needs >= 4085 clusters: largest cluster size (sectors) that keeps >= 4200
spc=1
while [ $(((total - start) / (spc * 2))) -ge 4200 ] && [ "$spc" -lt 64 ]; do spc=$((spc * 2)); done
# mkfs.fat takes the size in 1 KiB blocks
mkfs.fat -F 16 -s "$spc" -n MINIMIG --invariant --offset="$start" "$img" "$(((total - start) / 2))" >/dev/null
# mkfs.fat leaves "hidden sectors" (BPB offset 28) at 0: set it to the partition start
printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((start & 255)) $((start >> 8 & 255)) 0 0)" |
    dd of="$img" bs=1 seek=$((start * 512 + 28)) conv=notrunc status=none
export MTOOLS_SKIP_CHECK=1
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600} TZ=UTC
for f in "$@"; do
    mcopy -i "$img@@$((start * 512))" -o "$f" ::
done
echo "mkcard: $img ${mb} MB, FAT16 at LBA $start, $# file(s)"
