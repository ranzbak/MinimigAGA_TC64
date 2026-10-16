#!/bin/bash
# L2 host-bridge bench (xsim): the RISC-V host CPU through the real
# EightThirtyTwo_Bridge, hostcache and cfide.  See tb_host_bridge.v, README.md.
#
#   bash sim/host_bridge/run.sh all          # every test x SLAT {2,8,20} x SJIT {0,8}
#   bash sim/host_bridge/run.sh mutant       # the four-phase handshake's teeth (below)
#   bash sim/host_bridge/run.sh t_lanes ...  # named tests at SLAT/SJIT from env
#   SLAT=20 SJIT=8 EXTRA_WS=3 bash sim/host_bridge/run.sh t_b2b
#   bash sim/host_bridge/run.sh boot         # committed boot ROM loads RV32OSDA.BIN
#   bash sim/host_bridge/run.sh boot_nofile  # card without it: error path
#
# Environment: RUNTAG (run directory run_${RUNTAG:-wt}), SLAT (8), SJIT (0),
# EXTRA_WS (0, the bridge's rv_extra_ws), SEED (1), XARGS (extra plusargs,
# e.g. "+VERBOSE=1"), VIVADO_PATH; boot runs also BOOT_TIMEOUT (clk_114
# cycles; boot 40000000, boot_nofile 27000000: the cycle limit that ends it,
# 0.76 M cycles after the retry's "Initializing SD card" line) and
# BOOT_CARD (another card image, e.g. a corrupted copy).
#
# boot / boot_nofile: the committed fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd,
# compiled unmodified (VHDL-93), boots from the SD card model (bench compiled
# with -d SDCARD -d RV_HOSTCPU_STATS, rv_hostcpu with -d RV_HOSTCPU_STATS).  sim/host_bridge/boot
# builds RV32OSDA.BIN and the card images into <run>/boot.  The run's
# "UART:" and "ERRORCODE:" lines must equal boot/expect.txt (@IMG@ = the
# line in <run>/boot/img.txt) or boot/expect_nofile.txt line for line, and
# the bench verdict must be "=== PASS".  Results in <run>/results.txt.
#
# mutant: t_b2b over the SLAT/SJIT matrix in three legs (EXTRA_WS from the
# environment is ignored, the legs set it):
#   gate     mutant bridge + fast master, EXTRA_WS=0      every run must FAIL
#   control  real bridge   + fast master, EXTRA_WS=0..3   every run must PASS
#            (the sweep moves the next request through all four clk_114
#            phases of clk_28: the four-phase handshake holds at each)
#   info     mutant bridge + real rv_hostcpu (EXTRA_WS=0) and mutant bridge
#            + fast master (EXTRA_WS=1..3), one run each, printed only
# mutant bridge: 832_bridge.vhd's "-- 4PHASE" line becomes "state <= waiting;"
# (two-phase: the next hw request may start while cfide's ack is still high).
# fast master: rv_hostcpu.v accepts the core's next dBus command in the ack
# cycle, so a request follows the previous ack with no idle cycle: the
# fastest the bus contract allows ("in the cycle after ack, req is 0 or a new
# request").  The real rv_hostcpu idles one cycle after every ack; its next hw
# request then always meets the next clk_28 edge, so the stale ack is never
# taken and the info leg passes (README.md, "Why the mutant needs the fast
# master").
#
# Steps: copy the RTL into the run directory (src/), apply the simulation
# fixes below, build the test ROMs there (make B=<run>/build), compile, then
# per test compile its ROM and elaborate a snapshot; xsim runs one at a time.
# Simulation fixes on the copies (never on rtl/); there are no others, the
# DUT is otherwise the RTL as committed:
#   hostcache.v  "ack <= #1 1'b0" -> "ack <= 1'b0" (as host832/run.sh: the
#                delayed default makes the ack a 1 ns glitch in simulation)
#   hostcache.v, dpram_inf_generic.v: a `timescale line (xelab warning)
# The test ROMs use the fw/ctrl_boot_rv ROM template, as the committed boot
# ROM does; every program clears x1-x31 at reset (the simulated register
# file starts as X), as fw/ctrl_boot_rv/crt0.S does.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TESTS="t_lanes t_hwoff t_b2b t_spibusy t_irq"
MATRIX="2,0 8,0 20,0 2,8 8,8 20,8"
XW=${EXTRA_WS:-0}
run="$HERE/run_${RUNTAG:-wt}"

die() { echo "FAILED: $*"; exit 1; }
X() { "$VIVADO_PATH/bin/$@" >> "$run/compile.log" 2>&1 || { echo "FAILED: $*"; tail -20 "$run/compile.log"; exit 1; }; }

