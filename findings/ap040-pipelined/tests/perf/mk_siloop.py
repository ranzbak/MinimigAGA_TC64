#!/usr/bin/env python3
"""Extract SysInfo 4.4's SPEED loop (the routine at hunk 0 $3068, see
README.md) into a position-dependent binary block for the perf benches.

  python3 mk_siloop.py <SysInfo executable> <out.bin> <base>

The block is hunk 0 bytes [$30A4, $335C): the counted loop at $30A4 and every
subroutine it calls ($3100 MULS/MULU, $3120 DIVS/DIVU, $3144 shifts/rotates,
$3344 logic, $3154 the 8x unrolled move/add/ext/swap/exg/neg block with its
nested BSR/RTS).  It is to be loaded at <base> + $30A4, so every byte keeps
the cache-line alignment it has in SysInfo.

Three patches, all size-preserving:
  $30DE  cmp.l (a4),d2 ; bgt.b $30A4   (loop until the VBlank server's count
         reaches d2)  ->  cmp.l (a4),d7 ; blt.b $30A4  (loop until the
         iteration count d7 reaches the longword at (a4)); the memory read of
         (a4) stays
  $30E2  lea $4564(pc),a1 (the RemIntServer that follows)  ->  rts
  (the tail $30E4-$30FF, RemIntServer and the result, becomes dead code)
  8x     the absolute #$45C4 (a hunk-0 relocation: the 16-byte table the
         unrolled block reads with move.l d(a0),d0)  ->  <base> + $45C4
"""
import struct, sys

def hunks(path):
    d = open(path, 'rb').read(); p = 0
    def L():
        nonlocal p
        v = struct.unpack('>I', d[p:p+4])[0]; p += 4; return v
    assert L() == 0x3F3
    while L(): pass
    L(); first = L(); last = L()
    for _ in range(last - first + 1): L()
    out = []
    while p < len(d):
        t = L() & 0x3FFFFFFF
        if t in (0x3E9, 0x3EA):
            n = L(); out.append([bytearray(d[p:p+4*n]), []]); p += 4*n
        elif t == 0x3EB:
            n = L(); out.append([bytearray(4*n), []])
        elif t == 0x3EC:
            while True:
                c = L()
                if not c: break
                h = L()
                for _ in range(c): out[-1][1].append((L(), h))
        elif t == 0x3F2: pass
        else: raise SystemExit('unknown hunk %x' % t)
    return out

h0, rel = hunks(sys.argv[1])[0]
base = int(sys.argv[3], 0)
LO, HI = 0x30A4, 0x335C
assert h0[0x30DE:0x30E2] == bytes.fromhex('b4946ec2'), h0[0x30DE:0x30E2].hex()
h0[0x30DE:0x30E2] = bytes.fromhex('be946dc2')
assert h0[0x30E2:0x30E4] == bytes.fromhex('43fa')
h0[0x30E2:0x30E4] = bytes.fromhex('4e75')
n = 0
for off, h in rel:
    if LO <= off < HI and not (0x30E2 <= off < 0x3100):   # (dead code after the patched rts)
        assert h == 0 and struct.unpack('>I', h0[off:off+4])[0] == 0x45C4, (hex(off), h)
        h0[off:off+4] = struct.pack('>I', base + 0x45C4); n += 1
assert n == 8, n
open(sys.argv[2], 'wb').write(bytes(h0[LO:HI]))
open(sys.argv[2] + '.tab', 'wb').write(bytes(h0[0x45C4:0x45D4]))
print('block %d bytes at %08x, table at %08x, %d relocations' % (HI - LO, base + LO, base + 0x45C4, n))
