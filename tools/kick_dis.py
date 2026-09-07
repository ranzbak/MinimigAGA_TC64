#!/usr/bin/env python3
"""Disassemble a range of a Kickstart ROM image, in Amiga address terms.

Written to read the code the CPU is actually stuck in.  The AP68040 bring-up
(findings/ap68040/plan-v2-with-ddr3.md) reached a spin loop at $F8068E-$F806A2
that an ILA could locate but not explain; the ROM says what the loop is
waiting for.

    tools/kick_dis.py <rom> <start> [end]

Addresses are Amiga addresses ($F80000-based for a 512 KB ROM), not file
offsets -- that is what the ILA reports and what a Guru quotes.  The base is
derived from the image size, so a 256 KB ROM is treated as $FC0000.

    tools/kick_dis.py kick.rom 0xf80680 0xf806b0

THE ROM MUST BE THE ONE THE BOARD IS RUNNING.  Offsets move between Kickstart
versions -- $F80690 in 46.143 is not $F80690 in 47.111 -- so a disassembly of
the wrong image is worse than none.  The version is printed on every run;
check it against what ShowConfig reports before believing a single line.

Needs capstone (pip install capstone).
"""
import re
import sys


def rom_base(size):
    # 512 KB maps at $F80000, 256 KB at $FC0000.
    return 0x1000000 - size


def version_string(data):
    m = re.search(rb"exec (\d+\.\d+)", data)
    exec_ver = m.group(1).decode() if m else "?"
    m = re.search(rb"Kickstart (\d+\.\d+)", data)
    kick = m.group(1).decode() if m else "?"
    return kick, exec_ver


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    path = sys.argv[1]
    start = int(sys.argv[2], 0)
    end = int(sys.argv[3], 0) if len(sys.argv) > 3 else start + 0x40

    with open(path, "rb") as f:
        data = f.read()

    base = rom_base(len(data))
    kick, exec_ver = version_string(data)
    print(f"# {path}: {len(data)} bytes, base ${base:06X}, "
          f"Kickstart {kick}, exec {exec_ver}")
    if not (base <= start < base + len(data)):
        print(f"# ${start:06X} is outside this image "
              f"(${base:06X}-${base + len(data) - 1:06X})")
        return 1

    try:
        from capstone import Cs, CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_040
    except ImportError:
        print("# capstone not installed: pip install capstone")
        return 1

    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_040)
    off = start - base
    n = min(end - start, len(data) - off)

    # Resync past anything capstone will not decode.  Kickstart interleaves
    # jump tables, LVO tables and string data with code, and a disassembly that
    # stops dead at the first of them shows nothing useful -- the run that found
    # the AllocMem loop returned zero lines because $F80660 happened to start on
    # a data word.  Emit the offending word as data and carry on.
    addr = start
    while addr < start + n:
        i = addr - base
        got = False
        for ins in md.disasm(data[i:start + n - base], addr):
            raw = " ".join(f"{b:02x}" for b in ins.bytes)
            print(f"{ins.address:08X}  {raw:<20}  {ins.mnemonic:<10} {ins.op_str}")
            addr = ins.address + ins.size
            got = True
        if not got:
            word = int.from_bytes(data[i:i + 2], "big")
            print(f"{addr:08X}  {data[i]:02x} {data[i+1]:02x}                 dc.w       ${word:04x}")
            addr += 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
