# Shared shell functions of the host-CPU benches (sim/host_bridge, later
# sim/l3).  Sourced by their run.sh (bash), never run:
#   . "$ROOT/sim/common/hostsim.sh"
#
# The caller sets, before calling any function here:
#   ROOT        the checkout (rtl/, fw/, sim/)
#   HERE        the bench directory (verilator/blackbox.vhd, verilator/romcheck.py
#               and the waiver file are looked up there)
#   SIM         xsim or verilator
#   GHDL, GHDLFLAGS, VERILATOR, JOBS, VIVADO_PATH
# and may set XRAND=1 (Verilator only), XSEED=<n>, RUNTAG.
#
# Functions (the run directory <run> is an absolute path):
#   hs_die <message>                     print "FAILED: ..." and exit 1
#   hs_copy_rtl <run> <rev>              the RTL of <rev> (a checkout directory) into <run>/src
#                                        with the hostcache.v simulation fixes
#   hs_ghdl_convert <run> <extra_ws> <cfide generics...>
#                                        ghdl --synth of the bridge (with the ROM) and cfide
#                                        into $HS_DIR/bridge.v, cfide.v.  Inputs in variables:
#                                        HS_DIR (output directory), HS_ROM (the ROM vhd),
#                                        HS_VB, HS_VC (bridge and cfide file names in <run>/src)
#   hs_verilate <run> <top> <defines> <sources...>
#                                        Verilator build of snapshot $HS_NAME into
#                                        <run>/vl_$HS_NAME/V<top>; <defines> is a
#                                        space-separated list of -D options; HS_VFLAGS holds
#                                        further verilator options (a plain string),
#                                        HS_VLT the waiver file.  XRAND=1: randomised
#                                        uninitialised state (hs_xrand_args)
#   hs_X <run> <tool> <args...>          one Vivado tool (xvlog, xvhdl, xelab), logged
#   hs_xsim_build <run> <snapshot> <extra_ws> <top>
#                                        the xelab step of an xsim snapshot
#   hs_simrun <run> <snapshot> <top> <log> <plusarg...>
#                                        one simulation (plusargs without the +); XRAND=1
#                                        adds the Verilator run plusargs and writes the
#                                        "=== XRAND seed <n>" line first in the log
#   hs_compare <runA> <runB>             every tb_*.log and spi.txt of two run directories
#                                        (exit 1 unless all SAME)
#   hs_fwrv <run>                        the RV firmware into <run>/fwrv (RV32OSDB.BIN) under
#                                        a date shim (L3_DATE, default 2026-01-01)
#   hs_fwname                            the firmware's file name, FW_FILE of
#                                        fw/ctrl/fwname.mk (RV32OSDB.BIN)
#
# XRAND=1 (X-sensitivity twin): the build flags --x-assign unique --x-initial
# unique instead of 0 / 0, and the run plusargs +verilator+rand+reset+2
# +verilator+seed+<n> (without rand+reset+2 the state still starts at 0).
# The seed is XSEED, default the cksum of the RUNTAG mod 2147483647 + 1 (Verilator takes 1..2147483647).

hs_die() { echo "FAILED: $*"; exit 1; }

# RTL files a bench copies (the Verilog / VHDL it simulates, never rtl/ itself)
HS_RTL_FILES="rtl/host/cfide.vhd rtl/host/host_bridge.vhd rtl/host/hostcache.v rtl/sdram/dpram_inf_generic.v rtl/host/rv_hostcpu.v rtl/host/vexriscv/VexOsd.v"
# ... and those copied only when the revision has them (older trees, e.g.
# osd-832-final or 745a47c3, have no rtl/host/sdcard_spi.v; the benches that
# compile it are of trees that do)
HS_RTL_OPT_FILES="rtl/host/sdcard_spi.v"

