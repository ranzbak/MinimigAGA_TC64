/* exc: synchronous exceptions through the firmware trap entry
 * (fw/ctrl_rv/arch/trap.S -> rv_trap -> rv_exception).  This program
 * overrides the weak rv_exception: it records mcause, mepc and mtval, steps
 * mepc over the faulting instruction (4 bytes, or 2 for a compressed one)
 * and returns, so the program continues.
 *   illegal instruction  .word 0xffffffff (a 32-bit encoding)  mcause 2
 *   misaligned load      lw  from buf + 1                       mcause 4
 *   misaligned store     sh  to   buf + 1                       mcause 6
 * Each must trap exactly once with the instruction's address in mepc; mtval
 * is the address for the misaligned accesses and EXC_ILL_MTVAL for the
 * illegal instruction.  The load's destination and the store's target must
 * be unchanged.
 * Exit code: 0 = pass, 0x10 * k + n for check n of case k (1 illegal,
 * 2 load, 3 store): n = 1 trap count, 2 mcause, 3 mepc, 4 mtval, 5 side effect. */
#include <stdint.h>
#include "l1.h"
#include "csr.h"

/* VexRiscv (DecoderSimplePlugin) reports the instruction word in mtval */
#define EXC_ILL_MTVAL 0xffffffffu

static volatile unsigned n_exc;
static volatile uint32_t r_cause, r_epc, r_tval;
static volatile uint32_t buf[2] = { 0x11223344u, 0x55667788u };

void rv_exception(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    uint16_t ins = *(volatile uint16_t *)mepc;

    n_exc = n_exc + 1;
    r_cause = mcause;
    r_epc = mepc;
    r_tval = mtval;
    csr_write(mepc, mepc + ((ins & 3) == 3 ? 4 : 2));
}

static int check(int k, uint32_t cause, uint32_t epc, uint32_t tval)
{
    if (n_exc != 1)
        return 0x10 * k + 1;
    if (r_cause != cause)
        return 0x10 * k + 2;
    if (r_epc != epc)
        return 0x10 * k + 3;
    if (r_tval != tval)
        return 0x10 * k + 4;
    n_exc = 0;
    return 0;
}

static int run(void)
{
    uint32_t pc, v;
    int rc;

    /* illegal instruction */
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "la   %0, 1f\n"
                     "1:\t.word 0xffffffff\n\t"
                     ".option pop"
                     : "=&r"(pc) : : "memory");
    if ((rc = check(1, 2, pc, EXC_ILL_MTVAL)))
        return rc;

    /* misaligned load: v keeps its value */
    v = 0xC0FFEE00u;
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "la   %0, 1f\n"
                     "1:\tlw   %1, 1(%2)\n\t"
                     ".option pop"
                     : "=&r"(pc), "+r"(v) : "r"(buf) : "memory");
    if ((rc = check(2, 4, pc, (uint32_t)buf + 1)))
        return rc;
    if (v != 0xC0FFEE00u)
        return 0x25;

    /* misaligned store: buf keeps its value */
    __asm__ volatile(".option push\n\t.option norvc\n\t"
                     "la   %0, 1f\n"
                     "1:\tsh   %1, 1(%2)\n\t"
                     ".option pop"
                     : "=&r"(pc) : "r"(0xBEEFu), "r"(buf) : "memory");
    if ((rc = check(3, 6, pc, (uint32_t)buf + 1)))
        return rc;
    if (buf[0] != 0x11223344u || buf[1] != 0x55667788u)
        return 0x35;
    return 0;
}

int main(void)
{
    l1_done(run());
}
