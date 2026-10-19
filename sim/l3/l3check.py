#!/usr/bin/env python3
"""l3check.py: offline data checks of an L3 run directory (sim/l3/run.sh).

    python3 -I l3check.py kick <run>
    python3 -I l3check.py order <run>
    python3 -I l3check.py mmc <run> [<golden>]

kick: the 256 KB kickstart the firmware uploaded equals the card's KICK.ROM
byte for byte.  UploadKickstart (fw/ctrl_rv/config.c) sends a 0x40000-byte
ROM twice with SendFileV2 (fpga.c), to the Amiga addresses 0xf80000 and
0xfc0000 (the mirror); SendFileV2 writes Amiga address a at host address
(a & 0x7fffff) ^ 0x680000 (HOSTMAP_ADDR, hardware.h): 0x100000 and 0x140000.
The memory is <run>/sdram.bin, the SDRAM model's dump (tb_l3.v
+SDRAM_DUMP: file offset = host byte address, byte A+0 = the upper byte of
halfword A), the file <run>/card/content/KICK.ROM.

order (plan 7.1 item 14): the kickstart is in the SDRAM before the Amiga
CPU runs.  From the run log <run>/tb_boot_*.log (mon_l3.vh): the cycle of
the last SDRAM write into the kickstart region ("=== KICK last SDRAM write
... at cycle W") must be before the last cpurst fall ("=== KICK cpurst
falls at cycle R", userio_osd releasing the CPU); the bench's own "=== MARGIN
14 kick_order" line must say R - W and ok.

mmc: the firmware's MMC_Init card commands equal <golden> (default
sim/l3/gold/mmc_init_rv.txt).  From the run log (+SD_LOG=1: sd_spi_model's
"SD: <time> <cmd> arg=<a> cs=<b>" lines): the commands after the jump to the
firmware ("=== BOOT first read of 0x2000"), up to and including the first
CMD58, as "<cmd> arg=<a>"; the golden's lines without '#' comments.

Each prints one line, "PASS <name>: ..." (exit 0) or "FAIL <name>: ..."
(exit 1); exit 2 on a usage error.  Python 3 standard library only.
"""
import glob
import re
import os
import sys

HOSTMAP_ADDR = 0x680000
KICK_SIZE = 0x40000
KICK_AMIGA = (0xF80000, 0xFC0000)


def host_addr(amiga):
    return (amiga & 0x7FFFFF) ^ HOSTMAP_ADDR


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b)) if len(a) != len(b) else -1


def kick(run):
    dump_path = os.path.join(run, "sdram.bin")
    rom_path = os.path.join(run, "card", "content", "KICK.ROM")
    for p in (dump_path, rom_path):
        if not os.path.isfile(p):
            print("FAIL kick: no %s" % p)
            return 1
    with open(dump_path, "rb") as f:
        mem = f.read()
    with open(rom_path, "rb") as f:
        rom = f.read()
    if len(rom) != KICK_SIZE:
        print("FAIL kick: %s is %d bytes, not 0x%x" % (rom_path, len(rom), KICK_SIZE))
        return 1
    bad = []
    for a in KICK_AMIGA:
        h = host_addr(a)
        got = mem[h:h + KICK_SIZE]
        k = first_diff(got, rom)
        if k >= 0:
            if k < len(got):
                bad.append("Amiga 0x%06x (host 0x%06x): differs from offset 0x%05x (%02x, want %02x)"
                           % (a, h, k, got[k], rom[k]))
            else:
                bad.append("Amiga 0x%06x (host 0x%06x): the dump ends at offset 0x%05x" % (a, h, k))
    if bad:
        print("FAIL kick: " + "; ".join(bad))
        return 1
    print("PASS kick: KICK.ROM (%d bytes) at Amiga 0x%06x and 0x%06x (host 0x%06x, 0x%06x)"
          % (KICK_SIZE, KICK_AMIGA[0], KICK_AMIGA[1], host_addr(KICK_AMIGA[0]), host_addr(KICK_AMIGA[1])))
    return 0


def run_log(run, name):
    logs = sorted(glob.glob(os.path.join(run, "tb_boot_*.log")))
    if len(logs) != 1:
        print("FAIL %s: %d tb_boot_*.log files in %s (want 1)" % (name, len(logs), run))
        return None
    with open(logs[0]) as f:
        return logs[0], f.read().splitlines()


def order(run):
    got = run_log(run, "order")
    if got is None:
        return 1
    log, lines = got
    w = r = margin = None
    for line in lines:
        m = re.match(r"=== KICK last SDRAM write into the kickstart region at cycle (\d+) \(host ([0-9a-f]+)\)", line)
        if m:
            w, wa = int(m.group(1)), m.group(2)
        m = re.match(r"=== KICK cpurst falls at cycle (\d+)", line)
        if m:
            r = int(m.group(1))
        if line.startswith("=== MARGIN 14 kick_order "):
            margin = line
    if w is None:
        print("FAIL order: no kickstart-region SDRAM write in %s" % log)
        return 1
    if r is None:
        print("FAIL order: no cpurst fall in %s" % log)
        return 1
    if w >= r:
        print("FAIL order: the last kickstart-region SDRAM write (cycle %d, host %s) is not before the last "
              "cpurst fall (cycle %d)" % (w, wa, r))
        return 1
    want = "=== MARGIN 14 kick_order min %d.0 clk_114 (bound 1, ok)" % (r - w)
    if margin is None or not margin.startswith(want):
        print("FAIL order: the bench's MARGIN 14 line is %r, want it to start with %r" % (margin, want))
        return 1
    print("PASS order: the last kickstart-region SDRAM write at cycle %d (host %s), the CPU released at "
          "cycle %d, %d cycles later" % (w, wa, r, r - w))
    return 0


def mmc(run, golden):
    got = run_log(run, "mmc")
    if got is None:
        return 1
    log, lines = got
    if not os.path.isfile(golden):
        print("FAIL mmc: no golden %s" % golden)
        return 1
    with open(golden) as f:
        want = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    seen = cmds = None
    for line in lines:
        if line.startswith("=== BOOT first read of 0x2000"):
            seen, cmds = True, []
            continue
        # (Verilator prints a space for the model's empty "%0s": "SD: <t>  CMD0")
        m = re.match(r"SD: \d+ +(A?CMD\d+ arg=[0-9a-f]{8}) cs=", line)
        if seen and m:
            cmds.append(m.group(1))
            if m.group(1).startswith("CMD58 "):
                break
    if not seen:
        print("FAIL mmc: no '=== BOOT first read of 0x2000' line in %s" % log)
        return 1
    if not cmds:
        print("FAIL mmc: no SD command after the jump to the firmware (was the run made with +SD_LOG=1?)")
        return 1
    for i in range(max(len(cmds), len(want))):
        a = cmds[i] if i < len(cmds) else "(none)"
        b = want[i] if i < len(want) else "(none)"
        if a != b:
            print("FAIL mmc: command %d is %s, the golden %s says %s" % (i + 1, a, golden, b))
            return 1
    print("PASS mmc: MMC_Init's %d commands after the jump (%s ... %s) = %s"
          % (len(cmds), cmds[0], cmds[-1], golden))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "kick":
        return kick(argv[2])
    if len(argv) == 3 and argv[1] == "order":
        return order(argv[2])
    if len(argv) in (3, 4) and argv[1] == "mmc":
        golden = argv[3] if len(argv) == 4 else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                             "gold", "mmc_init_rv.txt")
        return mmc(argv[2], golden)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
