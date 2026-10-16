#!/usr/bin/env bash
# L1 bench (iverilog): rv_hostcpu + BE memory model + bus contract checker.
#
#   make -C sim/rv_l1 tests            # build the test programs first
#   bash sim/rv_l1/run.sh all          # full matrix + teeth + gates
#   bash sim/rv_l1/run.sh lanes        # one program; WS, ROMWS, EXTRA_WS,
#   WS=8 ROMWS=0 EXTRA_WS=3 bash sim/rv_l1/run.sh refill   # DEBUG from env
#
# Outputs: sim/rv_l1/run_${RUNTAG:-wt}/ (vvp images, one log per run,
# results.txt).  JOBS= parallel vvp runs (default nproc).
#
# "all" =
#   gate 1  rv_hostcpu.v (+ cores) parses and elaborates with iverilog -g2005
#           (DEBUG 0 and 2)
#   gate 2  DEBUG=1 fails elaboration (no rv_bscane2 until Task 14)
#   matrix  every program in PROGS x WS {0,3,8} x ROMWS {0,1} x EXTRA_WS {0,3}
#           must print "=== PASS" (and match tests/<prog>.mem if present)
#   teeth   fencei_nofencei over the same matrix must print "=== FAIL 1"
#   debug   every program once with DEBUG=2 (WS=3 ROMWS=1)
#   no run may print "=== BUS VIOLATION"
#
#   make -C sim/rv_l1/prog             # build the firmware units first
#   bash sim/rv_l1/run.sh units        # atapi_emu cue_emu cdaudio_emu (WS=3
#                                      # ROMWS=1 by default); verdict as the emu
#                                      # Makefile: no line "FAIL...", a line
#                                      # exactly "PASS", bench "=== PASS"
set -u

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
IVERILOG=${IVERILOG:-/usr/local/bin/iverilog}
VVP=${VVP:-/usr/local/bin/vvp}
JOBS=${JOBS:-$(nproc)}
run=$here/run_${RUNTAG:-wt}
build=$here/build

PROGS="lanes refill fencei irq"
UNITS="atapi_emu cue_emu cdaudio_emu"
TEETH="fencei_nofencei"

CORES="$top/rtl/host/vexriscv/VexOsd.v $top/rtl/host/vexriscv/VexOsd_DMT.v $top/rtl/host/vexriscv/VexOsd_DMJ.v"
RTL="$top/rtl/host/rv_hostcpu.v $CORES"
BENCH="$here/tb_rv_l1.v $here/mem_model.v $here/bus_checker.v"

# expected outcome of a program: "pass" or "fail:<code>"
expect_of() {
  case "$1" in
    fencei_nofencei) echo "fail:1" ;;
    *)               echo "pass" ;;
  esac
}

# compile <extra_ws> <debug> -> $run/tb_x<n>_d<n>.vvp
compile() {
  local x=$1 dbg=$2 out=$run/tb_x$1_d$2.vvp
  [ -f "$out" ] && return 0
  if ! "$IVERILOG" -g2012 -DRV_HOSTCPU_STATS -s tb_rv_l1 \
       -P tb_rv_l1.EXTRA_WS="$x" -P tb_rv_l1.DEBUG="$dbg" \
       -o "$out" $BENCH $RTL > "$run/compile_x${x}_d${dbg}.log" 2>&1; then
    echo "COMPILE FAILED EXTRA_WS=$x DEBUG=$dbg (see $run/compile_x${x}_d${dbg}.log)"
    sed -n '1,20p' "$run/compile_x${x}_d${dbg}.log"
    return 1
  fi
}

# one <prog> <ws> <romws> <extra_ws> <debug>: prints one result line
one() {
  local prog=$1 ws=$2 romws=$3 x=$4 dbg=$5
  local tag="$prog ws=$ws romws=$romws x=$x d=$dbg"
  local log=$run/${prog}_ws${ws}_r${romws}_x${x}_d${dbg}.log
  local vvp=$run/tb_x${x}_d${dbg}.vvp
  local exp; exp=$(expect_of "$prog")
  local memf=$here/tests/$prog.mem args=""
  if [ ! -f "$build/$prog.hex" ]; then
    echo "FAIL $tag: $build/$prog.hex missing (make -C sim/rv_l1 tests)"; return 1
  fi
  if [ ! -f "$vvp" ]; then echo "FAIL $tag: $vvp missing (compile failed)"; return 1; fi
  if [ -f "$memf" ]; then
    args="+DUMP_ADDR=$(head -1 "$memf" | cut -d' ' -f1) +DUMP_N=$(grep -c . "$memf")"
  fi
  # shellcheck disable=SC2086
  "$VVP" -N "$vvp" +HEX="$build/$prog.hex" +WS="$ws" +ROMWS="$romws" $args > "$log" 2>&1
  local cyc; cyc=$(sed -n 's/^=== CYCLES //p' "$log")
  local res; res=$(grep -m1 -E '^=== (PASS|FAIL|TIMEOUT)' "$log" | sed 's/^=== //')
  local bad=""
  grep -q 'BUS VIOLATION' "$log" && bad="bus violation"
  if [ -z "$bad" ] && [ "$exp" = pass ] && [ "$res" = PASS ] && [ -f "$memf" ]; then
    if ! diff -q <(sed -n 's/^=== MEM //p' "$log" | tr a-f A-F) <(tr a-f A-F < "$memf") > /dev/null; then
      bad="memory dump differs from tests/$prog.mem"
    fi
  fi
  if [ -z "$bad" ]; then
    if [ "$exp" = pass ] && [ "$res" = PASS ]; then
      echo "PASS $tag cycles=$cyc"; return 0
    elif [ "$exp" != pass ] && [ "$res" = "FAIL ${exp#fail:}" ]; then
      echo "PASS $tag cycles=$cyc (expected FAIL ${exp#fail:})"; return 0
    fi
    bad="got '${res:-nothing}', expected $exp"
  fi
  echo "FAIL $tag: $bad ($log)"
  return 1
}

