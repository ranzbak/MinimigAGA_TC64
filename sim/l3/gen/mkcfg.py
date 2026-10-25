#!/usr/bin/env python3
"""mkcfg.py <dir> [cue|iso]: the L3 config file in the previous firmware's format.

Writes <dir>/MINMGAA.CFG (212 bytes, big-endian: the file name and byte
order of the previous firmware, which the RV firmware still converts) and
<dir>/MINMGAA.check, the field table `cfgconv --check` must print for it (field by field, the packing and the
printing of fw/ctrl/test/gold/mkcfgbe.py are reused, not copied).  The
RISC-V file MINMGAR.CFG is `cfgconv --to-rv` of the first (the Makefile).

Fields: the defaults of mkcfgbe.defaults() (the previous firmware's), except

  kickstart.name        "KICK    "              (KICK.ROM)
  enable_ide            1                         (HDD and CD need IDE)
  floppy.drives         1, floppy.speed 0         (normal speed, CONFIG_FLOPPY1X)
  hardfile[0]           enabled 1 (HDF_FILE), "RDB     " (RDB.HDF: unit 0
                        plain HDF_FILE, so hdd.c patches its rdb_Flags)
  hardfile[1]           enabled 129 (HDF_FILE | HDF_SYNTHRDB), "SYNTH   "
                        (SYNTH.HDF, the firmware synthesises the RDB)
  secondaryhardfile[0]  enabled 7 (HDF_CDROM): IDE port 2 master, the ATAPI
                        CD; name "TEST    ", present 2 (CUE: TEST.CUE) or,
                        variant iso, present 1 (ISO: TEST.ISO)
python3 -I, standard library only.
"""
import importlib.util
import os
import sys

GOLD = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "..", "..", "fw", "ctrl", "test", "gold", "mkcfgbe.py")


def load_mkcfgbe():
    spec = importlib.util.spec_from_file_location("mkcfgbe", GOLD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fields(m, cd):
    v = m.defaults()
    v.update({"enable_ide": 1,
              "floppy.speed": 0, "floppy.drives": 1,
              "hardfile[0].enabled": 1, "hardfile[0].name": b"RDB     ",
              "hardfile[1].enabled": 129, "hardfile[1].name": b"SYNTH   ",
              "secondaryhardfile[0].enabled": 7,
              "secondaryhardfile[0].name": b"TEST    ",
              "secondaryhardfile[0].present": 2 if cd == "cue" else 1})
    return v


def check_text(m, v):
    out = ["order = BE"]
    for field, code in m.FIELDS:
        if field is None:
            continue
        x = v[field]
        out.append("%s = %s" % (field, m.show(x) if isinstance(x, bytes) else x))
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("cue", "iso")):
        sys.exit("usage: mkcfg.py <dir> [cue|iso]")
    m = load_mkcfgbe()
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
