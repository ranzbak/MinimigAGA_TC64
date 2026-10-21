#!/usr/bin/env python3
"""rdb.py <dir>: the expected RDB blocks and the hardfiles of hdd_test (Task 12).

The Amiga reads a hard disk's RigidDiskBlock and PartitionBlock as big-endian
longs (the 68000's order): that is what the 832 firmware sends from
FakeRDB() for a hardfile without an RDB (HDF_SYNTHRDB), and what the RISC-V
firmware must send.  The blocks are built here with struct.pack('>I') from
the field offsets of the AmigaOS include file devices/hardblocks.h (and
dos/filehandler.h for the DosEnvec), not from fw/ctrl_rv/hdd_internal.h:

  RigidDiskBlock      0 rdb_ID 'RDSK', 4 SummedLongs, 8 ChkSum, 12 HostID,
                      16 BlockBytes, 20 Flags, 24 BadBlockList,
                      28 PartitionList, 32 FileSysHeaderList, 36 DriveInit,
                      40 Reserved1[6], 64 Cylinders, 68 Sectors, 72 Heads,
                      76 Interleave, 80 Park, 84 Reserved2[3], 96 WritePreComp,
                      100 ReducedWrite, 104 StepRate, 108 Reserved3[5],
                      128 RDBBlocksLo, 132 RDBBlocksHi, 136 LoCylinder,
                      140 HiCylinder, 144 CylBlocks, 148 AutoParkSeconds,
                      152 HighRDSKBlock, 156 Reserved4, 160 DiskVendor[8],
                      168 DiskProduct[16], 184 DiskRevision[4],
                      188 ControllerVendor[8], 196 ControllerProduct[16],
                      212 ControllerRevision[4], 216 Reserved5[10] (-> 256)
  PartitionBlock      0 pb_ID 'PART', 4 SummedLongs, 8 ChkSum, 12 HostID,
                      16 Next, 20 Flags, 24 Reserved1[2], 32 DevFlags,
                      36 DriveName[32] (BSTR), 68 Reserved2[15],
                      128 Environment[20] (DosEnvec: TableSize, SizeBlock,
                      SecOrg, Surfaces, SectorPerBlock, BlocksPerTrack,
                      Reserved, PreAlloc, Interleave, LowCyl, HighCyl,
                      NumBuffers, BufMemType, MaxTransfer, Mask, BootPri,
                      DosType, Baud, Control, BootBlocks), 208 EReserved[12]
  Checksum            the sum of the first SummedLongs longs (ChkSum
                      included) is 0 mod 2^32 (hardblocks.h); computed here
                      over the finished block.

Field values: the ones the 832 firmware sends (the observable stream of its
FakeRDB: one RDSK at block 0 and one PART at block 1, everything else of
the first cylinder zeros), i.e. HostID 7, BlockBytes 512, Flags 0x12
(RDBF_LASTLUN | RDBF_DISKID), no bad block / filesystem / drive-init list
(0xffffffff), Reserved1 all 0xffffffff, PartitionList 1, Interleave 1,
Park = WritePreComp = ReducedWrite = Cylinders, StepRate 3, RDB blocks 0..1,
LoCylinder 1, HiCylinder Cylinders-1, CylBlocks Heads*Sectors,
HighRDSKBlock 1, DiskVendor "Do not " and DiskProduct "repartition!" (NUL
padded); PART: Next -1, Flags 1 (bootable), DriveName BSTR "DH0", DosEnvec
TableSize 16, SizeBlock 128, Surfaces = Heads, SectorPerBlock 1,
BlocksPerTrack = Sectors, Reserved 2, LowCyl 1, HighCyl Cylinders-1,
NumBuffers 30, MaxTransfer 0x1fffe, Mask 0x7ffffffe, DosType 'DOS\\1'.
Bytes 256..511 are zero.

Geometry of an RDB-less hardfile: WinUAE's rule (the 832 firmware and the
Minimig docs follow it): 32 sectors per track and the fewest heads (1..16)
with cylinders <= 65534 and heads*cylinders*32 == blocks, plus one cylinder
for the synthesised RDB; when no head count fits, the generic table: sectors
per track 63, 127, 255, heads 4..16, the first with cylinders <= 1023 (up to
1M blocks) or else < 16383, or < 32767 with heads >= 5, or <= 65534, plus
one cylinder.  The RDB occupies the first cylinder: the hardfile's block 0
is the disk's block heads*sectors (hdf offset = -heads*sectors).

Written into <dir>:
  rdbcases.h   RDB_CASE(name, size, cylinders, heads, sectors, offset) and
               the arrays rdb_rdsk_<name>[512], rdb_part_<name>[512];
               work_rdb_patched[512] (below)
  hdf/WORK.HDF  4 MB, an HDF with its own RDB: block 0 an RDSK with Flags
                0x17 and a valid checksum, a nonzero tail (bytes 256..511);
                the firmware reads it as plain HDF_FILE.  work_rdb_patched
                is that block as the 832 sends it from unit 0: Flags 0x12,
                the checksum valid again (computed here from scratch)
  hdf/SYNTH.HDF 2 MB, no RDB (HDF_SYNTHRDB)
  hdf/ODD.HDF   20001 blocks, no RDB: falls back to the generic geometry
Every other block n of hardfile k (WORK 1, SYNTH 2, ODD 3) is
'H', k, n >> 8, n & 255, then (k*53 + n*37 + i*11) & 255 for bytes i 4..511:
unique, so hdd_test finds each block on the card image by its header.
The 2 GB case has no file: hdd_test sets hdf[] for its size alone.
python3 -I, standard library only.
"""
import os
import struct
import sys

