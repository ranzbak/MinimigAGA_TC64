#!/usr/bin/env python3
"""sertx.py -- send the SerRx test pattern (byte i = i & 255) to the Amiga.

  sertx.py [--port /dev/ttyUSB1] [--baud 57600] [--count 4096] [--gap-us 0]

8N1, no flow control (no RTS/CTS, no XON/XOFF).  --gap-us puts a pause after
every byte (one write per byte then); without it the whole pattern goes out in
one write, back to back.  Start SerRx on the Amiga first: it clears its buffer
when it starts and expects byte 0 first.
"""
import argparse
import sys
import time

import serial


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", default="/dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=57600)
    ap.add_argument("--count", type=int, default=4096)
    ap.add_argument("--gap-us", type=int, default=0,
                    help="pause after each byte, microseconds")
    a = ap.parse_args()

    data = bytes(i & 255 for i in range(a.count))
    s = serial.Serial(a.port, a.baud, bytesize=8, parity="N", stopbits=1,
                      xonxoff=False, rtscts=False, dsrdtr=False, timeout=1,
                      write_timeout=None)
    s.reset_input_buffer()
    s.reset_output_buffer()
    t0 = time.monotonic()
    if a.gap_us <= 0:
        s.write(data)
    else:
        gap = a.gap_us / 1e6
        for i in range(a.count):
            s.write(data[i:i + 1])
            s.flush()
            t = time.monotonic() + gap
            while time.monotonic() < t:
                pass
    s.flush()                      # wait until the OS has sent everything
    dt = time.monotonic() - t0
    s.close()
    line = a.baud / 10             # 8N1: 10 bits a byte
    print(f"sertx: sent {a.count} bytes to {a.port} at {a.baud} baud 8N1 in "
          f"{dt:.3f} s ({a.count / dt if dt else 0:.0f} bytes/s, line max "
          f"{line:.0f}), gap {a.gap_us} us")
    return 0


if __name__ == "__main__":
    sys.exit(main())
