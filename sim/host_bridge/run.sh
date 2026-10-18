#!/bin/bash
# L2 host-bridge bench: the RISC-V host CPU through the real
# EightThirtyTwo_Bridge, hostcache and cfide.  See tb_host_bridge.v, README.md.
#
# Simulator: SIM=xsim (default; 4-state, the X-checking reference) or
# SIM=verilator (Verilator 5, --binary --timing, 2-state: the bench's X
# checks cannot fire there).  Under Verilator the VHDL (cfide, the bridge, the
# ROM) is first converted to Verilog with ghdl --synth (GHDL 4.1), per
# snapshot, from the same run copies (mutants included).  Same targets,
# plusargs, verdicts, logs and run directories.
#   SIM=verilator bash sim/host_bridge/run.sh all
#   bash sim/host_bridge/run.sh compare <RUNTAG a> <RUNTAG b>
#        every tb_*.log of both run directories: identical apart from the
#        simulators' own lines (exit 1 otherwise)
#
#   bash sim/host_bridge/run.sh all          # every test x SLAT {2,8,20} x SJIT {0,8}
#   bash sim/host_bridge/run.sh mutant       # the four-phase handshake's teeth (below)
#   bash sim/host_bridge/run.sh irqmut       # the interrupt controller's teeth (below)
#   bash sim/host_bridge/run.sh t_lanes ...  # named tests at SLAT/SJIT from env
#   SLAT=20 SJIT=8 EXTRA_WS=3 bash sim/host_bridge/run.sh t_b2b
#   bash sim/host_bridge/run.sh boot         # committed boot ROM loads RV32OSDA.BIN
#   bash sim/host_bridge/run.sh boot_nofile  # card without it: error path
#   bash sim/host_bridge/run.sh fwboot       # the real firmware to its main loop
#   bash sim/host_bridge/run.sh fwboot_trap  # the same, trap constructor linked in
#   bash sim/host_bridge/run.sh fwboot_cfg   # fwboot with an 832 config file to convert
#
# Environment: RUNTAG (run directory run_${RUNTAG:-wt}), SLAT (8), SJIT (0),
# EXTRA_WS (0, the bridge's rv_extra_ws), SEED (1), XARGS (extra plusargs,
# e.g. "+VERBOSE=1"), VIVADO_PATH, SIM, GHDL (ghdl), VERILATOR (verilator),
# JOBS (Verilator build jobs, nproc), OBJCACHE (ccache if present; empty =
# none); boot runs also BOOT_TIMEOUT (clk_114
# cycles; boot 40000000, boot_nofile 27000000: the cycle limit that ends it,
# 0.76 M cycles after the retry's "Initializing SD card" line) and
# BOOT_CARD (another card image, e.g. a corrupted copy); fwboot runs also
# FW (the RV32OSDA.BIN to put on the card, default
# fw/ctrl_rv/build/RV32OSDA.BIN: make -C fw/ctrl_rv first) and
# FWBOOT_TIMEOUT (clk_114 cycles; defaults below).
#
# boot / boot_nofile: the committed fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd,
# compiled unmodified (VHDL-93), boots from the SD card model (bench compiled
# with -d SDCARD -d RV_HOSTCPU_STATS, rv_hostcpu with -d RV_HOSTCPU_STATS).  sim/host_bridge/boot
# builds RV32OSDA.BIN and the card images into <run>/boot.  The run's
# "UART:" and "ERRORCODE:" lines must equal boot/expect.txt (@IMG@ = the
# line in <run>/boot/img.txt) or boot/expect_nofile.txt line for line, and
# the bench verdict must be "=== PASS".  Results in <run>/results.txt.
#
# fwboot / fwboot_trap: the committed boot ROM loads the real firmware from
# a 16 MB card (sim/host_bridge/fwboot: $FW + the decoy, + DRIVESND.BIN for
# fwboot, no config, no kickstart); the bench (-d SDCARD -d FWBOOT -d RV_HOSTCPU_STATS) answers
# for the Minimig SPI slaves with minimig_spi_stub.v and logs every SPI frame
# to <run>/spi.txt; cfide is built with havei2c = true (README).  The run
# ends at FWBOOT_TIMEOUT.
#   fwboot       fwboot/milestones.txt in order (spitrace.py check: UART
#                lines and SPI frames), no EXC/TRAP line, bench "=== PASS"
#                (no X, no stale ack, no bench error; one bench error is an
#                OSD reply gap below +OSD_MIN_GAP, default 40: XARGS=+OSD_MIN_GAP=<n>)
#   fwboot_trap  the firmware of the source tree linked with
#                fwboot/smoke_trap.o (make -C fw/ctrl_rv EXTRA_OBJS=...,
#                into <run>/fwboot/trapfw; FW is not used): the UART shows
#                the line of <run>/fwboot/trap_expect.txt (EXC mcause 2,
#                mepc = smoke_trap from the map, mtval FFFFFFFF), no
#                HandleFpga frame, bench "=== PASS"
#   fwboot_cfg   fwboot on card_cfg.img (the fwboot card plus an 832
#                MINMGAA.CFG, gold/mkcfg832.py's l2 case): the milestones of
#                fwboot/milestones_cfg.txt (the first-boot conversion),
#                then the card as the run left it (+SD_SAVE): mtools reads
#                MINMGAR.CFG == cfgconv --to-rv MINMGAA.CFG and MINMGAA.CFG
#                unchanged, fsck.fat -n clean; no EXC/TRAP, "=== PASS"
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
# irqmut: t_irqctl at SLAT=8 SJIT=0 EXTRA_WS=0 with three run copies of
# cfide.vhd and the real one:
#   a clear-all   an IRQ_PENDING read clears all of PENDING, the edges of that
#                 cycle too ("-- IRQ SET WINS" line)     must FAIL test 4
#   b no set-wins the read cycle clears the returned bits and drops that
#                 cycle's edges                          must FAIL test 4
#   c no LEVEL    PENDING ignores MODE ("-- IRQ MODE MUX" line)
#                                                        must FAIL test 9
#   control       the real cfide                         must PASS
# "FAIL test 4" = a "BENCH ERROR ... t_irqctl test 4 (set wins)" line;
# "FAIL test 9" = DONE code 9xx.
#
# Steps: copy the RTL into the run directory (src/), apply the simulation
# fixes below, build the test ROMs there (make B=<run>/build), compile, then
# per test compile its ROM and elaborate a snapshot; xsim runs one at a time.
# Verilator: per snapshot, ghdl -a (verilator/blackbox.vhd, the cfide and
# bridge variants, the test's ROM) into ghdl_<snapshot>/, ghdl --synth of the
# bridge (cpu_riscv, rv_extra_ws = EXTRA_WS) and of cfide (the bench's
# generics), then verilator into vl_<snapshot>/Vtb_host_bridge (-DHB_GHDL,
# waivers in verilator/l2.vlt).  The conversion must find the ROM's RAM and
# keep its contents (verilator/romcheck.py).
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
SIM=${SIM:-xsim}
GHDL=${GHDL:-ghdl}
VERILATOR=${VERILATOR:-verilator}
JOBS=${JOBS:-$(nproc)}
case "$SIM" in
	xsim|verilator) ;;
	*) echo "SIM=$SIM: must be xsim or verilator"; exit 2 ;;