# setup: run directory, RTL copies with the simulation fixes, the mutant
# bridge and fast-master variants, test ROMs
setup() {
	rm -rf "$run"; mkdir -p "$run/src" || die "mkdir $run"
	cd "$run" || die "cd $run"
	: > compile.log
	for f in rtl/host/cfide.vhd rtl/host/832_bridge.vhd rtl/host/hostcache.v rtl/sdram/dpram_inf_generic.v \
	         rtl/host/rv_hostcpu.v rtl/host/vexriscv/VexOsd.v; do
		cp "$ROOT/$f" src/ || die "copy $f"
	done
	sed -i "s/ack <= #1 1'b0;/ack <= 1'b0;/" src/hostcache.v
	grep -q "ack <= #1" src/hostcache.v && die "hostcache #1 fix not applied"
	sed -i '1i `timescale 1ns/1ps' src/hostcache.v src/dpram_inf_generic.v

	# mutant bridge
	[ "$(grep -c -- '-- 4PHASE' src/832_bridge.vhd)" = 1 ] || die "832_bridge.vhd: not exactly one -- 4PHASE line"
	sed 's/^\( *\)state <= hw_release; -- 4PHASE.*/\1state <= waiting; -- 4PHASE MUTANT/' \
		src/832_bridge.vhd > src/832_bridge_mutant.vhd
	grep -q 'state <= waiting; -- 4PHASE MUTANT' src/832_bridge_mutant.vhd || die "mutant sed not applied"

	# fast master: dBus command accepted in the ack cycle (see the header)
	python3 - src/rv_hostcpu.v src/rv_hostcpu_fast.v <<'EOF' || die "fast-master patch not applied"
import sys
s = open(sys.argv[1]).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
sub("  reg           last;      // current request is the last of the transaction\n", "")
sub("  wire dBus_cmd_ready = ~busy;",
    "  reg  last;      // current request is the last of the transaction\n"
    "  wire done_now = req & ack & last;   // bench fast master\n"
    "  wire dBus_cmd_ready = ~busy | done_now;")
sub("  wire d_fire = ~busy & dBus_cmd_valid;", "  wire d_fire = (~busy | done_now) & dBus_cmd_valid;")
sub("  wire i_fire = ~busy & ~dBus_cmd_valid & iBus_cmd_valid;",
    "  wire i_fire = ~busy & ~done_now & ~dBus_cmd_valid & iBus_cmd_valid;")
# the ack block first, so a command accepted in the ack cycle wins
a = s.index("      if (req && ack) begin")
b = s.index("    end\n  end\n\n  // ------------------------------------------------------- simulation only")
ack = s[a:b]
s = s[:a] + s[b:]
f = s.index("      if (d_fire || i_fire) begin")
s = s[:f] + ack + s[f:]
open(sys.argv[2], "w").write(s)
EOF

	make -s -C "$HERE" B="$run/build" > make.log 2>&1 || { tail -20 make.log; die "make test ROMs (make.log)"; }
	X xvlog -sv "$ROOT/rtl/host/i2c_master_mmio.sv" "$ROOT/rtl/openaars/adv7511/i2c_master.v"
	X xvlog src/VexOsd.v src/hostcache.v src/dpram_inf_generic.v "$HERE/sdram_host_model.v" "$HERE/tb_host_bridge.v"
	X xvhdl src/cfide.vhd
}

# variant <bridge vhd> <rv_hostcpu v>: (re)compile the two variable sources
variant() {
	X xvlog "src/$2"
	X xvhdl "src/$1"
}

# snapshot <test> <name>: compile the test's ROM as built, elaborate snapshot
# <name> with EXTRA_WS=$XW
snapshot() {
	local t=$1
	local rom="$run/build/$t/OSDBoot_rv_ROM.vhd"
	[ -f "$rom" ] || die "no ROM for $t (sw/$t.S or .c, TESTS in Makefile)"
	grep -q '^shared variable ram' "$rom" || die "$t: ROM not built from the fw/ctrl_boot_rv template"
	X xvhdl "$rom"
	X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "$2"
}

