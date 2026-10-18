#!/usr/bin/env python3
"""mkcfg.py <dir> [cue|iso]: the L3 config file as the 832 writes it.

Writes <dir>/MINMGAA.CFG (212 bytes, big-endian: the 832 firmware's own
file name and byte order) and <dir>/MINMGAA.check, the field table
`cfgconv --check` must print for it (field by field, the packing and the
printing of fw/ctrl_rv/test/gold/mkcfg832.py are reused, not copied).  The
RISC-V file MINMGAR.CFG is `cfgconv --to-rv` of the first (the Makefile).

Fields: the 832 firmware's defaults (mkcfg832.defaults()), except

  kickstart.name        "KICK    "              (KICK.ROM)
  enable_ide            1                         (HDD and CD need IDE)
  floppy.drives         1, floppy.speed 0         (normal speed, CONFIG_FLOPPY1X)
  hardfile[0]           enabled 129 (HDF_FILE | HDF_SYNTHRDB), "SYNTH   "
                        (SYNTH.HDF, the firmware synthesises the RDB)
  hardfile[1]           enabled 1 (HDF_FILE), "RDB     " (RDB.HDF)
  secondaryhardfile[0]  enabled 7 (HDF_CDROM): IDE port 2 master, the ATAPI
                        CD; name "TEST    ", present 2 (CUE: TEST.CUE) or,
                        variant iso, present 1 (ISO: TEST.ISO)
python3 -I, standard library only.
"""
import importlib.util
import os
import sys

GOLD = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "..", "..", "fw", "ctrl_rv", "test", "gold", "mkcfg832.py")


def load_mkcfg832():
    spec = importlib.util.spec_from_file_location("mkcfg832", GOLD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fields(m, cd):
    v = m.defaults()
    v.update({"enable_ide": 1,
              "floppy.speed": 0, "floppy.drives": 1,
              "hardfile[0].enabled": 129, "hardfile[0].name": b"SYNTH   ",
              "hardfile[1].enabled": 1, "hardfile[1].name": b"RDB     ",
              "secondaryhardfile[0].enabled": 7,
              "secondaryhardfile[0].name": b"TEST    ",
              "secondaryhardfile[0].present": 2 if cd == "cue" else 1})
    return v


def check_text(m, v):
    out = ["order = 832"]
    for field, code in m.FIELDS:
        if field is None:
            continue
        x = v[field]
        out.append("%s = %s" % (field, m.show(x) if isinstance(x, bytes) else x))
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("cue", "iso")):
        sys.exit("usage: mkcfg.py <dir> [cue|iso]")
    m = load_mkcfg832()
    v = fields(m, sys.argv[2] if len(sys.argv) == 3 else "cue")
    os.makedirs(sys.argv[1], exist_ok=True)
    data = m.pack(v)
    assert len(data) == 212
    with open(os.path.join(sys.argv[1], "MINMGAA.CFG"), "wb") as f:
        f.write(data)
    with open(os.path.join(sys.argv[1], "MINMGAA.check"), "w") as f:
        f.write(check_text(m, v))


if __name__ == "__main__":
    main()
