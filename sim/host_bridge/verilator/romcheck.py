#!/usr/bin/env python3
"""romcheck.py <OSDBoot_rv_ROM.vhd | OSDBoot_832_ROM.vhd> <bridge.v>: the boot BRAM after ghdl --synth.

The ROM template (fw/ctrl_boot_rv; the 832's run copy, sim/common/hostsim.sh
hs_rom832) is a shared-variable RAM with its contents
as the variable's initial value.  ghdl --synth must turn it into memories
(not registers) and keep every word.  GHDL 4.1 writes one 8-bit memory per
byte lane (ram_n1 .. ram_n4) with "initial" assignments, index order
reversed or not.  This script reads the VHDL words and the Verilog
initialisers, and requires that every lane memory equals exactly one byte
lane of the VHDL words (all words, one index order for all lanes, each lane
once).  Exit 0 and one "romcheck ok" line, else exit 1 with the reason.
"""
import re
import sys


def vhdl_words(path):
    s = open(path).read()
    depth = 2048
    words = [0] * depth
    m = re.search(r"others\s*=>\s*\(?\s*x\"([0-9a-fA-F]{8})\"", s)
    if m:
        words = [int(m.group(1), 16)] * depth
    for i, w in re.findall(r"^\s*(\d+)\s*=>\s*x\"([0-9a-fA-F]{8})\"", s, re.M):
        words[int(i)] = int(w, 16)
    return words


def verilog_lanes(path):
    s = open(path).read()
    mod = re.search(r"^module osdboot_(?:rv|832)_rom\w*\n.*?^endmodule", s, re.S | re.M)
    if not mod:
        sys.exit("romcheck: no osdboot_rv_rom / osdboot_832_rom module in %s" % path)
    body = mod.group(0)
    lanes = {}
    for name, depth in re.findall(r"reg \[7:0\] (\w+)\[(\d+):0\] ; // memory", body):
        lanes[name] = [None] * (int(depth) + 1)
    for name, i, bits in re.findall(r"^\s*(\w+)\[(\d+)\] = 8'b([01]{8});", body, re.M):
        lanes[name][int(i)] = int(bits, 2)
    return lanes


def main():
    words = vhdl_words(sys.argv[1])
    lanes = verilog_lanes(sys.argv[2])
    if len(lanes) != 4 or any(len(v) != len(words) for v in lanes.values()):
        sys.exit("romcheck: want 4 lane memories of %d bytes, got %s"
                 % (len(words), {k: len(v) for k, v in lanes.items()}))
    for name, mem in lanes.items():
        if None in mem:
            sys.exit("romcheck: %s: %d bytes without an initial value" % (name, mem.count(None)))
    n = len(words)
    for rev in (False, True):
        used = {}
        for name, mem in lanes.items():
            for b in range(4):
                if all(mem[(n - 1 - i) if rev else i] == (words[i] >> (8 * b)) & 0xFF
                       for i in range(n)):
                    used.setdefault(name, []).append(b)
        if len(used) == 4 and sorted(sum(used.values(), [])) == [0, 1, 2, 3]:
            nz = sum(1 for w in words if w)
            print("romcheck ok: %d words (%d non-zero) in 4 byte-lane memories, index %s"
                  % (n, nz, "reversed" if rev else "direct"))
            return 0
    sys.exit("romcheck: the converted memories do not hold the VHDL ROM words")


if __name__ == "__main__":
    sys.exit(main())
