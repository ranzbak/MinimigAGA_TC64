# Scripted GDB session of run.sh gdb1 / gdb2 / gdb_teeth (plain command
# file: the xPack GDB has no Python).  Run from sim/rv_dbg/build with image
# A's symbols and the OpenOCD GDB port in $gdb_port:
#
#   riscv-none-elf-gdb -batch -nx -cd=sim/rv_dbg/build \
#       -ex 'set $gdb_port = 3333' -x sim/rv_dbg/gdb/session.gdb dbgtest_a.elf
#
# Each step prints "CHECK <name> <value>"; run.sh compares the lines, in
# order, against the expected values and prints "=== GDB PASS" or
# "=== GDB FAIL <name>".  A command that fails ends the script (GDB stops
# a command file at the first error), so the CHECK lines after it are
# missing and run.sh names the first missing one.
#
# Breakpoints: "break *main" is a software breakpoint (OpenOCD writes an
# ebreak into memory); "hbreak work" is a hardware trigger.  The session
# reaches main by software breakpoint, then resets the hart again before
# warming A's work() into the I-cache: in gdb_teeth (no I-cache flush on
# fence.i) the ebreak OpenOCD wrote and removed would otherwise stay in
# the cached line of main, and with B loaded a software breakpoint in the
# cached line of work would never be fetched -- the teeth would fail before
# the mailbox check.  The reset flushes the I-cache (it is the core reset)
# and the trigger does not depend on memory contents.

set pagination off
set confirm off
set width 0
set remotetimeout 60
eval "target extended-remote 127.0.0.1:%d", $gdb_port

# ---- 1. halt, registers: the hart is in main's loop or in work
monitor halt
maintenance flush register-cache
info registers pc sp ra
printf "CHECK halt_pc 0x%08x\n", $pc

# ---- 2. memory: main has copied the known words into pattern
x/8wx &pattern
printf "CHECK pattern %08x %08x %08x %08x %08x %08x %08x %08x\n", pattern[0], pattern[1], pattern[2], pattern[3], pattern[4], pattern[5], pattern[6], pattern[7]

# ---- 3. the hart runs: counter grows between two halts
set $c1 = counter
monitor resume
monitor halt
set $c2 = counter
print $c1
print $c2
printf "CHECK counter %u %u\n", $c1, $c2

# ---- 4. ndmreset: the hart restarts halted at the reset vector
monitor reset halt
maintenance flush register-cache
info registers pc
printf "CHECK reset_pc 0x%08x\n", $pc

# ---- 5. software breakpoint at main, run from the reset vector to it
break *main
continue
info registers pc
printf "CHECK main_pc 0x%08x\n", $pc
delete

# ---- 6. image A runs from a fresh reset (I-cache flushed): work() of A is
# now in the I-cache and has written its value
monitor reset halt
monitor resume
monitor halt
maintenance flush register-cache
printf "CHECK mailbox_a 0x%08x\n", mailbox

# ---- 7. load image B through the Debug Module (GDB sets pc to its entry,
# the reset vector), stop in work, run one more iteration
file dbgtest_b.elf
load
hbreak work
continue
info registers pc
printf "CHECK work_pc 0x%08x\n", $pc
continue
info registers pc
printf "CHECK mailbox 0x%08x\n", mailbox
delete

# ---- 8. detach: OpenOCD resumes the hart; its gdb-detach handler shuts it down
detach
echo CHECK detach done\n
