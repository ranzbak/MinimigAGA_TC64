#!/bin/bash
# kbd_release_gate: the OSD must not swallow the release of a key the Amiga
# saw go down.  ./run.sh (expects PASS) and ./run.sh mutant (expects FAIL).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
B=$HERE/build; mkdir -p $B
rc=0
for mode in ${*:-normal mutant}; do
  src=$ROOT/rtl/minimig/amiga_keyboard.v; want=PASS
  if [ "$mode" = mutant ]; then
    sed 's/allowed = !dis || (code\[7\] \&\& dn\[code\[6:0\]\]);/allowed = !dis;/' $src > $B/amiga_keyboard_mut.v
    grep -q 'allowed = !dis;' $B/amiga_keyboard_mut.v || { echo "mutant not applied"; exit 2; }
    src=$B/amiga_keyboard_mut.v; want=FAIL
  fi
  iverilog -g2012 -o $B/tb_$mode.vvp $HERE/kbd_gate_tb.v $src 2>&1 | grep -v -i 'warning' || true
  out=$(vvp -n $B/tb_$mode.vvp | grep -E 'KBD_GATE (PASS|FAIL)')
  echo "$mode: $out (want $want)"
  echo "$out" | grep -q "$want" || rc=1
done
exit $rc
