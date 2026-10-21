#!/bin/bash
# check.sh <make> <build-dir> <FWRV>: the proof of `make check`.
#  1. every card (and cd with CDCFG=iso) built twice, in two directories, 2 s
#     apart: byte-identical
#  2. fsck.fat -n of each image's FAT partition
#  3. mdir lists exactly the 8.3 names the card is meant to hold
#  4. cfgconv --check of the config files read back from the images prints the
#     field table mkcfg.py was given (MINMGAA.check; the RV file the same table
#     with order = RV)
#  5. python3 -I mkhdf.py --chs SYNTH.HDF: more than 255 cylinders, file <= 8 MB
#  6. manifest.txt equals the manifest of a fresh stand-in build
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin
make=$1; b=$2; fwrv=$3
here=$(cd "$(dirname "$0")" && pwd)
gen=$here/../gen
fail=0
bad() { echo "FAIL: $*"; fail=1; }
mkdir -p "$b/check"
build() {   # dir
    $make -s --no-print-directory B="$1" FWRV="$fwrv" cards CDCFG=cue >/dev/null
    $make -s --no-print-directory B="$1" FWRV="$fwrv" cd CDCFG=iso >/dev/null
}
d1=$b/check/a; d2=$b/check/b
mkdir -p "$d1" "$d2"
build "$d1"
sleep 2
build "$d2"
imgs="boot bootbecfg fdd hdd cd cd_iso cdhdd"
for i in $imgs; do
    cmp -s "$d1/$i.img" "$d2/$i.img" && echo "ok    reproducible $i.img" || bad "$i.img differs between two builds"
done
for f in content/KICK.ROM content/TEST.ADF content/SYNTH.HDF content/RDB.HDF content/TEST.ISO \
         content/TEST.CUE content/TEST.BIN cfg_cue/MINMGAR.CFG cfg_iso/MINMGAR.CFG; do
    cmp -s "$d1/$f" "$d2/$f" || bad "$f differs between two builds"
done
off=$((2048 * 512))
export MTOOLS_SKIP_CHECK=1
# expected names per card (sorted)
$make -s --no-print-directory list > "$b/check/list.txt"
for i in $imgs; do
    img=$d1/$i.img
    dd if="$img" of="$b/check/part.img" bs=512 skip=2048 status=none
    if fsck.fat -n "$b/check/part.img" >"$b/check/fsck.txt" 2>&1; then echo "ok    fsck.fat $i.img"
    else bad "fsck.fat $i.img"; cat "$b/check/fsck.txt"; fi
    card=${i%_iso}
    want=$(awk -v c="$card" '$1 == c { for (k = 2; k <= NF; k++) print $k }' "$b/check/list.txt" | LC_ALL=C sort)
    got=$(mdir -b -i "$img@@$off" :: | sed 's|^::/||' | LC_ALL=C sort)
    if [ "$want" = "$got" ]; then echo "ok    mdir $i.img: $(echo $got)"
    else bad "mdir $i.img: want [$(echo $want)] got [$(echo $got)]"; fi
done
# config files as they sit on the cards
cc=$d1/cfgconv
for i in boot cd_iso; do
    v=cue; [ "$i" = cd_iso ] && v=iso
    mcopy -i "$d1/$i.img@@$off" ::MINMGAA.CFG "$b/check/AA.$v" 
    mcopy -i "$d1/$i.img@@$off" ::MINMGAR.CFG "$b/check/RR.$v"
    "$cc" --check "$b/check/AA.$v" > "$b/check/AA.$v.txt"
    "$cc" --check "$b/check/RR.$v" > "$b/check/RR.$v.txt"
    if diff "$b/check/AA.$v.txt" "$d1/cfg_$v/MINMGAA.check" >/dev/null; then echo "ok    MINMGAA.CFG ($v) fields = mkcfg.py table"
    else bad "MINMGAA.CFG ($v) fields differ"; diff "$b/check/AA.$v.txt" "$d1/cfg_$v/MINMGAA.check" || true; fi
    if diff <(tail -n +2 "$b/check/RR.$v.txt") <(tail -n +2 "$d1/cfg_$v/MINMGAA.check") >/dev/null \
       && [ "$(head -1 "$b/check/RR.$v.txt")" = "order = RV" ]; then echo "ok    MINMGAR.CFG ($v) fields = mkcfg.py table, order RV"
    else bad "MINMGAR.CFG ($v) fields differ"; fi
done
# CHS rule
line=$(python3 -I "$gen/mkhdf.py" --chs SYNTH.HDF)
echo "      $line"
cyl=$(echo "$line" | sed 's/.*cylinders //')
size=$(stat -c %s "$d1/content/SYNTH.HDF")
if [ "$cyl" -gt 255 ] && [ "$size" -le 8388608 ] && [ "$size" = "$(echo "$line" | sed 's/.*: \([0-9]*\) bytes.*/\1/')" ]; then
    echo "ok    SYNTH.HDF $size bytes, $cyl cylinders > 255"
else bad "SYNTH.HDF CHS rule: $cyl cylinders, $size bytes"; fi
# manifest
$make -s --no-print-directory B="$b/manifest" FWRV="$b/manifest/standin/RV32OSDA.BIN" cards CDCFG=cue >/dev/null
$make -s --no-print-directory B="$b/manifest" FWRV="$b/manifest/standin/RV32OSDA.BIN" cd CDCFG=iso >/dev/null
"$here/manifest.sh" "$b/manifest" > "$b/check/manifest.new"
if diff "$b/check/manifest.new" "$here/manifest.txt" >/dev/null; then echo "ok    manifest.txt current"
else bad "manifest.txt is stale (make manifest)"; diff "$b/check/manifest.new" "$here/manifest.txt" || true; fi
if [ "$fail" = 0 ]; then echo "check PASS"; else echo "check FAIL"; exit 1; fi