esac
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# GHDL: cfide.vhd needs the Synopsys packages with explicit operator
# visibility (plain -fsynopsys makes its "=" ambiguous)
GHDLFLAGS="--std=93c --ieee=synopsys -fexplicit"
# cfide's generics for the conversion: derived from the bench's xsim instance
# (tb_host_bridge.v, "cfide #( ... ) mycfide"), see cfide_generics below
CFIDE_GENERICS=""
# the real Verilog of verilator/blackbox.vhd's i2c_master_mmio, linked when the
# converted cfide instantiates it (havei2c = true)
I2C_V="$ROOT/rtl/host/i2c_master_mmio.sv $ROOT/rtl/openaars/adv7511/i2c_master.v"
VB=832_bridge.vhd VR=rv_hostcpu.v VC=cfide.vhd   # Verilator: the current variant

TESTS="t_lanes t_hwoff t_b2b t_spibusy t_irq t_irqctl t_irqapi"
MATRIX="2,0 8,0 20,0 2,8 8,8 20,8"
XW=${EXTRA_WS:-0}
run="$HERE/run_${RUNTAG:-wt}"

die() { echo "FAILED: $*"; exit 1; }
X() { "$VIVADO_PATH/bin/$@" >> "$run/compile.log" 2>&1 || { echo "FAILED: $*"; tail -20 "$run/compile.log"; exit 1; }; }