# one <snapshot> <test> <slat> <sjit> <expect PASS|FAIL|ANY> <label>: one run
one() {
	local snap=$1 t=$2 s=$3 j=$4 exp=$5 label=$6
	local log="$run/${snap}_s${s}_j${j}.log" hex=""
	[ -f "$HERE/sw/$t.sdram.hex" ] && hex="-testplusarg SDRAM_HEX=$HERE/sw/$t.sdram.hex"
	[ -n "${SDRAM_HEX_FILE:-}" ] && hex="-testplusarg SDRAM_HEX=$SDRAM_HEX_FILE"
	# shellcheck disable=SC2046,SC2086
	"$VIVADO_PATH/bin/xsim" "$snap" -R --onfinish quit -testplusarg "TEST=$t" \
		-testplusarg "SLAT=$s" -testplusarg "SJIT=$j" -testplusarg "SEED=${SEED:-1}" $hex \
		$(for x in ${XARGS:-}; do echo -testplusarg "${x#+}"; done) > "$log" 2>&1
	local res; res=$(grep -m1 -E '^=== (PASS|FAIL)' "$log" || echo "=== NO RESULT")
	local cyc; cyc=$(sed -n 's/.*, main done \(-*[0-9]*\), cycles .*/\1/p' "$log")
	local stale; stale=$(sed -n 's/.*stale acks \([0-9]*\),.*/\1/p' "$log")
	local tag="$label$t SLAT=$s SJIT=$j EXTRA_WS=$XW: $res (main done at cycle ${cyc:-?}, stale acks ${stale:-?})"
	case "$exp:$res" in
		ANY:*)              echo "info $tag"; return 0 ;;
		"$exp:=== $exp"*)   echo "ok   $tag"; return 0 ;;
		*)                  echo "BAD  $tag, expected $exp ($log)"; return 1 ;;
	esac
}

matrix() {   # matrix <snapshot> <test> <expect> <label>
	local rc=0 c
	for c in $MATRIX; do one "$1" "$2" "${c%,*}" "${c#*,}" "$3" "$4" || rc=1; done
	return $rc
}

