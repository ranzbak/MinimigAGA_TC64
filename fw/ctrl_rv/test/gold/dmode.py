#!/usr/bin/env python3
"""dmode.py <lba>: the spi.txt trace of MMC_Read(lba, NULL) (direct mode) on
the card model of mock_hw.c with its defaults (NCR 1, token delay 4), over
the card image of mmc_test (byte i of sector n = (37 n + 11 i + (n >> 8))
mod 256).  The golden gold/dmode.txt of mmc_test, written from the SD SPI
protocol (independent of mmc.c and mock_hw.c), and the reference trace of
the direct-mode sequence for Phase 4 (L3 differential traces).

Frames (cs = the Enable value of the selected lines, 02 card, 42 card + DMode):
  02  flush 0xFF, CMD17 (0x51, lba big-endian, CRC7 << 1 | 1), R1 polled
      (NCR 0xFF, R1 00), 0xFF until the token: 4 x 0xFF, 0xFE
  42  EnableDMode + one SPI write: cfide clocks 4096 bits (512 bytes) with
      MOSI high while the FPGA takes the sector from MISO
  02  DisableDMode, the 2 CRC bytes (the model sends 00 00)
python3 -I, standard library only.
"""
import sys

NCR, TOKEN_DLY = 1, 4


def crc7(data):
    """CRC7 of the SD command (x^7 + x^3 + 1), MSB first; the command byte
    carries it in bits 7..1 and the end bit 1."""
    crc = 0
    for byte in data:
        for bit in range(7, -1, -1):
            fb = ((crc >> 6) ^ (byte >> bit)) & 1
            crc = (crc << 1) & 0x7F
            if fb:
                crc ^= 0x09
    return (crc << 1) | 1


assert crc7([0x40, 0, 0, 0, 0]) == 0x95          # CMD0, the spec's example
assert crc7([0x48, 0, 0, 0x01, 0xAA]) == 0x87    # CMD8 0x1AA


def sector(n):
    return [(37 * n + 11 * i + (n >> 8)) & 0xFF for i in range(512)]


def frame(cs, out, inp):
    return "%02x %s / %s" % (cs, " ".join("%02x" % b for b in out), " ".join("%02x" % b for b in inp))


def main():
    lba = int(sys.argv[1], 0)
    cmd = [0x51, (lba >> 24) & 255, (lba >> 16) & 255, (lba >> 8) & 255, lba & 255]
    out = [0xFF] + cmd + [crc7(cmd)]
    inp = [0xFF] * 7
    out += [0xFF] * (NCR + 1)                      # R1 polls
    inp += [0xFF] * NCR + [0x00]
    out += [0xFF] * (TOKEN_DLY + 1)                # data token wait
    inp += [0xFF] * TOKEN_DLY + [0xFE]
    print(frame(0x02, out, inp))
    print(frame(0x42, [0xFF] * 512, sector(lba)))
    print(frame(0x02, [0xFF, 0xFF], [0x00, 0x00]))


main()
