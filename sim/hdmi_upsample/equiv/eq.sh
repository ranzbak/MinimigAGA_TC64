#!/bin/bash
# eq.sh GOLDFILE GATEFILE [DEFINES]: formal equivalence of two pal_to_hd_upsample
# versions (Yosys equiv_make / equiv_simple / equiv_induct).  bram_tdp is a
# blackbox (bb.v) whose cells equiv_make merges, so its INPUTS are not
# compared: check the connections by eye.  The old file's empty bram pins get
# the new file's tie-offs (equiv_make asserts on a 0-bit vs 24-bit connection).
# CHP="-set NAME VALUE ..." sets parameters on both; signals named in
# blacklist.txt are not matched.  Work files go to $EQ_OUT (default
# ../build/equiv).
S=$(dirname "$(readlink -f "$0")")
O=${EQ_OUT:-$S/../build/equiv}
mkdir -p "$O"
python3 - "$1" "$2" "$O" <<'EOF'
import sys, re
g, t, O = sys.argv[1:4]
def load(f, name):
    s = open(f).read()
    s = re.sub(r'^module pal_to_hd_upsample\b', 'module ' + name, s, flags=re.M)
    if '.a_dout()' in s:
        s = s.replace('.a_dout(),', '.a_dout(w_douta_unused),')
        s = s.replace('.b_din(),', ".b_din(24'd0),")
        s = s.replace('.b_wr()', ".b_wr(1'b0)")
        s = s.replace('bram_tdp #(', 'wire [23:0] w_douta_unused;\nbram_tdp #(', 1)
    return s
open(O + '/gold.sv', 'w').write(load(g, 'gold'))
open(O + '/gate.sv', 'w').write(load(t, 'gate'))
EOF
D=${3:-}
cat > "$O/eq.ys" <<EOT
read_verilog -sv $D $S/bb.v
read_verilog -sv $D $O/gold.sv
read_verilog -sv $D $O/gate.sv
${CHP:+chparam $CHP gold gate}
hierarchy -check
proc
opt_clean
memory -nomap
memory_map
opt -fast
async2sync
equiv_make -blacklist $S/blacklist.txt gold gate equiv
hierarchy -top equiv
equiv_simple -seq 4
equiv_induct -seq 4
equiv_status
EOT
nice -n 19 yosys -q -l "$O/eq.log" -s "$O/eq.ys" > /dev/null 2>&1
echo "yosys exit $?"
sed -n '/Executing EQUIV_STATUS/,$p' "$O/eq.log" | head -40
