#!/usr/bin/env python3
"""glnet_rename.py <net_raw.v> <net.v>: make tools/vivado/glnet_bridge.tcl's
netlist usable in sim/ddr3_cpu GLNET.  Every module but the top
ap68040_minimig becomes gl_<name> (the netlist must not clash with the RTL
modules xsim also compiles), and the top gets the generic names TG68K.vhd
maps (DC1_ATC, DUAL, BTIC, ICHIP): the netlist has their values baked in,
so they are accepted and ignored."""
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
mods = [m for m in re.findall(r'^module\s+(\\?\S+)', t, flags=re.M) if m != 'ap68040_minimig']
for m in sorted(mods, key=len, reverse=True):
    e = re.escape(m)
    n = 'gl_' + m.lstrip('\\')
    t = re.sub(r'^module\s+' + e + r'(?=[\s(])', 'module ' + n, t, flags=re.M)
    t = re.sub(r'^(\s+)' + e + r'(\s)', r'\1' + n + r'\2', t, flags=re.M)
i = t.index('module ap68040_minimig')
j = t.index(');', i) + 2
t = (t[:j] + '\n  parameter DC1_ATC = 1;\n  parameter DUAL = 1;\n  parameter BTIC = 1;\n'
     '  parameter ICHIP = 1;\n' + t[j:])
open(dst, 'w').write(t)
print(f"{len(mods)} modules renamed, top parameters added")
