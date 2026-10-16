#!/bin/bash
# L2 host-bridge bench (xsim): the RISC-V host CPU through the real
# EightThirtyTwo_Bridge, hostcache and cfide.  See tb_host_bridge.v, README.md.
#
#   bash sim/host_bridge/run.sh all          # every test x SLAT {2,8,20} x SJIT {0,8}
#   bash sim/host_bridge/run.sh mutant       # the four-phase handshake's teeth (below)
#   bash sim/host_bridge/run.sh t_lanes ...  # named tests at SLAT/SJIT from env
#   SLAT=20 SJIT=8 EXTRA_WS=3 bash sim/host_bridge/run.sh t_b2b
#
# Environment: RUNTAG (run directory run_${RUNTAG:-wt}), SLAT (8), SJIT (0),
# EXTRA_WS (0, the bridge's rv_extra_ws), SEED (1), XARGS (extra plusargs,
# e.g. "+VERBOSE=1"), VIVADO_PATH.
#
# mutant: t_b2b over the SLAT/SJIT matrix in three legs.
#   gate     mutant bridge + fast master   every run must FAIL
#   control  real bridge   + fast master   every run must PASS
#   info     mutant bridge + real rv_hostcpu, one run, result printed only
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
# Simulation fixes on the copies (never on rtl/):
#   hostcache.v  "ack <= #1 1'b0" -> "ack <= 1'b0" (as host832/run.sh: the
#                delayed default makes the ack a 1 ns glitch in simulation)
#   cfide.vhd    timecnt and clkgen start at 0.  Neither has a reset; an FPGA
#                register powers up at 0, in simulation they stay 'U': TIMER
#                never counts and the UART never shifts (txbusy stays high
#                after the first character, the second write never acks)
#   hostcache.v, dpram_inf_generic.v: a `timescale line (xelab warning)
#   OSDBoot_rv_ROM.vhd (per test, *_sim.vhd next to it): port B's write is
#                removed.  Ports A and B are two processes assigning the one
#                signal "ram"; each has a driver for all of it, port B's
#                holding the initial image, so every port-A write that
#                changes a bit resolves to 'X' (stack, .data, t_lanes 0x1800).
#                Synthesis infers a true dual-port BRAM; port B is unused
#                (we2 = '0') in the bridge.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TESTS="t_lanes t_hwoff t_b2b t_spibusy"
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
	for sig in timecnt clkgen; do
		sed -i "s/^\( *signal $sig *: *std_logic_vector([0-9]* downto 0)\);/\1 := (others => '0');/" src/cfide.vhd
		grep -q "signal $sig .*:= (others => '0');" src/cfide.vhd || die "cfide $sig init not applied"
	done
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

# snapshot <test> <name>: compile the test's ROM, elaborate snapshot <name>
snapshot() {
	local t=$1
	local rom="$run/build/$t/OSDBoot_rv_ROM.vhd" simrom="$run/build/$t/OSDBoot_rv_ROM_sim.vhd"
	[ -f "$rom" ] || die "no ROM for $t (sw/$t.S or .c, TESTS in Makefile)"
	sed 's/^\( *\)ram(to_integer(unsigned(addr2))).*<= d2.*;/\1null; -- run.sh: port B write removed for simulation/' "$rom" > "$simrom"
	[ "$(grep -c 'port B write removed' "$simrom")" = 1 ] || die "$t: ROM port B fix not applied"
	X xvhdl "$simrom"
	X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "$2"
}

# one <snapshot> <test> <slat> <sjit> <expect PASS|FAIL|ANY> <label>: one run
one() {
	local snap=$1 t=$2 s=$3 j=$4 exp=$5 label=$6
	local log="$run/${snap}_s${s}_j${j}.log" hex=""
	[ -f "$HERE/sw/$t.sdram.hex" ] && hex="-testplusarg SDRAM_HEX=$HERE/sw/$t.sdram.hex"
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

case "${1:-}" in
	""|-h|--help) sed -n '2,46p' "$0"; exit 0 ;;
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
		snapshot t_b2b "tb_t_b2b_mutfast_x$XW"
		variant 832_bridge.vhd rv_hostcpu_fast.v
		snapshot t_b2b "tb_t_b2b_fast_x$XW"
		variant 832_bridge_mutant.vhd rv_hostcpu.v
		snapshot t_b2b "tb_t_b2b_mut_x$XW"
		{
			matrix "tb_t_b2b_mutfast_x$XW" t_b2b FAIL "gate    mutant bridge + fast master: "
			matrix "tb_t_b2b_fast_x$XW" t_b2b PASS "control real bridge + fast master:   "
			one "tb_t_b2b_mut_x$XW" t_b2b 8 0 ANY "info    mutant bridge + rv_hostcpu:  "
		} | tee "$run/results.txt"
		if grep -q '^BAD' "$run/results.txt"; then echo "=== MUTANT SURVIVED or CONTROL FAILED"; exit 1; fi
		echo "=== MUTANT CAUGHT ($(grep -c '^ok.*gate' "$run/results.txt") gate runs FAIL, $(grep -c '^ok.*control' "$run/results.txt") control runs PASS)"
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
