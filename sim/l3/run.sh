#!/bin/bash
# L3 bench: the host CPU (bridge, cfide) with the real Minimig SPI slaves
# (userio_osd, paula_floppy, gayle) boots the real boot ROM and firmware from
# an SD card image.  See tb_l3.v, scenarios.vh, README.md.
#
#   bash sim/l3/run.sh <scenario>        boot, boot_short
#   bash sim/l3/run.sh xpair <scenario>  the scenario and its XRAND twin
#                                        (run_$RUNTAG, run_${RUNTAG}_xr; in
#                                        parallel), then compare: both PASS
#                                        and SAME
#   bash sim/l3/run.sh compare <RUNTAG a> <RUNTAG b>
#                                        every tb_*.log and spi.txt of both
#                                        run directories (sim/common/hostsim.sh
#                                        hs_compare; exit 1 unless all SAME)
#
# Environment:
#   CPU      rv (default; 832: Phase 4 Task 6)
#   SIM      xsim (default, 4-state, the X-checking reference) or verilator
#            (GHDL --synth converts the VHDL, as sim/host_bridge)
#   RUNTAG   run directory sim/l3/run_${RUNTAG:-wt}; a new one per code change
#   FW       an RV32OSDA.BIN to put on the card; default: built from
#            fw/ctrl_rv into <run>/fwrv under a date shim (hs_fwrv, L3_DATE)
#   EXTRA_WS the bridge's rv_extra_ws (0)
#   SLAT, SJIT, SEED   the SDRAM model (8, 0, 1)
#   XARGS    extra plusargs ("+FAST_HW=1 +OSD_EARLY_OK=1 +TICKDIV=643 ...");
#            +FAST_HW=1 also puts the models' fast plusargs first (below)
#   NOKICK=1 boot only: the boot card without KICK.ROM.  The run must FAIL
#            at the main-loop milestone (the fatal-error loop); the exit
#            status is 0 when it does
#   XRAND=1  (verilator) the X-sensitivity build, XSEED=<n> its seed
#   TIMEOUT  clk_114 cycles (default per scenario below)
#   L3CHECK  tests of run.sh only: the l3check.py to run (default sim/l3's)
#   VIVADO_PATH, GHDL, VERILATOR, JOBS, OBJCACHE as sim/host_bridge/run.sh
#
# Scenarios (scenarios.vh), card, checks:
#   boot        boot card (sim/l3/card), +SCENARIO=boot +SD_LOG=1, TICKDIV 1;
#               checks: milestones_boot.txt (spitrace.py check: UART lines and
#               SPI frames in order; "NOT UART <text>" lines here: no UART
#               line contains <text>), no EXC / TRAP on the UART, l3check.py
#               kick (the uploaded kickstart = KICK.ROM, from the SDRAM
#               dump), order (plan 7.1 item 14: the last kickstart write
#               before the CPU release) and mmc (MMC_Init's card commands =
#               gold/mmc_init_rv.txt), every "=== MARGIN" line of MARGINS
#               below present and none LOW, bench "=== PASS" (no bench
#               error: OSD GAP >= 40, OSD EARLY 0, no X, no stale ack, no
#               MARGIN LOW)
#   boot_short  boot cut at its end event (scenarios.vh); milestones_boot.txt
#               up to the line "#@ boot_short end"; the MARGIN lines; no
#               kick, order or mmc check
# Logs in the run directory: tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log,
# spi.txt, spi_t.txt (frames with cycles, not compared), milestones.txt,
# results.txt (with the wall time).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
L2="$ROOT/sim/host_bridge"
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
SIM=${SIM:-xsim}
CPU=${CPU:-rv}
GHDL=${GHDL:-ghdl}
VERILATOR=${VERILATOR:-verilator}
JOBS=${JOBS:-$(nproc)}
case "$SIM" in
	xsim|verilator) ;;
	*) echo "SIM=$SIM: must be xsim or verilator"; exit 2 ;;
esac
[ "$CPU" = rv ] || { echo "CPU=$CPU: only rv so far (the 832 comes with Phase 4 Task 6)"; exit 2; }
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
GHDLFLAGS="--std=93c --ieee=synopsys -fexplicit"
I2C_V="$ROOT/rtl/host/i2c_master_mmio.sv $ROOT/rtl/openaars/adv7511/i2c_master.v"
ROM="$ROOT/fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd"
XW=${EXTRA_WS:-0}
SL=${SLAT:-8} SJ=${SJIT:-0}
run="$HERE/run_${RUNTAG:-wt}"

