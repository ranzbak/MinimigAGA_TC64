#!/bin/bash
# manifest.sh <build-dir>: the manifest text on stdout: name, size, sha256 of
# every generated file and every card image in <build-dir> (see the Makefile's
# `manifest`: stand-in firmware, so the lines do not move with a firmware build).
set -euo pipefail
d=$1
echo "# L3 cards manifest: name size sha256 (make -C sim/l3/card manifest)."
echo "# Images are built with stand-in firmware (gen/mkblob.py), files are the generator output."
cd "$d"
for f in content/KICK.ROM content/TEST.ADF content/SYNTH.HDF content/RDB.HDF \
         content/TEST.ISO content/TEST.CUE content/TEST.BIN content/DRIVESND.BIN \
         cfg_cue/MINMGAA.CFG cfg_cue/MINMGAR.CFG cfg_iso/MINMGAA.CFG cfg_iso/MINMGAR.CFG \
         standin/RV32OSDA.BIN standin/832OSDAD.BIN \
         boot.img boot832cfg.img fdd.img hdd.img cd.img cd_iso.img cdhdd.img; do
    printf '%s %s %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
