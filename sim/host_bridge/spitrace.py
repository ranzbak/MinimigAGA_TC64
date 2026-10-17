#!/usr/bin/env python3
"""spitrace.py: the L2 firmware boot's SPI frame log (tb_host_bridge.v
+SPI_LOG, run.sh fwboot) -- summary and milestone check.

    python3 -I spitrace.py summary <spi.txt>
    python3 -I spitrace.py check <milestones.txt> <run log> <spi.txt>
    python3 -I spitrace.py count <spi.txt> <pattern>

spi.txt: one SPI frame per line, "<cs> <MOSI bytes> / <MISO bytes>", hex,
no timestamps (cs = ~sd_cs without bit 0, the Enable value: 20 OSD, 10 FPGA,
02 card, 00 none).

milestones.txt, one per line ('#' starts a comment line, blank lines
ignored), each checked in order within its own stream (an ordered
subsequence: other lines may come in between):
    UART <text>            a "UART: " line of the run log containing <text>
                           (several milestones may match in one line, in
                           order along it)
    SPI <cs> <pattern>     a frame with that cs whose bytes match
    SPI>=<n> <cs> <pattern>  n such frames, in order
<pattern> = <MOSI tokens> [/ <MISO tokens>]; a token is a hex byte, "xx"
(any byte) or ".." (any number of further bytes, last token only).
Without "..", the frame has exactly as many bytes as tokens; without a
MISO part, MISO is not checked.

Exit status: 0 = every milestone found (check), 1 = not, 2 = usage.
Python 3 standard library only.
"""
import sys
from collections import Counter


def read_frames(path):
    frames = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            left, sep, right = line.partition(" /")
            if not sep:
                raise SystemExit("%s:%d: no ' /' in the frame line" % (path, n))
            toks = left.split()
            cs = int(toks[0], 16)
            out = [int(t, 16) for t in toks[1:]]
            inp = [int(t, 16) for t in right.split()]
            if len(out) != len(inp):
                raise SystemExit("%s:%d: %d MOSI but %d MISO bytes" % (path, n, len(out), len(inp)))
            frames.append((cs, out, inp))
    return frames


def parse_tokens(toks, where):
    pat, more = [], False
    for i, t in enumerate(toks):
        if t == "..":
            if i != len(toks) - 1:
                raise SystemExit("%s: '..' must be the last token" % where)
            more = True
        elif t.lower() == "xx":
            pat.append(None)
        else:
            pat.append(int(t, 16))
    return pat, more


def parse_pattern(words, where):
    """words after the cs: '<out> [/ <in>]' -> (out, out_more, in, in_more)"""
    if "/" in words:
        k = words.index("/")
        o, om = parse_tokens(words[:k], where)
        i, im = parse_tokens(words[k + 1:], where)
        return o, om, i, im
    o, om = parse_tokens(words, where)
    return o, om, None, True


def tok_match(pat, more, data):
    if len(data) < len(pat) or (not more and len(data) != len(pat)):
        return False
    return all(p is None or p == d for p, d in zip(pat, data))


def frame_match(spec, frame):
    cs, (o, om, i, im) = spec
    fcs, out, inp = frame
    if fcs != cs or not tok_match(o, om, out):
        return False
    if i is not None:
        # the MISO part is matched against the same number of bytes as MOSI
        if not tok_match(i, im, inp):
            return False
    return True


def parse_spi_spec(words, where):
    return int(words[0], 16), parse_pattern(words[1:], where)


def count(frames, spec):
    return sum(1 for fr in frames if frame_match(spec, fr))


def summary(path):
    frames = read_frames(path)
    by_cs = Counter(cs for cs, _, _ in frames)
    print("frames %d" % len(frames))
    for cs in sorted(by_cs):
        nbytes = sum(len(o) for c, o, _ in frames if c == cs)
        print("  cs %02x: %d frames, %d bytes" % (cs, by_cs[cs], nbytes))
    osd = Counter(o[0] for c, o, _ in frames if c == 0x20 and o)
    if osd:
        print("OSD commands (first byte): " +
              ", ".join("%02x x%d" % (k, osd[k]) for k in sorted(osd)))
    fpga6 = sum(1 for c, o, _ in frames if c == 0x10 and o == [0] * 6)
    print("FPGA frames 10 00 00 00 00 00 00 (HandleFpga): %d" % fpga6)
    for c, o, i in frames:
        if c == 0x20 and o and o[0] == 0x88:
            print("OSD_CMD_VERSION: out %s / in %s" %
                  (" ".join("%02x" % b for b in o), " ".join("%02x" % b for b in i)))
    return 0


def uart_lines(path):
    lines = []
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("UART: "):
                lines.append(line[len("UART: "):].rstrip("\n"))
    return lines


def check(mpath, logpath, spipath):
    frames = read_frames(spipath)
    uart = uart_lines(logpath)
    upos = (0, 0)        # next line, offset in it
    fpos = 0             # next frame
    bad = 0
    nm = 0
    with open(mpath) as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            nm += 1
            where = "%s:%d" % (mpath, n)
            kind, _, rest = line.partition(" ")
            if kind == "UART":
                text = rest
                li, off = upos
                found = None
                while li < len(uart):
                    k = uart[li].find(text, off)
                    if k >= 0:
                        found = (li, k + len(text))
                        break
                    li, off = li + 1, 0
                if found:
                    print("ok   UART %s (log UART line %d)" % (text, found[0] + 1))
                    upos = found
                else:
                    print("BAD  UART %s: not found after UART line %d" % (text, upos[0] + 1))
                    bad += 1
            elif kind == "SPI" or kind.startswith("SPI>="):
                need = int(kind[5:]) if kind.startswith("SPI>=") else 1
                spec = parse_spi_spec(rest.split(), where)
                got, k = 0, fpos
                while k < len(frames) and got < need:
                    if frame_match(spec, frames[k]):
                        got += 1
                    k += 1
                if got == need:
                    print("ok   %s %s (frames up to %d)" % (kind, rest, k))
                    fpos = k
                else:
                    print("BAD  %s %s: %d of %d found after frame %d" % (kind, rest, got, need, fpos))
                    bad += 1
            else:
                raise SystemExit("%s: unknown milestone kind %r" % (where, kind))
    if nm == 0:
        print("BAD  no milestones in %s" % mpath)
        return 1
    print("milestones: %d of %d found in order" % (nm - bad, nm))
    return 1 if bad else 0


def main(argv):
    if len(argv) == 3 and argv[1] == "summary":
        return summary(argv[2])
    if len(argv) == 5 and argv[1] == "check":
        return check(argv[2], argv[3], argv[4])
    if len(argv) >= 4 and argv[1] == "count":
        print(count(read_frames(argv[2]), parse_spi_spec(argv[3:], "argument")))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
