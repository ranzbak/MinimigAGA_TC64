#!/usr/bin/env bash
# L1 bench: rv_hostcpu + BE memory model + bus contract checker.
#
# Simulator: SIM=iverilog (default; 4-state, the X-checking reference) or
# SIM=verilator (Verilator 5, --binary --timing, 2-state: the bench's X
# checks cannot fire there).  Same tests, plusargs, parameters, verdict
# lines and run directories; the gates always run on iverilog.
#   SIM=verilator bash sim/rv_l1/run.sh all
#   bash sim/rv_l1/run.sh compare <RUNTAG a> <RUNTAG b>
#        every log in both run directories: same verdict, cycles, stats,
#        memory dumps, TIME stamps and program output (exit 1 otherwise)
#
#   bash sim/rv_l1/run.sh all          # full matrix + teeth + gates
#   bash sim/rv_l1/run.sh lanes        # one program; WS, ROMWS, EXTRA_WS,
#   WS=8 ROMWS=0 EXTRA_WS=3 bash sim/rv_l1/run.sh refill   # DEBUG from env
#   bash sim/rv_l1/run.sh irq          # interrupt/trap set (below)
#   bash sim/rv_l1/run.sh dm_smoke     # debug smoke test over the pin TAP (below)
#
# The test programs are (re)built first (make -C sim/rv_l1 tests; units:
# make -C sim/rv_l1/prog; dhry: make -C fw/dhrystone_rv).
# Outputs: sim/rv_l1/run_${RUNTAG:-wt}/ (simulator images tb_*.vvp or
# vl_*/Vtb_rv_l1, one log per run, results.txt).  JOBS= parallel runs
# (default nproc).
#
# "all" =
#   gate 1  rv_hostcpu.v (+ cores) parses and elaborates with iverilog -g2005
#           (DEBUG 0 and 2)
#   gate 2  DEBUG=1 without rtl/host/xilinx/rv_bscane2.v fails elaboration on
#           rv_bscane2 only, and with it on BSCANE2 + BUFG only (no unisims
#           here; sim/host_bridge/stub/elab.sh dmt elaborates it in xsim)
#   gate 3  DEBUG=3 fails elaboration (rv_hostcpu_DEBUG_must_be_0_1_or_2)
#   gate 4  vendor-neutral: no BSCANE2/BUFG* instance in rtl/host except
#           rtl/host/xilinx/rv_bscane2.v; rtl/host/host.qip does not name it
#   matrix  every program in PROGS x WS {0,3,8} x ROMWS {0,1} x EXTRA_WS {0,3}
#           must print "=== PASS" (and match tests/<prog>.mem if present)
#   teeth   fencei_nofencei over the same matrix must print "=== FAIL 1",
#           irq_sig_mut "=== FAIL 11c"; uart_read (a read of the cfide UART,
#           which cfide never acks) once at WS=3 ROMWS=1 "=== FAIL uart read"
#   debug   every program once with DEBUG=2 (WS=3 ROMWS=1)
#   dm      dm_smoke (DEBUG=2, -DDM_SMOKE) x WS {0,3,8} x EXTRA_WS {0,3}, ROMWS=1
#   no run may print "=== BUS VIOLATION"
#
# "irq" = irq irq_sig irq_c exc x WS {0,3,8} (ROMWS, EXTRA_WS, DEBUG from env,
#   default 1/0/0) must PASS, and irq_sig_mut (fw/ctrl_rv/arch/trap.S without
#   the restore of t3) once at WS=3 must end "=== FAIL 11c" (x28 changed);
#   ends "=== IRQ PASS" or "=== IRQ FAILED"
#
# "dm_smoke" = tests/dm_smoke.v (JTAG BFM jtag_bfm.v on the VexOsd_DMJ pin
#   TAP: IDCODE, dtmcs, dmactive, halt, abstract register read/write,
#   resume, ndmreset) with program tests/dm_smoke.S, DEBUG=2, x WS {0,3,8} x
#   EXTRA_WS {0,3} (ROMWS from env, default 1); each run must end "=== PASS";
#   ends "=== DM_SMOKE PASS (6 runs)" or "=== DM_SMOKE FAILED"
#
#   bash sim/rv_l1/run.sh units        # atapi_emu cue_emu cdaudio_emu in parallel
#                                      # (WS=3 ROMWS=1 by default); verdict as the emu
#                                      # Makefile: no line "FAIL...", a line
#                                      # exactly "PASS", bench "=== PASS";
#                                      # TIMEOUT default 40000000 (cdaudio_emu
#                                      # needs about 19.1 M cycles)
#
#   bash sim/rv_l1/run.sh dhry         # fw/dhrystone_rv -O2 and -Os, WS=3 ROMWS=1
#                                      # (WS, ROMWS, EXTRA_WS, DEBUG from env); each
#                                      # must PASS with no "should be" line, "Result
#                                      # checks" wrong = 0; the cycles between the
#                                      # TIME 1 and TIME 2 stamps are the result;
#                                      # then dhry_teeth (-DDHRY_CHECK_TEETH, one
#                                      # value wrong) must end "=== FAIL 1" with
#                                      # one "should be" line and "1 wrong"
set -u

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
IVERILOG=${IVERILOG:-/usr/local/bin/iverilog}
VVP=${VVP:-/usr/local/bin/vvp}
VERILATOR=${VERILATOR:-verilator}
SIM=${SIM:-iverilog}
JOBS=${JOBS:-$(nproc)}
run=$here/run_${RUNTAG:-wt}
build=$here/build
case "$SIM" in
  iverilog|verilator) ;;
  *) echo "SIM=$SIM: must be iverilog or verilator"; exit 2 ;;
