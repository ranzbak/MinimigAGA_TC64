#!/usr/bin/env bash
# Debug bench: rv_hostcpu on Verilator with a remote_bitbang / XVC server
# (harness.cpp); real OpenOCD 0.12 attaches through the committed configs
# tools/openocd/minimig-rv-{pins,bscan}.cfg + remote-bitbang.cfg.
#
#   bash sim/rv_dbg/run.sh attach2   # DEBUG=2 (VexOsd_DMJ, pin TAP), minimig-rv-pins.cfg
#   bash sim/rv_dbg/run.sh attach1   # DEBUG=1 (VexOsd_DMT, BSCANE2 tunnel), minimig-rv-bscan.cfg
#   bash sim/rv_dbg/run.sh teeth     # DEBUG=1, TAP model USER4 = 0x22: examine must fail
#   bash sim/rv_dbg/run.sh xvc_loop  # DEBUG=1 harness as XVC server: IDCODE + BYPASS via xvc_idcode.py
#   bash sim/rv_dbg/run.sh xcheck    # xsim: xc7_tap.v against Vivado's JTAG_SIME2 + BSCANE2
#   bash sim/rv_dbg/run.sh all       # all five, "=== RV_DBG ALL PASS"
#   bash sim/rv_dbg/run.sh harness <1|2> [plusargs]   # build, then run the harness
#                                    # in the foreground (by hand: OpenOCD / GDB)
#
# attach1/attach2: build the Verilator image, start the harness (+HEX=
# build/attach.hex, +exit_on_disconnect, +rbblog), start OpenOCD with the
# config + attach.tcl (init, halt, reg pc, resume, shutdown).  PASS needs:
# OpenOCD exit 0; the TAP found with its IDCODE (attach2: riscv.cpu
# 0x10002fff; attach1: xc7.tap 0x03631093, the XC7A100T of
# cpld/xilinx-xc7.cfg); "Examined RISC-V core" (attach1: "found 1 harts");
# the halted PC in [attach_loop, attach_loop_end) of build/attach.elf; the
# harness closed on OpenOCD's 'Q' and exited on the disconnect.
# Verdict: "=== ATTACH PASS" / "=== ATTACH FAIL <what>".
# teeth: the same with the DEBUG=1 image built -DTEETH_USER4 (TAP model USER4
# code 0x22): xc7.tap found, "target cpu.0 examination failed", no "Examined
# RISC-V core", OpenOCD exit 1, harness closed by 'Q'.  Verdict
# "=== TEETH PASS" / "=== TEETH FAIL <what>".
#
# Environment: RBB_PORT (default 44853; in use -> the harness takes a free
# port and prints it), XVC_PORT (default 2542), TCK_HALF (system clocks per
# TCK half period, default 4), RUNTAG (outputs in sim/rv_dbg/run_${RUNTAG:-wt}/),
# VERILATOR, OPENOCD, PYTHON, VIVADO_PATH (xcheck; default
# /opt/Xilinx/Vivado/2023.2), JOBS (C++ build jobs, default 2).
# Every run has a wall-clock timeout and kills its own children by PID.
set -u

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
VERILATOR=${VERILATOR:-verilator}
OPENOCD=${OPENOCD:-openocd}
PYTHON=${PYTHON:-python3}
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
JOBS=${JOBS:-2}
TCK_HALF=${TCK_HALF:-4}
RBB_PORT=${RBB_PORT:-44853}
XVC_PORT=${XVC_PORT:-2542}
NM=${RV_GCC_DIR:-$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1}/bin/${RV_PREFIX:-riscv-none-elf-}nm
run=$here/run_${RUNTAG:-wt}
build=$here/build
mkdir -p "$run"

CORE_RTL="$top/rtl/host/rv_hostcpu.v"
BENCH="$here/tb_rv_dbg.v $top/sim/rv_l1/mem_model.v $top/sim/rv_l1/bus_checker.v"

