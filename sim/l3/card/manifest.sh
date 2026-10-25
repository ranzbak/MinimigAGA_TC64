#!/bin/bash
# manifest.sh <build-dir> <firmware name>: the manifest text on stdout: name,
# size, sha256 of every generated file and every card image in <build-dir>
# (see the Makefile's `manifest`: stand-in firmware, so the lines do not move
# with a firmware build; the firmware's name is the Makefile's FW_FILE).
set -euo pipefail
d=$1 fw=$2
echo "# L3 cards manifest: name size sha256 (make -C sim/l3/card manifest)."
echo "# Images are built with stand-in firmware (gen/mkblob.py), files are the generator output."
cd "$d"
for f in content/KICK.ROM content/TEST.ADF content/SYNTH.HDF content/RDB.HDF \
         content/TEST.ISO content/TEST.CUE content/TEST.BIN content/DRIVESND.BIN \
         cfg_cue/MINMGAA.CFG cfg_cue/MINMGAR.CFG cfg_iso/MINMGAA.CFG cfg_iso/MINMGAR.CFG \
         "standin/$fw" \
         boot.img bootbecfg.img fdd.img hdd.img cd.img cd_iso.img cdhdd.img; do
    printf '%s %s %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
