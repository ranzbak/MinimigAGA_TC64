#!/usr/bin/env python3
"""mfm.py <outdir>: an Amiga MFM track encoder, the reference of fdd_test.

Written from the Amiga floppy track format (AmigaDOS / trackdisk.device
sector layout, as in the Amiga Hardware Reference Manual's disk chapter and
the ADF format notes), not from fdd.c.  The spec facts it uses:

  * A double-density track holds 11 sectors of 512 data bytes.  An ADF image
    is the 160 tracks in order, track = cylinder * 2 + side (head), each 11
    sectors: track t, sector s is at byte offset (t * 11 + s) * 512.
  * A sector on the disk is 1088 bytes (544 MFM words):
      2 words   0xAAAA 0xAAAA     MFM of two zero data bytes (preamble)
      2 words   sync 0x4489 0x4489 (an MFM pattern no data byte encodes)
      1 long    header info, odd bits    info = 0xFF (format), track,
      1 long    header info, even bits          sector, sectors until the gap
                                                (11 - sector), one byte each
      4 longs   sector label, odd bits   (16 bytes, zero for AmigaDOS)
      4 longs   sector label, even bits
      1 long    header checksum, odd bits    checksum: XOR of the 10 MFM
      1 long    header checksum, even bits   longs info..label, AND 0x55555555
      1 long    data checksum, odd bits      checksum: XOR of the 256 MFM
      1 long    data checksum, even bits     data longs, AND 0x55555555
      128 longs data, odd bits  of the 128 big-endian data longs
      128 longs data, even bits of the 128 big-endian data longs
    odd(v) = (v >> 1) & 0x55555555, even(v) = v & 0x55555555: every MFM long
    carries 16 data bits on the bit positions of mask 0x55555555 and 16
    clock bits on the positions of 0xAAAAAAAA.
  * The sectors follow each other without a gap; the track gap comes after
    the last sector written (the "sectors until the gap" count reaches 1 on
    sector 10 of a track written from sector 0).
  * MFM clock rule (a real disk, i.e. what the Amiga's write DMA sends):
    a clock bit is 1 when the data bits on both sides of it are 0, else 0;
    the sync word is written as it is (its missing clock is the point).
    The Amiga's decoder (trackdisk, and fdd.c's GetHeader/GetData) masks
    every MFM long with 0x55555555: clock bits never reach the data.

Two choices that are the Minimig's, not the Amiga's, so they are parameters
here and named as such:

  * MINIMIG_TRACK = 12668 bytes: the length of the track the Minimig
    firmware feeds to Paula (11 x 1088 bytes of sectors, then the gap filled
    with 0xAA, MFM zero data, up to this length).
  * The clock bits of the Minimig's read stream: the firmware does not
    compute MFM clocks (the Amiga strips them), so its stream carries clock
    bit 1 everywhere except in the two header info longs, which go out with
    clock bits 0 (data bits only).  clocks="minimig" renders this,
    clocks="mfm" renders the real clock rule (the write stream the Amiga's
    DMA produces).  The data bits are the format's either way, and every
    rendered sector is decoded again by decode_sector() below with the
    format's rules (sync, odd/even, both checksums over the rendered MFM
    longs AND 0x55555555): a self-check of the encoder.

Outputs (in <outdir>):
  disk.adf              the ADF of the test, 160 tracks: sector n (n = 0..1759,
                        the LBA) is tagged 'L' 'B' n>>8 n&0xff, then
                        (n * 37 + i * 151 + ((i * n) >> 7)) & 0xff for byte i
  read_4489.bin         the read stream of every track 0..159 (12668 bytes
                        each, in track order): sectors 0..10, gap; sync 0x4489,
                        clocks "minimig"
  read_4891_t000.bin    track 0 with the sync 0x4891 (a non-standard sync the
                        firmware passes through: Prince of Persia's)
  track_c00_s0.hex      track 0 (cylinder 0 side 0) and track 159 (cylinder
  track_c79_s1.hex      79 side 1) of read_4489.bin as hex, 32 bytes per
                        line (xxd -r -p reads it back): committed as
                        gold/mfm_c00_s0.hex and gold/mfm_c79_s1.hex for
                        Phase 4's L3 data check
  write_<case>.bin      the MFM word stream the Amiga's write DMA sends for
                        the case (big-endian words, clocks "mfm"): a gap of
                        WRITE_GAP_HEAD zero data words, the case's sectors in
                        its order, WRITE_GAP_TAIL zero data words
  write_<case>.adf      the ADF after that track write: disk.adf with the
                        case's sectors replaced by their data
  fddcases.h            the write cases for fdd_test.c
python3 -I, standard library only.
"""
import os
import sys

SECTORS = 11
TRACKS = 160
SECTOR_BYTES = 1088
MINIMIG_TRACK = 12668
WRITE_GAP_HEAD = 16     # words
WRITE_GAP_TAIL = 8
M = 0x55555555

