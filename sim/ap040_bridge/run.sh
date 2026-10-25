#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# sim/ap040_bridge -- the AP68040 faster core behind rtl/soc/ap68040_minimig.sv
# on a model of TG68K.vhd's master port (Verilator).  Tests the bridge's
# instruction-cacheable window (ICHIP) and the instruction-cache
# invalidations it pushes into the core.  findings/aga-perf/fix.md.
#
#   ./run.sh                 ICHIP=1 (the design): t_ichip must PASS
#   ICHIP=0 ./run.sh         the old bridge (only fast RAM cached): tests 1,
#                            6, 7 and 10 fail (code from chip RAM, the ROM and
#                            slow RAM is fetched every time; nothing pushed)
#   MUTANT=noxinv ./run.sh   ICHIP=1 with the bridge's pushes tied off:
#                            tests 2, 3 and 10 fail (stale code runs)
#
# Needs Verilator 5 and vasmm68k_mot (VASM=..., default /opt/vbcc/bin).
# Takes about two minutes, most of it Verilating the core.
#-----------------------------------------------------------------------------
set -e
D="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$D/../.." && pwd)"
C="$R/lib/AP68040-faster/rtl"
VASM=${VASM:-/opt/vbcc/bin/vasmm68k_mot}
ICHIP=${ICHIP:-1}
MUTANT=${MUTANT:-}
B="$D/build_ichip${ICHIP}${MUTANT:+_$MUTANT}"
mkdir -p "$B"
$VASM -quiet -Fbin -m68040 -no-opt -L "$B/t_ichip.lst" -o "$B/t_ichip.bin" "$D/asm/t_ichip.s"
python3 "$R/lib/AP68040-faster/tb/bin2hex.py" "$B/t_ichip.bin" "$B/t_ichip.hex"
BRIDGE="$R/rtl/soc/ap68040_minimig.sv"
if [ "$MUTANT" = "noxinv" ]; then
	sed 's/^assign xinv     = self_v || dq_v;/assign xinv     = 1'"'"'b0;/' "$BRIDGE" > "$B/ap68040_minimig.sv"
	grep -q "^assign xinv     = 1'b0;" "$B/ap68040_minimig.sv" || { echo "mutant edit failed"; exit 2; }
	BRIDGE="$B/ap68040_minimig.sv"
elif [ -n "$MUTANT" ]; then
	echo "unknown MUTANT=$MUTANT"; exit 2
fi
(cd "$R/lib/AP68040-faster/tb" && python3 ../tools/ucode.py)
verilator --binary --timing -j 8 --build-jobs 8 -O3 \
	-Wno-fatal -Werror-PINMISSING -Werror-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
	--top-module tb_bridge --Mdir "$B/obj" -o tb_bridge \
	-I"$C" -I"$C/fpu" -CFLAGS "-O2" +define+ICHIP=$ICHIP \
	$C/ap68040_pkg.sv $C/gen/ap68040_upkg.sv $C/ap68040_alu.sv $C/ap68040_alu_slow.sv $C/ap68040_muldiv.sv \
	$C/ap68040_biu.sv $C/ap68040_ram.sv $C/ap68040_atc.sv $C/ap68040_dmu.sv $C/ap68040_predec.sv $C/ap68040_fetch.sv \
	$C/ap68040_decode.sv $C/ap68040_useq.sv $C/fpu/ap040_fpu.v $C/ap68040_fpif.sv $C/ap68040_backend.sv \
	$C/ap68040_snoop.sv $C/ap68040.sv "$BRIDGE" "$D/tb_bridge.sv" > "$B/verilator.log" 2>&1 \
	|| { tail -30 "$B/verilator.log"; exit 1; }
"$B/obj/tb_bridge" +prog="$B/t_ichip.hex" | tee "$B/run.log" | grep -E "^(PASS|FAIL|test|  fetch)"
