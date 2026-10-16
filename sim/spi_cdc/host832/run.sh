#!/bin/bash
# The direct-mode transfer with the real 832 on the host side.  See
# tb_832_dmode.v and gen832.py.
#
#   ./run.sh                   SLAT grid on the working tree
#   REV=<git rev> ./run.sh     on the RTL of that revision
#   ./run.sh "<slat> <sjit>" ...
#
# The EightThirtyTwo CPU sources come from the EightThirtyTwo submodule
# (E832=<dir> to point elsewhere, e.g. the main checkout when the worktree's
# submodule is not initialised).  xsim, one configuration after the other.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
E832=${E832:-$ROOT/EightThirtyTwo/RTL}
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-$HOME/lib/tinfo5}

run="$HERE/run_${RUNTAG:-${REV:-wt}}"
rm -rf "$run"; mkdir -p "$run/src"
cd "$run"
python3 "$HERE/gen832.py" > gen.log
FILES="rtl/host/cfide.vhd rtl/host/832_bridge.vhd rtl/host/hostcache.v rtl/sdram/dpram_inf_generic.v
       rtl/minimig/paula_floppy.v rtl/minimig/paula_floppy_fifo.v"
for f in $FILES; do
	if [ -n "$REV" ]; then git -C "$ROOT" show "$REV:$f" > "src/$(basename $f)"
	else cp "$ROOT/$f" "src/$(basename $f)"; fi
done
# hostcache.v mixes "ack <= #1 1'b0" (default) with "ack <= 1'b1": in
# simulation the delayed default lands 1 ns after the set and the ack is a 1 ns
# glitch the bridge never sees.  Synthesis ignores the delay; drop it here.
sed -i "s/ack <= #1 1'b0;/ack <= 1'b0;/" src/hostcache.v
X() { "$VIVADO_PATH/bin/$@" >> compile.log 2>&1 || { echo "FAILED: $1"; tail -20 compile.log; exit 1; }; }
: > compile.log
X xvlog -sv "$ROOT/rtl/host/i2c_master_mmio.sv" "$ROOT/rtl/openaars/adv7511/i2c_master.v"
X xvhdl "$E832/eightthirtytwo_pkg.vhd" "$E832/eightthirtytwo_shifter.vhd" "$E832/eightthirtytwo_alu.vhd" \
	"$E832/eightthirtytwo_aligner.vhd" "$E832/eightthirtytwo_aligner_le.vhd" "$E832/eightthirtytwo_decode.vhd" \
	"$E832/eightthirtytwo_fetchloadstore.vhd" "$E832/eightthirtytwo_hazard.vhd" "$E832/eightthirtytwo_debug.vhd" \
	"$E832/eightthirtytwo_cpu.vhd"
X xvlog src/hostcache.v src/dpram_inf_generic.v src/paula_floppy.v src/paula_floppy_fifo.v "$HERE/tb_832_dmode.v"
X xvhdl rom.vhd "$HERE/debug_bridge_stub.vhd" src/832_bridge.vhd src/cfide.vhd
X xelab -debug off -relax tb_832_dmode -s tb

CFGS=("$@")
[ ${#CFGS[@]} -eq 0 ] && CFGS=("0 0" "2 0" "4 0" "8 0" "16 0" "0 16" "4 32")
rc=0
for c in "${CFGS[@]}"; do
	set -- $c
	"$VIVADO_PATH/bin/xsim" tb -R --onfinish quit -testplusarg "SLAT=$1" -testplusarg "SJIT=$2" \
		$(for x in $XARGS; do echo -testplusarg "${x#+}"; done) > "xsim_s$1_j$2.log" 2>&1 || true
	res=$(grep -E "^=== " "xsim_s$1_j$2.log" || echo "=== NO RESULT")
	Ls=$(grep -E "^L [0-9]+" "xsim_s$1_j$2.log" | awk '{print $2}' | sort -n | uniq -c | awk '{printf "%s:%s ", $2, $1}')
	echo "SLAT=$1 SJIT=$2: $res   L(cycles:count) $Ls"
	case "$res" in *PASS*) ;; *) rc=1 ;; esac
done
exit $rc