hs_copy_rtl() {
	local run=$1 rev=$2 f
	mkdir -p "$run/src" || hs_die "mkdir $run/src"
	for f in $HS_RTL_FILES; do
		cp "$rev/$f" "$run/src/" || hs_die "copy $f"
	done
	for f in $HS_RTL_OPT_FILES; do
		[ -e "$rev/$f" ] || continue
		cp "$rev/$f" "$run/src/" || hs_die "copy $f"
	done
	sed -i "s/ack <= #1 1'b0;/ack <= 1'b0;/" "$run/src/hostcache.v"
	grep -q "ack <= #1" "$run/src/hostcache.v" && hs_die "hostcache #1 fix not applied"
	sed -i '1i `timescale 1ns/1ps' "$run/src/hostcache.v" "$run/src/dpram_inf_generic.v"
	hs_pin_hostcache "$run"
}

# XRAND=1: flops the RTL leaves without a reset and the FPGA starts at 0 (its
# configuration initialises every flop; sim/host_bridge/README.md, "Shared
# parts") are pinned to 0 at time 0 in the run copies / the conversion, so the
# seeds keep randomising everything else.  hostcache.v: ack, sdram_req;
# host_bridge.vhd (converted): cache_req, cpu_ack, rom_wr.  Counts in
# <run>/src/pinned_hostcache and <ghdl dir>/pinned.txt, printed by hs_simrun.
hs_pin_hostcache() {
	local run=$1 n
	[ "${XRAND:-0}" = 1 ] || return 0
	sed -i -e 's/^\toutput reg ack,/\toutput reg ack = 1'"'"'b0,/' -e 's/^\toutput reg sdram_req,/\toutput reg sdram_req = 1'"'"'b0,/' "$run/src/hostcache.v"
	n=$(grep -c "output reg [a-z_]* = 1'b0," "$run/src/hostcache.v")
	[ "$n" = 2 ] || hs_die "XRAND pin: hostcache.v ack / sdram_req not found"
	echo "$n" > "$run/src/pinned_hostcache"
}

# hs_pin_bridge <converted bridge.v> <count file>
hs_pin_bridge() {
	local v=$1 n=0 sig q
	[ "${XRAND:-0}" = 1 ] || return 0
	for sig in cache_req cpu_ack rom_wr; do
		q=$(sed -n "s/^  assign $sig = \(n[0-9]*_q\); .*/\1/p" "$v")
		[ -n "$q" ] || hs_die "XRAND pin: no flop behind $sig in $v (GHDL output format?)"
		sed -i "s/^  reg $q;/  reg $q = 1'b0;/" "$v"
		grep -q "^  reg $q = 1'b0;" "$v" || hs_die "XRAND pin: flop $q of $sig not found in $v"
		n=$((n + 1))
	done
	echo "$n" > "$2"
}

hs_ghdl_convert() {
	local run=$1 xw=$2 bb d=$HS_DIR rom=$HS_ROM; shift 2
	rm -rf "$d"; mkdir -p "$d" || hs_die "mkdir $d"
	# shellcheck disable=SC2086
	"$GHDL" -a $GHDLFLAGS --workdir="$d" "$HERE/verilator/blackbox.vhd" "$run/src/$HS_VC" "$run/src/$HS_VB" "$rom" \
		> "$d/analyse.log" 2>&1 || { cat "$d/analyse.log"; hs_die "ghdl -a ($d/analyse.log)"; }
	# shellcheck disable=SC2086
	"$GHDL" --synth $GHDLFLAGS --workdir="$d" -grv_extra_ws="$xw" --out=verilog \
		host_bridge > "$d/bridge.v" 2> "$d/bridge.log" || { cat "$d/bridge.log"; hs_die "ghdl --synth bridge ($d/bridge.log)"; }
	# shellcheck disable=SC2086
	"$GHDL" --synth $GHDLFLAGS --workdir="$d" "$@" --out=verilog \
		cfide > "$d/cfide.v" 2> "$d/cfide.log" || { cat "$d/cfide.log"; hs_die "ghdl --synth cfide ($d/cfide.log)"; }
	grep -q 'found RAM "ram", width: 32 bits, depth: 2048' "$d/bridge.log" \
		|| hs_die "ghdl --synth did not infer the ROM's RAM ($d/bridge.log)"
	python3 "$HERE/verilator/romcheck.py" "$rom" "$d/bridge.v" > "$d/romcheck.log" 2>&1 \
		|| { cat "$d/romcheck.log"; hs_die "converted ROM contents ($rom)"; }
	for bb in $(sed -n 's/^entity \([a-z0-9_]*\) is$/\1/p' "$HERE/verilator/blackbox.vhd"); do
		sed -i "/^module $bb\$/,/^endmodule\$/d" "$d/bridge.v" "$d/cfide.v"
		# the delete must have worked: a stub left in would shadow the real module
		grep -qE "^ *module +$bb\b" "$d/bridge.v" "$d/cfide.v" \
			&& hs_die "black-box module $bb still in $d/bridge.v or cfide.v after the delete (GHDL output format?)"
	done
	sed -i '1i `timescale 1ns/1ps' "$d/bridge.v" "$d/cfide.v"
	hs_pin_bridge "$d/bridge.v" "$d/pinned.txt"
}

