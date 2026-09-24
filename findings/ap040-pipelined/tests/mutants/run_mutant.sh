#!/bin/sh
# run_mutant.sh <rtl-file> <sed-expr> <bench>
#
# Applies ONE mutation to a scratch copy of the pipelined tree's rtl/, runs a
# bench against it, and reports
#     MUTANT CAUGHT     the bench failed (the test has teeth)       exit 0
#     MUTANT SURVIVED   the bench still passed                     exit 1
#     MUTATION DID NOT APPLY  the sed expression changed nothing    exit 2
#     MUTANT DOES NOT COMPILE the mutated tree fails to build       exit 3
#                             (not teeth: fix the mutation)
#
#   <rtl-file>  file name under rtl/ (e.g. ap040_pipe_l1.v)
#   <sed-expr>  a sed expression applied with sed -e (e.g. 's/wbuf_valid <= 1.b1;/wbuf_valid <= 1'"'"'b0;/')
#   <bench>     one of
#       pipe:<name>       tb/tb_ap040_pipe_<name>.v of the pipelined tree
#       red:<name>        tests/tb_ap040_pipe_red_<name>.v here (passes = ALL TESTS PASSED)
#       tb:<path.v>       any bench file; pass = "ALL TESTS PASSED" in its output
#       prog:<name>       program bench tb/pipe_asm/<name>.s + .exp through tb_ap040_pipe_prog.v
#       fpu:<name>        the program bench with HAS_FPU = 1 and tb/tb_fpu_stub.v attached
#       fpr:<name>        the same with the REAL rtl/compat/ap040_fpu.v attached
#       bus:<name>        the program bench through the memory port (BUS=1), 3 wait profiles
#       compat:<name>     the wrapper (rtl/compat, MMU and cache) on tb/build/<name>.hex of the
#                         pipelined tree (built by tb/run_pipe_tests.sh: t_integer,
#                         t_bitfield_mmu, t_mmu_m7), all three phases
#       diff:<prog>       differential leg tests/asm/<prog>.s via run_all.sh ONLY=<prog>
#                         (against lib/AP68040 unless AP040_REF is set)
#       cmd:<shell>       any command run with AP040_PIPE pointing at the mutant;
#                         pass = exit status 0
# Env: AP040_PIPE (default ../../../../AP68040-pipelined), MUTANT_KEEP=1 keeps the scratch.
set -u
[ $# -eq 3 ] || { sed -n '2,24p' "$0"; exit 2; }
F=$1; EXPR=$2; BENCH=$3
HERE=$(cd "$(dirname "$0")" && pwd)
TESTS=$(cd "$HERE/.." && pwd)
R=$(cd "$TESTS/../../.." && pwd)
AP040_PIPE=${AP040_PIPE:-$R/../AP68040-pipelined}
mkdir -p "$TESTS/build/mut"; SCR=$(mktemp -d "$TESTS/build/mut/m.XXXXXX")
trap '[ -n "${MUTANT_KEEP:-}" ] || rm -rf "$SCR"' EXIT
mkdir -p "$SCR/pipe"
cp -r "$AP040_PIPE/rtl" "$SCR/pipe/rtl"
[ -d "$AP040_PIPE/tb" ] && cp -r "$AP040_PIPE/tb" "$SCR/pipe/tb"
[ -f "$SCR/pipe/rtl/$F" ] || { echo "no rtl/$F in $AP040_PIPE"; exit 2; }
sed -e "$EXPR" "$SCR/pipe/rtl/$F" > "$SCR/mut.v"
if cmp -s "$SCR/mut.v" "$SCR/pipe/rtl/$F"; then
	echo "MUTATION DID NOT APPLY: $F  $EXPR"; exit 2
fi
diff "$SCR/pipe/rtl/$F" "$SCR/mut.v" | sed 's/^/  mutation: /' | head -8
cp "$SCR/mut.v" "$SCR/pipe/rtl/$F"
PSRC="$(ls "$SCR/pipe/rtl"/*.sv 2>/dev/null) $(ls "$SCR/pipe/rtl"/*.v)"
LOG=$SCR/bench.log
case "$BENCH" in
	pipe:*|red:*|tb:*)
		case "$BENCH" in
			pipe:*) TB=$SCR/pipe/tb/tb_ap040_pipe_${BENCH#pipe:}.v ;;
			red:*)  TB=$TESTS/tb_ap040_pipe_red_${BENCH#red:}.v ;;
			tb:*)   TB=${BENCH#tb:} ;;
		esac
		# a bench that drives the core's FPU port group needs the stub model
		STUB=""
		grep -q tb_fpu_stub "$TB" && STUB="$SCR/pipe/tb/tb_fpu_stub.v"
		if ! iverilog -g2012 -I "$SCR/pipe/rtl" -o "$SCR/b.vvp" "$TB" $STUB $PSRC > "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant" "$LOG" | head -3; exit 3
		fi
		timeout 600 vvp "$SCR/b.vvp" > "$LOG" 2>&1
		if grep -q "ALL TESTS PASSED" "$LOG"; then pass=1; else pass=0; fi ;;
	prog:*)
		n=${BENCH#prog:}
		( cd "$SCR/pipe/tb/pipe_asm" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$SCR/p.bin" "$n.s" ) > "$LOG" 2>&1
		python3 "$TESTS/bin2hex.py" "$SCR/p.bin" "$SCR/p.hex"
		if ! iverilog -g2012 -I "$SCR/pipe/rtl" -o "$SCR/b.vvp" "$SCR/pipe/tb/tb_ap040_pipe_prog.v" $PSRC >> "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant" "$LOG" | head -3; exit 3
		fi
		cyc=$(sed -n 's/^; diff:.*--cycles \([0-9]*\).*/\1/p' "$SCR/pipe/tb/pipe_asm/$n.s" | head -1)
		timeout 600 vvp "$SCR/b.vvp" +prog="$SCR/p.hex" +expect="$SCR/pipe/tb/pipe_asm/$n.exp" +cycles=${cyc:-20000} > "$LOG" 2>&1
		if grep -q "ALL TESTS PASSED" "$LOG"; then pass=1; else pass=0; fi ;;
	fpu:*)
		# fpu:<name> -- the program bench with the core built HAS_FPU = 1 and
		# tb/tb_fpu_stub.v answering its fp_* port group (plan M10.1)
		n=${BENCH#fpu:}
		( cd "$SCR/pipe/tb/pipe_asm" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$SCR/p.bin" "$n.s" ) > "$LOG" 2>&1
		python3 "$TESTS/bin2hex.py" "$SCR/p.bin" "$SCR/p.hex"
		if ! iverilog -g2012 -DFPU_STUB -I "$SCR/pipe/rtl" -o "$SCR/b.vvp" \
		     "$SCR/pipe/tb/tb_ap040_pipe_prog.v" "$SCR/pipe/tb/tb_fpu_stub.v" $PSRC >> "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant" "$LOG" | head -3; exit 3
		fi
		cyc=$(sed -n 's/^; diff:.*--cycles \([0-9]*\).*/\1/p' "$SCR/pipe/tb/pipe_asm/$n.s" | head -1)
		timeout 600 vvp "$SCR/b.vvp" +prog="$SCR/p.hex" +expect="$SCR/pipe/tb/pipe_asm/$n.exp" +cycles=${cyc:-20000} > "$LOG" 2>&1
		if grep -q "ALL TESTS PASSED" "$LOG"; then pass=1; else pass=0; fi ;;
	fpr:*)
		# fpr:<name> -- the program bench with the core built HAS_FPU = 1 and
		# the REAL rtl/compat/ap040_fpu.v on its port group, instantiated by
		# rtl/compat/ap040_fpu_tie.vh, the same include the wrapper uses
		# (plan M10.1 step 3)
		n=${BENCH#fpr:}
		( cd "$SCR/pipe/tb/pipe_asm" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$SCR/p.bin" "$n.s" ) > "$LOG" 2>&1
		python3 "$TESTS/bin2hex.py" "$SCR/p.bin" "$SCR/p.hex"
		if ! iverilog -g2012 -DFPU_REAL -I "$SCR/pipe/rtl" -I "$SCR/pipe/rtl/compat" -o "$SCR/b.vvp" \
		     "$SCR/pipe/tb/tb_ap040_pipe_prog.v" $PSRC "$SCR/pipe/rtl/compat/ap040_fpu.v" >> "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant" "$LOG" | head -3; exit 3
		fi
		cyc=$(sed -n 's/^; diff:.*--cycles \([0-9]*\).*/\1/p' "$SCR/pipe/tb/pipe_asm/$n.s" | head -1)
		timeout 900 vvp "$SCR/b.vvp" +prog="$SCR/p.hex" +expect="$SCR/pipe/tb/pipe_asm/$n.exp" +cycles=${cyc:-20000} > "$LOG" 2>&1
		if grep -q "ALL TESTS PASSED" "$LOG"; then pass=1; else pass=0; fi ;;
	bus:*)
		# bus:<name> -- program bench through the memory port (BUS=1), all three wait profiles
		n=${BENCH#bus:}
		( cd "$SCR/pipe/tb/pipe_asm" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$SCR/p.bin" "$n.s" ) > "$LOG" 2>&1
		python3 "$TESTS/bin2hex.py" "$SCR/p.bin" "$SCR/p.hex"
		if ! iverilog -g2012 -DBUS_MODE -I "$SCR/pipe/rtl" -o "$SCR/b.vvp" "$SCR/pipe/tb/tb_ap040_pipe_prog.v" $PSRC >> "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant" "$LOG" | head -3; exit 3
		fi
		cyc=$(sed -n 's/^; diff:.*--cycles \([0-9]*\).*/\1/p' "$SCR/pipe/tb/pipe_asm/$n.s" | head -1)
		cyc=$(( ${cyc:-20000} * 8 ))
		pass=1
		for p in 0 1 2; do
			timeout 900 vvp "$SCR/b.vvp" +prog="$SCR/p.hex" +expect="$SCR/pipe/tb/pipe_asm/$n.exp" +prof=$p +cycles=$cyc > "$LOG.$p" 2>&1
			grep -q "ALL TESTS PASSED" "$LOG.$p" || { pass=0; cat "$LOG.$p" >> "$LOG"; }
		done ;;
	compat:*)
		n=${BENCH#compat:}
		CSRC="$PSRC $(ls "$SCR/pipe/rtl/compat"/*.v) $SCR/pipe/rtl/compat/primitives/dpram.v"
		if ! iverilog -g2012 -I "$SCR/pipe/rtl" -I "$SCR/pipe/rtl/compat" -o "$SCR/b.vvp" "$SCR/pipe/tb/tb_ap040_pipe_compat.v" $CSRC > "$LOG" 2>&1; then
			echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -v "sorry: constant\|constant selects" "$LOG" | head -3; exit 3
		fi
		timeout 1800 vvp "$SCR/b.vvp" +prog="$AP040_PIPE/tb/build/$n.hex" > "$LOG" 2>&1
		if grep -q "ALL TESTS PASSED" "$LOG"; then pass=1; else pass=0; fi ;;
	diff:*)
		AP040_PIPE=$SCR/pipe AP040_REF=${AP040_REF:-$R/lib/AP68040} WORK=$SCR/work ONLY=${BENCH#diff:} \
			sh "$TESTS/run_all.sh" > "$LOG" 2>&1 && pass=1 || pass=0 ;;
	cmd:*)
		AP040_PIPE=$SCR/pipe sh -c "${BENCH#cmd:}" > "$LOG" 2>&1 && pass=1 || pass=0 ;;
	*) echo "unknown bench kind: $BENCH"; exit 2 ;;
esac
if grep -q "error:\|COMPILE-ERROR" "$LOG"; then
	echo "MUTANT DOES NOT COMPILE  $BENCH"; grep -m3 "error:" "$LOG"; exit 3
fi
if [ $pass -eq 1 ]; then
	echo "MUTANT SURVIVED  $F  $BENCH"; tail -5 "$LOG" | sed 's/^/  /'; exit 1
fi
echo "MUTANT CAUGHT  $F  $BENCH"
grep -m3 'FAIL\|DIVERGENCE\|differs\|MISMATCH' "$LOG" | sed 's/^/  /'
exit 0