# the write cases: (name, track, sector order, sectors that get new data)
# full159  the whole of track 159 (cylinder 79 side 1) from sector 0; new
#          data in sectors 0, 4 and 10, the others written with what the
#          ADF holds already
# subset1  three sectors of track 1 (cylinder 0 side 1), out of order: 5, 2, 9
#          (2 after 5: WriteTrack goes back to the start of the track)
# rot80    the whole of track 80 (cylinder 40 side 0) starting at sector 6
#          (the write wraps from 10 to 0); new data in sectors 7 and 0
WRITE_CASES = [
    ("full159", 159, list(range(11)), [0, 4, 10]),
    ("subset1", 1, [5, 2, 9], [5, 2, 9]),
    ("rot80", 80, [6, 7, 8, 9, 10, 0, 1, 2, 3, 4, 5], [7, 0]),
]


def odd(v):
    return (v >> 1) & M


def even(v):
    return v & M


def adf_sector(n):
    b = bytearray((n * 37 + i * 151 + ((i * n) >> 7)) & 0xFF for i in range(512))
    b[0:4] = bytes((0x4C, 0x42, n >> 8, n & 0xFF))      # 'L' 'B' LBA
    return bytes(b)


def new_sector(n):
    """the data a write case puts into sector n (LBA)"""
    b = bytearray((0xC3 ^ (i * 89 + n * 11 + (i >> 6))) & 0xFF for i in range(512))
    b[0:4] = bytes((0x57, 0x52, n >> 8, n & 0xFF))      # 'W' 'R' LBA
    return bytes(b)


def be_longs(data):
    return [int.from_bytes(data[i:i + 4], "big") for i in range(0, len(data), 4)]


def sector_cells(track, sector, data, sync):
    """one sector as a list of cells: ("raw", 16-bit word) is sent as it is,
    ("data", 32-bit long, cls) holds data bits only (mask 0x55555555); cls
    "info" marks the header info longs (clock class of the Minimig stream)"""
    info = (0xFF << 24) | (track << 16) | (sector << 8) | (SECTORS - sector)
    label = [0, 0, 0, 0]
    hdr = [odd(info), even(info)] + [odd(x) for x in label] + [even(x) for x in label]
    hsum = 0
    for x in hdr:
        hsum ^= x
    hsum &= M
    d = be_longs(data)
    dat = [odd(x) for x in d] + [even(x) for x in d]
    dsum = 0
    for x in dat:
        dsum ^= x
    dsum &= M
    cells = [("data", 0, "pre")]                         # 0xAAAA 0xAAAA
    cells += [("raw", sync), ("raw", sync)]
    cells += [("data", hdr[0], "info"), ("data", hdr[1], "info")]
    cells += [("data", x, "") for x in hdr[2:]]
    cells += [("data", odd(hsum), ""), ("data", even(hsum), "")]
    cells += [("data", odd(dsum), ""), ("data", even(dsum), "")]
    cells += [("data", x, "") for x in dat]
    return cells


