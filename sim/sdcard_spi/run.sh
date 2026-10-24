#!/bin/bash
# Unit bench of rtl/host/sdcard_spi.v (the SD card SPI peripheral) with the
# card model sim/common/sd_spi_model.v (CRC off).  See tb_sdcard_spi.v.
#
#   bash sim/sdcard_spi/run.sh                # both legs, in parallel
#   LEGS=iverilog bash sim/sdcard_spi/run.sh  # one leg (verilator | iverilog)
#   TEST=t_sck_pause bash sim/sdcard_spi/run.sh
#
# Legs:
#   verilator  the speed leg: Verilator 5 --binary --timing (2-state), built
#              with sim/common/hostsim.sh's hs_verilate (waivers:
#              sdcard_spi.vlt); log <run>/tb_verilator.log
#   iverilog   the X-check leg: Icarus Verilog (4-state), run with +XCHECK
#              (no X / Z on reg_q, irq and the pins after reset);
#              log <run>/tb_iverilog.log
# Each leg prints its per-case PASS / FAIL lines; the script exits 1 unless
# every leg ends with "=== PASS tb_sdcard_spi".  The bench's watchdog turns a
# hang into "=== FAIL"; the run itself is limited by `timeout` (TMO, 600 s).
#
# Environment: RUNTAG (run directory sim/sdcard_spi/run_${RUNTAG:-wt}),
# LEGS, TEST, XARGS (extra plusargs, e.g. +SD_LOG=1), VERILATOR (verilator),
# JOBS (nproc), IVERILOG (/usr/local/bin/iverilog if present, else iverilog),
# VVP (vvp), TMO, XRAND / XSEED (Verilator leg, sim/common/hostsim.sh).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RUNTAG=${RUNTAG:-wt}
run=$HERE/run_$RUNTAG
LEGS=${LEGS:-verilator iverilog}
VERILATOR=${VERILATOR:-verilator}
JOBS=${JOBS:-$(nproc)}
if [ -z "${IVERILOG:-}" ]; then
	if [ -x /usr/local/bin/iverilog ]; then IVERILOG=/usr/local/bin/iverilog; else IVERILOG=iverilog; fi
fi
VVP=${VVP:-vvp}
TMO=${TMO:-600}
SIM=verilator
# shellcheck source=../common/hostsim.sh
. "$ROOT/sim/common/hostsim.sh"

mkdir -p "$run" || hs_die "mkdir $run"
SRCS=("$HERE/tb_sdcard_spi.v" "$ROOT/sim/common/sd_spi_model.v" "$ROOT/rtl/host/sdcard_spi.v")
PA=(+SD_IMG="$run/card.img")
[ -n "${TEST:-}" ] && PA+=(+TEST="$TEST")
# shellcheck disable=SC2206
[ -n "${XARGS:-}" ] && PA+=($XARGS)

# 512 KB pseudo-random card (1024 sectors, the bench's IMG_SECTORS)
python3 -I -c '
import sys
x = 4711; o = bytearray()
for i in range(1024 * 512):
    x = (x * 1103515245 + 12345) & 0x7fffffff
    o.append((x >> 16) & 255)
open(sys.argv[1], "wb").write(o)' "$run/card.img" || hs_die "card image"

leg_verilator() {
	HS_NAME=tb HS_VLT="$HERE/sdcard_spi.vlt" HS_VFLAGS="--timescale 1ns/1ps"
	hs_verilate "$run" tb_sdcard_spi "" "${SRCS[@]}"
	# shellcheck disable=SC2046
	timeout "$TMO" "$run/vl_tb/Vtb_sdcard_spi" $(hs_xrand_args) "${PA[@]}" > "$run/tb_verilator.log" 2>&1
}

leg_iverilog() {
	"$IVERILOG" -g2005 -Wall -Wno-timescale -o "$run/tb.vvp" "${SRCS[@]}" > "$run/compile_iverilog.log" 2>&1 \
		|| { cat "$run/compile_iverilog.log"; hs_die "iverilog ($run/compile_iverilog.log)"; }
	timeout "$TMO" "$VVP" -N "$run/tb.vvp" +XCHECK=1 "${PA[@]}" > "$run/tb_iverilog.log" 2>&1
}

pids=()
for leg in $LEGS; do
	case $leg in
		verilator|iverilog) ;;
		*) hs_die "unknown leg $leg (verilator | iverilog)" ;;
	esac
	rm -f "$run/tb_$leg.log"
	( "leg_$leg" ) &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done

fails=0
for leg in $LEGS; do
	log=$run/tb_$leg.log
	echo "--- $leg ($log)"
	if [ -f "$log" ]; then
		grep -E '^(PASS|FAIL) t_[a-z0-9_]+( \(|$)' "$log"
		grep -E '^FAIL' "$log" | grep -vE '^FAIL t_[a-z0-9_]+ \(' | head -20
		grep -E '^=== ' "$log" || echo "=== FAIL tb_sdcard_spi ($leg: no verdict)"
	else
		echo "=== FAIL tb_sdcard_spi ($leg: no log, build failed)"
	fi
	grep -q '^=== PASS tb_sdcard_spi' "$log" 2>/dev/null || fails=$((fails + 1))
done
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails leg(s)"; exit 1; fi
echo "ALL PASS ($LEGS)"