esac
export SIM

PROGS="lanes refill fencei irq irq_sig irq_c exc"
IRQPROGS="irq irq_sig irq_c exc"
UNITS="atapi_emu cue_emu cdaudio_emu"
TEETH="fencei_nofencei irq_sig_mut"
DMPROGS="dm_smoke"   # need the -DDM_SMOKE bench (BFM + tests/dm_smoke.v), DEBUG=2

CORES="$top/rtl/host/vexriscv/VexOsd.v $top/rtl/host/vexriscv/VexOsd_DMT.v $top/rtl/host/vexriscv/VexOsd_DMJ.v"
RTL="$top/rtl/host/rv_hostcpu.v $CORES"
BENCH="$here/tb_rv_l1.v $here/mem_model.v $here/bus_checker.v"
BENCH_DM="$BENCH $here/jtag_bfm.v $here/tests/dm_smoke.v"

# expected outcome of a program: "pass" or "fail:<code>"
expect_of() {
  case "$1" in
    fencei_nofencei) echo "fail:1" ;;
    irq_sig_mut)     echo "fail:11c" ;;
    uart_read)       echo "fail:uart read" ;;
    dhry_teeth)      echo "fail:1" ;;
    *)               echo "pass" ;;
  esac
}

# image <extra_ws> <debug> [dm]: the simulator image of that bench build
image() {
  if [ "$SIM" = verilator ]; then echo "$run/vl_x$1_d$2${3:+_dm}/Vtb_rv_l1"
  else                            echo "$run/tb_x$1_d$2${3:+_dm}.vvp"; fi
}

# drop <extra_ws> <debug> [dm]: remove that image (the next compile rebuilds it)
drop() {
  rm -f "$run/tb_x$1_d$2${3:+_dm}.vvp"
  [ -d "$run/vl_x$1_d$2${3:+_dm}" ] && rm -r "$run/vl_x$1_d$2${3:+_dm}"
  return 0
}

# sim <image> <plusargs...>: one simulation
sim() {
  local im=$1; shift
  if [ "$SIM" = verilator ]; then "$im" "$@"; else "$VVP" -N "$im" "$@"; fi
}

