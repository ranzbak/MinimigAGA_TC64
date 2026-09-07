#!/usr/bin/env bash
# Assemble the 68k test program for sim/ddr3_cpu.
# Same toolchain as sim/tg68vswf68ksim/asm/build_68k_test.sh.
#
# Extra arguments are passed straight to vasm, so the region sizes can be
# overridden for a quick run, e.g.
#   ./build_68k_test.sh -DPATBYTES=64 -DMISLINES=2 -DCNTN=8
#
# BIN=<path> puts the binary somewhere else; run.sh uses that so that two
# variants building at the same time cannot race on one output file.
#
# SRC=mmu_walk_test.asm builds the stage-B MMU walker program instead, which
# needs -m68040 for movec urp/srp/tc and pflusha.  run.sh --mmu does that.
set -e
cd "$(dirname "$0")"
BIN=${BIN:-ddr3_cpu_test.bin}
SRC=${SRC:-ddr3_cpu_test.asm}
CPUOPT=-m68020
if [ "$SRC" = "mmu_walk_test.asm" ]; then CPUOPT=-m68040; fi
vasmm68k_mot $CPUOPT -Fbin -L "${BIN%.bin}.lst" -o "$BIN" "$@" "$SRC"
ls -l "$BIN"
