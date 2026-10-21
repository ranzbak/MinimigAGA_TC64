#!/bin/bash
# mkiso.sh <dir>: <dir>/TEST.ISO, an ISO 9660 image with one file DATA.BIN.
# DATA.BIN is 256 KB (128 blocks of 2048 bytes), block n tagged 'L' 'B'
# n>>8 n&0xff (n = the block within the file; the disc LBA is n plus the
# file's start LBA), then (n*37 + i*151) & 0xff for byte i.
# Reproducible: volume id, dates (SOURCE_DATE_EPOCH, default 2026-01-01
# 00:00 UTC) and file times are fixed; no Rock Ridge, no Joliet, level 1.
set -euo pipefail
if [ $# -ne 1 ]; then
    echo "usage: $0 <dir>" >&2
    exit 2
fi
out=$1
epoch=${SOURCE_DATE_EPOCH:-1767225600}
command -v xorriso >/dev/null 2>&1 || { echo "mkiso: xorriso not found" >&2; exit 2; }
mkdir -p "$out"
tree=$(mktemp -d "$out/isotree.XXXXXX")
trap 'rm -f "$tree/DATA.BIN"; rmdir "$tree"' EXIT
python3 -I -c '
import sys
with open(sys.argv[1], "wb") as f:
    for n in range(128):
        b = bytearray((n * 37 + i * 151) & 0xFF for i in range(2048))
        b[0:4] = bytes((0x4C, 0x42, n >> 8, n & 0xFF))
        f.write(b)
' "$tree/DATA.BIN"
touch -d "@$epoch" "$tree/DATA.BIN" "$tree"
date=$(TZ=UTC date -d "@$epoch" +%Y%m%d%H%M%S00)
SOURCE_DATE_EPOCH=$epoch xorriso -as mkisofs -quiet -iso-level 1 -V L3TEST \
    -volset L3TEST -publisher L3 -preparer L3 -appid L3 -sysid L3 \
    --modification-date="$date" -o "$out/TEST.ISO" "$tree" >/dev/null 2>&1
