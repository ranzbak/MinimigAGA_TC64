#!/usr/bin/env bash
# config_check.sh <config_test> <cfgconv> <case dir> <out dir> <tag> <mkcard.sh>
# The config file's byte order (Task 11), run by make run-config_test:
#   1. cfgconv on every case of gold/mkcfg832.py (<case dir>: <case>.cfg,
#      <case>.check): --check prints exactly <case>.check; --to-rv, then
#      --check of the result prints the same fields ("order = RV");
#      --to-832 of the result gives the 832 file back byte for byte.
#      Refused, exit 1 and no output file: every corrupt case, --to-832 of an
#      832 file, --to-rv of an RV file, an output that is the input (the same
#      name, a ./ spelling of it, a hard link), and the input is unchanged.
#   2. CFG832_DIR=<dir> (optional): the same round trip on every file there
#      (real 832 config files, e.g. copies from an SD card): --to-rv,
#      --to-832 == the file, the fields of both --check outputs equal.
#   3. card images (tools/sim/mkcard.sh) for config_test (config_test.c has
#      the list), then config_test: cfg_order, the fields through configTYPE,
#      LoadConfiguration on the card model
#   4. the card config_test saved after case (b): mtools reads MINMGAR.CFG ==
#      cfgconv --to-rv MINMGAA.CFG, the 832 files == the originals, fsck.fat -n
#      clean
set -euo pipefail
if [ $# -ne 6 ]; then
    echo "usage: $0 <config_test> <cfgconv> <case dir> <out dir> <tag> <mkcard.sh>" >&2; exit 2
fi
ctest=$1; conv=$2; cases=$3; out=$4; tag=$5; mkcard=$6
PATH=$PATH:/usr/sbin:/sbin
export MTOOLS_SKIP_CHECK=1 TZ=UTC
w=$out/config_$tag
rm -rf "$w"
mkdir -p "$w/cases" "$w/img"
fail() { echo "config_test ($tag): FAIL: $*"; exit 1; }

# ---- 1. cfgconv on the generated cases ----
cp "$cases"/*.cfg "$cases"/*.check "$w/cases/"
c=$w/cases
nvalid=0
for f in "$c"/*.cfg; do
    n=$(basename "$f" .cfg)
    if [ -f "$c/$n.check" ]; then
        nvalid=$((nvalid + 1))
        "$conv" --check "$f" > "$c/$n.out" || fail "cfgconv --check $n.cfg"
        diff "$c/$n.check" "$c/$n.out" || fail "cfgconv --check $n.cfg differs from mkcfg832.py's $n.check (< expected)"
        "$conv" --to-rv "$f" "$c/$n.rv" || fail "cfgconv --to-rv $n.cfg"
        "$conv" --check "$c/$n.rv" > "$c/$n.rvout" || fail "cfgconv --check $n.rv"
        diff <(sed '1s/^order = 832$/order = RV/' "$c/$n.check") "$c/$n.rvout" \
            || fail "cfgconv --check $n.rv: other fields than $n.cfg (< expected)"
        "$conv" --to-832 "$c/$n.rv" "$c/$n.back" || fail "cfgconv --to-832 $n.rv"
        cmp "$f" "$c/$n.back" || fail "round trip: cfgconv --to-832 of $n.rv is not $n.cfg"
        # refusals: already in the target order
        if "$conv" --to-832 "$f" "$c/$n.x" 2> "$c/$n.err"; then fail "cfgconv --to-832 accepted the 832 file $n.cfg"; fi
        grep -q "already in 832 byte order" "$c/$n.err" || fail "cfgconv --to-832 $n.cfg: $(cat "$c/$n.err")"
        if "$conv" --to-rv "$c/$n.rv" "$c/$n.x" 2> "$c/$n.err"; then fail "cfgconv --to-rv accepted the RV file $n.rv"; fi
        grep -q "already in RV byte order" "$c/$n.err" || fail "cfgconv --to-rv $n.rv: $(cat "$c/$n.err")"
        [ ! -e "$c/$n.x" ] || fail "cfgconv wrote $n.x on a refusal"
    else
        # a corrupt case: every mode refuses it, nothing is written
        for m in --to-rv --to-832; do
            if "$conv" "$m" "$f" "$c/$n.x" 2> "$c/$n.err"; then fail "cfgconv $m accepted the corrupt $n.cfg"; fi
            grep -q "not a config file" "$c/$n.err" || fail "cfgconv $m $n.cfg: $(cat "$c/$n.err")"
            [ ! -e "$c/$n.x" ] || fail "cfgconv $m wrote $n.x for the corrupt $n.cfg"
        done
        if "$conv" --check "$f" > /dev/null 2>&1; then fail "cfgconv --check accepted the corrupt $n.cfg"; fi
    fi
done
[ "$nvalid" -ge 6 ] || fail "only $nvalid valid cases in $cases"
# the output is the input: by name, by another spelling, by a hard link
cp "$c/distinct.cfg" "$c/same.cfg"
ln "$c/same.cfg" "$c/same_link.cfg"
for o in "$c/same.cfg" "$c/./same.cfg" "$c/same_link.cfg"; do
    if "$conv" --to-rv "$c/same.cfg" "$o" 2> "$c/same.err"; then fail "cfgconv --to-rv wrote over its input ($o)"; fi
    grep -q "is the input" "$c/same.err" || fail "cfgconv --to-rv same.cfg $o: $(cat "$c/same.err")"
    cmp "$c/same.cfg" "$c/distinct.cfg" || fail "cfgconv changed its input ($o)"
done
echo "config_test ($tag): cfgconv: $nvalid cases --check == mkcfg832.py, --to-rv/--to-832 round trip, refusals"

# ---- 2. real 832 files (optional) ----
if [ -n "${CFG832_DIR:-}" ]; then
    nreal=0
    mkdir -p "$w/real"
    for f in "$CFG832_DIR"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        "$conv" --to-rv "$f" "$w/real/$b.rv" || fail "CFG832_DIR: cfgconv --to-rv $f"
        "$conv" --to-832 "$w/real/$b.rv" "$w/real/$b.back" || fail "CFG832_DIR: cfgconv --to-832 $b.rv"
        cmp "$f" "$w/real/$b.back" || fail "CFG832_DIR: round trip of $f"
        diff <("$conv" --check "$f" | tail -n +2) <("$conv" --check "$w/real/$b.rv" | tail -n +2) \
            || fail "CFG832_DIR: the fields of $b and its RV file differ"
        nreal=$((nreal + 1))
    done
    [ "$nreal" -gt 0 ] || fail "CFG832_DIR=$CFG832_DIR holds no file"
    echo "config_test ($tag): CFG832_DIR: $nreal file(s) round trip, fields equal"
fi

# ---- 3. the card images, config_test ----
mkimg() {   # <image> <card name>=<file>...
    local img=$1 d; shift
    d=$w/img/$(basename "$img" .img).files
    mkdir -p "$d"
    local args=()
    for p in "$@"; do cp "${p#*=}" "$d/${p%%=*}"; args+=("$d/${p%%=*}"); done
    bash "$mkcard" "$img" 8 "${args[@]}" > /dev/null
}
printf 'config_test card\n' > "$w/HELLO.TXT"
mkimg "$w/img/empty.img" "HELLO.TXT=$w/HELLO.TXT"
mkimg "$w/img/rv.img"    "MINMGAR.CFG=$c/distinct.rv"
mkimg "$w/img/a832.img"  "MINMGAA.CFG=$c/distinct.cfg" "MINMGAA1.CFG=$c/v2.cfg" "MINMGAA2.CFG=$c/v3_208.cfg"
mkimg "$w/img/wrong.img" "MINMGAR.CFG=$c/distinct.cfg"
mkimg "$w/img/both.img"  "MINMGAR.CFG=$c/distinct.rv" "MINMGAA.CFG=$c/l2.cfg"
mkimg "$w/img/rvas832.img" "MINMGAA.CFG=$c/distinct.rv"
"$ctest" "$c" "$w/img" "$w/out" || fail "config_test (UART text: $w/out.uart)"

# ---- 4. the (b) card by mtools and fsck.fat ----
saved=$w/out_a832.img
off=$((2048 * 512))
mcopy -n -i "$saved@@$off" ::MINMGAR.CFG "$w/MINMGAR.CFG" || fail "mcopy ::MINMGAR.CFG from the saved card"
"$conv" --to-rv "$c/distinct.cfg" "$w/expect_rv.cfg"
cmp "$w/MINMGAR.CFG" "$w/expect_rv.cfg" || fail "MINMGAR.CFG on the card is not cfgconv --to-rv MINMGAA.CFG"
for p in MINMGAA.CFG=distinct MINMGAA1.CFG=v2 MINMGAA2.CFG=v3_208; do
    mcopy -n -i "$saved@@$off" "::${p%%=*}" "$w/${p%%=*}" || fail "mcopy ::${p%%=*}"
    cmp "$w/${p%%=*}" "$c/${p#*=}.cfg" || fail "${p%%=*} on the card changed"
done
mdir -i "$saved@@$off" :: > "$w/mdir.txt"
dd if="$saved" of="$w/part.img" bs=512 skip=2048 status=none
fsck.fat -n "$w/part.img" > "$w/fsck.txt" 2>&1 || { cat "$w/fsck.txt"; fail "fsck.fat -n of the saved card"; }
rm -f "$w/part.img" "$saved"
echo "config_test ($tag): PASS (cfgconv, config_test, mtools: MINMGAR.CFG == cfgconv --to-rv MINMGAA.CFG, the 832 files unchanged, fsck.fat -n clean)"
