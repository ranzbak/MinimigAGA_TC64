#!/bin/bash
# Tooth (e), a PATCH for sim/l3/run.sh: the run copy of gayle.v built with
# GAYLE_MUT_SHARED (sim/gayle's mutant: one register file for both ports,
# the port select ignored).
# Usage (run.sh): PATCH=sim/l3/teeth/gayle_shared.sh; args <run>/src <root>
set -eu
src=$1
grep -q '^`ifdef GAYLE_MUT_SHARED$' "$src/gayle.v"
sed -i '1i `define GAYLE_MUT_SHARED' "$src/gayle.v"
echo "gayle_shared: GAYLE_MUT_SHARED defined in the run copy of gayle.v"
