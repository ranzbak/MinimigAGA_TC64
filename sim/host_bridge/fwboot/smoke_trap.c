/* smoke_trap.c: the teeth of run.sh fwboot_trap (the firmware's trap path).
 * Linked into a bench-only build of fw/ctrl (EXTRA_OBJS, see
 * fwboot/Makefile); no firmware source changes.  crt0 runs this
 * constructor (priority 65535, .init_array.65535) after it has set mtvec,
 * before main: the first instruction is the all-ones word, an illegal
 * instruction, so the arch default rv_exception prints
 *     EXC mcause=00000002 mepc=<smoke_trap> mtval=FFFFFFFF
 * and spins.  Naked: no prologue, the .word is at the symbol's address
 * (global, so the link map lists it). */
void smoke_trap(void);
__attribute__((constructor(65535), naked, used)) void smoke_trap(void)
{
    __asm__ volatile(".word 0xffffffff");
}
