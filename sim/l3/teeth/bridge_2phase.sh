#!/bin/bash
# Tooth (b), a PATCH for sim/l3/run.sh: the bridge without the four-phase
# handshake and rv_hostcpu with the fast master, both exactly as
# sim/host_bridge/run.sh's mutant gate leg (plan 7.1 item 1: stale acks).
# Usage (run.sh): PATCH=sim/l3/teeth/bridge_2phase.sh; args <run>/src <root>
set -eu
src=$1
[ "$(grep -c -- '-- 4PHASE' "$src/host_bridge.vhd")" = 1 ]
sed -i 's/^\( *\)state <= hw_release; -- 4PHASE.*/\1state <= waiting; -- 4PHASE MUTANT/' "$src/host_bridge.vhd"
grep -q 'state <= waiting; -- 4PHASE MUTANT' "$src/host_bridge.vhd"
python3 - "$src/rv_hostcpu.v" <<'EOP'
import sys
p = sys.argv[1]
s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
sub("  reg           last;      // current request is the last of the transaction\n", "")
sub("  wire dBus_cmd_ready = ~busy;",
    "  reg  last;      // current request is the last of the transaction\n"
    "  wire done_now = req & ack & last;   // bench fast master\n"
    "  wire dBus_cmd_ready = ~busy | done_now;")
sub("  wire d_fire = ~busy & dBus_cmd_valid;", "  wire d_fire = (~busy | done_now) & dBus_cmd_valid;")
sub("  wire i_fire = ~busy & ~dBus_cmd_valid & iBus_cmd_valid;",
    "  wire i_fire = ~busy & ~done_now & ~dBus_cmd_valid & iBus_cmd_valid;")
a = s.index("      if (req && ack) begin")
b = s.index("    end\n  end\n\n  // ------------------------------------------------------- simulation only")
ack = s[a:b]
s = s[:a] + s[b:]
f = s.index("      if (d_fire || i_fire) begin")
s = s[:f] + ack + s[f:]
open(p, "w").write(s)
EOP
echo "bridge_2phase: host_bridge.vhd 4PHASE mutant, rv_hostcpu.v fast master"
