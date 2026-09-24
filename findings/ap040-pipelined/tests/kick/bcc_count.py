#!/usr/bin/env python3
"""(plan M11) Count Bcc instructions in a Kickstart trace and split them into
TAKEN and NOT TAKEN, to put an upper bound on what the branch guess costs.

The pipelined core's ID guesses every Bcc TAKEN, so a NOT-taken one pays a
two-clock correction in EA-fetch (three for the long form).  The bound is
   not-taken Bcc x penalty / total cycles
which needs no new RTL to compute: the trace has every retired PC, and the
ROM has the opcodes.
"""
import sys
rom_path, trace_path = sys.argv[1], sys.argv[2]
rom = open(rom_path, 'rb').read()
ROM_BASE = 0xF80000
def word(a):
    if ROM_BASE <= a < ROM_BASE + len(rom):
        o = a - ROM_BASE
        return rom[o] << 8 | rom[o+1]
    if 0x00F80000 <= a < 0x00F80000 + len(rom):
        o = a - 0x00F80000
        return rom[o] << 8 | rom[o+1]
    return None

n_total = n_rom = 0
taken = nottaken = 0
taken_b = taken_w = taken_l = 0
nt_b = nt_w = nt_l = 0
prev_pc = None; prev_op = None; prev_size = None
with open(trace_path) as f:
    for line in f:
        if line.startswith('#'):
            continue
        p = line.split(' ', 2)
        if len(p) < 2:
            continue
        try:
            pc = int(p[1], 16)
        except ValueError:
            continue
        n_total += 1
        if prev_op is not None:
            # Bcc: $6xxx with condition 2..15 (0 = BRA, 1 = BSR)
            if pc == prev_pc + prev_size:
                nottaken += 1
                if prev_size == 2: nt_b += 1
                elif prev_size == 4: nt_w += 1
                else: nt_l += 1
            else:
                taken += 1
                if prev_size == 2: taken_b += 1
                elif prev_size == 4: taken_w += 1
                else: taken_l += 1
        prev_op = None
        w = word(pc)
        if w is None:
            continue
        n_rom += 1
        if (w & 0xF000) == 0x6000 and ((w >> 8) & 0x0F) >= 2:
            disp = w & 0xFF
            prev_size = 4 if disp == 0x00 else (6 if disp == 0xFF else 2)
            prev_op = w
            prev_pc = pc
print("retired instructions      : %d" % n_total)
print("  of them decodable (ROM) : %d (%.1f%%)" % (n_rom, 100.0*n_rom/n_total))
print("Bcc taken                 : %d  (byte %d word %d long %d)" % (taken, taken_b, taken_w, taken_l))
print("Bcc NOT taken             : %d  (byte %d word %d long %d)" % (nottaken, nt_b, nt_w, nt_l))
print("Bcc not taken / retired   : %.2f%%" % (100.0*nottaken/n_total))
