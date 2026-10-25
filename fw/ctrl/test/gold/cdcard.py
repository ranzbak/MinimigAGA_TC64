#!/usr/bin/env python3
"""cdcard.py <dir>: the files of cdpath_test's card (findings/sdcard-engine Task 11b).

  TEST.ISO    ISO_SECTORS 2048-byte sectors; byte p of the file is iso_byte(p)
              below (the same formula is in cdpath_test.c): the 512-byte
              sector number in its first four bytes (big-endian), then a mix
              of that number and the offset, so every 512-byte quarter of a
              CD sector differs (a quarter read from a wrong card sector, or
              in a wrong order, is seen)
  DISC.CUE    TEST.ISO as track 1 (MODE1/2048), TRACK2.WAV as track 2 (AUDIO,
              a 2 s PREGAP)
  TRACK2.WAV  RIFF / PCM 44100 Hz, 2 channels, 16 bit, WAV_SECTORS of 2352
              bytes after the 44-byte header
  FILL1.BIN   3 clusters of 4 KB, FILL2.BIN 1 cluster: cdcard.sh copies both,
              deletes FILL1.BIN and then copies TEST.ISO, which so takes
              FILL1's 3 clusters first and goes on after FILL2's: its chain
              has a gap after the file's 24th 512-byte sector (CD sector 6)
"""
import os
import struct
import sys

ISO_SECTORS = 300
WAV_SECTORS = 400


def iso_byte(p):
    s, i = p >> 9, p & 511
    if i < 4:
        return (s >> (24 - 8 * i)) & 0xFF
    return (s * 31 + i * 7 + (i >> 8) * 101 + 0x55) & 0xFF


def wav_bytes():
    data = bytearray(WAV_SECTORS * 2352)
    for k in range(len(data)):
        data[k] = (k * 5 + (k >> 9)) & 0xFF
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + \
        struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16) + \
        b"data" + struct.pack("<I", len(data))
    return hdr + bytes(data)


CUE = (
    'FILE "TEST.ISO" BINARY\r\n'
    "  TRACK 01 MODE1/2048\r\n"
    "    INDEX 01 00:00:00\r\n"
    'FILE "TRACK2.WAV" WAVE\r\n'
    "  TRACK 02 AUDIO\r\n"
    "    PREGAP 00:02:00\r\n"
    "    INDEX 01 00:00:00\r\n"
)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: cdcard.py <dir>")
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    iso = bytes(iso_byte(p) for p in range(ISO_SECTORS * 2048))
    files = {
        "TEST.ISO": iso,
        "DISC.CUE": CUE.encode(),
        "TRACK2.WAV": wav_bytes(),
        "FILL1.BIN": bytes(12288),
        "FILL2.BIN": bytes(4096),
    }
    for name, b in files.items():
        with open(os.path.join(d, name), "wb") as f:
            f.write(b)


if __name__ == "__main__":
    main()
