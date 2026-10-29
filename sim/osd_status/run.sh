#!/bin/bash
# The OSD text layer's status byte and the RTG screen's Video Pos register
# (findings/osd-redesign Phase 4).
#
#   bash sim/osd_status/run.sh           both benches (iverilog: userio_osd.v
#                                        VERSION bytes 10..14; GHDL: cfide.vhd
#                                        pos_data_q / pos_rtg_q)
#   bash sim/osd_status/run.sh mutants   the teeth: each mutant, on a run
#                                        copy of the RTL, MUST fail its check
#     mutant_ver    layer version byte 11 left at 1     -> (a) fails
#     mutant_rtg    byte 14 a constant 0                -> (b) fails
#     mutant_alias  cfide: 0x54 still the PAL register  -> (g) fails
#
# cfide's I2C master (SystemVerilog) is not elaborated (havei2c false): its
# entity comes from sim/host_bridge/verilator/blackbox.vhd.
# Fresh Ubuntu 24.04: sudo apt install iverilog ghdl; a second or two.
# RUNTAG names the run directory (sim/osd_status/run_<tag>).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MODES="$*"
[ -z "$MODES" ] && MODES="normal"
[ "$MODES" = mutants ] && MODES="mutant_ver mutant_rtg mutant_alias"

rc=0
for mode in $MODES; do
	run="$HERE/run_${RUNTAG:-$mode}"
	rm -rf "$run"; mkdir -p "$run"
	osd="$ROOT/rtl/minimig/userio_osd.v"
	cfide="$ROOT/rtl/host/cfide.vhd"
	want=PASS; mustfail=""
	case "$mode" in
		normal) ;;
		mutant_ver)
			sed "s/4'd11   : rtl_ver = 8'd2;/4'd11   : rtl_ver = 8'd1;/" "$osd" > "$run/userio_osd.v"
			osd="$run/userio_osd.v"; want=FAIL; mustfail="(a)" ;;
		mutant_rtg)
			sed "s/4'd14   : rtl_ver = {7'd0, rtg_ena};/4'd14   : rtl_ver = 8'd0;/" "$osd" > "$run/userio_osd.v"
			osd="$run/userio_osd.v"; want=FAIL; mustfail="(b)" ;;
		mutant_alias)
			sed 's/if addr(3 downto 2) = "01" then/if false then/' "$cfide" > "$run/cfide.vhd"
			cfide="$run/cfide.vhd"; want=FAIL; mustfail="(g)" ;;
		*) echo "unknown mode $mode"; exit 2 ;;
	esac
	if [ "$osd" != "$ROOT/rtl/minimig/userio_osd.v" ] && cmp -s "$osd" "$ROOT/rtl/minimig/userio_osd.v"; then
		echo "$mode: BROKEN (the sed changed nothing)"; rc=1; continue; fi
	if [ "$cfide" != "$ROOT/rtl/host/cfide.vhd" ] && cmp -s "$cfide" "$ROOT/rtl/host/cfide.vhd"; then
		echo "$mode: BROKEN (the sed changed nothing)"; rc=1; continue; fi

	iverilog -g2005 -o "$run/sim.vvp" -I "$ROOT/rtl/minimig" -I "$ROOT/fpga/openaars" -D MINIMIG_XILINX \
		-s osd_status_tb "$HERE/osd_status_tb.v" "$osd" "$ROOT/rtl/minimig/userio_osd_spi.v" \
		"$ROOT/rtl/fifo/sync_fifo.v" > "$run/compile.log" 2>&1 || {
		echo "$mode: iverilog COMPILE FAILED"; sed -n 1,30p "$run/compile.log"; exit 1; }
	( cd "$run" && vvp sim.vvp > run.log 2>&1 ) || true
	( cd "$run" && ghdl -a --std=08 -fsynopsys "$ROOT/sim/host_bridge/verilator/blackbox.vhd" "$cfide" "$HERE/cfide_tb.vhd" && ghdl -e --std=08 -fsynopsys cfide_tb \
		&& ghdl -r --std=08 -fsynopsys cfide_tb ) > "$run/ghdl.log" 2>&1 || true
	sed -e 's/^.*(report note): //' "$run/ghdl.log" > "$run/ghdl_run.log"

	got=PASS
	grep -q "^=== PASS" "$run/run.log" || got=FAIL
	grep -q "^=== PASS" "$run/ghdl_run.log" || got=FAIL
	grep -hE "^(---|  ok|FAIL|=== )" "$run/run.log" "$run/ghdl_run.log" | sed "s/^/$mode: /"
	if [ -n "$mustfail" ] && ! grep -qF "FAIL: $mustfail" "$run/run.log" "$run/ghdl_run.log"; then
		got="FAIL-outside-$mustfail"; fi
	if [ "$got" = "$want" ]; then echo "$mode: $got (expected $want) -- OK"
	else echo "$mode: $got (expected $want) -- WRONG"; rc=1; fi
done
exit $rc