# children started by this script, killed on exit
pids=""
cleanup() {
  local p
  for p in $pids; do kill "$p" 2> /dev/null; done
  for p in $pids; do wait "$p" 2> /dev/null; done
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# image <debug> [teeth]
image() { echo "$run/vl_d$1${2:+_teeth}/Vtb_rv_dbg"; }

# build <debug> [teeth]: the Verilator image (warnings fatal; the waivers of
# sim/rv_l1/verilator/l1.vlt cover the generated cores and the L1 models)
build() {
  local dbg=$1 teeth=${2:-} tag=d$1${2:+_teeth} src def="" rc=0
  case "$dbg" in
    2) src="$CORE_RTL $top/rtl/host/vexriscv/VexOsd_DMJ.v" ;;
    1) src="$CORE_RTL $top/rtl/host/vexriscv/VexOsd_DMT.v $top/rtl/host/xilinx/rv_bscane2.v $here/xc7_tap.v"
       def="-DRV_DBG_XC7TAP${teeth:+ -DTEETH_USER4}" ;;
    *) echo "build: DEBUG must be 1 or 2"; return 1 ;;
  esac
  local t0=$SECONDS
  # shellcheck disable=SC2086
  OBJCACHE=${OBJCACHE-$(command -v ccache)} timeout 900 "$VERILATOR" --cc --exe --build --timing \
    -j "$JOBS" -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -CFLAGS -O2 \
    $def --top-module tb_rv_dbg -GDEBUG="$dbg" --Mdir "$run/vl_$tag" -o Vtb_rv_dbg \
    "$top/sim/rv_l1/verilator/l1.vlt" $BENCH $src "$here/harness.cpp" \
    > "$run/build_$tag.log" 2>&1 || rc=1
  if [ $rc -ne 0 ] || [ ! -x "$(image "$dbg" "$teeth")" ]; then
    echo "BUILD FAILED DEBUG=$dbg${teeth:+ teeth} (see $run/build_$tag.log)"
    grep -m20 -E '^%(Error|Warning)|error:' "$run/build_$tag.log" || tail -20 "$run/build_$tag.log"
    return 1
  fi
  echo "built $(image "$dbg" "$teeth") ($((SECONDS - t0)) s)"
}

progs() {
  make -s -C "$here" tests > "$run/make_tests.log" 2>&1 && return 0
  echo "FAIL make -C sim/rv_dbg tests ($run/make_tests.log)"; tail -5 "$run/make_tests.log"
  return 1
}

# start_harness <image> <log> <plusargs...>: harness in the background
# (wall clock 900 s); waits for its "listening" line; sets hpid and hport
start_harness() {
  local im=$1 log=$2 i; shift 2
  timeout 900 "$im" "$@" > "$log" 2>&1 &
  hpid=$!; pids="$pids $hpid"
  for i in $(seq 1 600); do
    hport=$(sed -n 's/^=== \(RBB\|XVC\) listening 127\.0\.0\.1:\([0-9]*\).*/\2/p' "$log")
    [ -n "$hport" ] && return 0
    kill -0 "$hpid" 2> /dev/null || break
    sleep 0.1
  done
  echo "harness did not start ($log)"; tail -5 "$log"
  return 1
}

# wait_pid <pid> <seconds>: wait for a child, kill it after the limit
wait_pid() {
  local p=$1 n=$(( $2 * 10 )) i
  for i in $(seq 1 "$n"); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
  kill "$p" 2> /dev/null
  wait "$p" 2> /dev/null
}

sym() { "$NM" "$build/attach.elf" | awk -v s="$1" '$3 == s { print $1 }'; }