# the Minimig RTL the bench simulates (copied into <run>/src), after the
# board's global include (rtl/soc/openaars_defines.vh)
MM_FILES="rtl/soc/openaars_defines.vh rtl/minimig/userio_osd.v rtl/minimig/userio_osd_spi.v
          rtl/minimig/paula_floppy.v rtl/minimig/paula_floppy_fifo.v rtl/minimig/gayle.v
          rtl/minimig/gayle_port.v rtl/minimig/gayle_fifo.v rtl/minimig/minimig_syscontrol.v"
MM_INC="$ROOT/fpga/openaars"     # minimig_version.vh (the board's)

# the "=== MARGIN <item> <name>" lines every run must print (mon_l3.vh)
MARGINS="1:stale_acks 3:dmode_release 3:dmode_L 4:paula_cs_release 4:userio_cs_release
         4:paula_word_spacing 4:userio_byte_spacing 5:spi_write_busy 12:rtc_cs_high 14:kick_order"

# cycles per scenario (clk_114): 1.5 x the measured end event (README "boot",
# Verilator 2026-10-19: boot 158,155,012, boot_short 57,659,090)
L3_BOOT_TO=${L3_BOOT_TO:-237300000}
L3_SHORT_TO=${L3_SHORT_TO:-86500000}

# shellcheck source=../common/hostsim.sh
. "$ROOT/sim/common/hostsim.sh"
# every fatal step, hostsim.sh's hs_* included (they call hs_die), ends the
# run with the scenario's verdict line: no step failure is silent
hs_die() { echo "FAILED: $*"; echo "=== ${SCEN:-run.sh} FAILED"; exit 1; }
die() { hs_die "$@"; }
L3CHECK=${L3CHECK:-$HERE/l3check.py}   # tests of run.sh only: another l3check.py

# l3_check <name> <out file> <pass regex> <command...>: one offline check
# (spitrace.py, l3check.py), its output in <out file>.  "ok   <the first line
# matching <pass regex>>" only when the command exits 0 AND printed such a
# line; otherwise its BAD lines and "BAD  <name>: exit <rc>, ..." (a crash
# prints no PASS line and exits non-zero: it fails the scenario either way)
l3_check() {
	local name=$1 out=$2 re=$3 rc line; shift 3
	"$@" > "$out" 2>&1; rc=$?
	line=$(grep -m1 -E -- "$re" "$out")
	if [ "$rc" -eq 0 ] && [ -n "$line" ]; then echo "ok   $line ($out)"; return 0; fi
	grep '^BAD' "$out"
	echo "BAD  $name: exit $rc, ${line:-no line matching '$re'}; last line: $(tail -1 "$out") ($out)"
	return 1
}
X() { hs_X "$run" "$@"; }

# cfide_generics: -g<name>=true|false from tb_l3.v's "cfide #( ... ) mycfide ("
# block, one per boolean generic of the cfide entity (dies otherwise)
cfide_generics() {
	local names tbg n
	names=$(sed -n '/^entity cfide is$/,/^ *port($/s/^ *\([a-z0-9_]*\) *: *in boolean.*/\1/p' "$ROOT/rtl/host/cfide.vhd")
	tbg=$(sed -n '/^  cfide #($/,/^  ) mycfide ($/p' "$HERE/tb_l3.v" | grep -o "\.[a-z0-9_]*(1'b[01])" \
		| sed "s/^\.\([a-z0-9_]*\)(1'b0)$/-g\1=false/; s/^\.\([a-z0-9_]*\)(1'b1)$/-g\1=true/")
	[ -n "$names" ] || die "no boolean generics found in rtl/host/cfide.vhd's entity"
	for n in $names; do
		echo "$tbg" | grep -qx -- "-g$n=\(true\|false\)" || die "tb_l3.v: the cfide instance does not set generic $n"
	done
	[ "$(echo "$tbg" | wc -l)" = "$(echo "$names" | wc -w)" ] || die "tb_l3.v: the cfide instance sets other generics than cfide.vhd has"
	CFIDE_GENERICS=$(echo $tbg)
}

