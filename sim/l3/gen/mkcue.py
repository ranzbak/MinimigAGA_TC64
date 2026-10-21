#!/usr/bin/env python3
"""mkcue.py <dir>: TEST.BIN and TEST.CUE, a three-track disc.

TEST.BIN  one raw file of 2352-byte sectors, 364 of them (856,128 bytes):
  sectors 0..63     track 1, MODE1/2352 data: 12 sync bytes, header (MSF of
                    LBA+150 in BCD, mode 1), 2048 data bytes tagged
                    'L' 'B' lba>>8 lba&0xff then (lba*37 + i*151) & 0xff,
                    288 EDC/ECC bytes left zero (nothing here checks them)
  sectors 64..213   track 2, AUDIO, 2 s = 150 sectors = 88,200 frames
  sectors 214..363  track 3, AUDIO, 2 s
  Audio frame f counts from 0 at the first frame of track 2 through track 3
  (0..176,399): left sample f & 0xFFFF, right sample ~f & 0xFFFF, 16-bit
  little-endian, 588 frames to a sector.
TEST.CUE  as fw/ctrl_rv/cue.c parses it: one FILE, track 2 with the standard
  2 s PREGAP (silent, not in the file), so the disc map is
    LBA 0..63 track 1 | 64..213 pregap of track 2 | 214..363 track 2 |
    364..513 track 3 | lead-out 514
python3 -I, standard library only.
"""
import os
import struct
import sys

DATA_SECTORS = 64
AUDIO_SECTORS = 150          # 2 s
FRAMES = 588

CUE = """FILE "TEST.BIN" BINARY
  TRACK 01 MODE1/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    PREGAP 00:02:00
    INDEX 01 00:00:64
  TRACK 03 AUDIO
    INDEX 01 00:02:64
"""


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def data_sector(lba):
    m, rest = divmod(lba + 150, 75 * 60)
    s, f = divmod(rest, 75)
    user = bytearray((lba * 37 + i * 151) & 0xFF for i in range(2048))
    user[0:4] = bytes((0x4C, 0x42, lba >> 8, lba & 0xFF))
    return (b"\x00" + b"\xff" * 10 + b"\x00" + bytes((bcd(m), bcd(s), bcd(f), 1))
            + bytes(user) + bytes(288))


def audio(first_frame, sectors):
    out = bytearray()
    for f in range(first_frame, first_frame + sectors * FRAMES):
        out += struct.pack("<HH", f & 0xFFFF, ~f & 0xFFFF)
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkcue.py <dir>")
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "TEST.BIN"), "wb") as f:
        for lba in range(DATA_SECTORS):
            f.write(data_sector(lba))
        f.write(audio(0, 2 * AUDIO_SECTORS))
    with open(os.path.join(d, "TEST.CUE"), "w", newline="\n") as f:
        f.write(CUE)


if __name__ == "__main__":
    main()
