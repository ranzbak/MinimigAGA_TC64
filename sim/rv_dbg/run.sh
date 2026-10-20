#!/usr/bin/env bash
# Debug bench: rv_hostcpu on Verilator with a remote_bitbang / XVC server
# (harness.cpp); real OpenOCD 0.12 attaches through the committed configs
# tools/openocd/minimig-rv-{pins,bscan}.cfg + remote-bitbang.cfg.
#
#   bash sim/rv_dbg/run.sh attach2   # DEBUG=2 (VexOsd_DMJ, pin TAP), minimig-rv-pins.cfg
#   bash sim/rv_dbg/run.sh attach1   # DEBUG=1 (VexOsd_DMT, BSCANE2 tunnel), minimig-rv-bscan.cfg
#   bash sim/rv_dbg/run.sh teeth     # DEBUG=1, TAP model USER4 = 0x22: examine must fail
#   bash sim/rv_dbg/run.sh xvc_loop  # DEBUG=1 harness as XVC server: IDCODE + BYPASS via xvc_idcode.py
#   bash sim/rv_dbg/run.sh gdb2      # DEBUG=2: scripted GDB session (gdb/session.gdb)
#   bash sim/rv_dbg/run.sh gdb1      # DEBUG=1: the same over the BSCANE2 tunnel
#   bash sim/rv_dbg/run.sh gdb_teeth # DEBUG=1, fence.i flushes no I-cache: must fail at "mailbox"
#   bash sim/rv_dbg/run.sh xcheck    # xsim: xc7_tap.v against Vivado's JTAG_SIME2 + BSCANE2
#   bash sim/rv_dbg/run.sh all       # all of the above, "=== RV_DBG ALL PASS"
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
# gdb1/gdb2: the harness starts with build/dbgtest_a.hex (sw/dbgtest.c,
# image A); OpenOCD with the config + gdb/openocd.tcl (GDB server on
# 127.0.0.1:GDB_PORT, shutdown on GDB's detach); GDB runs gdb/session.gdb
# in batch mode (halt, registers, memory, counter grows, reset halt,
# software breakpoint at main, load of image B, hardware breakpoint in
# work, mailbox = B's value, detach).  The session prints "CHECK <name>
# <value>" lines; PASS needs every one in order with its expected value
# (from build/dbgtest_a.elf), GDB, OpenOCD and the harness ending cleanly
# and no "Error" line in the OpenOCD log.  Verdict "=== GDB PASS" /
# "=== GDB FAIL <check>".
# gdb_teeth: gdb1 with a scratch copy of VexOsd_DMT.v whose I-cache flush
# input is tied low (fence.i flushes nothing; run_<tag>/noflush_rtl/, never
# the committed core): the session must fail exactly at "mailbox" with A's
# value 0xa5a50001 (the stale work() line).  "=== GDB_TEETH PASS/FAIL".
#
# Environment: RBB_PORT (default 44853; in use -> the harness takes a free
# port and prints it), XVC_PORT (default 2542), TCK_HALF (system clocks per
# TCK half period, default 4), RUNTAG (outputs in sim/rv_dbg/run_${RUNTAG:-wt}/),
# VERILATOR, OPENOCD, PYTHON, VIVADO_PATH (xcheck; default
# /opt/Xilinx/Vivado/2023.2), JOBS (C++ build jobs, default 2), GDB_PORT
# (default 3333; in use -> a free port, printed), GDB (default the xPack
# riscv-none-elf-gdb).
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
GDB_PORT=${GDB_PORT:-3333}
RV_BIN=${RV_GCC_DIR:-$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1}/bin/${RV_PREFIX:-riscv-none-elf-}
NM=${RV_BIN}nm
GDB=${GDB:-${RV_BIN}gdb}
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

# image <debug> [variant]
image() { echo "$run/vl_d$1${2:+_$2}/Vtb_rv_dbg"; }