# l3_pin_minimig (XRAND=1 only): reset-less state of the Minimig slaves
# that the FPGA's configuration starts at 0, pinned to 0 at time 0 in the
# run copy, as hostsim.sh pins the bridge's and hostcache's flops (README
# "boot", XRAND): paula_floppy.v dsktrack[0..3] (the drives' head
# positions, never reset: HandleFpga's track byte; found by the first XRAND
# twin, findings/osd-riscv/phase4.md).  The count joins hostsim.sh's
# "=== XRAND pinned <n> regs" (it sums the lines of src/pinned_hostcache).
l3_pin_minimig() {
	local v="$run/src/paula_floppy.v" decl='	reg		[6:0] dsktrack[3:0]; //track select'
	[ "${XRAND:-0}" = 1 ] || return 0
	[ "$(grep -cxF -- "$decl" "$v")" = 1 ] || die "XRAND pin: paula_floppy.v dsktrack declaration not found"
	sed -i "/^$(printf '%s' "$decl" | sed 's/[][\/.*^$]/\\&/g')\$/a\\	initial begin dsktrack[0] = 7'd0; dsktrack[1] = 7'd0; dsktrack[2] = 7'd0; dsktrack[3] = 7'd0; end // XRAND pin" "$v"
	[ "$(grep -c '// XRAND pin$' "$v")" = 1 ] || die "XRAND pin: dsktrack initialiser not inserted"
	echo 4 >> "$run/src/pinned_hostcache"
}