# cfide_generics [fwboot]: CFIDE_GENERICS (-g<name>=true|false) from the
# bench's instance, one per generic of the cfide entity; dies if the bench
# misses one or sets one cfide does not have, so the two simulators build the
# same cfide.  `HB_HAVEI2C is the value of the bench's "`define HB_HAVEI2C
# ... // FWBOOT" line with the argument fwboot, else of its "// other runs"
# line.
cfide_generics() {
	local names tbg n hi tag="other runs"
	[ "${1:-}" = fwboot ] && tag=FWBOOT
	names=$(sed -n '/^entity cfide is$/,/^ *port($/s/^ *\([a-z0-9_]*\) *: *in boolean.*/\1/p' "$ROOT/rtl/host/cfide.vhd")
	hi=$(sed -n "s|^\`define HB_HAVEI2C \(1'b[01]\) *// $tag\$|\1|p" "$HERE/tb_host_bridge.v")
	[ "$(echo "$hi" | wc -w)" = 1 ] || die "tb_host_bridge.v: no single \`define HB_HAVEI2C line for '$tag'"
	tbg=$(sed -n '/^  cfide #($/,/^  ) mycfide ($/p' "$HERE/tb_host_bridge.v" | sed "s/\`HB_HAVEI2C/$hi/" \
		| grep -o "\.[a-z0-9_]*(1'b[01])" \
		| sed "s/^\.\([a-z0-9_]*\)(1'b0)$/-g\1=false/; s/^\.\([a-z0-9_]*\)(1'b1)$/-g\1=true/")
	[ -n "$names" ] || die "no boolean generics found in rtl/host/cfide.vhd's entity"
	for n in $names; do
		echo "$tbg" | grep -qx -- "-g$n=\(true\|false\)" || die "tb_host_bridge.v: the cfide instance does not set generic $n"
	done
	[ "$(echo "$tbg" | wc -l)" = "$(echo "$names" | wc -w)" ] \
		|| die "tb_host_bridge.v: the cfide instance sets other generics than cfide.vhd has ($(echo $names))"
	CFIDE_GENERICS=$(echo $tbg)
}
cfide_generics

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

	# interrupt controller mutants (irqmut, see the header)
	python3 - src/cfide.vhd <<'EOF' || die "cfide mutant patch not applied"
import re, sys
s = open(sys.argv[1]).read()
def mutant(tag, marker, new):
    lines = [l for l in s.split("\n") if l.rstrip().endswith(marker)]
    assert len(lines) == 1, marker
    ind = re.match(" *", lines[0]).group(0)
    open(sys.argv[1].replace(".vhd", "_irqmut_%s.vhd" % tag), "w").write(
        s.replace(lines[0], ind + new + " -- IRQ MUTANT " + tag))
mutant("a", "-- IRQ SET WINS",
       "irq_pend_nx <= (others => '0') when irq_rd = '1' "
       "else (irq_pend or irq_edge) and not irq_mode;")
mutant("b", "-- IRQ SET WINS",
       "irq_pend_nx <= (irq_pend and not irq_clr and not irq_mode) when irq_rd = '1' "
       "else (irq_pend or irq_edge) and not irq_mode;")
mutant("c", "-- IRQ MODE MUX", "return pend;")
EOF

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
	[ "$SIM" = verilator ] && return 0
	X xvlog -sv "$ROOT/rtl/host/i2c_master_mmio.sv" "$ROOT/rtl/openaars/adv7511/i2c_master.v"
	X xvlog src/VexOsd.v src/hostcache.v src/dpram_inf_generic.v "$HERE/sdram_host_model.v" "$HERE/tb_host_bridge.v"
	X xvhdl src/cfide.vhd
}

# variant <bridge vhd> <rv_hostcpu v>: (re)compile the two variable sources
# (Verilator: remember them for the next snapshots)
variant() {
	if [ "$SIM" = verilator ]; then VB=$1; VR=$2; return 0; fi
	X xvlog "src/$2"
	X xvhdl "src/$1"
}

# cfide_variant <cfide vhd>: the cfide of the next snapshots
cfide_variant() {
	if [ "$SIM" = verilator ]; then VC=$1; return 0; fi
	X xvhdl "src/$1"
}