# hs_xrand_seed: the seed of this run (XSEED, else the cksum of the RUNTAG
# reduced to Verilator's range 1..2147483647)
hs_xrand_seed() {
	local c
	if [ -n "${XSEED:-}" ]; then echo "$XSEED"
	else c=$(printf '%s' "${RUNTAG:-wt}" | cksum | cut -d' ' -f1); echo $((c % 2147483647 + 1)); fi
}

# hs_xrand_args: the Verilator run plusargs of an XRAND run (empty otherwise)
hs_xrand_args() {
	[ "${XRAND:-0}" = 1 ] || return 0
	echo "+verilator+rand+reset+2 +verilator+seed+$(hs_xrand_seed)"
}

hs_verilate() {
	local run=$1 top=$2 defs=$3 xr="--x-assign 0 --x-initial 0"; shift 3
	local name=$HS_NAME
	[ "${XRAND:-0}" = 1 ] && xr="--x-assign unique --x-initial unique"
	rm -rf "$run/vl_$name"
	# shellcheck disable=SC2086
	OBJCACHE=${OBJCACHE-$(command -v ccache)} "$VERILATOR" --binary --timing -j "$JOBS" \
		-MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" $xr \
		$defs ${HS_VFLAGS:-} --top-module "$top" \
		--Mdir "$run/vl_$name" -o "V$top" "$HS_VLT" \
		"$@" > "$run/compile_$name.log" 2>&1
	if [ ! -x "$run/vl_$name/V$top" ]; then
		grep -m20 -E '^%(Error|Warning)' "$run/compile_$name.log" || tail -20 "$run/compile_$name.log"
		hs_die "verilator $name ($run/compile_$name.log)"
	fi
}

hs_X() {
	local run=$1; shift
	# through hs_die, which a bench may redefine (sim/l3: the verdict line)
	"$VIVADO_PATH/bin/$@" >> "$run/compile.log" 2>&1 || { tail -20 "$run/compile.log"; hs_die "$*"; }
}

hs_xsim_build() {
	hs_X "$1" xelab -debug off -generic_top "EXTRA_WS=$3" "$4" -s "$2"
}

hs_simrun() {
	local run=$1 snap=$2 top=$3 log=$4 x a=(); shift 4
	if [ "$SIM" = verilator ]; then
		for x; do a+=("+$x"); done
		if [ "${XRAND:-0}" = 1 ]; then
			echo "=== XRAND seed $(hs_xrand_seed)" > "$log"
			echo "=== XRAND pinned $(cat "$run/ghdl_$snap/pinned.txt" "$run/src/pinned_hostcache" 2>/dev/null | awk '{s += $1} END {print s + 0}') regs" >> "$log"
			# shellcheck disable=SC2046
			"$run/vl_$snap/V$top" $(hs_xrand_args) "${a[@]}" >> "$log" 2>&1
		else
			"$run/vl_$snap/V$top" "${a[@]}" > "$log" 2>&1
		fi
	else
		[ "${XRAND:-0}" = 1 ] && hs_die "XRAND=1 needs SIM=verilator"
		for x; do a+=(-testplusarg "$x"); done
		"$VIVADO_PATH/bin/xsim" "$snap" -R --onfinish quit "${a[@]}" > "$log" 2>&1
	fi
}

