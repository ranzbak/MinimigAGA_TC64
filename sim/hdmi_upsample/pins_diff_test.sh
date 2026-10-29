#!/bin/bash
# sim/hdmi_upsample: self-test of pins_diff.py on synthetic pin dumps
# (tb_crt_frame +pins format, "C D V H XXX"): identical, uniform shifts
# either way (B later with filler, B earlier and shorter by |k|), one changed
# line, a truncated dump, a shift beyond the search range, empty and missing
# dumps.  Each case: the expected exit code and output line.  Seconds.
set -e
cd "$(dirname "$0")"
T=build/pins_diff_test
mkdir -p $T
python3 - $T <<'EOF'
import random, sys
d = sys.argv[1]
random.seed(1)
L = ['%d %d %d %d %03x' % (random.randint(0, 1), random.randint(0, 1), random.randint(0, 1),
                           random.randint(0, 1), random.randint(0, 4095)) for _ in range(5000)]
def w(n, lines): open('%s/%s.txt' % (d, n), 'w').write(''.join(l + '\n' for l in lines))
w('a', L)
w('same', L)
w('later5', ['0 0 0 0 000'] * 5 + L[:-5])     # B's pins 5 half-cycles later
w('earlier3', L[3:])                          # B 3 earlier, 3 lines shorter
M = list(L); M[100] = '1 1 1 1 fff'
w('onechange', M)
w('trunc', L[:4900])                          # 100 lines short, no shift
w('later100', ['0 0 0 0 000'] * 100 + L[:-100])   # beyond -64..+64
w('empty', [])
EOF
fail=0
# case B expected-exit expected-line
check() {
	set +e
	out=$(python3 pins_diff.py $T/a.txt "$1" 2>&1); rc=$?
	set -e
	if [ $rc -eq "$2" ] && echo "$out" | grep -q -- "$3"; then echo "  pass  $(basename "$1"): exit $rc, $3"
	else echo "  FAIL  $(basename "$1"): exit $rc (want $2, '$3')"; echo "$out" | sed 's/^/        /'; fail=1; fi
}
check $T/same.txt      0 '^IDENTICAL$'
check $T/later5.txt    0 '^UNIFORM SHIFT 5$'
check $T/earlier3.txt  0 '^UNIFORM SHIFT -3$'
check $T/onechange.txt 1 '^offset 0: 1 of 5000 lines differ$'
check $T/trunc.txt     1 'lengths differ by 100, 100 more than |k|'
check $T/later100.txt  1 'lines differ'
check $T/empty.txt     2 'is empty'
check $T/missing.txt   2 'No such file'
# an empty A too
set +e; out=$(python3 pins_diff.py $T/empty.txt $T/a.txt 2>&1); rc=$?; set -e
if [ $rc -eq 2 ] && echo "$out" | grep -q 'is empty'; then echo "  pass  empty A: exit 2"
else echo "  FAIL  empty A: exit $rc"; echo "$out"; fail=1; fi
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "FAILURES"; exit 1; }
