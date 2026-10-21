/* dbgtest: the program of the scripted GDB session (run.sh gdb1 / gdb2 /
 * gdb_teeth, gdb/session.gdb).  Built twice from this source, -DIMG_A and
 * -DIMG_B (build/dbgtest_a.elf, build/dbgtest_b.elf): the two images have
 * the same layout (the Makefile compares their nm output) and differ only
 * in the constant work() returns.  The memory model starts with image A;
 * GDB later loads image B through the Debug Module while A's work() sits in
 * the I-cache, so B's value in mailbox proves OpenOCD's fence.i on resume.
 *
 * main copies pattern_init into pattern (the session reads it back with
 * x/8wx), then loops forever: mailbox = work(); counter++.  It never writes
 * DONE: OpenOCD's shutdown (GDB detach) or the harness timeout ends the run.
 *
 * Placement (4 KB direct-mapped I-cache, 32-byte lines, set = addr[11:5]):
 * main is first in .text (.text.entry, 0x2000); work is 256-byte aligned,
 * so it lands at 0x2100 (set 8), a set no line run between the reset vector
 * and the call to work uses (0x0-0xFF: reset, trap, crt0; 0x2000-0x20FF:
 * main).  After "load" GDB resumes at the reset vector; nothing evicts A's
 * work line before main calls it, so only the I-cache flush of fence.i
 * makes the hart fetch B's work. */
#include <stdint.h>

#if defined(IMG_A)
#define WORK_VALUE 0xA5A50001u
#elif defined(IMG_B)
#define WORK_VALUE 0xB5B50002u
#else
#error "build with -DIMG_A or -DIMG_B"
#endif

/* the known words; run.sh holds the same list (PATTERN) */
static const uint32_t pattern_init[8] = {
    0x01234567u, 0x89ABCDEFu, 0xDEADBEEFu, 0xCAFEF00Du,
    0x0BADF00Du, 0x5A5AA5A5u, 0x13579BDFu, 0x2468ACE0u,
};

volatile uint32_t pattern[8];
volatile uint32_t counter;
volatile uint32_t mailbox;

/* noipa: no inlining, and no interprocedural propagation of the constant
 * into main (with plain noinline GCC may still replace the call's result) */
__attribute__((noinline, noipa, aligned(256)))
uint32_t work(void)
{
    return WORK_VALUE;
}

__attribute__((section(".text.entry"), noreturn))
int main(void)
{
    for (unsigned i = 0; i < 8; i++)
        pattern[i] = pattern_init[i];
    counter = 0;
    for (;;) {
        mailbox = work();
        counter++;
    }
}
