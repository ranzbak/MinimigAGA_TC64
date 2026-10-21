#!/bin/bash
# Tooth (a), a PATCH for sim/l3/run.sh: the run copy of paula_floppy.v with
# commit 202e077 reverted (a direct-mode word qualified by the live direct
# chip select again, not by rx_direct latched with the word: plan 7.1 item 3).
# Usage (run.sh): PATCH=sim/l3/teeth/paula_202e077.sh; args <run>/src <root>
set -eu
src=$1 root=$2
git -C "$root" show 202e077 -- rtl/minimig/paula_floppy.v | patch -R -p3 -d "$src" --no-backup-if-mismatch
grep -q '(scs2 && rx_flag) ? 1' "$src/paula_floppy.v"
! grep -q 'rx_direct' "$src/paula_floppy.v"
echo "paula_202e077: 202e077 reverted in the run copy of paula_floppy.v"
