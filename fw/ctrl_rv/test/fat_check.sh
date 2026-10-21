#!/usr/bin/env bash
# fat_check.sh <fat_test binary> <image dir> <out dir> <fat16|fat32|super> <tag>
# One image through fat_test (the real mmc.c + fat.c on the card model), then
# the checks that need tools outside the test:
#   - fat_test's listing (ScanDirectory) == <image>.gold (mdir + mshowfat)
#   - fsck.fat -n of the image fat_test wrote (FileCreate/FileWrite/UpdateEntry)
#   - mtype of the file it wrote == W3.BIN
#   - mdir of it: 1536 bytes, 2009-09-01 0:00 (FileCreate's ModifyDate/Time)
# The image in <image dir> is only read; fat_test saves its card to <out>/<image>_<tag>.img.
set -euo pipefail
if [ $# -ne 5 ]; then echo "usage: $0 <fat_test> <image dir> <out dir> <fat16|fat32|super> <tag>" >&2; exit 2; fi
bin=$1; imgs=$2; out=$3; name=$4; tag=$5
case $name in
    fat16) type=16; start=2048 ;;
    fat32) type=32; start=2048 ;;
    super) type=16; start=0 ;;
    *) echo "fat_check: unknown image $name" >&2; exit 2 ;;
esac
PATH=$PATH:/usr/sbin:/sbin
export MTOOLS_SKIP_CHECK=1 TZ=UTC
mkdir -p "$out"
pre=$out/${name}_$tag
rm -f "$pre.img" "$pre.list" "$pre.uart"
fail() { echo "fat_test $name ($tag): FAIL: $*"; exit 1; }

rc=0
"$bin" "$imgs/$name.img" "$imgs/fatdata" "$pre" "$type" "$start" || rc=$?
# the listing is compared even when fat_test failed later on (it is written first)
if [ -f "$pre.list" ] && ! LC_ALL=C sort "$pre.list" | diff - "$imgs/$name.gold" > "$pre.listdiff"; then
    cat "$pre.listdiff"
    fail "listing differs from mdir/mshowfat (< fat_test, > $imgs/$name.gold)"
fi
[ "$rc" = 0 ] || fail "fat_test (UART text: $pre.uart)"

if [ "$start" = 0 ]; then
    part=$pre.img
else
    part=$pre.part
    dd if="$pre.img" of="$part" bs=512 skip="$start" status=none
fi
if ! fsck.fat -n "$part" > "$pre.fsck" 2>&1; then
    cat "$pre.fsck"
    fail "fsck.fat -n of the written image"
fi
[ "$part" = "$pre.img" ] || rm -f "$part"

mtype -i "$pre.img@@$((start * 512))" ::NEWFILE.BIN > "$pre.new" || fail "mtype ::NEWFILE.BIN"
cmp "$pre.new" "$imgs/fatdata/W3.BIN" || fail "NEWFILE.BIN read back by mtype differs from W3.BIN"
mdir -i "$pre.img@@$((start * 512))" ::NEWFILE.BIN > "$pre.mdir" || fail "mdir ::NEWFILE.BIN"
grep -qE '^NEWFILE +BIN +1536 2009-09-01 +0:00' "$pre.mdir" \
    || { cat "$pre.mdir"; fail "mdir: NEWFILE.BIN is not 1536 bytes of 2009-09-01 0:00"; }
# the written card is not needed any more (132 MB for FAT32)
rm -f "$pre.img" "$pre.new" "$pre.mdir"
echo "fat_test $name ($tag): PASS (listing == mdir/mshowfat, fsck.fat -n clean, mtype == W3.BIN, mdir date)"