# convert <dir> <rom vhd>: ghdl --synth of the current variant (src/$VB,
# src/$VC) with that ROM -> <dir>/bridge.v (EightThirtyTwo_Bridge, the ROM
# inside, rv_hostcpu and hostcache as instances of the Verilog modules) and
# <dir>/cfide.v.  The entities of verilator/blackbox.vhd come out as empty
# modules: they are deleted (and checked gone), Verilator links the real
# Verilog (vbuild).
convert() {
	local d=$1 rom=$2 bb
	rm -rf "$d"; mkdir -p "$d" || die "mkdir $d"
	# shellcheck disable=SC2086
	"$GHDL" -a $GHDLFLAGS --workdir="$d" "$HERE/verilator/blackbox.vhd" "src/$VC" "src/$VB" "$rom" \
		> "$d/analyse.log" 2>&1 || { cat "$d/analyse.log"; die "ghdl -a ($d/analyse.log)"; }
	# shellcheck disable=SC2086
	"$GHDL" --synth $GHDLFLAGS --workdir="$d" -gcpu_riscv=true -grv_extra_ws="$XW" --out=verilog \
		EightThirtyTwo_Bridge > "$d/bridge.v" 2> "$d/bridge.log" || { cat "$d/bridge.log"; die "ghdl --synth bridge ($d/bridge.log)"; }
	# shellcheck disable=SC2086
	"$GHDL" --synth $GHDLFLAGS --workdir="$d" $CFIDE_GENERICS --out=verilog \
		cfide > "$d/cfide.v" 2> "$d/cfide.log" || { cat "$d/cfide.log"; die "ghdl --synth cfide ($d/cfide.log)"; }
	grep -q 'found RAM "ram", width: 32 bits, depth: 2048' "$d/bridge.log" \
		|| die "ghdl --synth did not infer the ROM's RAM ($d/bridge.log)"
	python3 "$HERE/verilator/romcheck.py" "$rom" "$d/bridge.v" > "$d/romcheck.log" 2>&1 \
		|| { cat "$d/romcheck.log"; die "converted ROM contents ($rom)"; }
	for bb in $(sed -n 's/^entity \([a-z0-9_]*\) is$/\1/p' "$HERE/verilator/blackbox.vhd"); do
		sed -i "/^module $bb\$/,/^endmodule\$/d" "$d/bridge.v" "$d/cfide.v"
		# the delete must have worked: a stub left in would shadow the real module
		grep -qE "^ *module +$bb\b" "$d/bridge.v" "$d/cfide.v" \
			&& die "black-box module $bb still in $d/bridge.v or cfide.v after the delete (GHDL output format?)"
	done
	sed -i '1i `timescale 1ns/1ps' "$d/bridge.v" "$d/cfide.v"
}

# vbuild <name> <rom vhd> [defines]: convert, then verilate snapshot <name>
# -> $run/vl_<name>/Vtb_host_bridge (EXTRA_WS=$XW, rv_hostcpu src/$VR).
# Warnings are fatal (waivers in verilator/l2.vlt); X constants and
# uninitialised variables are 0.  C++ with -O2, through ccache if present.
vbuild() {
	local name=$1 rom=$2 sd="" i2c="" stub=""; shift 2
	local d="$run/ghdl_$name"
	case " $* " in *" -DSDCARD "*) sd="$ROOT/sim/common/sd_spi_model.v" ;; esac
	case " $* " in *" -DFWBOOT "*) stub="$HERE/minimig_spi_stub.v" ;; esac
	convert "$d" "$rom"
	# havei2c = true: cfide.v instantiates i2c_master_mmio, link the real one
	grep -qE '^ *i2c_master_mmio +[a-z0-9_]+ *\(' "$d/cfide.v" && i2c=$I2C_V
	rm -rf "$run/vl_$name"
	# shellcheck disable=SC2086
	OBJCACHE=${OBJCACHE-$(command -v ccache)} "$VERILATOR" --binary --timing -j "$JOBS" \
		-MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" --x-assign 0 --x-initial 0 \
		-DHB_GHDL "$@" --top-module tb_host_bridge -GEXTRA_WS="$XW" \
		--Mdir "$run/vl_$name" -o Vtb_host_bridge "$HERE/verilator/l2.vlt" \
		"$d/bridge.v" "$d/cfide.v" "src/$VR" src/VexOsd.v src/hostcache.v src/dpram_inf_generic.v \
		"$HERE/sdram_host_model.v" $sd $stub $i2c "$HERE/tb_host_bridge.v" > "$run/compile_$name.log" 2>&1
	if [ ! -x "$run/vl_$name/Vtb_host_bridge" ]; then
		grep -m20 -E '^%(Error|Warning)' "$run/compile_$name.log" || tail -20 "$run/compile_$name.log"
		die "verilator $name ($run/compile_$name.log)"
	fi
}

# snapshot <test> <name>: compile the test's ROM as built, elaborate snapshot
# <name> with EXTRA_WS=$XW
snapshot() {
	local t=$1
	local rom="$run/build/$t/OSDBoot_rv_ROM.vhd"
	[ -f "$rom" ] || die "no ROM for $t (sw/$t.S or .c, TESTS in Makefile)"
	grep -q '^shared variable ram' "$rom" || die "$t: ROM not built from the fw/ctrl_boot_rv template"
	if [ "$SIM" = verilator ]; then vbuild "$2" "$rom"; return 0; fi
	X xvhdl "$rom"
	X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "$2"
}

# simrun <snapshot> <log> <plusarg>...: one simulation (plusargs without +)
simrun() {
	local snap=$1 log=$2 x a=(); shift 2
	if [ "$SIM" = verilator ]; then
		for x; do a+=("+$x"); done
		"$run/vl_$snap/Vtb_host_bridge" "${a[@]}" > "$log" 2>&1
	else
		for x; do a+=(-testplusarg "$x"); done
		"$VIVADO_PATH/bin/xsim" "$snap" -R --onfinish quit "${a[@]}" > "$log" 2>&1
	fi
}

