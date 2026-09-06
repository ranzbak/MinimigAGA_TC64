#!/bin/sh
# Run the AP68040's own self-test suite against the RAM primitive this project
# actually builds with.
#
# lib/AP68040 is a pinned submodule and stays pristine; rtl/cpu040/dpram.v is
# compiled in place of rtl/primitives/dpram.v (see that file for why).  The
# submodule's tb/run_tests.sh hardcodes RTL=../rtl relative to itself, so the
# only way to substitute a file is to run it against a shadow copy of the tree
# -- which is what this does, in a scratch directory, leaving the submodule
# untouched.
#
# Needs iverilog and vasmm68k_mot (vbcc), both installed here.
#
#   tools/test_ap040.sh            run against rtl/cpu040/dpram.v (default)
#   tools/test_ap040.sh --stock    run against the submodule's own primitive,
#                                  to tell a core failure from an override one
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
SUB=$R/lib/AP68040
OVERRIDE=$R/rtl/cpu040/dpram.v

if [ ! -f "$SUB/tb/run_tests.sh" ]; then
	echo "lib/AP68040 is empty -- run: git submodule update --init lib/AP68040" >&2
	exit 1
fi

stock=0
if [ "${1:-}" = "--stock" ]; then stock=1; shift; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$SUB/rtl" "$SUB/tb" "$WORK/"

if [ $stock -eq 0 ]; then
	cp "$OVERRIDE" "$WORK/rtl/primitives/dpram.v"
	echo "== AP68040 self-tests with rtl/cpu040/dpram.v =="
else
	echo "== AP68040 self-tests with the submodule's stock dpram.v =="
fi

cd "$WORK/tb"
sh ./run_tests.sh "$@"
