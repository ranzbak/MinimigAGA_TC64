#!/bin/bash
# Stage E2 Task 4a: the ap040_ram_seq unit-splitter bench.
#
#   ./run.sh              both gate modes
#   ./run.sh open         gate held open only
#   ./run.sh gated        gate open one cycle in four only
#
# RUNTAG names the run directory, as everywhere else in sim/.  This bench has
# no tracked reference log, but keep the habit: a bare run writes run_<mode>/.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VIV=/opt/Xilinx/Vivado/2023.2/bin

# Vivado 2023.2 needs libtinfo.so.5.  Keep the shim in its OWN directory and
# apply it per command: putting a whole snap lib dir on LD_LIBRARY_PATH
# overrides libc for every binary in this shell.
SHIM="$HERE/.shim"
mkdir -p "$SHIM"
if [ ! -e "$SHIM/libtinfo.so.5" ]; then
	for c in /snap/core18/current/lib/x86_64-linux-gnu/libtinfo.so.5.9 \
	         /lib/x86_64-linux-gnu/libtinfo.so.6; do
		[ -e "$c" ] && ln -sf "$c" "$SHIM/libtinfo.so.5" && break
	done
fi
V() { env LD_LIBRARY_PATH="$SHIM" "$@"; }

MODES="$*"
[ -z "$MODES" ] && MODES="open gated mutant"

rc=0
for mode in $MODES; do
	mut=0; want=PASS
	case "$mode" in
		open)   div=1 ;;
		gated)  div=4 ;;
		mutant) div=1; mut=1; want=FAIL ;;   # teeth check: MUST fail
		*) echo "unknown mode: $mode (use open, gated or mutant)"; exit 2 ;;
	esac

	RUN="$HERE/run_${RUNTAG:-$mode}"
	mkdir -p "$RUN"
	cd "$RUN"

	V $VIV/xvhdl --nolog "$ROOT/rtl/soc/ap040_ram_seq.vhd" > analyze.log 2>&1
	V $VIV/xvhdl --nolog "$HERE/ap040_ram_seq_tb.vhd"     >> analyze.log 2>&1
	V $VIV/xelab --nolog -debug off \
		-generic_top "gate_div=$div" -generic_top "line_mutant=$mut" \
		work.ap040_ram_seq_tb -s tb > elab.log 2>&1
	V $VIV/xsim --nolog tb -runall > "sim_${mode}.log" 2>&1 || true

	echo "--- gate mode: $mode (gate_div=$div)"
	grep -E '^(Note|Error|Failure): ' "sim_${mode}.log" | sed 's/^/    /' | tail -20
	if grep -q 'ram_seq PASS' "sim_${mode}.log"; then got=PASS; else got=FAIL; fi
	if [ "$got" = "$want" ]; then
		echo "    RESULT: $got (wanted $want)"
	else
		echo "    RESULT: $got but wanted $want  (see $RUN/sim_${mode}.log)"
		rc=1
	fi
done

exit $rc
