#!/usr/bin/env python3
"""mkhdf.py <dir>                    write SYNTH.HDF and RDB.HDF into <dir>
mkhdf.py --chs SYNTH.HDF|RDB.HDF   print the CHS OpenHardfile() will report

SYNTH.HDF  4 MB (8192 blocks), no RDB: the firmware synthesises one
           (HDF_FILE | HDF_SYNTHRDB).  GetHardfileGeometry(): 32 sectors per
           track, the fewest heads with heads*cyl*32 == blocks: 1 head, 256
           cylinders, plus one for the fake RDB = CHS 257.1.32: more than 255
           cylinders (the case that does not fit an 8-bit field), at most 8 MB.
RDB.HDF    2 MB (4096 blocks) with its own RDB at block 0: an RDSK block with
           rdb_Flags 0x17 (not 0x12, so the firmware's patch "rdb_ChkSum +=
           rdb_Flags - 0x12" has something to do) and a valid checksum, then a
           PART block at block 1.  Plain HDF_FILE: the firmware's generic
           geometry for 4096 blocks is 16.4.63 (the RDSK says the same).
Every other 512-byte block n of file id k (RDB.HDF 1, SYNTH.HDF 2, the ids of
fw/ctrl_rv/test/gold/rdb.py) is 'H', k, n>>8, n&255, then
(k*53 + n*37 + i*11) & 255 for byte i: the LBA and the file are in the block.
In SYNTH.HDF n is the file's block; the disk's LBA is n + 32 (the RDB cylinder
is in front: hdf offset = -heads*sectors).
python3 -I, standard library only.
"""
import os
import struct
import sys

FILES = {"RDB.HDF": (1, 4096), "SYNTH.HDF": (2, 8192)}


def put32(b, off, v):
    struct.pack_into(">I", b, off, v & 0xFFFFFFFF)


def checksum(b, summed=64):
    put32(b, 8, 0)
    put32(b, 8, -sum(struct.unpack_from(">%dI" % summed, b, 0)))


def geometry_synth(blocks):
    """hdd.c GetHardfileGeometry(), HDF_FILE | HDF_SYNTHRDB (the exact-fit branch)"""
    cyllimit = 65534
    head, cyl = 1, blocks // 32
    while head < 16 and (cyl > cyllimit or head * cyl * 32 != blocks):
        head += 1
        cyl = blocks // (32 * head)
    if head * cyl * 32 == blocks:
        return cyl + 1, head, 32
    raise SystemExit("mkhdf: no exact WinUAE geometry for %d blocks" % blocks)


def geometry_plain(blocks):
    """hdd.c GetHardfileGeometry(), HDF_FILE, a file up to 1M blocks"""
    for spt in (63, 127, 255):
        for head in range(4, 17):
            cyl = blocks // (head * spt)
            if cyl <= 1023:
                return cyl, head, spt
    raise SystemExit("mkhdf: no geometry for %d blocks" % blocks)


def chs(name):
    blocks = FILES[name][1]
    return geometry_synth(blocks) if name == "SYNTH.HDF" else geometry_plain(blocks)


def pattern(k, n):
    b = bytearray((k * 53 + n * 37 + i * 11) & 255 for i in range(512))
    b[0:4] = bytes((ord("H"), k, n >> 8, n & 255))
    return b


def rdsk(cyl, heads, secs):
    b = bytearray(512)
    b[0:4] = b"RDSK"
    put32(b, 4, 64)
    put32(b, 12, 7)
    put32(b, 16, 512)
    put32(b, 20, 0x17)          # RDBF_LAST | RDBF_LASTLUN | RDBF_LASTTID | RDBF_DISKID: not 0x12
    for off in (24, 32, 36) + tuple(40 + 4 * i for i in range(6)):
        put32(b, off, 0xFFFFFFFF)
    put32(b, 28, 1)
    put32(b, 64, cyl)
    put32(b, 68, secs)
    put32(b, 72, heads)
    put32(b, 76, 1)
    put32(b, 80, cyl)
    put32(b, 96, cyl)
    put32(b, 100, cyl)
    put32(b, 104, 3)
    put32(b, 132, 1)
    put32(b, 136, 1)
    put32(b, 140, cyl - 1)
    put32(b, 144, heads * secs)
    put32(b, 152, 1)
    b[160:167] = b"HDTOOLS"
    b[168:181] = b"L3 own RDB blk"[:13]
    checksum(b)
    return b


def part(cyl, heads, secs):
    b = bytearray(512)
    b[0:4] = b"PART"
    put32(b, 4, 64)
    put32(b, 12, 7)
    put32(b, 16, 0xFFFFFFFF)
    put32(b, 20, 1)
    b[36:40] = b"\x03DH1"
    env = [16, 128, 0, heads, 1, secs, 2, 0, 0, 1, cyl - 1, 30, 0, 0x1FFFE,
           0x7FFFFFFE, 0, 0x444F5301, 0, 0, 0]
    for i, v in enumerate(env):
        put32(b, 128 + 4 * i, v)
    checksum(b)
    return b


def write(path, name):
    k, blocks = FILES[name]
    rdb = name == "RDB.HDF"
    cyl, heads, secs = geometry_plain(blocks) if rdb else (0, 0, 0)
    with open(path, "wb") as f:
        for n in range(blocks):
            if rdb and n == 0:
                f.write(rdsk(cyl, heads, secs))
            elif rdb and n == 1:
                f.write(part(cyl, heads, secs))
            else:
                f.write(pattern(k, n))


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--chs" and a[1] in FILES:
        c, h, s = chs(a[1])
        print("%s: %d bytes, CHS %d.%d.%d, cylinders %d" % (a[1], FILES[a[1]][1] * 512, c, h, s, c))
    elif len(a) == 1 and not a[0].startswith("-"):
        os.makedirs(a[0], exist_ok=True)
        for name in sorted(FILES):
            write(os.path.join(a[0], name), name)
    else:
        sys.exit("usage: mkhdf.py <dir> | mkhdf.py --chs SYNTH.HDF|RDB.HDF")


if __name__ == "__main__":
    main()
