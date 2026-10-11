#!/bin/bash
# The CIA time-of-day counter against the 8520, and where CIA-A's TOD ticks
# in the beam frame.  See cia_tod_tb.v.
#
#   ./run.sh                     the bench
#   ./run.sh wrgate latch        teeth checks, both of which MUST fail
#
# iverilog: a few modules, finishes in seconds.  RUNTAG names the run
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
		# The old counter: any CPU write anywhere (the CIA's wr is the CPU's
		# write strobe for every address) took the counter's write branch
		# and dropped a count landing in that 7 MHz cycle.
		wrgate) defs="-DCIA_TOD_WRGATE_MUTANT"; want=FAIL ;;
		# The old latch release, at the START of the TODLO read: the rest of
		# the read then follows the live count.
		latch) defs="-DCIA_TOD_LATCH_MUTANT"; want=FAIL ;;
		# The RTL as it was before both fixes (for the record).
		old) defs="-DCIA_TOD_WRGATE_MUTANT -DCIA_TOD_LATCH_MUTANT"; want=FAIL ;;
		*) echo "unknown mode: $mode (use normal, wrgate, latch or old)"; exit 2 ;;
	esac

	run="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$run"

	iverilog -g2005 -o "$run/sim.vvp" $defs \
		-s cia_tod_tb \
		"$HERE/cia_tod_tb.v" \
		"$ROOT/rtl/minimig/ciaa.v" \
		"$ROOT/rtl/minimig/ciab.v" \
		"$ROOT/rtl/minimig/cia_int.v" \
		"$ROOT/rtl/minimig/cia_timera.v" \
		"$ROOT/rtl/minimig/cia_timerb.v" \
		"$ROOT/rtl/minimig/cia_timerd.v" \
		"$ROOT/rtl/minimig/agnus_beamcounter.v" \
		> "$run/compile.log" 2>&1 || {
			echo "$mode: COMPILE FAILED"; sed -n '1,30p' "$run/compile.log"; exit 1; }

	( cd "$run" && vvp -n sim.vvp > run.log 2>&1 ) || true
	rm -f "$run/sim.vvp"

	if grep -q "^=== PASS" "$run/run.log"; then got=PASS; else got=FAIL; fi
	grep -E "^(---|  ok|  TOD|  VHPOSR|FAIL|=== )" "$run/run.log" | sed "s/^/$mode: /"

	if [ "$got" = "$want" ]; then
		echo "$mode: $got (expected $want) -- OK"
	else
		echo "$mode: $got (expected $want) -- WRONG"
		rc=1
	fi
done

exit $rc
