#!/usr/bin/env python3
"""mkadf.py <file>: TEST.ADF, 901,120 bytes (160 tracks x 11 sectors x 512).

Sector s (0..1759, the LBA) is tagged 'L' 'B' s>>8 s&0xff, then byte i
(4..511) is (s*37 + i*151 + ((i*s) >> 7)) & 0xff: the layout of
fw/ctrl/test/gold/mfm.py adf_sector(), so the L3 floppy data check
(Task 13) and the L2 gold files agree on what sector s holds.
python3 -I, standard library only.
"""
import sys

SECTORS = 1760


def sector(s):
    b = bytearray((s * 37 + i * 151 + ((i * s) >> 7)) & 0xFF for i in range(512))
    b[0:4] = bytes((0x4C, 0x42, s >> 8, s & 0xFF))
    return bytes(b)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkadf.py <file>")
    with open(sys.argv[1], "wb") as f:
        for s in range(SECTORS):
            f.write(sector(s))


if __name__ == "__main__":
    main()