# noflush_core <core.v>: scratch copy of a generated core with the I-cache
# flush input tied low (fence.i flushes nothing), under run_<tag>/ (git
# ignored; the committed core is never edited).  The copy sits in a
# .../rtl/host/vexriscv/ directory so l1.vlt's waivers for the generated
# cores apply to it.  Prints the copy's path.
noflush_core() {
  local d=$run/noflush_rtl/rtl/host/vexriscv f
  f=$d/$(basename "$1")
  mkdir -p "$d"
  sed "s|^\(  assign IBusCachedPlugin_cache_io_flush = \).*;\$|\11'b0; // run.sh gdb_teeth: fence.i flushes nothing|" \
    "$1" > "$f"
  # exactly one line changed
  if [ "$(diff "$1" "$f" | grep -c '^>')" != 1 ]; then
    echo "noflush_core: the flush assignment of $1 not found once" >&2; return 1
  fi
  echo "$f"
}

# build <debug> [variant]: the Verilator image (warnings fatal; the waivers of
# sim/rv_l1/verilator/l1.vlt cover the generated cores and the L1 models).
# variant: teeth (DEBUG=1, TAP model USER4 = 0x22), noflush (the core's
# I-cache flush tied low, see noflush_core)
build() {
  local dbg=$1 var=${2:-} tag=d$1${2:+_$2} src def="" rc=0 core
  case "$dbg" in
    2) core=$top/rtl/host/vexriscv/VexOsd_DMJ.v ;;
    1) core=$top/rtl/host/vexriscv/VexOsd_DMT.v ;;
    *) echo "build: DEBUG must be 1 or 2"; return 1 ;;
  esac
  if [ "$var" = noflush ]; then core=$(noflush_core "$core") || return 1; fi
  case "$dbg" in
    2) src="$CORE_RTL $core" ;;
    1) src="$CORE_RTL $core $top/rtl/host/xilinx/rv_bscane2.v $here/xc7_tap.v"
       def="-DRV_DBG_XC7TAP"; [ "$var" = teeth ] && def="$def -DTEETH_USER4" ;;
  esac
  local t0=$SECONDS
  # shellcheck disable=SC2086
  OBJCACHE=${OBJCACHE-$(command -v ccache)} timeout 900 "$VERILATOR" --cc --exe --build --timing \
    -j "$JOBS" -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -CFLAGS -O2 \
    $def --top-module tb_rv_dbg -GDEBUG="$dbg" --Mdir "$run/vl_$tag" -o Vtb_rv_dbg \
    "$top/sim/rv_l1/verilator/l1.vlt" $BENCH $src "$here/harness.cpp" \
    > "$run/build_$tag.log" 2>&1 || rc=1
  if [ $rc -ne 0 ] || [ ! -x "$(image "$dbg" "$var")" ]; then
    echo "BUILD FAILED DEBUG=$dbg${var:+ $var} (see $run/build_$tag.log)"
    grep -m20 -E '^%(Error|Warning)|error:' "$run/build_$tag.log" || tail -20 "$run/build_$tag.log"
    return 1
  fi
  echo "built $(image "$dbg" "$var") ($((SECONDS - t0)) s)"
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

# sym <name> [elf]: the symbol's address (hex, no 0x); symsize: its size
sym() { "$NM" "${2:-$build/attach.elf}" | awk -v s="$1" '$3 == s { print $1 }'; }
symsize() { "$NM" -S "${2:-$build/attach.elf}" | awk -v s="$1" '$4 == s { print $2 }'; }

# start_openocd <debug> <log> <script> [-c args before the config]: OpenOCD
# with the board config of <debug> (2: minimig-rv-pins.cfg, which defaults
# to an FTDI adapter, so remote_bitbang is named; 1: minimig-rv-bscan.cfg,
# remote-bitbang.cfg by default, only the port is set) and <script>, in the
# background (wall clock 600 s), to the harness on $hport; sets opid
start_openocd() {
  local dbg=$1 log=$2 script=$3; shift 3
  if [ "$dbg" = 2 ]; then
    timeout 600 "$OPENOCD" -c "set ADAPTER $top/tools/openocd/remote-bitbang.cfg" \
      -c "set RBB_PORT $hport" "$@" -f "$top/tools/openocd/minimig-rv-pins.cfg" -f "$script" > "$log" 2>&1 &
  else
    timeout 600 "$OPENOCD" -c "set RBB_PORT $hport" "$@" \
      -f "$top/tools/openocd/minimig-rv-bscan.cfg" -f "$script" > "$log" 2>&1 &
  fi
  opid=$!; pids="$pids $opid"
}

