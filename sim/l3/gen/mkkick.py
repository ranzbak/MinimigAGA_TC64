#!/usr/bin/env python3
"""mkkick.py <file>: the synthetic 256 KB kickstart KICK.ROM of the L3 cards.

262,144 bytes (0x40000: the only thing the firmware checks of a kickstart).
Word i (0..65535) is 0x4B490000 | i, big-endian, so every 4-byte word is
unique and tells its own offset; the ASCII tag "L3 SYNTHETIC KICKSTART" sits
at 0x18 (overwriting words 6..11), so no byte pattern
PatchKick1xMemoryDetection looks for is present.  No real ROM content.
python3 -I, standard library only.
"""
import struct
import sys

SIZE = 0x40000
TAG = b"L3 SYNTHETIC KICKSTART"


def kick():
    b = bytearray(struct.pack(">65536I", *[0x4B490000 | i for i in range(SIZE // 4)]))
    b[0x18:0x18 + len(TAG)] = TAG
    assert len(b) == SIZE
    return bytes(b)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkkick.py <file>")
    with open(sys.argv[1], "wb") as f:
        f.write(kick())


if __name__ == "__main__":
    main()
