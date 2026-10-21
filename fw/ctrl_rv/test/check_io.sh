#!/usr/bin/env bash
# check_io.sh <check_io.awk> <fixture dir> <output file>: the static I/O
# check of fw/ctrl_rv's "make check" (b) and (c) on three small objdump -d
# snippets (check_io/*.dis); its output and exit status for each snippet
# and mode must be check_io/expected.txt (written by hand from the rules in
# check_io.awk's header, not from a run):
#   good.dis        every access allowed: HOST_REQ -76(zero), TIMER, SPI
#                   DATA, a UART store, I/O through a tracked base
#                   (li a4,-112), a lui base that is not I/O, a register
#                   forgotten after a j (clang's branch-only blocks)
#   uart_read.dis   a load from the UART through a register: (b) fails
#   misaligned.dis  HOST_REQ read at -74 (offset 6 of the window): (c) fails
set -u
awkf=$1 dir=$2 out=$3
: > "$out"
for f in good uart_read misaligned; do
	for m in b c; do
		echo "== $f.dis $m" >> "$out"
		awk -v mode="$m" -f "$awkf" "$dir/$f.dis" >> "$out" 2>&1
		echo "exit $?" >> "$out"
	done
done
if diff "$dir/expected.txt" "$out"; then
	echo "check_io fixture PASS (6 verdicts as check_io/expected.txt)"
else
	echo "FAIL check_io fixture: the verdicts differ from $dir/expected.txt (above: < expected, > got)"
	exit 1
fi