# attach <debug> [teeth]
attach() {
  local dbg=$1 teeth=${2:-} name log hlog im opid why="" t0=$SECONDS
  name=attach$dbg; [ -n "$teeth" ] && name=teeth
  progs || return 1
  build "$dbg" "$teeth" || return 1
  im=$(image "$dbg" "$teeth"); log=$run/$name.openocd.log; hlog=$run/$name.harness.log
  start_harness "$im" "$hlog" +HEX="$build/attach.hex" +rbb_port="$RBB_PORT" \
    +tck_half="$TCK_HALF" +timeout=2000000000 +exit_on_disconnect +rbblog="$run/$name.rbb" || return 1
  [ "$hport" = "$RBB_PORT" ] || echo "RBB port $RBB_PORT in use: the harness listens on $hport"
  start_openocd "$dbg" "$log" "$here/attach.tcl"
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
  if [ -z "$lo" ] || [ -z "$hi" ]; then
    why="$why; no attach_loop/attach_loop_end symbols in $build/attach.elf"
  elif [ -z "$pc" ]; then
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

# free_port <port>: <port> if it can be bound on 127.0.0.1, else a free one
free_port() {
  "$PYTHON" -I -c '
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])' "$1"
}

# the known words main() copies into pattern (sw/dbgtest.c pattern_init)
PATTERN="01234567 89abcdef deadbeef cafef00d 0badf00d 5a5aa5a5 13579bdf 2468ace0"
# the CHECK lines of gdb/session.gdb, in order
GDB_CHECKS="halt_pc pattern counter reset_pc main_pc mailbox_a work_pc mailbox detach"

# gdb_check <name> <value> <elf>: empty if <value> is the expected one, else why
gdb_check() {
  local n=$1 v=$2 elf=$3 a z
  hex8() { printf '0x%08x' "$((16#$1))"; }
  case "$n" in
    halt_pc)   # in main or in work (the loop)
      local ok=""
      for f in main work; do
        a=$((16#$(sym "$f" "$elf"))); z=$((a + 16#$(symsize "$f" "$elf")))
        [ $((v)) -ge $a ] && [ $((v)) -lt $z ] && ok=1
      done
      [ -n "$ok" ] || echo "$v not in main or work" ;;
    pattern)   [ "$v" = "$PATTERN" ] || echo "'$v', expected '$PATTERN'" ;;
    counter)   # two reads around monitor resume / halt: it grew
      set -- $v
      [ $# -eq 2 ] && [ "$2" -gt "$1" ] 2> /dev/null || echo "'$v' did not grow" ;;
    reset_pc)  a=$(hex8 "$(sym _reset "$elf")"); [ "$v" = "$a" ] || echo "$v, expected $a (_reset)" ;;
    main_pc)   a=$(hex8 "$(sym main "$elf")"); [ "$v" = "$a" ] || echo "$v, expected $a (main)" ;;
    work_pc)   a=$(hex8 "$(sym work "$elf")"); [ "$v" = "$a" ] || echo "$v, expected $a (work)" ;;
    mailbox_a) [ "$v" = 0xa5a50001 ] || echo "$v, expected 0xa5a50001 (image A)" ;;
    mailbox)   [ "$v" = 0xb5b50002 ] || echo "$v, expected 0xb5b50002 (image B)" ;;
    detach)    [ "$v" = done ] || echo "'$v'" ;;
  esac
}

