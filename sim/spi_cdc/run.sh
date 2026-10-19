#!/bin/bash
# SPI clock-domain bench: cfide.vhd (the 832's SPI master) driving paula_floppy
# and userio_osd the way the firmware does.  See tb_spi_cdc.v.
#
#   ./run.sh                       the grid below on the working tree
#   REV=<git rev> ./run.sh         the same grid on the RTL of that revision
#   ./run.sh "<sckdly> <c28dly>" ...   your own (SCKDLY, C28DLY) pairs, in ns
#
# Extra plusargs: XARGS="+REPS=5 +SEED=7 ..." (see tb_spi_cdc.v).
#
# The OSD reply-ready handshake (cfide HOST_REQ, see tb_spi_cdc.v +RDY):
#   RUNTAG=a XARGS="+RDY=1 +TESTS=24 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
#        osd and xframe with the HOST_REQ poll, every osd failure counted
#   RUNTAG=b RDY_MUT=1 XARGS="+RDY=1 +TESTS=8 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
#        the same on a run copy of cfide.vhd whose OSD_RDY is always 1 (the
#        "-- OSD RDY" line): must FAIL (osd at the small gaps)
#
# xsim because cfide is VHDL.  The configurations run one after the other in
# ONE directory (concurrent xsim runs in one directory corrupt each other);
# RUNTAG names that directory, as everywhere else in sim/.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-$HOME/lib/tinfo5}

run="$HERE/run_${RUNTAG:-${REV:-wt}}"
rm -rf "$run"; mkdir -p "$run/src"
cd "$run"

FILES="rtl/host/cfide.vhd rtl/minimig/paula_floppy.v rtl/minimig/paula_floppy_fifo.v
       rtl/minimig/userio_osd.v rtl/minimig/userio_osd_spi.v rtl/fifo/sync_fifo.v"
for f in $FILES; do
	if [ -n "$REV" ]; then
		git -C "$ROOT" show "$REV:$f" > "src/$(basename $f)"
	else
		cp "$ROOT/$f" "src/$(basename $f)"
	fi
done

# RDY_MUT=1: the run copy of cfide answers OSD_RDY = 1 whatever the counts say
if [ "${RDY_MUT:-0}" = 1 ]; then
	[ "$(grep -c -- '-- OSD RDY$' src/cfide.vhd)" = 1 ] || { echo "RDY_MUT: not exactly one '-- OSD RDY' line in cfide.vhd"; exit 1; }
	sed -i "s/^\( *\)osd_rdy <= .*-- OSD RDY\$/\1osd_rdy <= '1'; -- OSD RDY MUTANT/" src/cfide.vhd
	[ "$(grep -c -- "osd_rdy <= '1'; -- OSD RDY MUTANT\$" src/cfide.vhd)" = 1 ] || { echo "RDY_MUT: mutation not applied"; exit 1; }
	echo "RDY_MUT: $(grep -- '-- OSD RDY MUTANT' src/cfide.vhd | sed 's/^ *//')"
fi

# cfide instantiates i2c_master_mmio (its generate is off here, but the entity
# must still be known to the VHDL analyser)
"$VIVADO_PATH/bin/xvlog" -sv "$ROOT/rtl/host/i2c_master_mmio.sv" "$ROOT/rtl/openaars/adv7511/i2c_master.v" > compile.log 2>&1 || { echo COMPILE FAILED; tail -20 compile.log; exit 1; }
"$VIVADO_PATH/bin/xvhdl" src/cfide.vhd >> compile.log 2>&1 || { echo COMPILE FAILED; tail -20 compile.log; exit 1; }
"$VIVADO_PATH/bin/xvlog" -d MINIMIG_XILINX -i "$ROOT/rtl/minimig" -i "$ROOT/fpga/openaars" \
	src/paula_floppy.v src/paula_floppy_fifo.v src/userio_osd.v src/userio_osd_spi.v \
	src/sync_fifo.v "$HERE/tb_spi_cdc.v" >> compile.log 2>&1 || { echo COMPILE FAILED; tail -20 compile.log; exit 1; }
"$VIVADO_PATH/bin/xelab" -debug off -relax tb_spi_cdc -s tb >> compile.log 2>&1 || { echo ELAB FAILED; tail -20 compile.log; exit 1; }

# (SCKDLY, C28DLY) pairs: sck at the slaves early / late against clk_28,
# both orders of the two edges, and sck a whole clk_114 period late.
PAIRS=("$@")
[ ${#PAIRS[@]} -eq 0 ] && PAIRS=("0.5 0.2" "0.2 0.5" "1.5 0.3" "4.0 0.3" "0.3 4.0" "8.0 0.3" "9.5 0.3")

rc=0
for p in "${PAIRS[@]}"; do
	set -- $p
	tag="s$1_c$2"
	"$VIVADO_PATH/bin/xsim" tb -R --onfinish quit \
		-testplusarg "SCKDLY=$1" -testplusarg "C28DLY=$2" \
		$(for x in $XARGS; do echo -testplusarg "${x#+}"; done) \
		> "xsim_$tag.log" 2>&1 || true
	res=$(grep -E "^=== " "xsim_$tag.log" || echo "=== NO RESULT")
	fails=$(grep -E "^GAP .* fail [1-9]" "xsim_$tag.log" | tr '\n' ';' || true)
	echo "SCKDLY=$1 C28DLY=$2: $res  ${fails}"
	case "$res" in *PASS*) ;; *) rc=1 ;; esac
done
exit $rc