# compile <extra_ws> <debug> [dm] -> image (tb_x<n>_d<n>[_dm].vvp or
# vl_x<n>_d<n>[_dm]/Vtb_rv_l1); dm: the -DDM_SMOKE bench with the JTAG BFM
# and tests/dm_smoke.v
compile() {
  local x=$1 dbg=$2 dm=${3:-} out; out=$(image "$@")
  local tag=x${x}_d${dbg}${dm:+_dm} src=$BENCH def="" rc=0
  [ -n "$dm" ] && { src=$BENCH_DM; def=-DDM_SMOKE; }
  [ -f "$out" ] && return 0
  if [ "$SIM" = verilator ]; then
    # Warnings are fatal; the waivers are in verilator/l1.vlt.  The C++ is
    # built with -O2 (Verilator's default -Os runs slower); ccache if present.
    # shellcheck disable=SC2086
    OBJCACHE=${OBJCACHE-$(command -v ccache)} "$VERILATOR" --binary --timing \
      -j "$JOBS" -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" \
      -DRV_HOSTCPU_STATS $def --top-module tb_rv_l1 \
      -GEXTRA_WS="$x" -GDEBUG="$dbg" --Mdir "$run/vl_$tag" -o Vtb_rv_l1 \
      "$here/verilator/l1.vlt" $src $RTL > "$run/compile_$tag.log" 2>&1 || rc=1
  else
    # shellcheck disable=SC2086
    "$IVERILOG" -g2012 -DRV_HOSTCPU_STATS $def -s tb_rv_l1 \
      -P tb_rv_l1.EXTRA_WS="$x" -P tb_rv_l1.DEBUG="$dbg" \
      -o "$out" $src $RTL > "$run/compile_$tag.log" 2>&1 || rc=1
  fi
  if [ $rc -ne 0 ] || [ ! -f "$out" ]; then
    echo "COMPILE FAILED ($SIM) EXTRA_WS=$x DEBUG=$dbg ${dm:+DM_SMOKE }(see $run/compile_$tag.log)"
    grep -m20 -E '^%(Error|Warning)' "$run/compile_$tag.log" || sed -n '1,20p' "$run/compile_$tag.log"
    return 1
  fi
}

# progs: rebuild the test programs if their sources changed
progs() {
  make -s -C "$here" tests > "$run/make_tests.log" 2>&1 && return 0
  echo "FAIL make -C sim/rv_l1 tests ($run/make_tests.log)"
  tail -5 "$run/make_tests.log"
  exit 1
}

is_dm() { case " $DMPROGS " in *" $1 "*) return 0 ;; esac; return 1; }

# one <prog> <ws> <romws> <extra_ws> <debug>: prints one result line
one() {
  local prog=$1 ws=$2 romws=$3 x=$4 dbg=$5
  local tag="$prog ws=$ws romws=$romws x=$x d=$dbg"
  local log=$run/${prog}_ws${ws}_r${romws}_x${x}_d${dbg}.log
  local im; im=$(image "$x" "$dbg")
  is_dm "$prog" && im=$(image "$x" "$dbg" dm)
  local exp; exp=$(expect_of "$prog")
  local memf=$here/tests/$prog.mem args=""
  if [ ! -f "$build/$prog.hex" ]; then
    echo "FAIL $tag: $build/$prog.hex missing (make -C sim/rv_l1 tests)"; return 1
  fi
  if [ ! -f "$im" ]; then echo "FAIL $tag: $im missing (compile failed)"; return 1; fi
  if [ -f "$memf" ]; then
    args="+DUMP_ADDR=$(head -1 "$memf" | cut -d' ' -f1) +DUMP_N=$(grep -c . "$memf")"
  fi
  # shellcheck disable=SC2086
  sim "$im" +HEX="$build/$prog.hex" +WS="$ws" +ROMWS="$romws" $args > "$log" 2>&1
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
  local im; im=$(image "$x" "$dbg")
  if [ ! -f "$build/$prog.hex" ]; then
    echo "FAIL $tag: $build/$prog.hex missing (make -C sim/rv_l1/prog)"; return 1
  fi
  sim "$im" +HEX="$build/$prog.hex" +WS="$ws" +ROMWS="$romws" +TIMEOUT="${TIMEOUT:-40000000}" > "$log" 2>&1
  local cyc; cyc=$(sed -n 's/^=== CYCLES //p' "$log")
  local res; res=$(grep -m1 -E '^=== (PASS|FAIL|TIMEOUT)' "$log" | sed 's/^=== //')
  if [ "$res" = PASS ] && ! grep -q '^FAIL' "$log" && grep -qx PASS "$log" \
     && ! grep -q 'BUS VIOLATION' "$log"; then
    echo "PASS $tag cycles=$cyc"; return 0
  fi
  echo "FAIL $tag: bench '${res:-nothing}' ($log)"
  return 1
}

# norm <log>: a run log without the simulator's own lines (iverilog
# "...: $finish called at ...", Verilator "- ...: Verilog $finish") and with
# the start-up lines of the bench's initial blocks (TB, MEMLOAD, MEMCFG,
# WARNING; their order between initial blocks is the simulator's choice)
# sorted at the top; everything else in order
norm() {
  local hdr='^=== (TB|MEMLOAD|MEMCFG|WARNING) '
  grep -E "$hdr" "$1" | LC_ALL=C sort
  grep -vE "$hdr"'|\$finish called at |^- .*: Verilog \$finish' "$1"
}

