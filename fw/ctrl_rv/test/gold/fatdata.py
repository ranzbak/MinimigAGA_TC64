#!/usr/bin/env python3
"""fatdata.py <dir>: the file contents of the fat_test images (fatimg.sh).

Deterministic (a 32-bit xorshift per file, seeded by the name), so every run
builds the same images.  python3 -I, standard library only.

  HELLO.TXT   15 B   short 8.3 name, text
  A.BIN     8192 B   before the hole
  MIDDLE.BIN 40960 B deleted again: the hole that BIG.BIN is fragmented over
  C.BIN     8192 B   after the hole
  BIG.BIN  307300 B  300 KB + 100: not a whole number of sectors or clusters
  LONG.TXT   777 B   stored as "Long Name File.txt"
  DEEP.DAT  5000 B   stored as "Games Collection/Another Level/Deep File Name.dat"
  W3.BIN    1536 B   three sectors, written by fat_test (FileCreate/FileWrite)
"""
import os
import sys

FILES = [
    ("HELLO.TXT", None),
    ("A.BIN", 8192),
    ("MIDDLE.BIN", 40960),
    ("C.BIN", 8192),
    ("BIG.BIN", 300 * 1024 + 100),
    ("LONG.TXT", 777),
    ("DEEP.DAT", 5000),
    ("W3.BIN", 1536),
]


def stream(name, n):
    x = 0x9E3779B9
    for c in name.encode():
        x = ((x ^ c) * 0x01000193) & 0xFFFFFFFF
    out = bytearray()
    while len(out) < n:
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(x & 0xFF)
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fatdata.py <dir>")
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    for name, size in FILES:
        data = b"host test card\n" if size is None else stream(name, size)
        with open(os.path.join(d, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    main()