# setup: run directory, RTL copies, firmware, card
setup() {
	local f mk=()
	rm -rf "$run"; mkdir -p "$run/src" || die "mkdir $run"
	cd "$run" || die "cd $run"
	: > compile.log
	hs_copy_rtl "$run" "$ROOT"
	for f in $MM_FILES; do cp "$ROOT/$f" "$run/src/" || die "copy $f"; done
	# the slaves have no `timescale (xelab refuses a design that mixes);
	# their #1 delays are 1 ns, as in a build after any 1ns/1ps file
	for f in $MM_FILES; do
		case "$f" in *.v) sed -i '1i `timescale 1ns/1ps' "$run/src/$(basename "$f")" ;; esac
	done
	l3_pin_minimig
	if [ -n "${FW:-}" ]; then
		FWBIN=$(realpath -m -- "$FW")
		[ -f "$FWBIN" ] || die "no firmware $FWBIN (FW=)"
	else
		hs_fwrv "$run"
		FWBIN="$run/fwrv/RV32OSDA.BIN"
	fi
	[ "${NOKICK:-0}" = 1 ] && mk=(NOKICK=1)
	make -s -C "$HERE/card" boot B="$run/card" FWRV="$FWBIN" "${mk[@]}" > "$run/make_card.log" 2>&1 \
		|| { tail -20 "$run/make_card.log"; die "make the boot card ($run/make_card.log)"; }
	CARD="$run/card/boot.img"
	[ ${#CARD} -le 1024 ] || die "card image path longer than 1024 characters (+SD_IMG): $CARD"
}

# build: the snapshot tb_l3_x<XW> (Verilator: GHDL conversion + verilate)
build() {
	local snap=$1 d="$run/ghdl_$1" i2c="" mm=() f
	for f in $MM_FILES; do mm+=("$run/src/$(basename "$f")"); done
	cfide_generics
	if [ "$SIM" = verilator ]; then
		# the L2 bench's black-box list and ROM check (HERE, for this call only)
		HS_DIR=$d HS_ROM=$ROM HS_VB=832_bridge.vhd HS_VC=cfide.vhd
		# shellcheck disable=SC2086
		HERE=$L2 hs_ghdl_convert "$run" true "$XW" $CFIDE_GENERICS
		grep -qE '^ *i2c_master_mmio +[a-z0-9_]+ *\(' "$d/cfide.v" && i2c=$I2C_V
		HS_NAME=$snap HS_VLT="$HERE/l3.vlt"
		HS_VFLAGS="-GEXTRA_WS=$XW -I$ROOT/sim/common -I$HERE -I$MM_INC -I$ROOT/rtl/minimig"
		# shellcheck disable=SC2086
		hs_verilate "$run" tb_l3 "-DL3_GHDL -DRV_HOSTCPU_STATS" \
			"$d/bridge.v" "$d/cfide.v" src/rv_hostcpu.v src/VexOsd.v src/hostcache.v src/dpram_inf_generic.v \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" $i2c \
			"${mm[@]}" "$HERE/bfm_audio.v" "$HERE/rtc_model.v" "$HERE/tb_l3.v"
	else
		X xvlog -sv $I2C_V
		X xvhdl src/cfide.vhd
		X xvlog -d RV_HOSTCPU_STATS src/rv_hostcpu.v src/VexOsd.v src/hostcache.v src/dpram_inf_generic.v
		X xvhdl src/832_bridge.vhd
		X xvhdl "$ROM"
		# --relax: rtl/minimig/gayle_port.v uses the wire err before its
		# declaration (an error for xvlog, accepted by synthesis and Verilator)
		X xvlog --relax -i "$MM_INC" -i "$ROOT/rtl/minimig" "${mm[@]}"
		X xvlog -d RV_HOSTCPU_STATS -i "$ROOT/sim/common" -i "$HERE" \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" "$HERE/bfm_audio.v" \
			"$HERE/rtc_model.v" "$HERE/tb_l3.v"
		hs_xsim_build "$run" "$snap" "$XW" tb_l3
	fi
}


# milestones <scenario> <log>: the milestone file of the scenario, spitrace
# check of its UART / SPI lines, and its "NOT UART <text>" lines
milestones() {
	local s=$1 log=$2 ms="$run/milestones_$1.txt" t
	if [ "$s" = boot_short ]; then
		sed '/^#@ boot_short end/q' "$HERE/milestones_boot.txt" > "$ms"
	else
		cp "$HERE/milestones_boot.txt" "$ms"
	fi
	grep -v '^NOT ' "$ms" > "$ms.check"
	l3_check milestones "$run/milestones.txt" '^milestones: [0-9]+ of [0-9]+ found in order$' \
		python3 -I "$L2/spitrace.py" check "$ms.check" "$log" "$run/spi.txt"
	grep '^NOT UART ' "$ms" | sed 's/^NOT UART //' | while IFS= read -r t; do
		if grep -E '^UART: ' "$log" | grep -qF -- "$t"; then echo "BAD  a UART line contains '$t'"
		else echo "ok   no UART line contains '$t'"; fi
	done
}

# margins <log>: every MARGINS line once, none LOW (mon_l3.vh)
margins() {
	local m n re k=0 bad=0
	for m in $MARGINS; do
		re="^=== MARGIN ${m%%:*} ${m#*:} min "
		k=$((k + 1))
		n=$(grep -c -E -- "$re" "$1")
		if [ "$n" != 1 ]; then echo "BAD  $n lines '=== MARGIN ${m%%:*} ${m#*:} ...' (want 1)"; bad=1
		elif grep -E -- "$re" "$1" | grep -q ', LOW)'; then echo "BAD  MARGIN ${m%%:*} ${m#*:} LOW"; bad=1; fi
	done
	[ "$bad" = 0 ] && echo "ok   MARGIN lines: all $k present, none LOW"
}

# scenario <name>: build, run, checks
scenario() {
	local s=$1 to snap="tb_l3_x$XW" pa=() st x
	local log="$run/tb_${s}_x${XW}_s${SL}_j${SJ}.log"
	case "$s" in
		boot) to=${TIMEOUT:-$L3_BOOT_TO}; pa=("SDRAM_DUMP=$run/sdram.bin" "SD_LOG=1") ;;
		boot_short) to=${TIMEOUT:-$L3_SHORT_TO} ;;
		*) die "unknown scenario $s" ;;
	esac
	if git -C "$ROOT" diff --quiet HEAD -- "${ROM#$ROOT/}"; then st="unmodified (= git HEAD)"; else st="BAD  MODIFIED against git HEAD"; fi
	{
		echo "boot ROM: ${ROM#$ROOT/} $st, sha256 $(sha256sum "$ROM" | cut -c1-16)"
		echo "firmware: $FWBIN, $(stat -c %s "$FWBIN") bytes, sha256 $(sha256sum "$FWBIN" | cut -c1-16)"
		echo "card: $CARD$( [ "${NOKICK:-0}" = 1 ] && echo " (NOKICK=1: no KICK.ROM)")"
	} | tee "$run/results.txt"
	build "$snap"
	# plusargs without the +: FAST_HW's model timing first (the first match
	# wins in $value$plusargs), then the run's, then XARGS
	case " ${XARGS:-} " in
		*" +FAST_HW=1 "*) pa=(SD_TOKEN_DLY=0 SD_BUSY=1 SD_NCR=1 SLAT=2 SJIT=0 "${pa[@]}") ;;
	esac
	pa+=("SCENARIO=$s" "SLAT=$SL" "SJIT=$SJ" "SEED=${SEED:-1}" "SD_IMG=$CARD" "TIMEOUT=$to"
	     "SPI_LOG=$run/spi.txt" "SPI_T_LOG=$run/spi_t.txt")
	for x in ${XARGS:-}; do pa+=("${x#+}"); done
	local t0=$SECONDS
	hs_simrun "$run" "$snap" tb_l3 "$log" "${pa[@]}"
	local secs=$((SECONDS - t0))
	python3 -I "$L2/spitrace.py" summary "$run/spi.txt" > "$run/spi_summary.txt" 2>&1
	{
		grep -E '^=== (BOOT|MAIN|END|STATS|HW accesses|cycle limit|HandleFpga|SPI frames|OSD GAP|OSD EARLY|STACK|RTC|KICK|MARGIN)' "$log"
		grep -E '^BENCH ERROR' "$log" | sed 's/^/BAD  /'
		margins "$log"
		grep -q '^SD: image .* loaded' "$log" || echo "BAD  the SD model did not load $CARD"
		milestones "$s" "$log"
		grep -E '^UART: .*(EXC |TRAP )' "$log" | sed 's/^/BAD  /'
		if [ "$s" = boot ]; then
			l3_check kick "$run/kick.txt" '^PASS kick: ' python3 -I "$L3CHECK" kick "$run"
			l3_check order "$run/order.txt" '^PASS order: ' python3 -I "$L3CHECK" order "$run"
			l3_check mmc "$run/mmc.txt" '^PASS mmc: ' python3 -I "$L3CHECK" mmc "$run"
		fi
		if grep -q '^=== PASS' "$log"; then echo "ok   bench verdict: === PASS"
		else echo "BAD  bench verdict: $(grep -m1 -E '^=== (PASS|FAIL)' "$log" || echo none) ($log)"; fi
		echo "$SIM wall time ${secs} s, $(sed -n 's/.*, cycles \([0-9]*\)$/\1/p' "$log") cycles"
	} | tee -a "$run/results.txt"
	if grep -q 'BAD' "$run/results.txt"; then echo "=== $s FAILED"; return 1; fi
	echo "=== $s PASS"
}

