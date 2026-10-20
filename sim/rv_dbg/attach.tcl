# OpenOCD script of run.sh attach1 / attach2 / teeth, after the board config
# (tools/openocd/minimig-rv-{bscan,pins}.cfg) with -f: no GDB/telnet/Tcl
# servers (parallel runs never collide on 3333/4444/6666), attach, halt,
# print the PC, resume, quit.  run.sh checks the output.
gdb_port disabled
telnet_port disabled
tcl_port disabled
init
halt
echo "state after halt: [[target current] curstate]"
echo [reg pc]
resume
echo "state after resume: [[target current] curstate]"
shutdown