CASES = [  # name, size in bytes, file of the card (None: size only)
    ("small", 2 * 1024 * 1024, "SYNTH.HDF"),
    ("big", 2 * 1024 * 1024 * 1024, None),
    ("odd", 20001 * 512, "ODD.HDF"),
]
FILE_ID = {"WORK.HDF": 1, "SYNTH.HDF": 2, "ODD.HDF": 3}


def geometry_synth(blocks):
    """WinUAE's rule for an RDB-less hardfile (module docstring)."""
    cyllimit = 65534
    head = 1
    cyl = blocks // 32
    while head < 16 and (cyl > cyllimit or head * cyl * 32 != blocks):
        head += 1
        cyl = blocks // (32 * head)
    if head * cyl * 32 == blocks:
        return cyl + 1, head, 32
    for spt in (63, 127, 255):
        for head in range(4, 17):
            cyl = blocks // (head * spt)
            if blocks <= 1024 * 1024:
                if cyl <= 1023:
                    return cyl + 1, head, spt
            elif cyl < 16383 or (cyl < 32767 and head >= 5) or cyl <= cyllimit:
                return cyl + 1, head, spt
    raise SystemExit("rdb.py: no geometry for %d blocks" % blocks)


def put32(b, off, v):
    struct.pack_into(">I", b, off, v & 0xFFFFFFFF)


def checksum(b, summed=64):
    """ChkSum (offset 8) so that the first `summed` longs add up to 0."""
    put32(b, 8, 0)
    s = sum(struct.unpack_from(">%dI" % summed, b, 0)) & 0xFFFFFFFF
    put32(b, 8, -s)


def rdsk(cyl, heads, secs, flags=0x12, vendor=b"Do not ", product=b"repartition!"):
    b = bytearray(512)
    b[0:4] = b"RDSK"
    put32(b, 4, 64)
    put32(b, 12, 7)
    put32(b, 16, 512)
    put32(b, 20, flags)
    put32(b, 24, 0xFFFFFFFF)
    put32(b, 28, 1)
    put32(b, 32, 0xFFFFFFFF)
    put32(b, 36, 0xFFFFFFFF)
    for i in range(6):
        put32(b, 40 + 4 * i, 0xFFFFFFFF)
    put32(b, 64, cyl)
    put32(b, 68, secs)
    put32(b, 72, heads)
    put32(b, 76, 1)
    put32(b, 80, cyl)
    put32(b, 96, cyl)
    put32(b, 100, cyl)
    put32(b, 104, 3)
    put32(b, 128, 0)
    put32(b, 132, 1)
    put32(b, 136, 1)
    put32(b, 140, cyl - 1)
    put32(b, 144, heads * secs)
    put32(b, 148, 0)
    put32(b, 152, 1)
    b[160:160 + len(vendor)] = vendor
    b[168:168 + len(product)] = product
    checksum(b)
    return b


def part(cyl, heads, secs):
    b = bytearray(512)
    b[0:4] = b"PART"
    put32(b, 4, 64)
    put32(b, 12, 7)
    put32(b, 16, 0xFFFFFFFF)
    put32(b, 20, 1)
    put32(b, 32, 0)
    b[36:40] = b"\x03DH0"
    env = [16, 128, 0, heads, 1, secs, 2, 0, 0, 1, cyl - 1, 30, 0, 0x1FFFE,
           0x7FFFFFFE, 0, 0x444F5301, 0, 0, 0]
    for i, v in enumerate(env):
        put32(b, 128 + 4 * i, v)
    checksum(b)
    return b


def pattern_block(k, n):
    b = bytearray((k * 53 + n * 37 + i * 11) & 255 for i in range(512))
    b[0:4] = bytes((ord("H"), k, n >> 8, n & 255))
    return b


def carray(name, data):
    lines = ["static const unsigned char %s[512] = {" % name]
    for i in range(0, 512, 16):
        lines.append("\t" + ", ".join("0x%02x" % x for x in data[i:i + 16]) + ",")
    lines.append("};")
    return "\n".join(lines) + "\n"


def write_hdf(path, k, blocks, block0=None):
    with open(path, "wb") as f:
        for n in range(blocks):
            f.write(block0 if (n == 0 and block0 is not None) else pattern_block(k, n))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: rdb.py <dir>")
    d = sys.argv[1]
    os.makedirs(os.path.join(d, "hdf"), exist_ok=True)
    out = ["/* generated by gold/rdb.py: the RDB blocks the 832 sends (big-endian) */\n"]
    for name, size, fname in CASES:
        cyl, heads, secs = geometry_synth(size // 512)
        out.append("#define RDB_CASE_%s RDB_CASE(%s, %dUL, %d, %d, %d, %d)\n"
                   % (name.upper(), name, size, cyl, heads, secs, -heads * secs))
        out.append(carray("rdb_rdsk_" + name, rdsk(cyl, heads, secs)))
        out.append(carray("rdb_part_" + name, part(cyl, heads, secs)))
        if fname:
            write_hdf(os.path.join(d, "hdf", fname), FILE_ID[fname], size // 512)
    # WORK.HDF: its own RDB (the geometry the firmware gives a plain 4 MB HDF,
    # 32/4/63; any would do), Flags 0x17 (+ RDBF_LAST, RDBF_LASTTID), a tail
    own = rdsk(32, 4, 63, flags=0x17, vendor=b"HDTOOLS", product=b"own RDB block")
    for i in range(256, 512):
        own[i] = (i * 7 + 3) & 255
    write_hdf(os.path.join(d, "hdf", "WORK.HDF"), FILE_ID["WORK.HDF"], 8192, own)
    patched = bytearray(own)
    put32(patched, 20, 0x12)
    checksum(patched)
    out.append(carray("work_rdb_patched", patched))
    with open(os.path.join(d, "rdbcases.h"), "w") as f:
        f.write("".join(out))


if __name__ == "__main__":
    main()
