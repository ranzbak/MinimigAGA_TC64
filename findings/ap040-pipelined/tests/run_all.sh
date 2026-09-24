#!/bin/sh
# Parity test runner for the pipelined AP68040 against the reference core(s).
#
#   AP040_PIPE =<clone of nonarkitten/AP68040 @pipelined (work branch)>
#   AP040_REF  =<one reference: lib/AP68040 or a clone of apolkosnik/AP68040>
#   AP040_REFS ="<ref1> <ref2> ..."  run the differential legs against EACH.
#               Default: lib/AP68040 (the core that ships) and, when present,
#               ../AP68040-reference (apolkosnik main).  AP040_REF, if set,
#               replaces the list with that one reference.
#
# Legs:
#   red_*      pipelined-only benches for behaviour the pipeline lacks.
#              Reported as "red (expected)" / "GREEN", never fail the run.
#   diff_<prog> for every tests/asm/diff_*.s and every program bench of the
#              pipelined tree (tb/pipe_asm/*.s): assemble, run on the pipelined
#              core and on each reference through the trace dumpers, compare
#              registers (event order + final state), the W stream (per-address
#              memory-write sequences) and the X stream (exception frames, in
#              order, field for field).  These legs MUST pass, except those
#              listed in EXPECTED_RED below with their reason.
#   Per-program options come from a header line in the .s file:
#       ; diff: --from-pc 402 --cycles 3000
#   (--from-pc/--ignore-exc/--no-mem/--no-exc go to compare_trace.py,
#    --cycles to both dumpers).
#   ONLY=<prog>  run only the differential leg asm/<prog>.s (and no red legs);
#                used by mutants/run_mutant.sh
# Needs iverilog, vvp, python3, vasmm68k_mot (vbcc).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)
AP040_PIPE=${AP040_PIPE:-$R/../AP68040-pipelined}
if [ -n "${AP040_REF:-}" ]; then
	AP040_REFS=$AP040_REF
elif [ -z "${AP040_REFS:-}" ]; then
	AP040_REFS=$R/lib/AP68040
	[ -f "$R/../AP68040-reference/rtl/ap040_tg68k_compat.v" ] && AP040_REFS="$AP040_REFS $R/../AP68040-reference"
fi
VASM=${VASM:-vasmm68k_mot}
WORK=${WORK:-$HERE/build}
mkdir -p "$WORK"

PRTL=$AP040_PIPE/rtl
[ -f "$PRTL/ap040_pipe_core.v" ] || { echo "AP040_PIPE=$AP040_PIPE has no rtl/ap040_pipe_core.v" >&2; exit 2; }
# every rtl/*.v of the pipelined tree (new stage/unit files are picked up
# without editing this script)
PSRC="$(ls "$PRTL"/*.sv 2>/dev/null) $(ls "$PRTL"/*.v)"

