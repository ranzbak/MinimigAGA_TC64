#!/usr/bin/env python3
"""mkwrtrack.py <adf> <cylinder> <head> <out.hex> [--bad-header <sector>]

The MFM word stream the Amiga's write DMA sends to Paula when AmigaDOS
(trackdisk.device) writes one whole track, for the L3 scenario fdd_wr
(sim/l3 README "fdd_wr", bfm_floppy.v fdd_dma_write): every sector of the
track gets new contents, mfm.py's new_sector(lba) (tagged 'W' 'R' lba>>8
lba&0xff, then a pattern unlike the ADF's), so the written ADF can be told
from the original in every sector.

The stream (fw/ctrl_rv/test/gold/mfm.py's encoder, clocks "mfm": the real
MFM clock bits the Amiga's encoder writes):
  - a gap of MFM zero data (0xAAAA words) first, as trackdisk writes a
    track: the gap, then sectors 0..10 back to back (each one's "sectors
    until the gap" counts down to it: 11 - sector)
  - each sector as mfm.py's sector_cells(): 2 words of preamble (zero
    data), the sync 0x4489 0x4489, header info, label, header checksum,
    data checksum, data (odd bits, even bits)
  - the length: one Minimig track, fdd.c's TRACK_SIZE 12,668 bytes = 6,334
    words, the length fdd_rd reads (mfm.py MINIMIG_TRACK): the gap is
    6,334 - 11 x 544 = 350 words.  trackdisk.device's own gap length is
    not in this repository; the firmware's WriteTrack does not depend on
    it (FindSync skips everything up to a sync word)
--bad-header <s>: sector s's header checksum (its odd long) has one data
bit flipped, the clock bits recomputed: fdd.c GetHeader's "Bad checksum"
path (error 26).  Its header info, data checksum and data stay right.

<adf>: the image whose geometry is used (901,120 bytes; its contents are
not in the stream, every sector is new).  <out.hex>: one 16-bit word per
line, 4 hex digits (bfm_floppy reads it with $fscanf "%h"; xxd -r -p
reads it back).  A self-check decodes the stream again before it is
written.  python3 -I, standard library only.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GOLD = os.path.join(HERE, "..", "..", "..", "fw", "ctrl_rv", "test", "gold")
TRACK_WORDS = 6334            # fdd.c TRACK_SIZE / 2 (mfm.py MINIMIG_TRACK)
SYNC = 0x4489


def load_mfm():
    spec = importlib.util.spec_from_file_location("mfm", os.path.join(GOLD, "mfm.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mfm = load_mfm()
SECTOR_WORDS = mfm.SECTOR_BYTES // 2
GAP_WORDS = TRACK_WORDS - mfm.SECTORS * SECTOR_WORDS


def new_data(track, sector):
    """the data fdd_wr writes into a sector: mfm.py's new_sector(lba)"""
    return mfm.new_sector(track * mfm.SECTORS + sector)


def track_stream(track, bad=None):
    """the write DMA's bytes for ADF track `track` (cylinder * 2 + head)"""
    cells = mfm.zero_words(GAP_WORDS)
    for s in range(mfm.SECTORS):
        sc = mfm.sector_cells(track, s, new_data(track, s), SYNC)
        if s == bad:
            # cells 13 / 14: the header checksum, odd / even long (mfm.py
            # sector_cells: pre, sync, sync, info x2, label x8, hsum x2)
            kind, v, cls = sc[13]
            sc[13] = (kind, v ^ 0x00000001, cls)
        cells += sc
    stream = mfm.render(cells, "mfm")
    assert len(stream) == 2 * TRACK_WORDS
    # self-check: MFM run-length limits, and every sector decodes where it
    # was put (the bad one fails on its header checksum only)
    bits = bin(int.from_bytes(stream, "big"))[2:].zfill(len(stream) * 8)
    assert "11" not in bits and "0000" not in bits, "MFM run-length"
    for s in range(mfm.SECTORS):
        p = 2 * (GAP_WORDS + s * SECTOR_WORDS)
        b = stream[p:p + mfm.SECTOR_BYTES]
        if s == bad:
            try:
                mfm.decode_sector(b, SYNC)
            except ValueError as e:
                assert str(e) == "header checksum", e
            else:
                raise AssertionError("the bad-header sector decodes")
            continue
        assert mfm.decode_sector(b, SYNC) == (track, s, mfm.SECTORS - s, new_data(track, s))
    return stream


def main(argv):
    args = argv[1:]
    bad = None
    if "--bad-header" in args:
        k = args.index("--bad-header")
        if k + 1 >= len(args):
            sys.exit("--bad-header needs a sector number")
        bad = int(args[k + 1])
        del args[k:k + 2]
        if not 0 <= bad < mfm.SECTORS:
            sys.exit("--bad-header %d: a sector 0..%d" % (bad, mfm.SECTORS - 1))
    if len(args) != 4:
        sys.exit(__doc__)
    adf, cyl, head, out = args[0], int(args[1]), int(args[2]), args[3]
    if os.path.getsize(adf) != mfm.TRACKS * mfm.SECTORS * 512:
        sys.exit("%s: not a %d-byte ADF" % (adf, mfm.TRACKS * mfm.SECTORS * 512))
    if not (0 <= cyl < mfm.TRACKS // 2 and head in (0, 1)):
        sys.exit("cylinder 0..%d, head 0 or 1" % (mfm.TRACKS // 2 - 1))
    track = cyl * 2 + head
    stream = track_stream(track, bad)
    with open(out, "w") as f:
        for i in range(0, len(stream), 2):
            f.write("%02x%02x\n" % (stream[i], stream[i + 1]))
    print("mkwrtrack: track %d (cylinder %d head %d): %d words, gap %d, sectors 0..10 new (mfm.py new_sector)%s -> %s"
          % (track, cyl, head, TRACK_WORDS, GAP_WORDS,
             ", bad header checksum in sector %d" % bad if bad is not None else "", out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
