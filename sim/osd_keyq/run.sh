#!/bin/bash
# The OSD key-event queue and the version reply's sixth byte.
#
#   ./run.sh              the bench
#   ./run.sh mutant       teeth check: the queue removed, which MUST fail
#
# iverilog, not xsim: this is a two-module bench that finishes in a second, and
# it can then be run while a Vivado build holds the machine -- concurrent xsim
# runs corrupt each other, so a bench that does not need xsim should not use it.
#
# RUNTAG names the run directory, as everywhere else in sim/.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

MODES="$*"
[ -z "$MODES" ] && MODES="normal"

rc=0
for mode in $MODES; do
	want=PASS
	defs=""
	case "$mode" in
		normal) ;;
		# The mutant empties the queue's write side, so every drain reports
		# nothing.  If the bench still passes, it is not testing the queue.
		mutant) defs="-DKEYQ_MUTANT"; want=FAIL ;;
		*) echo "unknown mode: $mode (use normal or mutant)"; exit 2 ;;
	esac

	run="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$run"

	iverilog -g2005 -o "$run/sim.vvp" $defs \
		-I "$ROOT/rtl/minimig" \
		-D MINIMIG_XILINX \
		-s osd_keyq_tb \
		"$HERE/osd_keyq_tb.v" \
		"$ROOT/rtl/minimig/userio_osd.v" \
		"$ROOT/rtl/minimig/userio_osd_spi.v" \
		"$ROOT/rtl/fifo/sync_fifo.v" \
		> "$run/compile.log" 2>&1 || {
			echo "$mode: COMPILE FAILED"; sed -n '1,30p' "$run/compile.log"; exit 1; }

	( cd "$run" && vvp sim.vvp > run.log 2>&1 ) || true

	if grep -q "^=== PASS" "$run/run.log"; then got=PASS; else got=FAIL; fi
	grep -E "^(---|  ok|FAIL|=== )" "$run/run.log" | sed "s/^/$mode: /"

	if [ "$got" = "$want" ]; then
		echo "$mode: $got (expected $want) -- OK"
	else
		echo "$mode: $got (expected $want) -- WRONG"
		rc=1
	fi
done

exit $rc