# hs_norm <log>: a run log without the simulators' own lines (xsim's banner,
# script echo, "$finish called at", exit, memory usage; Verilator's
# "- ...: Verilog $finish") and without empty lines; run directories as run_*.
# Also without i2c_master_mmio.sv's $monitor lines ("r_cmd_done=", havei2c =
# true only): xsim prints the first one, Verilator repeats it at every
# evaluation.  And without the "=== XRAND seed" line of an XRAND run.
hs_norm() {
	grep -vE '^(r_cmd_done=|=== XRAND (seed|pinned) |\*\*\*\*\*\* xsim v|  \*\*\*\* |    \*\* |source xsim\.dir/|# xsim |Time resolution is |run -all$|exit [0-9]+$|INFO: \[Common 17-206\] Exiting xsim|INFO: xsimkernel Simulation Memory Usage|\$finish called at time |- .*: Verilog \$finish$|$)' "$1" \
		| sed 's|/run_[^/]*/|/run_*/|g'
}

# hs_compare <dir a> <dir b>: every run log (tb_*.log) of both directories
hs_compare() {
	local a=$1 b=$2 f n=0 nd=0 no=0 v c
	for f in $( (cd "$a" && ls tb_*.log; cd "$b" && ls tb_*.log) 2>/dev/null | LC_ALL=C sort -u); do
		if [ ! -f "$a/$f" ] || [ ! -f "$b/$f" ]; then
			echo "ONLY ${f%.log}: in $( [ -f "$a/$f" ] && echo "$a" || echo "$b")"; no=$((no + 1)); continue
		fi
		n=$((n + 1))
		v=$(grep -m1 -E '^=== (PASS|FAIL)' "$a/$f" | sed 's/^=== //')
		c=$(sed -n 's/.*, main done \(-*[0-9]*\), cycles \([0-9]*\)$/\1 \/ \2/p' "$a/$f")
		if diff -q <(hs_norm "$a/$f") <(hs_norm "$b/$f") > /dev/null; then
			echo "SAME ${f%.log}: ${v:-no verdict}, main done / cycles ${c:-?}"
		else
			nd=$((nd + 1))
			echo "DIFF ${f%.log}: ${v:-no verdict} in $a, $(grep -m1 -E '^=== (PASS|FAIL)' "$b/$f" | sed 's/^=== //') in $b"
			diff <(hs_norm "$a/$f") <(hs_norm "$b/$f") | sed -n '1,6s/^/    /p'
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

# hs_fwname: the firmware's file name on the card and of fw/ctrl's build
# output, FW_FILE of fw/ctrl/fwname.mk, evaluated by make as the Makefiles
# do (the one place the name is written; the boot ROM looks for the same)
hs_fwname() {
	local n
	n=$(printf 'hs_fwname:\n\t@echo $(FW_FILE)\n' \
		| make -s --no-print-directory -f "$ROOT/fw/ctrl/fwname.mk" -f - hs_fwname) \
		|| hs_die "make -f fw/ctrl/fwname.mk"
	case "$n" in ????????.???) echo "$n" ;; *) hs_die "fw/ctrl/fwname.mk: FW_FILE '$n' is not an 8.3 name" ;; esac
}

# hs_fwrv <run>: build fw/ctrl into <run>/fwrv with a `date` that always
# prints L3_DATE (default 2026-01-01), so two builds of one tree are
# byte-identical (the version string carries the build minute).  The shim
# is <run>/dateshim/date; the image is <run>/fwrv/$(hs_fwname).
hs_fwrv() {
	local run=$1 shim="$1/dateshim"
	mkdir -p "$shim" "$run/fwrv" || hs_die "mkdir $run/fwrv"
	printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$shim/date"
	chmod +x "$shim/date"
	PATH="$shim:$PATH" make -s -C "$ROOT/fw/ctrl" B="$run/fwrv" > "$run/make_fwrv.log" 2>&1 \
		|| { tail -20 "$run/make_fwrv.log"; hs_die "make fw/ctrl ($run/make_fwrv.log)"; }
	local fwn
	fwn=$(hs_fwname) || hs_die "${fwn#FAILED: }"
	[ -f "$run/fwrv/$fwn" ] || hs_die "no $run/fwrv/$fwn"
}