fail=0
echo "== red legs (pipelined core only; expected to fail until the feature lands) =="
for tb in "$HERE"/tb_ap040_pipe_red_*.v; do
	[ -n "${ONLY:-}" ] && break
	t=$(basename "$tb" .v); t=${t#tb_ap040_pipe_red_}
	if ! iverilog -g2012 -I "$PRTL" -o "$WORK/red_$t.vvp" "$tb" $PSRC 2> "$WORK/red_$t.compile.log"; then
		echo "  COMPILE-ERROR red_$t (see $WORK/red_$t.compile.log)"; fail=1; continue
	fi
	vvp "$WORK/red_$t.vvp" > "$WORK/red_$t.log" 2>&1
	if grep -q "ALL TESTS PASSED" "$WORK/red_$t.log"; then
		echo "  GREEN          red_$t   (feature is now implemented)"
	else
		echo "  red (expected) red_$t   $(grep -m1 '^FAIL' "$WORK/red_$t.log")"
	fi
done

# Differential legs that are known red, with the reason.  Format: "<leg>:<reason>".
EXPECTED_RED=${EXPECTED_RED:-""}   # none since M1 (diff_smoke_from_reset went green with the reset vector fetch)

is_expected_red() {
	for e in $EXPECTED_RED_LIST; do [ "${e%%:*}" = "$1" ] && return 0; done
	return 1
}
EXPECTED_RED_LIST=$(echo "$EXPECTED_RED" | tr ' ' '_' | tr ';' ' ')

echo "== pipelined trace bench =="
iverilog -g2012 -I "$PRTL" -o "$WORK/pipe_trace.vvp" "$HERE/tb_ap040_pipe_trace.v" $PSRC || exit 1

ri=0
for REF in $AP040_REFS; do
	ri=$((ri + 1))
	RRTL=$REF/rtl
	[ -f "$RRTL/ap040_tg68k_compat.v" ] || { echo "reference $REF has no rtl/ap040_tg68k_compat.v" >&2; exit 2; }
	RSRC="$RRTL/ap040_tg68k_compat.v $RRTL/ap040_core.v $RRTL/ap040_bus16_adapter.v $RRTL/ap040_bus_timeout.v \
	      $RRTL/ap040_regfile.v $RRTL/ap040_alu.v $RRTL/ap040_muldiv.v $RRTL/ap040_mmu.v $RRTL/ap040_cache.v \
	      $RRTL/ap040_fpu.v $RRTL/ap040_walker_cdc.v $RRTL/primitives/dpram.v"
	[ -f "$RRTL/ap040_fill_cdc.v" ] && RSRC="$RSRC $RRTL/ap040_fill_cdc.v"
	if grep -q bus_clkena_in "$RRTL/ap040_tg68k_compat.v"; then
		RDEF="-DREF_UPSTREAM"; RNAME="upstream"
	else
		RDEF=""; RNAME="lib"
	fi
	echo "== differential legs against reference $ri ($RNAME: $REF) =="
	iverilog -g2012 $RDEF -I "$RRTL" -o "$WORK/ref_trace_$RNAME.vvp" "$HERE/tb_ap040_ref_trace.v" $RSRC \
		2> "$WORK/ref_trace_$RNAME.compile.log" || { echo "  COMPILE-ERROR reference bench ($WORK/ref_trace_$RNAME.compile.log)"; fail=1; continue; }
	for src in "$HERE"/asm/diff_*.s "$AP040_PIPE"/tb/pipe_asm/*.s; do
		prog=$(basename "$src" .s)
		[ -n "${ONLY:-}" ] && [ "$prog" != "$ONLY" ] && continue
		opts=$(sed -n 's/^; *diff: *//p' "$src" | head -1)
		cyc=3000; cmpopts=""
		set -- $opts
		while [ $# -gt 0 ]; do
			case "$1" in
				--cycles) cyc=$2; shift 2 ;;
				*) cmpopts="$cmpopts $1"; shift ;;
			esac
		done
		if [ $ri -eq 1 ]; then
			rm -f "$WORK/$prog.pipe.txt"
			"$VASM" -Fbin -m68040 -no-opt -quiet -I "$(dirname "$src")" -o "$WORK/$prog.bin" "$src" || { echo "  assembler failed: $prog"; fail=1; continue; }
			python3 "$HERE/bin2hex.py" "$WORK/$prog.bin" "$WORK/$prog.hex"
			vvp "$WORK/pipe_trace.vvp" +prog="$WORK/$prog.hex" +trace="$WORK/$prog.pipe.txt" +cycles=$cyc > "$WORK/$prog.pipe.log" 2>&1
		fi
		[ -f "$WORK/$prog.pipe.txt" ] || { echo "  FAIL  $prog (no pipelined trace)"; fail=1; continue; }
		vvp "$WORK/ref_trace_$RNAME.vvp" +prog="$WORK/$prog.hex" +trace="$WORK/$prog.ref_$RNAME.txt" +cycles=$cyc > "$WORK/$prog.ref_$RNAME.log" 2>&1
		# (1) from reset, no options: must match unless listed as expected red
		if [ -n "$cmpopts" ]; then
			python3 "$HERE/compare_trace.py" "$WORK/$prog.pipe.txt" "$WORK/$prog.ref_$RNAME.txt" \
				> "$WORK/$prog.$RNAME.full.log" 2>&1
			frc=$?
			leg=${prog}_from_reset
			if [ $frc -eq 0 ]; then
				if is_expected_red "$leg"; then echo "  GREEN          $leg  (was expected red: update EXPECTED_RED)"; else echo "  pass  $leg"; fi
			elif is_expected_red "$leg"; then
				echo "  red (expected) $leg   $(grep -m1 'DIVERGENCE\|differs' "$WORK/$prog.$RNAME.full.log")"
			else
				echo "  FAIL  $leg   $(grep -m1 'DIVERGENCE\|differs' "$WORK/$prog.$RNAME.full.log")"; fail=1
			fi
		fi
		# (2) with the program's own options
		python3 "$HERE/compare_trace.py" "$WORK/$prog.pipe.txt" "$WORK/$prog.ref_$RNAME.txt" $cmpopts \
			> "$WORK/$prog.$RNAME.compare.log" 2>&1
		rc=$?
		sed 's/^/    /' "$WORK/$prog.$RNAME.compare.log"
		if [ $rc -eq 0 ]; then
			echo "  pass  $prog"
		elif is_expected_red "$prog"; then
			echo "  red (expected) $prog"
		else
			echo "  FAIL  $prog"; fail=1
		fi
	done
done
exit $fail
