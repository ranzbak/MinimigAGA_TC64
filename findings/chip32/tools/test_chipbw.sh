#!/usr/bin/env bash
# Unit test for chipbw (findings/chip32/plan.md, Task 1), run under vamos, the
# AmigaOS API emulator in amitools (installed here for python3.10 only).
#
# vamos has no custom chips, no CIA timers and no ROM, so this checks the
# program's plumbing, not its numbers:
#   * dos.library opens, the chip buffer is allocated, and the four chip tests
#     each print one line in the "<name> <lines> lines <KB/s> KB/s" format
#   * every timing reads CIA-B TOD high, then mid, then low (the latch order)
#   * the ROM test reads $F80000 (vamos has no ROM there and stops on it,
#     which is the expected end of the run here)
#
#   ./test_chipbw.sh [binary]      default ./chipbw
set -u
cd "$(dirname "$0")"
BIN=${1:-./chipbw}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
timeout 120 python3.10 -c "from amitools.tools.vamos import main; import sys; sys.argv=['vamos','$BIN']; sys.exit(main())" >"$OUT" 2>&1
fail=0
for t in "chip rd.l" "chip wr.l" "chip rd.w" "chip wr.w"; do
  if ! grep -Eq "^$t +[0-9]+ lines +[0-9]+ KB/s$" "$OUT"; then
    echo "FAIL: no result line for '$t'"; fail=1
  fi
done
# TOD reads, in order: must be hi/mid/lo repeated, two reads per test
seq=$(grep -o "CIA read byte @bfd[89a]00" "$OUT" | sed 's/.*@//' | tr '\n' ' ')
want="bfda00 bfd900 bfd800 "
reads=$(grep -c "CIA read byte @bfd[89a]00" "$OUT")
if [ "$reads" -lt 24 ] || [ "$(printf '%s' "$seq" | sed "s/$want//g")" != "" ]; then
  echo "FAIL: CIA-B TOD not read as hi,mid,lo triples ($reads reads): $seq"; fail=1
fi
if ! grep -q "Invalid Memory Access R(4): f80000" "$OUT"; then
  echo "FAIL: the ROM test did not read \$F80000"; fail=1
fi
if [ $fail = 0 ]; then echo "test_chipbw: PASS"; else echo "test_chipbw: FAIL"; tail -20 "$OUT"; fi
exit $fail