# boot <boot|boot_nofile>: the committed boot ROM from the SD card model
boot() {
	local t=$1 rom="fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd" exp st
	local log="$run/tb_${t}_x${XW}_s${SLAT:-8}_j${SJIT:-0}.log"
	local card="$run/boot/card.img" to=40000000
	[ "$t" = boot_nofile ] && { card="$run/boot/card_nofile.img"; to=27000000; }
	card=${BOOT_CARD:-$card}
	[ ${#card} -le 1024 ] || die "card image path longer than 1024 characters (sd_spi_model's +SD_IMG buffer): $card"
	exp="$HERE/boot/expect.txt"
	[ "$t" = boot_nofile ] && exp="$HERE/boot/expect_nofile.txt"
	make -s -C "$HERE/boot" B="$run/boot" > make_boot.log 2>&1 || { tail -20 make_boot.log; die "make boot firmware/cards (make_boot.log)"; }
	# the gate is the committed ROM: a modified one still runs, but the run fails
	if git -C "$ROOT" diff --quiet HEAD -- "$rom"; then st="unmodified (= git HEAD)"; else st="BAD  MODIFIED against git HEAD"; fi
	echo "boot ROM: $rom $st, sha256 $(sha256sum "$ROOT/$rom" | cut -c1-16)" | tee "$run/results.txt"
	X xvlog -d RV_HOSTCPU_STATS src/rv_hostcpu.v
	X xvhdl src/832_bridge.vhd
	X xvlog -d SDCARD -d RV_HOSTCPU_STATS "$ROOT/sim/common/sd_spi_model.v" "$HERE/tb_host_bridge.v"
	X xvhdl "$ROOT/$rom"
	X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "tb_${t}_x$XW"
	local t0=$SECONDS
	# shellcheck disable=SC2046,SC2086
	"$VIVADO_PATH/bin/xsim" "tb_${t}_x$XW" -R --onfinish quit -testplusarg "TEST=$t" \
		-testplusarg "SLAT=${SLAT:-8}" -testplusarg "SJIT=${SJIT:-0}" -testplusarg "SEED=${SEED:-1}" \
		-testplusarg "SD_IMG=$card" -testplusarg "TIMEOUT=${BOOT_TIMEOUT:-$to}" \
		$(for x in ${XARGS:-}; do echo -testplusarg "${x#+}"; done) > "$log" 2>&1
	local secs=$((SECONDS - t0))
	sed "s/@IMG@/$(cat "$run/boot/img.txt")/" "$exp" > "$run/$t.expect"
	grep -E '^(UART|ERRORCODE): ' "$log" > "$run/$t.got"
	{
		grep -E '^=== (BOOT|STATS|HW accesses|cycle limit|SD card)' "$log"
		if diff -u "$run/$t.expect" "$run/$t.got" > "$run/$t.diff"; then
			echo "ok   log = $(basename "$exp") ($(wc -l < "$run/$t.got") lines)"
		else
			echo "BAD  log differs from $(basename "$exp"): $run/$t.diff"
		fi
		grep -q '^SD: image .* loaded' "$log" || echo "BAD  the SD model did not load $card"
		grep -qE '^UART: .*(TRAP|EXC)' "$log" && echo "BAD  TRAP/EXC on the UART"
		if grep -q '^=== PASS' "$log"; then echo "ok   bench verdict: === PASS"
		else echo "BAD  bench verdict: $(grep -m1 -E '^=== (PASS|FAIL)' "$log" || echo none) ($log)"; fi
		echo "xsim wall time ${secs} s"
	} | tee -a "$run/results.txt"
	if grep -q 'BAD' "$run/results.txt"; then echo "=== $t FAILED"; return 1; fi
	echo "=== $t PASS"
}

case "${1:-}" in
	""|-h|--help) sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 0 ;;
	boot|boot_nofile)
		setup
		boot "$1"
		exit $?
		;;
	all)
		setup
		variant 832_bridge.vhd rv_hostcpu.v
		for t in $TESTS; do snapshot "$t" "tb_${t}_x$XW"; done
		for t in $TESTS; do matrix "tb_${t}_x$XW" "$t" PASS ""; done | tee "$run/results.txt"
		if grep -q '^BAD' "$run/results.txt"; then echo "=== SOME FAILED"; exit 1; fi
		echo "=== ALL PASS ($(grep -c '^ok' "$run/results.txt") runs)"
		;;
	mutant)
		setup
		echo "mutant bridge: $(grep -- '-- 4PHASE' src/832_bridge_mutant.vhd | sed 's/^ *//')"
		variant 832_bridge_mutant.vhd rv_hostcpu_fast.v
		for XW in 0 1 2 3; do snapshot t_b2b "tb_t_b2b_mutfast_x$XW"; done
		variant 832_bridge.vhd rv_hostcpu_fast.v
		for XW in 0 1 2 3; do snapshot t_b2b "tb_t_b2b_fast_x$XW"; done
		variant 832_bridge_mutant.vhd rv_hostcpu.v
		XW=0; snapshot t_b2b "tb_t_b2b_mut_x$XW"
		{
			XW=0; matrix "tb_t_b2b_mutfast_x$XW" t_b2b FAIL "gate    mutant bridge + fast master: "
			for XW in 0 1 2 3; do
				matrix "tb_t_b2b_fast_x$XW" t_b2b PASS "control real bridge + fast master:   "
			done
			XW=0; one "tb_t_b2b_mut_x$XW" t_b2b 8 0 ANY "info    mutant bridge + rv_hostcpu:  "
			for XW in 1 2 3; do
				one "tb_t_b2b_mutfast_x$XW" t_b2b 8 0 ANY "info    mutant bridge + fast master: "
			done
		} | tee "$run/results.txt"
		if grep -q '^BAD' "$run/results.txt"; then echo "=== MUTANT SURVIVED or CONTROL FAILED"; exit 1; fi
		echo "=== MUTANT CAUGHT ($(grep -c '^ok.*gate' "$run/results.txt") gate runs FAIL, $(grep -c '^ok.*control' "$run/results.txt") control runs PASS)"
		;;
	dhry)
		opt=${DHRY_OPT:-O2}
		make -s -C "$ROOT/fw/dhrystone_rv" "l2_$opt.hex" || die "make fw/dhrystone_rv l2_$opt.hex"
		export SDRAM_HEX_FILE="$ROOT/fw/dhrystone_rv/l2_$opt.hex"
		XARGS="${XARGS:-} +TIMEOUT=${DHRY_TIMEOUT:-40000000}"
		setup
		variant 832_bridge.vhd rv_hostcpu.v
		snapshot dhry "tb_dhry_x$XW"
		rc=0
		one "tb_dhry_x$XW" dhry "${SLAT:-8}" "${SJIT:-0}" PASS "" || rc=1
		log="$run/tb_dhry_x${XW}_s${SLAT:-8}_j${SJIT:-0}.log"
		grep -E '^UART: ' "$log"
		if grep -q 'should be' "$log"; then echo "BAD  Dhrystone result check mismatch"; rc=1; fi
		grep -q '^UART: Result checks: [0-9]* compared, 0 wrong' "$log" || { echo "BAD  no 'Result checks ... 0 wrong' line"; rc=1; }
		t1=$(sed -n 's/^=== TIME 1 cycle //p' "$log"); t2=$(sed -n 's/^=== TIME 2 cycle //p' "$log")
		if [ -n "$t1" ] && [ -n "$t2" ]; then
			echo "dhry_$opt L2: $((t2 - t1)) cycles per 100 runs (SLAT=${SLAT:-8} SJIT=${SJIT:-0} EXTRA_WS=$XW)"
		else echo "BAD  TIME stamps missing"; rc=1; fi
		grep -E '^=== (HW accesses)' "$log"
		exit $rc
		;;
	*)
		setup
		variant 832_bridge.vhd rv_hostcpu.v
		rc=0
		for t in "$@"; do snapshot "$t" "tb_${t}_x$XW"; done
		for t in "$@"; do one "tb_${t}_x$XW" "$t" "${SLAT:-8}" "${SJIT:-0}" PASS "" || rc=1; done
		exit $rc
		;;
esac
