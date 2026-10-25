#!/bin/bash
# Bench for sd_spi_model: makes a FAT16 card image with tools/sim/mkcard.sh,
# runs tb_sd_spi_model with iverilog, checks the CMD24 write-back image.
#   bash sim/common/run_sd_model.sh [vvp plusargs, e.g. +SD_TOKEN_DLY=200 +SD_NCR=8]
#   bash sim/common/run_sd_model.sh crc [vvp plusargs]
#        tb_sd_model_crc: the model's CRC7/CRC16, CMD59, ACMD22, CMD13, CMD10 and
#        error injection (+SD_ERR_*, remove_card), one vvp run per +CASE on a
#        512 KB pseudo-random card; logs in <run>/crc_<case>.log
# Env: RUNTAG (run dir run_${RUNTAG:-wt}), IVERILOG, VVP.
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
root=$(cd ../.. && pwd)
run=$here/run_${RUNTAG:-wt}
IVERILOG=${IVERILOG:-/usr/local/bin/iverilog}
VVP=${VVP:-vvp}
mkdir -p "$run"

if [ "${1:-}" = crc ]; then
    shift
    python3 -I -c '
import sys
x = 777; o = bytearray()
for i in range(1024 * 512):
    x = (x * 1103515245 + 12345) & 0x7fffffff
    o.append((x >> 16) & 255)
open(sys.argv[1], "wb").write(o)' "$run/crc.img"
    "$IVERILOG" -g2012 -o "$run/tb_crc.vvp" \
        "$here/tb_sd_model_crc.v" "$here/sd_spi_model.v"
    fails=0
    # case and its injection plusargs (see tb_sd_model_crc.v)
    for leg in "basic" "cid +SD_CID_PSN=12345678" "wrrej +SD_ERR_WRREJ=2" "wrfail +SD_ERR_WRFAIL=1" \
               "rdcrc +SD_ERR_RDCRC=3" "noresp +SD_ERR_NORESP=11" "remove" \
               "cmdcrc +SD_ERR_CMDCRC=11" "rdcnt +SD_ERR_RDCRC=2 +SD_ERR_RDCRC_CNT=4" \
               "nrcnt +SD_ERR_NORESP=11 +SD_ERR_NORESP_CNT=3" "rdcut +SD_ERR_RDCRC=2" \
               "wrcnt +SD_ERR_WRREJ=1 +SD_ERR_WRREJ_CNT=2 +SD_ERR_WRFAIL=3 +SD_ERR_WRFAIL_CNT=2"; do
        read -r c pa <<< "$leg"
        # shellcheck disable=SC2086
        "$VVP" -N "$run/tb_crc.vvp" +SD_IMG="$run/crc.img" +CASE="$c" $pa "$@" \
            > "$run/crc_$c.log" 2>&1 || true
        if grep -q '^=== PASS' "$run/crc_$c.log"; then
            echo "crc $c: PASS"
        else
            echo "crc $c: FAIL"; grep -E '^(FAIL|===)' "$run/crc_$c.log" | head -20
            fails=$((fails + 1))
        fi
    done
    [ "$fails" = 0 ] || { echo "=== FAIL run_sd_model crc ($fails cases)"; exit 1; }
    echo "=== PASS run_sd_model crc"
    exit 0
fi

# 4 KB test file (deterministic pseudo-random) and its hex dump (1 byte/line)
python3 -I -c '
import sys
x = 12345; o = bytearray()
for i in range(4096):
    x = (x * 1103515245 + 12345) & 0x7fffffff
    o.append((x >> 16) & 255)
open(sys.argv[1], "wb").write(o)' "$run/TEST4K.BIN"
od -An -v -tx1 -w1 "$run/TEST4K.BIN" | tr -d ' ' > "$run/test4k.hex"
bash "$root/tools/sim/mkcard.sh" "$run/card.img" 8 "$run/TEST4K.BIN"

"$IVERILOG" -g2012 -o "$run/tb.vvp" \
    "$here/tb_sd_spi_model.v" "$here/sd_spi_model.v"
rm -f "$run/saved.img"
"$VVP" -N "$run/tb.vvp" +SD_IMG="$run/card.img" +SD_SAVE="$run/saved.img" \
    +HEX="$run/test4k.hex" "$@" | tee "$run/log.txt"
grep -q '^=== PASS' "$run/log.txt" || { echo "run_sd_model: no PASS line"; exit 1; }

# The saved image must hold the CMD24 pattern at LBA 100 (byte i = i*7+3)
# and still be a valid FAT16 volume with the file intact.
python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read()
exp = bytes(((i * 7 + 3) & 255) for i in range(512))
assert d[100*512:101*512] == exp, "LBA 100 pattern missing in saved image"
assert len(d) == 16384*512, "saved image size"
print("saved image: LBA 100 pattern ok")' "$run/saved.img"
MTOOLS_SKIP_CHECK=1 mcopy -i "$run/saved.img@@$((2048*512))" -o ::TEST4K.BIN "$run/back.bin"
cmp "$run/TEST4K.BIN" "$run/back.bin"
echo "saved image: FAT16 file intact"