# gdb_session <debug> [noflush]
gdb_session() {
  local dbg=$1 var=${2:-} name log hlog glog im opid gport t0=$SECONDS i
  local elf=$build/dbgtest_a.elf fail="" why="" n v w
  name=gdb$dbg; [ -n "$var" ] && name=gdb_teeth
  progs || return 1
  build "$dbg" "$var" || return 1
  im=$(image "$dbg" "$var")
  log=$run/$name.openocd.log; hlog=$run/$name.harness.log; glog=$run/$name.gdb.log
  start_harness "$im" "$hlog" +HEX="$build/dbgtest_a.hex" +rbb_port="$RBB_PORT" \
    +tck_half="$TCK_HALF" +timeout=2000000000 +exit_on_disconnect || return 1
  [ "$hport" = "$RBB_PORT" ] || echo "RBB port $RBB_PORT in use: the harness listens on $hport"
  gport=$(free_port "$GDB_PORT")
  [ "$gport" = "$GDB_PORT" ] || echo "GDB port $GDB_PORT in use: OpenOCD serves GDB on $gport"
  start_openocd "$dbg" "$log" "$here/gdb/openocd.tcl" -c "set GDB_PORT $gport"
  for i in $(seq 1 1200); do
    grep -q "Listening on port $gport for gdb connections" "$log" && break
    kill -0 "$opid" 2> /dev/null || break
    sleep 0.1
  done
  if ! grep -q "Listening on port $gport for gdb connections" "$log"; then
    echo "=== GDB FAIL openocd: no GDB server on $gport ($log)"; tail -5 "$log"; return 1
  fi
  timeout 600 "$GDB" -batch -nx -cd="$build" -ex "set \$gdb_port = $gport" \
    -x "$here/gdb/session.gdb" "$(basename "$elf")" > "$glog" 2>&1 &
  local gpid=$!; pids="$pids $gpid"
  wait "$gpid"; local grc=$?
  wait_pid "$opid" 60; local orc=$?   # OpenOCD shuts down on the detach
  wait_pid "$hpid" 60
  local secs=$((SECONDS - t0))

  # the CHECK lines, in order: the first missing or wrong one fails
  for n in $GDB_CHECKS; do
    if ! grep -q "^CHECK $n " "$glog"; then fail=$n; why="missing"; break; fi
    v=$(sed -n "s/^CHECK $n //p" "$glog" | head -1)
    w=$(gdb_check "$n" "$v" "$elf")
    if [ -n "$w" ]; then fail=$n; why=$w; break; fi
  done
  # the tools ended cleanly
  local env=""
  [ "$grc" -eq 0 ] || env="$env; GDB exit $grc"
  [ "$orc" -eq 0 ] || env="$env; OpenOCD exit $orc"
  grep -q '^Error' "$log" && env="$env; OpenOCD: $(grep -m1 '^Error' "$log")"
  grep -q 'connection 1 closed (Q)' "$hlog" || env="$env; harness: no 'connection 1 closed (Q)'"
  grep -q '^=== EXIT disconnect' "$hlog" || env="$env; harness did not exit on the disconnect"

  grep '^CHECK ' "$glog" | sed 's/^/    /'
  if [ -z "$fail" ] && [ -z "$env" ]; then
    echo "=== GDB PASS DEBUG=$dbg TCK_HALF=$TCK_HALF: $(echo $GDB_CHECKS | wc -w) checks, $secs s"
  elif [ -n "$fail" ]; then
    echo "=== GDB FAIL $fail: $why${env:+ (also${env#;})} ($glog, $log)"
  else
    echo "=== GDB FAIL tools${env/#;/:} ($glog, $log, $hlog)"
  fi
  if [ -n "$var" ]; then
    # teeth: every check before mailbox passes, mailbox holds A's value
    if [ "$fail" = mailbox ] && [ -z "$env" ] && grep -q '^CHECK mailbox 0xa5a50001$' "$glog"; then
      echo "=== GDB_TEETH PASS: fence.i without I-cache flush leaves A's work() running ($secs s)"
      return 0
    fi
    echo "=== GDB_TEETH FAIL: expected '=== GDB FAIL mailbox' with 0xa5a50001"
    return 1
  fi
  [ -z "$fail" ] && [ -z "$env" ]
}

xcheck() {
  bash "$here/xcheck/run_xcheck.sh"
}

case "${1:-}" in
  attach2) attach 2; exit $? ;;
  attach1) attach 1; exit $? ;;
  teeth)   attach 1 teeth; exit $? ;;
  xvc_loop) xvc_loop; exit $? ;;
  gdb2)    gdb_session 2; exit $? ;;
  gdb1)    gdb_session 1; exit $? ;;
  gdb_teeth) gdb_session 1 noflush; exit $? ;;
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
    for t in attach2 attach1 teeth gdb2 gdb1 gdb_teeth xvc_loop xcheck; do
      echo "--- $t"
      bash "$0" "$t" || fail=1
    done
    if [ $fail -eq 0 ]; then echo "=== RV_DBG ALL PASS"; else echo "=== RV_DBG SOME FAILED"; fi
    exit $fail
    ;;
  *)
    sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 2 ;;
esac