# attach <debug> [teeth]
attach() {
  local dbg=$1 teeth=${2:-} name cfg log hlog im rc=0 why="" t0=$SECONDS
  name=attach$dbg; [ -n "$teeth" ] && name=teeth
  progs || return 1
  build "$dbg" "$teeth" || return 1
  im=$(image "$dbg" "$teeth"); log=$run/$name.openocd.log; hlog=$run/$name.harness.log
  start_harness "$im" "$hlog" +HEX="$build/attach.hex" +rbb_port="$RBB_PORT" \
    +tck_half="$TCK_HALF" +timeout=2000000000 +exit_on_disconnect +rbblog="$run/$name.rbb" || return 1
  [ "$hport" = "$RBB_PORT" ] || echo "RBB port $RBB_PORT in use: the harness listens on $hport"
  if [ "$dbg" = 2 ]; then
    cfg=$top/tools/openocd/minimig-rv-pins.cfg
    # the pins config defaults to an FTDI adapter: name remote_bitbang
    timeout 600 "$OPENOCD" -c "set ADAPTER $top/tools/openocd/remote-bitbang.cfg" \
      -c "set RBB_PORT $hport" -f "$cfg" -f "$here/attach.tcl" > "$log" 2>&1 &
  else
    cfg=$top/tools/openocd/minimig-rv-bscan.cfg
    # the bscan config defaults to remote-bitbang.cfg: only the port is set
    timeout 600 "$OPENOCD" -c "set RBB_PORT $hport" -f "$cfg" -f "$here/attach.tcl" > "$log" 2>&1 &
  fi
  local opid=$!; pids="$pids $opid"
  wait "$opid"; local orc=$?
  wait_pid "$hpid" 60
  local secs=$((SECONDS - t0))

  local lo hi pc
  lo=$(sym attach_loop); hi=$(sym attach_loop_end)
  pc=$(sed -n 's/^pc (\/32): 0x\([0-9a-fA-F]*\).*/\1/p' "$log" | head -1)
  if [ -n "$teeth" ]; then
    # the tunnel IR (0x23) selects nothing: the TAP is found, the hart is not
    grep -q 'tap/device found: 0x03631093' "$log" || why="$why; xc7.tap IDCODE 0x03631093 not found"
    grep -q 'Examined RISC-V core' "$log" && why="$why; the hart was examined"
    grep -q 'target cpu.0 examination failed' "$log" || why="$why; no 'target cpu.0 examination failed'"
    # OpenOCD's own error exit (1), not 0 and not the wall-clock timeout (124)
    [ "$orc" -eq 1 ] || why="$why; OpenOCD exit $orc (expected 1)"
    grep -q 'connection 1 closed (Q)' "$hlog" || why="$why; harness: no 'connection 1 closed (Q)'"
    if [ -z "$why" ]; then
      echo "=== TEETH PASS: USER4 = 0x22, OpenOCD failed to examine the hart (exit $orc, $secs s):"
      grep -m3 -E '^Error' "$log" | sed 's/^/    /'
      return 0
    fi
    echo "=== TEETH FAIL${why/#;/:} ($log)"; return 1
  fi
  [ "$orc" -eq 0 ] || why="$why; OpenOCD exit $orc"
  if [ "$dbg" = 2 ]; then
    grep -q 'tap/device found: 0x10002fff' "$log" || why="$why; riscv.cpu IDCODE 0x10002fff not found"
    grep -q 'Examined RISC-V core' "$log" || why="$why; no 'Examined RISC-V core'"
  else
    grep -q 'tap/device found: 0x03631093' "$log" || why="$why; xc7.tap IDCODE 0x03631093 not found"
    grep -q 'Examined RISC-V core; found 1 harts' "$log" || why="$why; no 'Examined RISC-V core; found 1 harts'"
  fi
  if [ -z "$pc" ]; then
    why="$why; no 'pc (/32)' line"
  elif [ $((16#$pc)) -lt $((16#$lo)) ] || [ $((16#$pc)) -ge $((16#$hi)) ]; then
    why="$why; halted pc 0x$pc outside attach_loop [0x$lo, 0x$hi)"
  fi
  grep -q '^state after halt: halted' "$log" || why="$why; not halted after halt"
  grep -q '^state after resume: running' "$log" || why="$why; not running after resume"
  grep -q 'connection 1 closed (Q)' "$hlog" || why="$why; harness: no 'connection 1 closed (Q)'"
  grep -q '^=== EXIT disconnect' "$hlog" || why="$why; harness did not exit on the disconnect"
  if [ -z "$why" ]; then
    echo "=== ATTACH PASS DEBUG=$dbg: pc 0x$pc in [0x$lo, 0x$hi), $(grep -m1 'tap/device found' "$log" | sed 's/^Info : //'), $secs s"
    return 0
  fi
  echo "=== ATTACH FAIL DEBUG=$dbg${why/#;/:} ($log, $hlog)"
  return 1
}

xvc_loop() {
  local log=$run/xvc_loop.harness.log clog=$run/xvc_loop.client.log t0=$SECONDS
  build 1 || return 1
  progs || return 1
  start_harness "$(image 1)" "$log" +HEX="$build/attach.hex" +xvc="$XVC_PORT" \
    +tck_half="$TCK_HALF" +timeout=2000000000 +exit_on_disconnect || return 1
  [ "$hport" = "$XVC_PORT" ] || echo "XVC port $XVC_PORT in use: the harness listens on $hport"
  timeout 300 "$PYTHON" -I "$here/xvc_idcode.py" 127.0.0.1 "$hport" 0x03631093 > "$clog" 2>&1 &
  local cpid=$!; pids="$pids $cpid"
  wait "$cpid"; local crc=$?
  wait_pid "$hpid" 60
  cat "$clog"
  if [ "$crc" -eq 0 ] && grep -q '^=== EXIT disconnect' "$log"; then
    echo "=== XVC_LOOP PASS ($((SECONDS - t0)) s)"; return 0
  fi
  echo "=== XVC_LOOP FAIL (client exit $crc; $clog, $log)"; return 1
}

xcheck() {
  bash "$here/xcheck/run_xcheck.sh"
}

case "${1:-}" in
  attach2) attach 2; exit $? ;;
  attach1) attach 1; exit $? ;;
  teeth)   attach 1 teeth; exit $? ;;
  xvc_loop) xvc_loop; exit $? ;;
  xcheck)  xcheck; exit $? ;;
  harness)
    shift; dbg=${1:-}; shift
    progs || exit 1
    build "$dbg" || exit 1
    trap - EXIT
    exec timeout 7200 "$(image "$dbg")" +HEX="$build/attach.hex" +tck_half="$TCK_HALF" "$@"
    ;;
  all)
    fail=0
    for t in attach2 attach1 teeth xvc_loop xcheck; do
      echo "--- $t"
      bash "$0" "$t" || fail=1
    done
    if [ $fail -eq 0 ]; then echo "=== RV_DBG ALL PASS"; else echo "=== RV_DBG SOME FAILED"; fi
    exit $fail
    ;;
  *)
    sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 2 ;;
esac