# xargs_list: XARGS as plusargs without the +
xargs_list() {
	local x
	for x in ${XARGS:-}; do echo "${x#+}"; done
}

# one <snapshot> <test> <slat> <sjit> <expect PASS|FAIL|ANY> <label>: one run
one() {
	local snap=$1 t=$2 s=$3 j=$4 exp=$5 label=$6
	local log="$run/${snap}_s${s}_j${j}.log" hex=()
	[ -f "$HERE/sw/$t.sdram.hex" ] && hex=("SDRAM_HEX=$HERE/sw/$t.sdram.hex")
	[ -n "${SDRAM_HEX_FILE:-}" ] && hex=("SDRAM_HEX=$SDRAM_HEX_FILE")
	# shellcheck disable=SC2046
	simrun "$snap" "$log" "TEST=$t" "SLAT=$s" "SJIT=$j" "SEED=${SEED:-1}" "${hex[@]}" $(xargs_list)
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
	if [ "$SIM" = verilator ]; then
		VB=832_bridge.vhd VR=rv_hostcpu.v VC=cfide.vhd
		vbuild "tb_${t}_x$XW" "$ROOT/$rom" -DSDCARD -DRV_HOSTCPU_STATS
	else
		X xvlog -d RV_HOSTCPU_STATS src/rv_hostcpu.v
		X xvhdl src/832_bridge.vhd
		X xvlog -d SDCARD -d RV_HOSTCPU_STATS "$ROOT/sim/common/sd_spi_model.v" "$HERE/tb_host_bridge.v"
		X xvhdl "$ROOT/$rom"
		X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "tb_${t}_x$XW"
	fi
	local t0=$SECONDS
	# shellcheck disable=SC2046
	simrun "tb_${t}_x$XW" "$log" "TEST=$t" "SLAT=${SLAT:-8}" "SJIT=${SJIT:-0}" "SEED=${SEED:-1}" \
		"SD_IMG=$card" "TIMEOUT=${BOOT_TIMEOUT:-$to}" $(xargs_list)
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
		echo "$SIM wall time ${secs} s"
	} | tee -a "$run/results.txt"
	if grep -q 'BAD' "$run/results.txt"; then echo "=== $t FAILED"; return 1; fi
	echo "=== $t PASS"
}

