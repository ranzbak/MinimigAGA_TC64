#!/bin/bash
# The CIA timer count-source selects and the E-clock-aligned reload.
#
#   ./run.sh                     the bench
#   ./run.sh inmode reload       teeth checks, both of which MUST fail
#
# iverilog rather than xsim: two small modules, finishes in a second, and can
# therefore run while a Vivado build holds the machine.  RUNTAG names the run
# directory, as everywhere else in sim/.
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
		# Put the timers back the way they were: count source hardwired to
		# the E clock, INMODE stored and ignored.  If the bench still passes,
		# it is not testing the fix.
		inmode) defs="-DCIA_INMODE_MUTANT"; want=FAIL ;;
		# And put the reload back on the next 7 MHz tick instead of the E
		# edge, which is fix 1.2.  Checking that the counter merely reaches
		# its new value would NOT catch this -- the old code reloaded too,
		# just early -- so the bench watches the reload strobe against eclk.
		reload) defs="-DCIA_RELOAD_MUTANT"; want=FAIL ;;
		*) echo "unknown mode: $mode (use normal, inmode or reload)"; exit 2 ;;
	esac

	run="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$run"

	iverilog -g2005 -o "$run/sim.vvp" $defs \
		-s cia_timer_tb \
		"$HERE/cia_timer_tb.v" \
		"$ROOT/rtl/minimig/cia_timera.v" \
		"$ROOT/rtl/minimig/cia_timerb.v" \
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
