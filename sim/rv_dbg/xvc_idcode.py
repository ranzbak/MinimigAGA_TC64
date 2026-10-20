#!/usr/bin/env python3
"""XVC 1.0 loopback client for the debug bench harness (+xvc=<port>).

    python3 -I sim/rv_dbg/xvc_idcode.py <host> <port> <expected IDCODE>

Talks to the harness the way Vivado hw_server would (getinfo, settck,
shift; vectors LSB first per byte) and checks, on the DEBUG = 1 bench's
7-series TAP:
  1. getinfo answers "xvcServer_v1.0:<n>", settck echoes the period;
  2. Test-Logic-Reset, then a 32-bit DR scan reads the IDCODE (the IR is
     IDCODE after reset);
  3. an IR scan of IDCODE (0x09) returns the IR capture value 0x11 (LSBs 01)
     and the next DR scan the IDCODE again;
  4. IR = BYPASS (0x3F): a 16-bit DR scan returns TDI delayed by one bit.
Prints one line per check; exit 0 when all pass, 1 otherwise.
"""
import socket
import struct
import sys


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("server closed")
        b += c
    return b


class Xvc:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=120)

    def getinfo(self):
        self.s.sendall(b"getinfo:")
        r = b""
        while not r.endswith(b"\n"):
            c = self.s.recv(1)
            if not c:
                raise EOFError("server closed")
            r += c
        return r.decode()

    def settck(self, ns):
        self.s.sendall(b"settck:" + struct.pack("<I", ns))
        return struct.unpack("<I", recv_exact(self.s, 4))[0]

    def shift(self, tms, tdi):
        n = len(tms)
        nb = (n + 7) // 8
        tb, db = bytearray(nb), bytearray(nb)
        for i in range(n):
            tb[i // 8] |= tms[i] << (i % 8)
            db[i // 8] |= tdi[i] << (i % 8)
        self.s.sendall(b"shift:" + struct.pack("<I", n) + bytes(tb) + bytes(db))
        r = recv_exact(self.s, nb)
        return [(r[i // 8] >> (i % 8)) & 1 for i in range(n)]


def bits(v, n):
    return [(v >> i) & 1 for i in range(n)]


def value(b):
    return sum(x << i for i, x in enumerate(b))


def scan(x, ir, data, n):
    """From Run-Test/Idle: one scan (IR if ir else DR) of n bits, back to
    Run-Test/Idle; returns the n TDO bits (sampled before each rising edge,
    as the harness does)."""
    head = [1, 1, 0, 0] if ir else [1, 0, 0]       # -> Shift-IR / Shift-DR
    tms = head + [0] * (n - 1) + [1] + [1, 0]      # last bit -> Exit1, Update, RTI
    tdi = [0] * len(head) + bits(data, n) + [0, 0]
    tdo = x.shift(tms, tdi)
    return tdo[len(head):len(head) + n]


def main():
    host, port, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0)
    x = Xvc(host, port)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    info = x.getinfo()
    check(info.startswith("xvcServer_v1.0:"), "getinfo: %r" % info)
    check(x.settck(100) == 100, "settck 100 ns echoed")

    x.shift([1] * 5 + [0], [0] * 6)                # Test-Logic-Reset, Run-Test/Idle
    idc = value(scan(x, False, 0, 32))
    check(idc == want, "IDCODE after reset 0x%08x (expected 0x%08x)" % (idc, want))

    cap = value(scan(x, True, 0x09, 6))
    check(cap == 0x11, "IR capture 0x%02x (expected 0x11)" % cap)
    idc = value(scan(x, False, 0, 32))
    check(idc == want, "IDCODE after IR 0x09: 0x%08x" % idc)

    scan(x, True, 0x3F, 6)
    pat = 0xB5C3
    out = scan(x, False, pat, 16)
    check(out[1:] == bits(pat, 16)[:-1], "BYPASS: TDI delayed by one bit (sent 0x%04x, got 0x%04x)"
          % (pat, value(out)))

    x.s.close()
    print("=== XVC CLIENT %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
