# OpenOCD script of run.sh gdb1 / gdb2 / gdb_teeth, after the board config
# (tools/openocd/minimig-rv-{bscan,pins}.cfg) with -f.  Set GDB_PORT with
# -c "set GDB_PORT <port>" before the first -f.  GDB server on
# 127.0.0.1:$GDB_PORT only (no telnet/Tcl servers: parallel runs never
# collide on 4444/6666); when GDB detaches, OpenOCD shuts down (the harness
# then ends on the remote_bitbang disconnect).
if { ![info exists GDB_PORT] } { set GDB_PORT 3333 }
bindto 127.0.0.1
gdb_port $GDB_PORT
telnet_port disabled
tcl_port disabled
[target current] configure -event gdb-detach { shutdown }
init
