#!/usr/bin/env bash
# TestTools.adf: IrqLat (+ IrqLatMatrix), ChipCoh, AdvPat and SerRx with their
# READMEs, for copying onto the board's HDF/SD card.  Rebuild the tools first
# (make in each directory).  xdftool comes from amitools (python3.10 here).
set -eu
cd "$(dirname "$0")"
xdf() { python3.10 -c "from amitools.tools.xdftool import main; import sys; sys.argv=['xdftool']+sys.argv[1:]; sys.exit(main())" "$@"; }
rm -f TestTools.adf
xdf TestTools.adf create + format TestTools ffs \
  + write IrqLat/IrqLat IrqLat + write IrqLat/IrqLatMatrix IrqLatMatrix \
  + write IrqLat/README.md IrqLat.readme \
  + write ChipCoh/ChipCoh ChipCoh + write ChipCoh/README.md ChipCoh.readme \
  + write AdvPat/AdvPat AdvPat + write AdvPat/README.md AdvPat.readme \
  + write SerRx/SerRx SerRx + write SerRx/README.md SerRx.readme
xdf TestTools.adf list
