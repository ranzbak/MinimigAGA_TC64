#!/bin/sh
# mkprog.sh <prog.s> [<ref>]  -- assemble a pipe_asm program, run it on the
# reference core (default lib/AP68040) and write <prog>.exp next to it for
# tb_ap040_pipe_prog.v (halt = the `halt` label).  Review the .exp by hand.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)
S=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
REF=${2:-$R/lib/AP68040}
B=$HERE/build/mkprog; mkdir -p "$B"
n=$(basename "$S" .s)
( cd "$(dirname "$S")" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -L "$B/$n.lst" -o "$B/$n.bin" "$S" )
python3 "$HERE/bin2hex.py" "$B/$n.bin" "$B/$n.hex"
halt=$(sed -n 's/^halt EXPR([0-9]*=0x\([0-9a-f]*\)).*/\1/p' "$B/$n.lst")
RRTL=$REF/rtl
RSRC="$RRTL/ap040_tg68k_compat.v $RRTL/ap040_core.v $RRTL/ap040_bus16_adapter.v $RRTL/ap040_bus_timeout.v \
      $RRTL/ap040_regfile.v $RRTL/ap040_alu.v $RRTL/ap040_muldiv.v $RRTL/ap040_mmu.v $RRTL/ap040_cache.v \
      $RRTL/ap040_fpu.v $RRTL/ap040_walker_cdc.v $RRTL/primitives/dpram.v"
[ -f "$RRTL/ap040_fill_cdc.v" ] && RSRC="$RSRC $RRTL/ap040_fill_cdc.v"
DEF=""; grep -q bus_clkena_in "$RRTL/ap040_tg68k_compat.v" && DEF="-DREF_UPSTREAM"
[ -f "$B/ref.vvp" ] || iverilog -g2012 $DEF -I "$RRTL" -o "$B/ref.vvp" "$HERE/tb_ap040_ref_trace.v" $RSRC 2>/dev/null
vvp "$B/ref.vvp" +prog="$B/$n.hex" +trace="$B/$n.ref.txt" +cycles=${CYCLES:-8000} +halt_pc=$halt > "$B/$n.ref.log"
grep -q "halt_pc reached" "$B/$n.ref.log" || { echo "reference did not reach halt ($halt)"; cat "$B/$n.ref.log"; exit 1; }
python3 "$HERE/mkexp.py" "$S" "$B/$n.ref.txt" "$B/$n.hex" --halt "$halt" > "${S%.s}.exp"
echo "wrote ${S%.s}.exp (halt $halt)"