# fwboot <fwboot|fwboot_trap>: the real firmware from the SD card model
FWBOOT_TO=176400000        # fwboot: 1.5 x the cycle of the 20th KEYQ frame, 117,557,674 (README; DRIVESND.BIN on the card)
FWBOOT_CFG_TO=119600000    # fwboot_cfg: 1.5 x the 20th KEYQ frame of fwboot's card without DRIVESND.BIN, 79,672,738
FWBOOT_TRAP_TO=65900000   # fwboot_trap: 1.5 x the cycle of the EXC line, 43,926,505 (README)
fwboot() {
	local t=$1 rom="fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd" st to card fw
	local log="$run/tb_${t}_x${XW}_s${SLAT:-8}_j${SJIT:-0}.log"
	local ms="$HERE/fwboot/milestones.txt" save=() saved="$run/fwboot/card_cfg_saved.img"
	fw=$FWBIN
	if [ "$t" = fwboot ]; then
		[ -f "$fw" ] || die "no firmware $fw (make -C fw/ctrl_rv, or FW=<RV32OSDA.BIN>)"
		make -s -C "$HERE/fwboot" B="$run/fwboot" FW="$fw" all > make_fwboot.log 2>&1 \
			|| { tail -20 make_fwboot.log; die "make fwboot card (make_fwboot.log)"; }
		card="$run/fwboot/card.img"; to=$FWBOOT_TO
	elif [ "$t" = fwboot_cfg ]; then
		[ -f "$fw" ] || die "no firmware $fw (make -C fw/ctrl_rv, or FW=<RV32OSDA.BIN>)"
		make -s -C "$HERE/fwboot" B="$run/fwboot" FW="$fw" cfg > make_fwboot.log 2>&1 \
			|| { tail -20 make_fwboot.log; die "make fwboot_cfg card (make_fwboot.log)"; }
		card="$run/fwboot/card_cfg.img"; to=$FWBOOT_CFG_TO
		ms="$HERE/fwboot/milestones_cfg.txt"
		rm -f "$saved"
		[ ${#saved} -le 1024 ] || die "saved card path longer than 1024 characters: $saved"
		save=("SD_SAVE=$saved")
	else
		make -C "$HERE/fwboot" B="$run/fwboot" trap > make_fwboot.log 2>&1 \
			|| { tail -20 make_fwboot.log; die "make fwboot trap firmware/card (make_fwboot.log)"; }
		card="$run/fwboot/card_trap.img"; to=$FWBOOT_TRAP_TO
	fi
	[ ${#card} -le 1024 ] || die "card image path longer than 1024 characters (sd_spi_model's +SD_IMG buffer): $card"
	if git -C "$ROOT" diff --quiet HEAD -- "$rom"; then st="unmodified (= git HEAD)"; else st="BAD  MODIFIED against git HEAD"; fi
	echo "boot ROM: $rom $st, sha256 $(sha256sum "$ROOT/$rom" | cut -c1-16)" | tee "$run/results.txt"
	if [ "$t" != fwboot_trap ]; then
		echo "firmware: $fw, $(stat -c %s "$fw") bytes, sha256 $(sha256sum "$fw" | cut -c1-16)" | tee -a "$run/results.txt"
	else
		echo "firmware: $run/fwboot/trapfw/RV32OSDA.BIN (+ smoke_trap.o), expect: $(cat "$run/fwboot/trap_expect.txt")" \
			| tee -a "$run/results.txt"
	fi
	if [ "$SIM" = verilator ]; then
		VB=832_bridge.vhd VR=rv_hostcpu.v VC=cfide.vhd
		cfide_generics fwboot     # havei2c = true (the bench's FWBOOT define)
		vbuild "tb_${t}_x$XW" "$ROOT/$rom" -DSDCARD -DFWBOOT -DRV_HOSTCPU_STATS
	else
		X xvlog -d RV_HOSTCPU_STATS src/rv_hostcpu.v
		X xvhdl src/832_bridge.vhd
		X xvlog -d SDCARD -d FWBOOT -d RV_HOSTCPU_STATS "$ROOT/sim/common/sd_spi_model.v" \
			"$HERE/minimig_spi_stub.v" "$HERE/tb_host_bridge.v"
		X xvhdl "$ROOT/$rom"
		X xelab -debug off -generic_top "EXTRA_WS=$XW" tb_host_bridge -s "tb_${t}_x$XW"
	fi
	local t0=$SECONDS
	# shellcheck disable=SC2046
	simrun "tb_${t}_x$XW" "$log" "TEST=$t" "SLAT=${SLAT:-8}" "SJIT=${SJIT:-0}" "SEED=${SEED:-1}" \
		"SD_IMG=$card" "TIMEOUT=${FWBOOT_TIMEOUT:-$to}" "SPI_LOG=$run/spi.txt" "${save[@]}" $(xargs_list)
	local secs=$((SECONDS - t0))
	python3 -I "$HERE/spitrace.py" summary "$run/spi.txt" > "$run/spi_summary.txt" 2>&1
	{
		grep -E '^=== (BOOT|STATS|HW accesses|cycle limit|HandleFpga|SPI frames|OSD GAP|STACK)' "$log"
		grep -E '^BENCH ERROR' "$log" | sed 's/^/BAD  /'    # e.g. the OSD GAP check
		grep -q '^SD: image .* loaded' "$log" || echo "BAD  the SD model did not load $card"
		if [ "$t" != fwboot_trap ]; then
			if python3 -I "$HERE/spitrace.py" check "$ms" "$log" "$run/spi.txt" \
				> "$run/milestones.txt" 2>&1; then
				echo "ok   $(tail -1 "$run/milestones.txt") ($run/milestones.txt)"
			else
				grep '^BAD' "$run/milestones.txt"
				echo "BAD  $(tail -1 "$run/milestones.txt") ($run/milestones.txt)"
			fi
			grep -E '^UART: .*(EXC |TRAP )' "$log" | sed 's/^/BAD  /'
			[ "$t" = fwboot_cfg ] && fwboot_cfg_card "$saved"
		else
			# the boot ROM's last line has no newline: the EXC text ends that line
			if grep -qE "^UART: .*$(cat "$run/fwboot/trap_expect.txt")\$" "$log"; then
				echo "ok   UART line ends with: $(cat "$run/fwboot/trap_expect.txt")"
			else
				echo "BAD  no UART line '$(cat "$run/fwboot/trap_expect.txt")'; EXC/TRAP lines:"
				grep -E '^UART: .*(EXC |TRAP )' "$log" | sed 's/^/     /'
			fi
			n=$(python3 -I "$HERE/spitrace.py" count "$run/spi.txt" 10 00 00 00 00 00 00)
			if [ "$n" = 0 ]; then echo "ok   no HandleFpga frame"; else echo "BAD  $n HandleFpga frames after the trap"; fi
		fi
		if grep -q '^=== PASS' "$log"; then echo "ok   bench verdict: === PASS"
		else echo "BAD  bench verdict: $(grep -m1 -E '^=== (PASS|FAIL)' "$log" || echo none) ($log)"; fi
		echo "$SIM wall time ${secs} s"
	} | tee -a "$run/results.txt"
	if grep -q 'BAD' "$run/results.txt"; then echo "=== $t FAILED"; return 1; fi
	echo "=== $t PASS"
}

# fwboot_cfg_card <saved card>: the config files on the card the run left
# (mtools, fsck.fat): the firmware wrote MINMGAR.CFG = cfgconv --to-rv of
# the 832 file and left MINMGAA.CFG as it was
fwboot_cfg_card() {
	local img=$1 d="$run/fwboot/cfgcheck" off=$((2048 * 512))
	if [ ! -f "$img" ]; then echo "BAD  no saved card $img (+SD_SAVE)"; return; fi
	rm -rf "$d"; mkdir -p "$d"
	if ! MTOOLS_SKIP_CHECK=1 mcopy -n -i "$img@@$off" ::MINMGAR.CFG ::MINMGAA.CFG "$d/" 2> "$d/mcopy.err"; then
		echo "BAD  mcopy of MINMGAR.CFG / MINMGAA.CFG from the saved card: $(head -1 "$d/mcopy.err")"; return
	fi
	"$run/fwboot/cfgconv" --to-rv "$run/fwboot/cfg/MINMGAA.CFG" "$d/expect_rv.cfg" || { echo "BAD  cfgconv --to-rv"; return; }
	if cmp -s "$d/MINMGAR.CFG" "$d/expect_rv.cfg"; then echo "ok   card: MINMGAR.CFG == cfgconv --to-rv MINMGAA.CFG"
	else echo "BAD  card: MINMGAR.CFG differs from cfgconv --to-rv MINMGAA.CFG ($d)"; fi
	if cmp -s "$d/MINMGAA.CFG" "$run/fwboot/cfg/MINMGAA.CFG"; then echo "ok   card: MINMGAA.CFG unchanged"
	else echo "BAD  card: MINMGAA.CFG changed ($d)"; fi
	dd if="$img" of="$d/part.img" bs=512 skip=2048 status=none
	if PATH=$PATH:/usr/sbin:/sbin fsck.fat -n "$d/part.img" > "$d/fsck.txt" 2>&1; then echo "ok   card: fsck.fat -n clean"
	else echo "BAD  card: fsck.fat -n: $(tail -1 "$d/fsck.txt") ($d/fsck.txt)"; fi
	rm -f "$d/part.img"
	MTOOLS_SKIP_CHECK=1 mdir -i "$img@@$off" :: > "$d/mdir.txt" 2>&1 || true
}

# norm <log>: a run log without the simulators' own lines (xsim's banner,
# script echo, "$finish called at", exit, memory usage; Verilator's
# "- ...: Verilog $finish") and without empty lines; run directories as run_*.
# Also without i2c_master_mmio.sv's $monitor lines ("r_cmd_done=", havei2c =
# true only): xsim prints the first one, Verilator repeats it at every
# evaluation.
norm() {
	grep -vE '^(r_cmd_done=|\*\*\*\*\*\* xsim v|  \*\*\*\* |    \*\* |source xsim\.dir/|# xsim |Time resolution is |run -all$|exit [0-9]+$|INFO: \[Common 17-206\] Exiting xsim|INFO: xsimkernel Simulation Memory Usage|\$finish called at time |- .*: Verilog \$finish$|$)' "$1" \
		| sed 's|/run_[^/]*/|/run_*/|g'
}

# compare <dir a> <dir b>: every run log (tb_*.log) of both directories
compare() {
	local a=$1 b=$2 f n=0 nd=0 no=0 v c
	for f in $( (cd "$a" && ls tb_*.log; cd "$b" && ls tb_*.log) 2>/dev/null | LC_ALL=C sort -u); do
		if [ ! -f "$a/$f" ] || [ ! -f "$b/$f" ]; then
			echo "ONLY ${f%.log}: in $( [ -f "$a/$f" ] && echo "$a" || echo "$b")"; no=$((no + 1)); continue
		fi
		n=$((n + 1))
		v=$(grep -m1 -E '^=== (PASS|FAIL)' "$a/$f" | sed 's/^=== //')
		c=$(sed -n 's/.*, main done \(-*[0-9]*\), cycles \([0-9]*\)$/\1 \/ \2/p' "$a/$f")
		if diff -q <(norm "$a/$f") <(norm "$b/$f") > /dev/null; then
			echo "SAME ${f%.log}: ${v:-no verdict}, main done / cycles ${c:-?}"
		else
			nd=$((nd + 1))
			echo "DIFF ${f%.log}: ${v:-no verdict} in $a, $(grep -m1 -E '^=== (PASS|FAIL)' "$b/$f" | sed 's/^=== //') in $b"
			diff <(norm "$a/$f") <(norm "$b/$f") | sed -n '1,6s/^/    /p'
		fi
	done
	# fwboot runs: the SPI frame log as well
	if [ -f "$a/spi.txt" ] || [ -f "$b/spi.txt" ]; then
		if [ ! -f "$a/spi.txt" ] || [ ! -f "$b/spi.txt" ]; then
			echo "ONLY spi.txt: in $( [ -f "$a/spi.txt" ] && echo "$a" || echo "$b")"; no=$((no + 1))
		else
			n=$((n + 1))
			if cmp -s "$a/spi.txt" "$b/spi.txt"; then echo "SAME spi.txt: $(wc -l < "$a/spi.txt") frames"
			else nd=$((nd + 1)); echo "DIFF spi.txt"; diff "$a/spi.txt" "$b/spi.txt" | cut -c1-120 | sed -n '1,6s/^/    /p'; fi
		fi
	fi
	echo "=== COMPARE $n logs: $((n - nd)) same, $nd differ, $no in one directory only"
	[ "$nd" -eq 0 ] && [ "$no" -eq 0 ] && [ "$n" -gt 0 ]
}

case "${1:-}" in
	""|-h|--help) sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 0 ;;
	compare)
		[ $# -eq 3 ] || { echo "usage: run.sh compare <RUNTAG a> <RUNTAG b>"; exit 2; }
		for t in "$2" "$3"; do [ -d "$HERE/run_$t" ] || { echo "no run directory $HERE/run_$t"; exit 2; }; done
		compare "$HERE/run_$2" "$HERE/run_$3"
		exit $?
		;;
	boot|boot_nofile)
		setup
		boot "$1"
		exit $?
		;;
	fwboot|fwboot_trap|fwboot_cfg)
		# FW relative to the caller's directory (setup changes into the run's)
		FWBIN=$(realpath -m -- "${FW:-$ROOT/fw/ctrl_rv/build/RV32OSDA.BIN}")
		setup
		fwboot "$1"
		exit $?
		;;
	all)
		setup
		variant 832_bridge.vhd rv_hostcpu.v
		for t in $TESTS; do snapshot "$t" "tb_${t}_x$XW"; done
		for t in $TESTS; do matrix "tb_${t}_x$XW" "$t" PASS ""; done | tee "$run/results.txt"
		if grep -q '^BAD' "$run/results.txt"; then echo "=== SOME FAILED"; exit 1; fi
		echo "=== ALL PASS ($(grep -c '^ok' "$run/results.txt") runs, $SIM)"
		;;
	irqmut)
		setup
		variant 832_bridge.vhd rv_hostcpu.v
		XW=0
		for m in a b c; do
			cfide_variant "cfide_irqmut_$m.vhd"
			snapshot t_irqctl "tb_t_irqctl_mut${m}_x$XW"
		done
		cfide_variant cfide.vhd
		snapshot t_irqctl "tb_t_irqctl_x$XW"
		{
			for m in a b c; do
				echo "cfide mutant $m: $(grep -- '-- IRQ MUTANT' "src/cfide_irqmut_$m.vhd" | sed 's/^ *//')"
				one "tb_t_irqctl_mut${m}_x$XW" t_irqctl 8 0 FAIL "gate    cfide mutant $m: "
				log="$run/tb_t_irqctl_mut${m}_x${XW}_s8_j0.log"
				if [ $m = c ]; then
					if grep -qE '^=== FAIL code 9[0-9][0-9],' "$log"; then echo "ok   mutant c fails in test 9"
					else echo "BAD  mutant c: not a test 9 failure ($(grep -m1 -E '^=== (PASS|FAIL)' "$log"))"; fi
				elif grep -q 'BENCH ERROR.*t_irqctl test 4 (set wins)' "$log"; then
					echo "ok   mutant $m fails test 4 in $(grep -c 'BENCH ERROR.*t_irqctl test 4 (set wins)' "$log") iterations"
				else echo "BAD  mutant $m: no test 4 (set wins) error"; fi
			done
			one "tb_t_irqctl_x$XW" t_irqctl 8 0 PASS "control real cfide: "
		} | tee "$run/results.txt"
		if grep -q '^BAD' "$run/results.txt"; then echo "=== IRQ MUTANT SURVIVED or CONTROL FAILED"; exit 1; fi
		echo "=== IRQ MUTANTS CAUGHT (3 mutants FAIL where expected, control PASS)"
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
