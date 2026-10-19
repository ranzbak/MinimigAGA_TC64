#!/bin/bash
# The OSD key-event queue and the version reply's sixth byte.
#
#   ./run.sh              the bench
#   ./run.sh mutant       teeth check: the queue removed, which MUST fail
#   ./run.sh mutant_seq   teeth check: osd_rx_seq steps one clk7 period early
#                         (on the SPI synchroniser's rx_sync, in a run copy of
#                         userio_osd.v): check (b) MUST fail
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
	mustfail=""
	case "$mode" in
		normal) ;;
		# The mutant empties the queue's write side, so every drain reports
		# nothing.  If the bench still passes, it is not testing the queue.
		mutant) defs="-DKEYQ_MUTANT"; want=FAIL ;;
		# The sequence steps at the clk7 edge BEFORE the one that takes the
		# byte, so a host polling it loads the reply before rddat has moved:
		# check (b) must catch that.
		mutant_seq) want=FAIL; mustfail="(b)" ;;
		*) echo "unknown mode: $mode (use normal, mutant or mutant_seq)"; exit 2 ;;
	esac

	run="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$run"

	osd="$ROOT/rtl/minimig/userio_osd.v"
	if [ "$mode" = mutant_seq ]; then
		inc="    if (rx) osd_rx_seq <= #1 osd_rx_seq + 2'd1;"
		[ "$(grep -cxF -- "$inc" "$osd")" = 1 ] || {
			echo "$mode: the osd_rx_seq increment line was not found in $osd"; exit 1; }
		sed "s/^    if (rx) osd_rx_seq <= /    if (spi0.rx_sync) osd_rx_seq <= /" "$osd" > "$run/userio_osd.v"
		[ "$(grep -c '^    if (spi0.rx_sync) osd_rx_seq <= ' "$run/userio_osd.v")" = 1 ] || {
			echo "$mode: mutation not applied"; exit 1; }
		osd="$run/userio_osd.v"
	fi

	iverilog -g2005 -o "$run/sim.vvp" $defs \
		-I "$ROOT/rtl/minimig" \
		-I "$ROOT/fpga/openaars" \
		-D MINIMIG_XILINX \
		-s osd_keyq_tb \
		"$HERE/osd_keyq_tb.v" \
		"$osd" \
		"$ROOT/rtl/minimig/userio_osd_spi.v" \
		"$ROOT/rtl/fifo/sync_fifo.v" \
		> "$run/compile.log" 2>&1 || {
			echo "$mode: COMPILE FAILED"; sed -n '1,30p' "$run/compile.log"; exit 1; }

	( cd "$run" && vvp sim.vvp > run.log 2>&1 ) || true

	if grep -q "^=== PASS" "$run/run.log"; then got=PASS; else got=FAIL; fi
	grep -E "^(---|  ok|FAIL|=== )" "$run/run.log" | sed "s/^/$mode: /"
	# a mutant must fail where it is meant to, not just somewhere
	if [ -n "$mustfail" ] && ! grep -qF "FAIL: $mustfail" "$run/run.log"; then
		got="FAIL-outside-$mustfail"
	fi

	if [ "$got" = "$want" ]; then
		echo "$mode: $got (expected $want) -- OK"
	else
		echo "$mode: $got (expected $want) -- WRONG"
		rc=1
	fi
done

exit $rc
