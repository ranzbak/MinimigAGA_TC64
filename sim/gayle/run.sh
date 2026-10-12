#!/bin/bash
# The two-port Gayle with ATAPI packet mode (findings/cdrom/plan.md 7.3,
# task 1.1).  See gayle_tb.v for the cases.
#
#   ./run.sh              the bench against rtl/minimig (all cases pass, and
#                         case (a)'s trace matches golden_a.txt)
#   ./run.sh old          the bench against gayle.v as it was at 8208e2b, the
#                         one-port Gayle: (a) must match the golden trace,
#                         (b)-(i) must fail
#   ./run.sh mut_nopkt    teeth: packet mode forced off -- (b)-(d) must fail
#   ./run.sh mut_shared   teeth: one register file for both ports (port
#                         select ignored) -- (g) and (h) must fail
#   ./run.sh golden       re-record golden_a.txt from the 8208e2b gayle.v
#   ./run.sh all          normal old mut_nopkt mut_shared
#
# iverilog, as sim/osd_keyq: a one-module bench that runs in seconds and can
# run while a Vivado build holds the machine.  RUNTAG names the run directory.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OLDREV=8208e2b

MODES="$*"
[ -z "$MODES" ] && MODES="normal"
[ "$MODES" = "all" ] && MODES="normal old mut_nopkt mut_shared"

rc=0
for mode in $MODES; do
	defs=""
	src="$ROOT/rtl/minimig"
	mustfail=""
	want=PASS
	case "$mode" in
		normal) ;;
		old|golden)
			defs="-DOLD_GAYLE"; want=FAIL; mustfail="b c d e f g h i"
			[ "$mode" = golden ] && want=any ;;
		mut_nopkt)  defs="-DGAYLE_MUT_NOPKT";  want=FAIL; mustfail="b c d" ;;
		mut_shared) defs="-DGAYLE_MUT_SHARED"; want=FAIL; mustfail="g h" ;;
		*) echo "unknown mode: $mode"; exit 2 ;;
	esac

	run="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$run"

	if [ -n "$defs" ] && [ "$defs" = "-DOLD_GAYLE" ]; then
		src="$run/old"
		mkdir -p "$src"
		git -C "$ROOT" show "$OLDREV:rtl/minimig/gayle.v" > "$src/gayle.v"
		git -C "$ROOT" show "$OLDREV:rtl/minimig/gayle_fifo.v" > "$src/gayle_fifo.v"
		files="$src/gayle.v $src/gayle_fifo.v"
	else
		files="$src/gayle.v $src/gayle_port.v $src/gayle_fifo.v"
	fi

	# shellcheck disable=SC2086
	iverilog -g2005 -o "$run/sim.vvp" $defs -s gayle_tb \
		"$HERE/gayle_tb.v" $files \
		> "$run/compile.log" 2>&1 || {
			echo "$mode: COMPILE FAILED"; sed -n '1,30p' "$run/compile.log"; rc=1; continue; }

	( cd "$run" && vvp -n sim.vvp > run.log 2>&1 ) || true
	grep "^TRACE" "$run/run.log" > "$run/trace_a.txt" || true

	if [ "$mode" = golden ]; then
		cp "$run/trace_a.txt" "$HERE/golden_a.txt"
		echo "golden: $(wc -l < "$HERE/golden_a.txt") lines from $OLDREV:rtl/minimig/gayle.v"
		grep -E "^(  ok|FAIL)   a " "$run/run.log" | sed "s/^/$mode: /"
		continue
	fi

	grep -E "^(---|  ok|FAIL|=== )" "$run/run.log" | sed "s/^/$mode: /"

	verdict=OK
	if cmp -s "$run/trace_a.txt" "$HERE/golden_a.txt"; then
		echo "$mode: case (a) trace matches golden_a.txt ($(wc -l < "$HERE/golden_a.txt") lines)"
	else
		echo "$mode: case (a) trace DIFFERS from golden_a.txt:"
		diff "$HERE/golden_a.txt" "$run/trace_a.txt" | head -20
		verdict=WRONG
	fi
	grep -q "^  ok   a " "$run/run.log" || { echo "$mode: case (a) did not pass"; verdict=WRONG; }

	if grep -q "^=== PASS" "$run/run.log"; then got=PASS; else got=FAIL; fi
	[ "$got" = "$want" ] || verdict=WRONG
	for c in $mustfail; do
		grep -q "^FAIL   $c " "$run/run.log" || { echo "$mode: case ($c) should fail and did not"; verdict=WRONG; }
	done
	echo "$mode: $got (expected $want${mustfail:+, failing: $mustfail}) -- $verdict"
	[ "$verdict" = OK ] || rc=1
done

exit $rc
