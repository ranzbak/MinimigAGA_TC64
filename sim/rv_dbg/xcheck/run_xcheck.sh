#!/usr/bin/env bash
# xsim cross-check of sim/rv_dbg/xc7_tap.v against Vivado's JTAG_SIME2 +
# BSCANE2 + glbl (compiled in place from $VIVADO_PATH/data/verilog/src, never
# copied).  Called by "bash sim/rv_dbg/run.sh xcheck".  Two runs, serially:
#   xcheck        the model as committed: must end with 0 mismatches
#   xcheck_teeth  -d XCHECK_TEETH (model USER4 = 0x22): must mismatch
# Outputs in sim/rv_dbg/run_${RUNTAG:-wt}/xcheck{,_teeth}/.  SEED, NCYC from
# the environment (defaults 1, 20000).  Ends "=== XCHECK PASS" or
# "=== XCHECK FAIL".
set -u
here=$(cd "$(dirname "$0")" && pwd)
dbg=$(cd "$here/.." && pwd)
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
src=$VIVADO_PATH/data/verilog/src
SEED=${SEED:-1}
NCYC=${NCYC:-20000}
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# one <dir> [teeth]: compile, elaborate, simulate; prints the XCHECK lines
one() {
  local out=$1 teeth=${2:-} def=""
  [ -n "$teeth" ] && def="-d XCHECK_TEETH"
  rm -rf "$out"; mkdir -p "$out"
  (
    cd "$out" || exit 1
    X() { timeout 900 "$VIVADO_PATH/bin/$@" >> compile.log 2>&1 || { echo "FAILED: $*"; tail -20 compile.log; exit 1; }; }
    : > compile.log
    X xvlog "$src/unisims/JTAG_SIME2.v" "$src/unisims/BSCANE2.v" "$src/glbl.v"
    # shellcheck disable=SC2086
    X xvlog -d XC7_TAP_NO_PRIMS $def "$dbg/xc7_tap.v" "$here/tb_xcheck.v"
    X xelab -debug off tb_xcheck work.glbl -s xcheck
    timeout 1800 "$VIVADO_PATH/bin/xsim" xcheck -R -testplusarg "SEED=$SEED" -testplusarg "NCYC=$NCYC" > sim.log 2>&1
    grep -E '^=== (XCHECK|MISMATCH)' sim.log | head -30
  )
}

t0=$SECONDS
rc=0
run=$dbg/run_${RUNTAG:-wt}
echo "--- xcheck (model as committed)"
one "$run/xcheck"
mis=$(sed -n 's/^=== XCHECK [0-9]* TCK cycles, [0-9]* comparisons, \([0-9]*\) mismatches/\1/p' "$run/xcheck/sim.log")
cyc=$(sed -n 's/^=== XCHECK \([0-9]*\) TCK cycles.*/\1/p' "$run/xcheck/sim.log")
if [ "${mis:-x}" != 0 ] || [ "${cyc:-0}" -lt "$NCYC" ]; then
  echo "FAIL xcheck: mismatches '${mis:-none}', cycles '${cyc:-none}' ($run/xcheck/sim.log)"; rc=1
fi
echo "--- xcheck_teeth (model USER4 = 0x22)"
one "$run/xcheck_teeth" teeth
tmis=$(sed -n 's/^=== XCHECK [0-9]* TCK cycles, [0-9]* comparisons, \([0-9]*\) mismatches/\1/p' "$run/xcheck_teeth/sim.log")
if [ -z "$tmis" ] || [ "$tmis" -eq 0 ]; then
  echo "FAIL xcheck_teeth: expected mismatches, got '${tmis:-none}' ($run/xcheck_teeth/sim.log)"; rc=1
fi
if [ $rc -eq 0 ]; then
  echo "=== XCHECK PASS: $cyc TCK cycles, 0 mismatches; teeth $tmis mismatches ($((SECONDS - t0)) s)"
else
  echo "=== XCHECK FAIL"
fi
exit $rc
