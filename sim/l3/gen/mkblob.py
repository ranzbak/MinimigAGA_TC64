#!/usr/bin/env python3
"""mkblob.py <file> <size> <tag>: a deterministic stand-in firmware file.

<size> bytes of a counter pattern that starts with <tag> (ASCII).  Used by
the manifest and by `make check` when no real firmware is given
(FWRV= / FW832=).  python3 -I, standard library only.
"""
import sys


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: mkblob.py <file> <size> <tag>")
    size, tag = int(sys.argv[2]), sys.argv[3].encode()
    b = bytearray((i * 7 + (i >> 8)) & 0xFF for i in range(size))
    b[:len(tag)] = tag
    with open(sys.argv[1], "wb") as f:
        f.write(b)


if __name__ == "__main__":
    main()