# nokick: boot on the card without KICK.ROM must fail at the main-loop
# milestone (the fatal-error loop has no HandleFpga frames after its first)
nokick() {
	if scenario boot; then echo "BAD  NOKICK=1: boot passed without a kickstart"; return 1; fi
	if grep -q '^BAD  SPI>=21 10 00 00 00 00 00 00' "$run/milestones.txt" \
		&& grep -q '^UART: .*ROM loading failed' "$run"/tb_boot_*.log; then
		echo "=== NOKICK=1: boot FAILED as expected (main-loop milestone missing, 'ROM loading failed')"
		return 0
	fi
	echo "BAD  NOKICK=1: boot failed, but not at the main-loop milestone ($run/milestones.txt)"
	return 1
}

case "${1:-}" in
	""|-h|--help) sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 0 ;;
	compare)
		[ $# -eq 3 ] || { echo "usage: run.sh compare <RUNTAG a> <RUNTAG b>"; exit 2; }
		for t in "$2" "$3"; do [ -d "$HERE/run_$t" ] || { echo "no run directory $HERE/run_$t"; exit 2; }; done
		hs_compare "$HERE/run_$2" "$HERE/run_$3"
		exit $?
		;;
	xpair)
		[ $# -eq 2 ] || { echo "usage: run.sh xpair <scenario>"; exit 2; }
		[ "$SIM" = verilator ] || { echo "xpair needs SIM=verilator"; exit 2; }
		rt=${RUNTAG:-wt}
		RUNTAG=$rt XRAND=0 bash "$0" "$2" > "$HERE/.xpair_$rt.out" 2>&1 & p1=$!
		RUNTAG=${rt}_xr XRAND=1 bash "$0" "$2" > "$HERE/.xpair_${rt}_xr.out" 2>&1 & p2=$!
		wait $p1; r1=$?
		wait $p2; r2=$?
		for t in "$rt" "${rt}_xr"; do
			echo "--- RUNTAG=$t"; cat "$HERE/.xpair_$t.out"
			if [ -d "$HERE/run_$t" ]; then mv "$HERE/.xpair_$t.out" "$HERE/run_$t/run.out"; else rm -f "$HERE/.xpair_$t.out"; fi
		done
		echo "--- compare $rt ${rt}_xr"
		hs_compare "$HERE/run_$rt" "$HERE/run_${rt}_xr"; rc=$?
		if [ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ $rc -eq 0 ]; then echo "=== xpair $2 PASS"; exit 0; fi
		echo "=== xpair $2 FAILED (runs $r1 / $r2, compare $rc)"
		exit 1
		;;
	boot|boot_short)
		SCEN=$1
		[ "${NOKICK:-0}" = 1 ] && [ "$1" != boot ] && die "NOKICK=1 is for boot only"
		setup
		if [ "${NOKICK:-0}" = 1 ]; then nokick; else scenario "$1"; fi
		exit $?
		;;
	*) echo "unknown target $1 (run.sh --help)"; exit 2 ;;
esac
