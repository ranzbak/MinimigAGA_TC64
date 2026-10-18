#!/usr/bin/env python3
"""l3check.py: offline data checks of an L3 run directory (sim/l3/run.sh).

    python3 -I l3check.py kick <run>

kick: the 256 KB kickstart the firmware uploaded equals the card's KICK.ROM
byte for byte.  UploadKickstart (fw/ctrl_rv/config.c) sends a 0x40000-byte
ROM twice with SendFileV2 (fpga.c), to the Amiga addresses 0xf80000 and
0xfc0000 (the mirror); SendFileV2 writes Amiga address a at host address
(a & 0x7fffff) ^ 0x680000 (HOSTMAP_ADDR, hardware.h): 0x100000 and 0x140000.
The memory is <run>/sdram.bin, the SDRAM model's dump (tb_l3.v
+SDRAM_DUMP: file offset = host byte address, byte A+0 = the upper byte of
halfword A), the file <run>/card/content/KICK.ROM.

Prints one line, "PASS kick: ..." (exit 0) or "FAIL kick: ..." (exit 1);
exit 2 on a usage error.  Python 3 standard library only.
"""
import os
import sys

HOSTMAP_ADDR = 0x680000
KICK_SIZE = 0x40000
KICK_AMIGA = (0xF80000, 0xFC0000)


def host_addr(amiga):
    return (amiga & 0x7FFFFF) ^ HOSTMAP_ADDR


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b)) if len(a) != len(b) else -1


def kick(run):
    dump_path = os.path.join(run, "sdram.bin")
    rom_path = os.path.join(run, "card", "content", "KICK.ROM")
    for p in (dump_path, rom_path):
        if not os.path.isfile(p):
            print("FAIL kick: no %s" % p)
            return 1
    with open(dump_path, "rb") as f:
        mem = f.read()
    with open(rom_path, "rb") as f:
        rom = f.read()
    if len(rom) != KICK_SIZE:
        print("FAIL kick: %s is %d bytes, not 0x%x" % (rom_path, len(rom), KICK_SIZE))
        return 1
    bad = []
    for a in KICK_AMIGA:
        h = host_addr(a)
        got = mem[h:h + KICK_SIZE]
        k = first_diff(got, rom)
        if k >= 0:
            if k < len(got):
                bad.append("Amiga 0x%06x (host 0x%06x): differs from offset 0x%05x (%02x, want %02x)"
                           % (a, h, k, got[k], rom[k]))
            else:
                bad.append("Amiga 0x%06x (host 0x%06x): the dump ends at offset 0x%05x" % (a, h, k))
    if bad:
        print("FAIL kick: " + "; ".join(bad))
        return 1
    print("PASS kick: KICK.ROM (%d bytes) at Amiga 0x%06x and 0x%06x (host 0x%06x, 0x%06x)"
          % (KICK_SIZE, KICK_AMIGA[0], KICK_AMIGA[1], host_addr(KICK_AMIGA[0]), host_addr(KICK_AMIGA[1])))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "kick":
        return kick(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
