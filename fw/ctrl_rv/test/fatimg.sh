#!/usr/bin/env bash
# fatimg.sh <dir> <mkcard.sh> <gold dir>: the three card images of fat_test,
# with the same files on each, and their expected listings (gold/fatlist.py,
# i.e. mtools):
#   fat16.img  16 MB, MBR, FAT16 at LBA 2048     tools/sim/mkcard.sh
#   fat32.img 132 MB, MBR, FAT32 at LBA 2048     sfdisk + mkfs.fat -F 32 --offset + mtools
#   super.img  16 MB, FAT16 without MBR          mkfs.fat on the whole file ("superfloppy")
# All three use 4-sector (2 KB) clusters: FileCreate allocates one cluster,
# and fat_test writes a 3-sector file.  FAT32 needs >= 65525 clusters, hence
# 132 MB.  Files (gold/fatdata.py): HELLO.TXT A.BIN MIDDLE.BIN C.BIN, then
# MIDDLE.BIN deleted and BIG.BIN (300 KB) copied, so that it is fragmented
# over the hole (checked here); "Games Collection/Another Level/Deep File
# Name.dat" and "Long Name File.txt" (long names).
# Byte-reproducible like mkcard.sh: fixed disk identifier, mkfs.fat
# --invariant, file times from SOURCE_DATE_EPOCH in UTC.  FAT32: the FSInfo
# free-cluster count and next-free hint are set to "unknown" (0xFFFFFFFF,
# allowed by the FAT spec): mtools then allocates from cluster 2 (fills the
# hole), and fsck.fat does not hold it against the image that FileCreate
# (like the 832 firmware) does not update the count.
set -euo pipefail
if [ $# -ne 3 ]; then echo "usage: $0 <dir> <mkcard.sh> <gold dir>" >&2; exit 2; fi
dir=$1; mkcard=$2; gold=$3
PATH=$PATH:/usr/sbin:/sbin
for t in sfdisk mkfs.fat fsck.fat mcopy mdel mmd mdir mshowfat truncate od dd python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "fatimg: $t not found" >&2; exit 2; }
done
export MTOOLS_SKIP_CHECK=1 TZ=UTC
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}
mkdir -p "$dir"
data=$dir/fatdata
python3 -I "$gold/fatdata.py" "$data"

# poke32 <file> <byte offset> <value>: a little-endian 32-bit store
poke32() {
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($3 & 255)) $(($3 >> 8 & 255)) $(($3 >> 16 & 255)) $(($3 >> 24 & 255)))" |
        dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}
# u16 <file> <byte offset>
u16() { od -An -tu2 -j "$2" -N2 "$1" | tr -d ' '; }

# fsinfo_unknown <img> <partition byte offset>: FAT32 FSInfo counts unknown
fsinfo_unknown() {
    local s; s=$(u16 "$1" $(($2 + 0x30)))
    poke32 "$1" $(($2 + s * 512 + 0x1e8)) 0xFFFFFFFF
    poke32 "$1" $(($2 + s * 512 + 0x1ec)) 0xFFFFFFFF
}

# populate <img> <partition byte offset> <fat32 0|1>: the files after the first four
populate() {
    local i="$1@@$2"
    mdel -i "$i" ::MIDDLE.BIN
    if [ "$3" = 1 ]; then fsinfo_unknown "$1" "$2"; fi
    mcopy -i "$i" "$data/BIG.BIN" ::BIG.BIN
    mmd -i "$i" "::Games Collection"
    mmd -i "$i" "::Games Collection/Another Level"
    mcopy -i "$i" "$data/DEEP.DAT" "::Games Collection/Another Level/Deep File Name.dat"
    mcopy -i "$i" "$data/LONG.TXT" "::Long Name File.txt"
    if [ "$3" = 1 ]; then fsinfo_unknown "$1" "$2"; fi
    local fat; fat=$(mshowfat -i "$i" ::BIG.BIN)
    case $fat in
        *"> <"*) ;;
        *) echo "fatimg: BIG.BIN is not fragmented in $1: $fat" >&2; exit 1 ;;
    esac
}
first4() {  # <img> <partition byte offset>
    local f
    for f in HELLO.TXT A.BIN MIDDLE.BIN C.BIN; do mcopy -i "$1@@$2" "$data/$f" "::$f"; done
}

# fat16.img: mkcard.sh (MBR, FAT16 at LBA 2048) with the first four files
bash "$mkcard" "$dir/fat16.img" 16 "$data/HELLO.TXT" "$data/A.BIN" "$data/MIDDLE.BIN" "$data/C.BIN" >/dev/null
populate "$dir/fat16.img" $((2048 * 512)) 0

# fat32.img: the same way, FAT32 (type 0x0c)
img=$dir/fat32.img
start=2048
total=$((132 * 2048))
rm -f "$img"
truncate -s $((total * 512)) "$img"
printf 'label: dos\nlabel-id: 0x4d494e49\nunit: sectors\n%s : start=%d, size=%d, type=c\n' \
    "$img" "$start" "$((total - start))" | sfdisk --quiet "$img" >/dev/null
mkfs.fat -F 32 -s 4 -n MINIMIG --invariant --offset="$start" "$img" "$(((total - start) / 2))" >/dev/null
# hidden sectors (BPB offset 28) = the partition start, in the boot sector and its backup
poke32 "$img" $((start * 512 + 28)) "$start"
poke32 "$img" $(((start + $(u16 "$img" $((start * 512 + 0x32)))) * 512 + 28)) "$start"
fsinfo_unknown "$img" $((start * 512))
first4 "$img" $((start * 512))
populate "$img" $((start * 512)) 1

# super.img: FAT16 on the whole file, no MBR
img=$dir/super.img
rm -f "$img"
truncate -s $((16 * 1024 * 1024)) "$img"
mkfs.fat -F 16 -s 4 -M 0xF8 -n MINIMIG --invariant "$img" >/dev/null
first4 "$img" 0
populate "$img" 0 0

# the expected listings, and a clean fsck of every image as built
for n in fat16 fat32 super; do
    off=$((2048 * 512)); [ "$n" = super ] && off=0
    python3 -I "$gold/fatlist.py" "$dir/$n.img" "$off" > "$dir/$n.gold"
    if [ "$off" = 0 ]; then
        fsck.fat -n "$dir/$n.img" > "$dir/$n.fsck" 2>&1 || { cat "$dir/$n.fsck"; echo "fatimg: $n.img not clean as built" >&2; exit 1; }
    else
        dd if="$dir/$n.img" of="$dir/$n.part" bs=512 skip=2048 status=none
        fsck.fat -n "$dir/$n.part" > "$dir/$n.fsck" 2>&1 || { cat "$dir/$n.fsck"; echo "fatimg: $n.img not clean as built" >&2; exit 1; }
        rm -f "$dir/$n.part"
    fi
done
(cd "$dir" && sha256sum fat16.img fat32.img super.img) > "$dir/fatimg.ok"
echo "fatimg: fat16.img fat32.img super.img in $dir"
