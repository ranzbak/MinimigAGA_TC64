#!/usr/bin/env python3
"""Disassemble the ROM (read by path, never copied) around an address.
usage: dis.py <rom> <hexaddr> [count]"""
import sys, capstone
ROMBASE = 0xF80000
def load(p):
    d = open(p, 'rb').read()
    return d * 2 if len(d) == 262144 else d
_md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN | capstone.CS_MODE_M68K_040)
def dis1(rom, a):
    off = (a - ROMBASE) & 0x7FFFF
    for i in _md.disasm(rom[off:off + 22], a, 1):
        return i.size, ("%s %s" % (i.mnemonic, i.op_str)).strip(), rom[off:off + i.size].hex()
    return 2, "dc.w $%s" % rom[off:off + 2].hex(), rom[off:off + 2].hex()
if __name__ == '__main__':
    rom = load(sys.argv[1]); a = int(sys.argv[2], 16); n = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    for _ in range(n):
        sz, t, h = dis1(rom, a)
        print("%08x  %-20s %s" % (a, h, t)); a += sz