# compare <dir a> <dir b>: every run log (<prog>_ws*_r*_x*_d*.log) of both
compare() {
  local a=$1 b=$2 f n=0 nd=0 no=0 v c
  for f in $( (cd "$a" && ls ./*_ws*_r*_x*_d*.log; cd "$b" && ls ./*_ws*_r*_x*_d*.log) 2>/dev/null \
              | sed 's|^\./||' | LC_ALL=C sort -u); do
    if [ ! -f "$a/$f" ] || [ ! -f "$b/$f" ]; then
      echo "ONLY ${f%.log}: in $( [ -f "$a/$f" ] && echo "$a" || echo "$b")"; no=$((no + 1)); continue
    fi
    n=$((n + 1))
    v=$(grep -m1 -E '^=== (PASS|FAIL|TIMEOUT)' "$a/$f" | sed 's/^=== //')
    c=$(sed -n 's/^=== CYCLES //p' "$a/$f")
    if diff -q <(norm "$a/$f") <(norm "$b/$f") > /dev/null; then
      echo "SAME ${f%.log}: ${v:-no verdict}, cycles ${c:-?}"
    else
      nd=$((nd + 1))
      echo "DIFF ${f%.log}: $(grep -m1 -E '^=== (PASS|FAIL|TIMEOUT)' "$b/$f" | sed 's/^=== //') cycles $(sed -n 's/^=== CYCLES //p' "$b/$f") in $b, ${v:-no verdict} cycles ${c:-?} in $a"
      diff <(norm "$a/$f") <(norm "$b/$f") | sed -n '1,6s/^/    /p'
    fi
  done
  echo "=== COMPARE $n logs: $((n - nd)) same, $nd differ, $no in one directory only"
  [ "$nd" -eq 0 ] && [ "$no" -eq 0 ] && [ "$n" -gt 0 ]
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
  # DEBUG=1: the only module it needs beyond the neutral files is rv_bscane2,
  # and rv_bscane2 needs only BSCANE2 and BUFG (unisims; not in iverilog)
  "$IVERILOG" -g2012 -s rv_hostcpu -P rv_hostcpu.DEBUG=1 -o "$run/debug1.vvp" $RTL \
    > "$run/debug1.log" 2>&1
  local miss; miss=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\) referenced .*/\1/p' "$run/debug1.log" | LC_ALL=C sort | tr '\n' ' ')
  if [ "$miss" = "rv_bscane2 " ]; then
    echo "PASS gate DEBUG=1 without rv_bscane2.v: missing only rv_bscane2"
  else
    echo "FAIL gate DEBUG=1 without rv_bscane2.v: missing '$miss' ($run/debug1.log)"; ok=1
  fi
  "$IVERILOG" -g2012 -s rv_hostcpu -P rv_hostcpu.DEBUG=1 -o "$run/debug1b.vvp" $RTL \
    "$top/rtl/host/xilinx/rv_bscane2.v" > "$run/debug1b.log" 2>&1
  miss=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\) referenced .*/\1/p' "$run/debug1b.log" | LC_ALL=C sort | tr '\n' ' ')
  if [ "$miss" = "BSCANE2 BUFG " ]; then
    echo "PASS gate DEBUG=1 with rv_bscane2.v: missing only BSCANE2 BUFG (unisims)"
  else
    echo "FAIL gate DEBUG=1 with rv_bscane2.v: missing '$miss' ($run/debug1b.log)"; ok=1
  fi
  if "$IVERILOG" -g2012 -s rv_hostcpu -P rv_hostcpu.DEBUG=3 -o "$run/debug3.vvp" $RTL \
       > "$run/debug3.log" 2>&1; then
    echo "FAIL gate DEBUG=3 elaborated"; ok=1
  elif grep -q 'rv_hostcpu_DEBUG_must_be_0_1_or_2' "$run/debug3.log"; then
    echo "PASS gate DEBUG=3 fails elaboration (rv_hostcpu_DEBUG_must_be_0_1_or_2)"
  else
    echo "FAIL gate DEBUG=3 failed for another reason ($run/debug3.log)"; ok=1
  fi
  local vend; vend=$(grep -rlE '^[[:space:]]*(BSCANE2|BUFG[A-Z0-9_]*)\b' "$top/rtl/host" | sed "s|^$top/||" | LC_ALL=C sort | tr '\n' ' ')
  if [ "$vend" = "rtl/host/xilinx/rv_bscane2.v " ] && ! grep -q rv_bscane2 "$top/rtl/host/host.qip"; then
    echo "PASS gate vendor primitives in rtl/host only in rtl/host/xilinx/rv_bscane2.v, not in host.qip"
  else
    echo "FAIL gate vendor primitives in rtl/host: '$vend' (or rv_bscane2 in host.qip)"; ok=1
  fi
  return $ok
}

if [ "${1:-}" = compare ]; then
  [ $# -eq 3 ] || { echo "usage: run.sh compare <RUNTAG a> <RUNTAG b>"; exit 2; }
  for t in "$2" "$3"; do
    [ -d "$here/run_$t" ] || { echo "no run directory $here/run_$t"; exit 2; }
  done
  compare "$here/run_$2" "$here/run_$3"
  exit $?
fi

mkdir -p "$run"

case "${1:-}" in
  __one) shift; one "$@" ;;
  __unit) shift; unit "$@" ;;
  units)
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}
    if ! make -s -C "$here/prog" > "$run/make_prog.log" 2>&1; then
      echo "FAIL make -C sim/rv_l1/prog ($run/make_prog.log)"; tail -5 "$run/make_prog.log"; exit 1
    fi
    drop "$x" "$dbg"
    compile "$x" "$dbg" || exit 1
    rc=0
    for p in $UNITS; do echo "$p ${WS:-3} ${ROMWS:-1} $x $dbg"; done \
      | xargs -P "$JOBS" -L1 bash "$0" __unit | sort | tee "$run/units.txt"
    [ "$(grep -c '^PASS' "$run/units.txt")" -eq "$(echo $UNITS | wc -w)" ] || rc=1
    if [ $rc -eq 0 ]; then echo "=== UNITS PASS"; else echo "=== UNITS FAILED"; fi
    exit $rc
    ;;
  irq)
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}; r=${ROMWS:-1}
    progs
    drop "$x" "$dbg"
    compile "$x" "$dbg" || exit 1
    {
      for p in $IRQPROGS; do for ws in 0 3 8; do echo "$p $ws $r $x $dbg"; done; done
      echo "irq_sig_mut 3 $r $x $dbg"
    } | xargs -P "$JOBS" -L1 bash "$0" __one | sort > "$run/irq.txt"
    cat "$run/irq.txt"
    n=$(grep -c '^PASS' "$run/irq.txt")
    if grep -q '^FAIL' "$run/irq.txt" || [ "$n" -ne 13 ]; then echo "=== IRQ FAILED"; exit 1; fi
    echo "=== IRQ PASS ($n runs)"
    exit 0
    ;;
  dm_smoke)
    r=${ROMWS:-1}
    progs
    drop 0 2 dm; drop 3 2 dm
    compile 0 2 dm || exit 1
    compile 3 2 dm || exit 1
    for p in $DMPROGS; do for ws in 0 3 8; do for x in 0 3; do echo "$p $ws $r $x 2"; done; done; done \
      | xargs -P "$JOBS" -L1 bash "$0" __one | sort > "$run/dm_smoke.txt"
    cat "$run/dm_smoke.txt"
    n=$(grep -c '^PASS' "$run/dm_smoke.txt")
    if grep -q '^FAIL' "$run/dm_smoke.txt" || [ "$n" -ne 6 ]; then echo "=== DM_SMOKE FAILED"; exit 1; fi
    echo "=== DM_SMOKE PASS ($n runs)"
    exit 0
    ;;
  dhry)
    # Dhrystone (fw/dhrystone_rv): own result checks + the TIME 1..2 cycles
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}
    drop "$x" "$dbg"
    compile "$x" "$dbg" || exit 1
    make -s -C "$top/fw/dhrystone_rv" l1_O2.hex l1_Os.hex build/l1_O2_teeth.hex || exit 1
    rc=0
    for o in O2 Os; do
      cp "$top/fw/dhrystone_rv/l1_$o.hex" "$build/dhry_$o.hex" || exit 1
      one "dhry_$o" "${WS:-3}" "${ROMWS:-1}" "$x" "$dbg" || rc=1
      log=$run/dhry_${o}_ws${WS:-3}_r${ROMWS:-1}_x${x}_d${dbg}.log
      if grep -q 'should be' "$log"; then echo "FAIL dhry_$o: result check mismatch"; grep 'should be' "$log"; rc=1; fi
      grep -q '^Result checks: [0-9]* compared, 0 wrong' "$log" || { echo "FAIL dhry_$o: no 'Result checks ... 0 wrong' line"; rc=1; }
      t1=$(sed -n 's/^=== TIME 1 cycle //p' "$log"); t2=$(sed -n 's/^=== TIME 2 cycle //p' "$log")
      if [ -n "$t1" ] && [ -n "$t2" ]; then
        echo "dhry_$o: $((t2 - t1)) cycles per 100 runs (WS=${WS:-3} ROMWS=${ROMWS:-1} EXTRA_WS=$x)"
      else echo "FAIL dhry_$o: TIME stamps missing"; rc=1; fi
    done
    # teeth: -DDHRY_CHECK_TEETH sets one value wrong; the checks must catch it
    cp "$top/fw/dhrystone_rv/build/l1_O2_teeth.hex" "$build/dhry_teeth.hex" || exit 1
    one dhry_teeth "${WS:-3}" "${ROMWS:-1}" "$x" "$dbg" || rc=1
    log=$run/dhry_teeth_ws${WS:-3}_r${ROMWS:-1}_x${x}_d${dbg}.log
    if grep -q '^Error Int_Glob is 6 but should be 5' "$log" && grep -q '^Result checks: [0-9]* compared, 1 wrong' "$log"; then
      echo "PASS dhry_teeth: the result checks caught the wrong value"
    else echo "FAIL dhry_teeth: no 'should be' line or not '1 wrong' ($log)"; rc=1; fi
    exit $rc
    ;;
  all)
    rm -f "$run"/*.vvp "$run"/*.log "$run/results.txt"
    for t in "x0 0" "x3 0" "x0 2" "x0 2 dm" "x3 2 dm"; do
      # shellcheck disable=SC2086
      set -- $t; drop "${1#x}" "$2" ${3:-}
    done
    progs
    fail=0
    gates | tee "$run/gates.txt"
    grep -q '^FAIL' "$run/gates.txt" && fail=1
    for x in 0 3; do compile "$x" 0 || fail=1; done
    compile 0 2 || fail=1
    compile 0 2 dm || fail=1
    compile 3 2 dm || fail=1
    {
      for p in $PROGS $TEETH; do
        for ws in 0 3 8; do for r in 0 1; do for x in 0 3; do
          echo "$p $ws $r $x 0"
        done; done; done
      done
      for p in $PROGS; do echo "$p 3 1 0 2"; done
      echo "uart_read 3 1 0 0"
      for p in $DMPROGS; do for ws in 0 3 8; do for x in 0 3; do echo "$p $ws 1 $x 2"; done; done; done
    } | xargs -P "$JOBS" -L1 bash "$0" __one | sort > "$run/results.txt"
    cat "$run/results.txt"
    n=$(grep -c . "$run/results.txt"); np=$(grep -c '^PASS' "$run/results.txt")
    nv=$(cat "$run"/*_ws*.log 2>/dev/null | grep -c 'BUS VIOLATION')
    echo "=== runs $np/$n as expected, bus violations $nv ($SIM)"
    [ "$np" -eq "$n" ] && [ "$nv" -eq 0 ] || fail=1
    if [ $fail -eq 0 ]; then echo "=== ALL PASS"; else echo "=== SOME FAILED"; fi
    exit $fail
    ;;
  ""|-h|--help)
    sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 0 ;;
  *)
    x=${EXTRA_WS:-0}; dbg=${DEBUG:-0}
    progs
    drop "$x" "$dbg"; drop "$x" "$dbg" dm
    compile "$x" "$dbg" || exit 1
    for p in "$@"; do
      if is_dm "$p"; then
        [ "$dbg" = 2 ] || { echo "FAIL $p needs DEBUG=2"; exit 1; }
        compile "$x" "$dbg" dm || exit 1
      fi
    done
    rc=0
    for p in "$@"; do
      one "$p" "${WS:-3}" "${ROMWS:-1}" "$x" "$dbg" || rc=1
    done
    exit $rc
    ;;
esac
