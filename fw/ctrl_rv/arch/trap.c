/* rv_trap: called by trap_entry (trap.S) for every trap.
 *   mcause 0x8000000B (machine external interrupt, cfide's INTERRUPT line)
 *     -> (*_InterruptVector)(), the handler installed with SetIntHandler
 *   anything else -> rv_exception(mcause, mepc, mtval)
 * rv_exception and rv_putc are weak: firmware or a test may provide its own.
 * The default rv_exception prints
 *     EXC mcause=XXXXXXXX mepc=XXXXXXXX mtval=XXXXXXXX
 * through rv_putc (default: cfide UART, 0xFFFFFFF0) and spins.  An override
 * that returns resumes at mepc, so it must step mepc (csrw mepc) past the
 * faulting instruction: 4 bytes, or 2 if its low two bits are not 11. */
#include <stdint.h>
#include "irq.h"
#include "csr.h"

void rv_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval);
void rv_exception(uint32_t mcause, uint32_t mepc, uint32_t mtval);
void rv_putc(int c);

__attribute__((weak)) void rv_putc(int c)
{
    /* cfide holds the write's ack until the UART takes the byte */
    *(volatile uint8_t *)0xFFFFFFF0 = (uint8_t)c;
}

static void rv_puts(const char *s)
{
    while (*s)
        rv_putc(*s++);
}

static void rv_puthex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4)
        rv_putc("0123456789ABCDEF"[(v >> i) & 15]);
}

__attribute__((weak)) void rv_exception(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    rv_puts("EXC mcause=");
    rv_puthex(mcause);
    rv_puts(" mepc=");
    rv_puthex(mepc);
    rv_puts(" mtval=");
    rv_puthex(mtval);
    rv_puts("\n");
    for (;;)
        ;
}

void rv_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    if (mcause == MCAUSE_MEI)
        (*_InterruptVector)();
    else
        rv_exception(mcause, mepc, mtval);
}