def zero_words(n):
    """n words of zero data (gap): as data longs, plus a half long"""
    cells = [("data", 0, "gap")] * (n // 2)
    if n % 2:
        cells.append(("half", 0, "gap"))
    return cells


def render(cells, clocks):
    """cells -> bytes.  clocks "minimig": clock bits 1, 0 in the info longs;
    "mfm": the MFM clock rule over the bit stream"""
    out = bytearray()
    prev = 0                                             # the last data bit sent
    for c in cells:
        if c[0] == "raw":
            out += c[1].to_bytes(2, "big")
            prev = c[1] & 1
            continue
        nbits = 32 if c[0] == "data" else 16
        v = c[1]
        if clocks == "minimig":
            w = v if c[2] == "info" else v | 0xAAAAAAAA
            w &= (1 << nbits) - 1
        else:
            w = 0
            for p in range(nbits - 2, -1, -2):           # data bit positions, MSB first
                bit = (v >> p) & 1
                clk = 1 if (prev == 0 and bit == 0) else 0
                w |= (clk << (p + 1)) | (bit << p)
                prev = bit
        out += w.to_bytes(nbits // 8, "big")
        if clocks == "minimig":
            prev = w & 1
    return bytes(out)


def decode_sector(b, sync):
    """the format's decoder: (track, sector, sectors to gap, data) of the
    1088 bytes b, or an exception"""
    w = [int.from_bytes(b[i:i + 2], "big") for i in range(0, 8, 2)]
    if w[2] != sync or w[3] != sync:
        raise ValueError("no sync")
    L = be_longs(b[8:])
    info = ((L[0] & M) << 1) | (L[1] & M)
    hsum = 0
    for x in L[0:10]:
        hsum ^= x
    if (hsum & M) != (((L[10] & M) << 1) | (L[11] & M)):
        raise ValueError("header checksum")
    dsum = 0
    for x in L[14:270]:
        dsum ^= x
    if (dsum & M) != (((L[12] & M) << 1) | (L[13] & M)):
        raise ValueError("data checksum")
    if info >> 24 != 0xFF:
        raise ValueError("format byte")
    data = b"".join((((L[14 + i] & M) << 1) | (L[142 + i] & M)).to_bytes(4, "big") for i in range(128))
    return (info >> 16) & 0xFF, (info >> 8) & 0xFF, info & 0xFF, data


def sector_bytes(track, sector, data, sync, clocks):
    b = render(sector_cells(track, sector, data, sync), clocks)
    assert len(b) == SECTOR_BYTES
    t, s, g, d = decode_sector(b, sync)
    assert (t, s, g, d) == (track, sector, SECTORS - sector, data), "self-check"
    return b


def read_track(adf, track, sync):
    """the Minimig's read stream of a track: sectors 0..10, then the gap"""
    out = bytearray()
    for s in range(SECTORS):
        n = track * SECTORS + s
        out += sector_bytes(track, s, adf[n * 512:(n + 1) * 512], sync, "minimig")
    out += b"\xAA" * (MINIMIG_TRACK - len(out))
    assert len(out) == MINIMIG_TRACK
    return bytes(out)


def write_stream(adf, track, order, new):
    """the Amiga's write DMA stream (clocks "mfm") and the ADF afterwards"""
    after = bytearray(adf)
    cells = zero_words(WRITE_GAP_HEAD)
    for s in order:
        n = track * SECTORS + s
        data = new_sector(n) if s in new else adf[n * 512:(n + 1) * 512]
        after[n * 512:(n + 1) * 512] = data
        cells += sector_cells(track, s, data, 0x4489)
    cells += zero_words(WRITE_GAP_TAIL)
    stream = render(cells, "mfm")
    # self-check of the clock rule: MFM's run-length limits (never two 1 bits
    # in a row, never four 0 bits in a row; the sync 0x4489 keeps both), and
    # the sectors decode where they were put
    bits = bin(int.from_bytes(stream, "big"))[2:].zfill(len(stream) * 8)
    assert "11" not in bits and "0000" not in bits, "MFM run-length"
    pos = WRITE_GAP_HEAD * 2
    for s in order:
        n = track * SECTORS + s
        t, sec, g, d = decode_sector(stream[pos:pos + SECTOR_BYTES], 0x4489)
        assert (t, sec, d) == (track, s, bytes(after[n * 512:(n + 1) * 512]))
        pos += SECTOR_BYTES
    return stream, bytes(after)


def hexlines(b):
    return "".join(b[i:i + 32].hex() + "\n" for i in range(0, len(b), 32))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mfm.py <outdir>")
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)

    def put(name, data, mode="wb"):
        with open(os.path.join(d, name), mode) as f:
            f.write(data)

    adf = b"".join(adf_sector(n) for n in range(TRACKS * SECTORS))
    assert len(adf) == 901120
    put("disk.adf", adf)
    tracks = [read_track(adf, t, 0x4489) for t in range(TRACKS)]
    put("read_4489.bin", b"".join(tracks))
    put("read_4891_t000.bin", read_track(adf, 0, 0x4891))
    put("track_c00_s0.hex", hexlines(tracks[0]), "w")
    put("track_c79_s1.hex", hexlines(tracks[79 * 2 + 1]), "w")

    h = ["/* fddcases.h: written by gold/mfm.py, the write cases of fdd_test */",
         "#define MFM_TRACK_BYTES %d" % MINIMIG_TRACK,
         "#define MFM_SECTOR_BYTES %d" % SECTOR_BYTES,
         "#define MFM_TRACKS %d" % TRACKS,
         "#define MFM_WRITE_GAP_HEAD %d\t/* words before the first sector of a write stream */" % WRITE_GAP_HEAD,
         "static const struct fdd_wcase {",
         "\tconst char *name;\t/* write_<name>.bin, write_<name>.adf */",
         "\tint track;",
         "\tint nsec;",
         "\tint order[11];\t\t/* the sectors in the stream, in order */",
         "\tint nnew;",
         "\tint fresh[11];\t\t/* the sectors whose data is new */",
         "} fdd_wcases[] = {"]
    for name, track, order, new in WRITE_CASES:
        stream, after = write_stream(adf, track, order, new)
        put("write_%s.bin" % name, stream)
        put("write_%s.adf" % name, after)
        h.append("\t{ \"%s\", %d, %d, { %s }, %d, { %s } }," % (
            name, track, len(order), ", ".join(map(str, order)), len(new), ", ".join(map(str, new))))
    h.append("};")
    put("fddcases.h", "\n".join(h) + "\n", "w")


if __name__ == "__main__":
    main()