# unit <prog> <ws> <romws> <extra_ws> <debug>: a firmware unit (prog/Makefile).
# Passes when the bench says PASS, no output line starts with FAIL, a line is
# exactly PASS (the verdict grep of fw/ctrl_832/test/emu/Makefile).
unit() {
  local prog=$1 ws=$2 romws=$3 x=$4 dbg=$5
  local tag="$prog ws=$ws romws=$romws x=$x d=$dbg"
  local log=$run/${prog}_ws${ws}_r${romws}_x${x}_d${dbg}.log
  local vvp=$run/tb_x${x}_d${dbg}.vvp
  if [ ! -f "$build/$prog.hex" ]; then
    echo "FAIL $tag: $build/$prog.hex missing (make -C sim/rv_l1/prog)"; return 1
  fi
  "$VVP" -N "$vvp" +HEX="$build/$prog.hex" +WS="$ws" +ROMWS="$romws" +TIMEOUT="${TIMEOUT:-20000000}" > "$log" 2>&1
  local cyc; cyc=$(sed -n 's/^=== CYCLES //p' "$log")
  local res; res=$(grep -m1 -E '^=== (PASS|FAIL|TIMEOUT)' "$log" | sed 's/^=== //')
  if [ "$res" = PASS ] && ! grep -q '^FAIL' "$log" && grep -qx PASS "$log" \
     && ! grep -q 'BUS VIOLATION' "$log"; then
    echo "PASS $tag cycles=$cyc"; return 0
  fi
  echo "FAIL $tag: bench '${res:-nothing}' ($log)"
  return 1
}

gates() {
  local ok=0
  for dbg in 0 2; do
    if "$IVERILOG" -g2005 -s rv_hostcpu -P rv_hostcpu.DEBUG=$dbg -o "$run/g2005_d$dbg.vvp" $RTL \
         > "$run/g2005_d$dbg.log" 2>&1; then
      echo "PASS gate iverilog -g2005 rv_hostcpu DEBUG=$dbg"
    else
      echo "FAIL gate iverilog -g2005 rv_hostcpu DEBUG=$dbg ($run/g2005_d$dbg.log)"; ok=1
    fi
  done
  if "$IVERILOG" -g2012 -s rv_hostcpu -P rv_hostcpu.DEBUG=1 -o "$run/debug1.vvp" $RTL \
       > "$run/debug1.log" 2>&1; then
    echo "FAIL gate DEBUG=1 elaborated (must fail until rv_bscane2, Task 14)"; ok=1
  elif grep -q 'rv_hostcpu_DEBUG1_needs_rv_bscane2_Task14' "$run/debug1.log"; then
    echo "PASS gate DEBUG=1 fails elaboration (rv_hostcpu_DEBUG1_needs_rv_bscane2_Task14)"
  else
    echo "FAIL gate DEBUG=1 failed for another reason ($run/debug1.log)"; ok=1
  fi
  return $ok
}

mkdir -p "$run"

case "${1:-}" in
  __one) shift; one "$@" ;;
  units)
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}
    rm -f "$run/tb_x${x}_d${dbg}.vvp"
    compile "$x" "$dbg" || exit 1
    rc=0
    for p in $UNITS; do
      unit "$p" "${WS:-3}" "${ROMWS:-1}" "$x" "$dbg" || rc=1
    done | tee "$run/units.txt"
    grep -q '^FAIL' "$run/units.txt" && rc=1
    if [ $rc -eq 0 ]; then echo "=== UNITS PASS"; else echo "=== UNITS FAILED"; fi
    exit $rc
    ;;
  all)
    rm -f "$run"/*.vvp "$run"/*.log "$run/results.txt"
    fail=0
    gates | tee "$run/gates.txt"
    grep -q '^FAIL' "$run/gates.txt" && fail=1
    for x in 0 3; do compile "$x" 0 || fail=1; done
    compile 0 2 || fail=1
    {
      for p in $PROGS $TEETH; do
        for ws in 0 3 8; do for r in 0 1; do for x in 0 3; do
          echo "$p $ws $r $x 0"
        done; done; done
      done
      for p in $PROGS; do echo "$p 3 1 0 2"; done
    } | xargs -P "$JOBS" -L1 bash "$0" __one | sort > "$run/results.txt"
    cat "$run/results.txt"
    n=$(grep -c . "$run/results.txt"); np=$(grep -c '^PASS' "$run/results.txt")
    nv=$(cat "$run"/*_ws*.log 2>/dev/null | grep -c 'BUS VIOLATION')
    echo "=== runs $np/$n as expected, bus violations $nv"
    [ "$np" -eq "$n" ] && [ "$nv" -eq 0 ] || fail=1
    if [ $fail -eq 0 ]; then echo "=== ALL PASS"; else echo "=== SOME FAILED"; fi
    exit $fail
    ;;
  ""|-h|--help)
    sed -n '2,25p' "$0"; exit 0 ;;
  *)
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}
    rm -f "$run/tb_x${x}_d${dbg}.vvp"
    compile "$x" "$dbg" || exit 1
    rc=0
    for p in "$@"; do
      one "$p" "${WS:-3}" "${ROMWS:-1}" "$x" "$dbg" || rc=1
    done
    exit $rc
    ;;
esac
