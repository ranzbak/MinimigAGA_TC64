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
#   ./run.sh bridge       -DSDC_BRIDGE: the SD card bridge (rtl/minimig/
#                         sdcard_gayle.v) and its mux in front of Gayle, a
#                         model of sdcard_spi's g_* side on clk_114 = 4 x clk:
#                         case (a) moves its data through the bridge and its
#                         trace must match golden_a.txt event for event
#                         (cycle numbers differ), (b)-(i) pass through the
#                         idle mux, (j)-(o) are the bridge cases
#   ./run.sh bridge_async as bridge, clk_114 at 112.4 MHz drifting against clk
#   ./run.sh bridge_mut_nogate   teeth: paula_floppy strobes not blocked
#                         while the bridge is active -- (n) must fail
#   ./run.sh bridge_mut_norst    teeth: the bridge ignores the FIFO reset --
#                         (l) must fail
#   ./run.sh bridge_mut_noyoung  teeth: no young-op guard on the clk_114 side
#                         -- (o) must fail
#   ./run.sh bridge_mut_noabsorb teeth: a dir-1 word request outlives its op
#                         -- (o) must fail
#   ./run.sh bridge_mut_noaddr   teeth: hdd_addr not forced to 0 while the
#                         bridge is active -- (p) must fail
#   ./run.sh bridge_mut_nosince  teeth: no abandoned-command flag -- (q)
#                         must fail
#   ./run.sh bridge_mut_regwnext teeth: g_wnext a cycle after the take -- (o)
#                         must fail
#   ./run.sh all          normal old mut_nopkt mut_shared bridge bridge_async
#                         and the seven bridge_mut_* modes
#
# iverilog, as sim/osd_keyq: a one-module bench that runs in seconds and can
# run while a Vivado build holds the machine.  RUNTAG names the run directory.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OLDREV=8208e2b

MODES="$*"
[ -z "$MODES" ] && MODES="normal"
[ "$MODES" = "all" ] && MODES="normal old mut_nopkt mut_shared bridge bridge_async bridge_mut_nogate bridge_mut_norst bridge_mut_noyoung bridge_mut_noabsorb bridge_mut_noaddr bridge_mut_nosince bridge_mut_regwnext"

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
		bridge)       defs="-DSDC_BRIDGE" ;;
		bridge_async) defs="-DSDC_BRIDGE -DSDC_ASYNC" ;;
		bridge_mut_nogate) defs="-DSDC_BRIDGE -DSDG_MUT_NOGATE"; want=FAIL; mustfail="n" ;;
		bridge_mut_norst)  defs="-DSDC_BRIDGE -DSDG_MUT_NORST";  want=FAIL; mustfail="l" ;;
		bridge_mut_noyoung)  defs="-DSDC_BRIDGE -DSDG_MUT_NOYOUNG";  want=FAIL; mustfail="o" ;;
		bridge_mut_noabsorb) defs="-DSDC_BRIDGE -DSDG_MUT_NOABSORB"; want=FAIL; mustfail="o" ;;
		bridge_mut_noaddr)   defs="-DSDC_BRIDGE -DSDG_MUT_NOADDR";   want=FAIL; mustfail="p" ;;
		bridge_mut_nosince)  defs="-DSDC_BRIDGE -DSDG_MUT_NOSINCE";  want=FAIL; mustfail="q" ;;
		bridge_mut_regwnext) defs="-DSDC_BRIDGE -DSDG_MUT_REGWNEXT"; want=FAIL; mustfail="o" ;;
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
	case "$defs" in *SDC_BRIDGE*) files="$files $src/sdcard_gayle.v" ;; esac

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
	case "$defs" in
		*SDC_BRIDGE*)
			# the bridge's timing is not the bench firmware's: compare the
			# events and values, not the clk7 cycle numbers
			sed 's/^TRACE [0-9]* //' "$HERE/golden_a.txt" > "$run/golden_ev.txt"
			sed 's/^TRACE [0-9]* //' "$run/trace_a.txt" > "$run/trace_ev.txt"
			ga="$run/golden_ev.txt"; ta="$run/trace_ev.txt"; how="event for event" ;;
		*)	ga="$HERE/golden_a.txt"; ta="$run/trace_a.txt"; how="" ;;
	esac
	if cmp -s "$ta" "$ga"; then
		echo "$mode: case (a) trace matches golden_a.txt ($(wc -l < "$HERE/golden_a.txt") lines${how:+, $how})"
	else
		echo "$mode: case (a) trace DIFFERS from golden_a.txt:"
		diff "$ga" "$ta" | head -20
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
