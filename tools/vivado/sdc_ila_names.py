#!/usr/bin/env python3
"""sdc_ila_names.py -- the hardware manager's name of every u_ila_sdc bit.

    python3 tools/vivado/sdc_ila_names.py <stage dir>

Reads <stage dir>/minimig_openaars_top.ltx (the build's probes file) and
<stage dir>/sdc_ila_map.txt (written by tools/vivado/sdc_ila.tcl when it
inserted the core: ILA port and bits per signal) and writes
<stage dir>/sdc_ila_bits.txt, one line per signal bit:

    <signal> <bit> <hw probe name> <probe width> <bit in the probe>

Why: the .ltx names a probe after its net, and synthesis / opt_design choose
those names per build (irq_pend_reg[0]_0, addr_reg[22]_0, u_ila_sdc_ila_etog,
... differ between two builds of the same commit), so a script cannot find a
signal by name.  The port and bit of each signal are fixed by sdc_ila.tcl's
table; this joins them with the .ltx's net names.  A bus net is one probe in
the hardware manager (named after the bus, its bits in port order, the
lowest port bit the probe's bit 0); any other net is a 1-bit probe named
after the net.  tools/vivado/sdc_ila_capture.tcl reads the file.
"""
import json
import re
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = sys.argv[1].rstrip('/')
    ltx = json.load(open(d + '/minimig_openaars_top.ltx'))
    # (port, port bit) -> (probe name, width, bit in probe)
    where = {}
    for blk in ltx['ltx_root']['ltx_data']:
        for core in blk.get('debug_cores', []):
            if core['name'] != 'u_ila_sdc':
                continue
            for pin in core.get('pins', []):
                port = int(pin['name'][len('probe'):])
                nets = pin['nets']
                lo, hi = sorted((pin['leftIndex'], pin['rightIndex']))
                if len(nets) == 1 and nets[0].get('isBus'):
                    for b in range(lo, hi + 1):
                        where[(port, b)] = (nets[0]['name'], hi - lo + 1, b - lo)
                else:
                    # one net per bit, listed from leftIndex towards rightIndex
                    step = 1 if pin['rightIndex'] >= pin['leftIndex'] else -1
                    for i, n in enumerate(nets):
                        where[(port, pin['leftIndex'] + i * step)] = (n['name'], 1, 0)
    if not where:
        sys.exit('sdc_ila_names.py: no u_ila_sdc in the .ltx')
    out = []
    for line in open(d + '/sdc_ila_map.txt'):
        if line.startswith('#') or not line.strip():
            continue
        m = re.match(r'probe(\d+)\s+\[(\d+)(?::(\d+))?\]\s+(\S+)', line)
        if not m:
            sys.exit('sdc_ila_names.py: map line not understood: ' + line)
        port = int(m.group(1))
        hi = int(m.group(2))
        lo = int(m.group(3)) if m.group(3) is not None else hi
        sig = m.group(4)
        for b in range(lo, hi + 1):
            if (port, b) not in where:
                sys.exit('sdc_ila_names.py: probe%d[%d] (%s) not in the .ltx' % (port, b, sig))
            name, width, pos = where[(port, b)]
            out.append('%s %d %s %d %d' % (sig, b - lo, name, width, pos))
    with open(d + '/sdc_ila_bits.txt', 'w') as f:
        f.write('# signal bit hw-probe width bit-in-probe (tools/vivado/sdc_ila_names.py)\n')
        f.write('\n'.join(out) + '\n')
    print('sdc_ila_names.py: %d bits -> %s/sdc_ila_bits.txt' % (len(out), d))


if __name__ == '__main__':
    main()
