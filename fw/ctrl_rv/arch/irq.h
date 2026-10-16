/* Interrupts of the OSD host CPU (VexRiscv): cfide's INTERRUPT register at
 * 0xFFFFFFA0 drives the core's machine external interrupt (mcause
 * 0x8000000B).  Same API as fw/ctrl_832/interrupts.h, plus irq_save /
 * irq_restore for short critical sections.
 *
 * INTERRUPT register (cfide): write bit 0 = enable (1) / disable (0); any
 * access, read or write, clears the pending line.  An event (VBL, I2C, Amiga
 * request) sets the line only if enabled at that moment: an event while
 * disabled is lost.
 *
 * crt0 sets mie.MEIE and mstatus.MIE before main(); irq.c's constructor
 * installs the default handler with SetIntHandler, which leaves the INTERRUPT
 * register disabled.  So nothing reaches the handler until EnableInterrupts().
 * The handler runs from the trap with mstatus.MIE clear (no nesting) and must
 * access the INTERRUPT register (GetInterrupts()) to clear the line, or the
 * trap re-enters at once. */
#ifndef ARCH_IRQ_H
#define ARCH_IRQ_H

#include <stdint.h>

#define INTERRUPTBASE      0xFFFFFFA0
#define HW_INTERRUPT(x)    (*(volatile unsigned int *)(INTERRUPTBASE + (x)))
#define REG_INTERRUPT_CTRL 0x0

#ifdef __cplusplus
extern "C" {
#endif

/* the current handler; rv_trap calls it for mcause 0x8000000B */
extern void (*volatile _InterruptVector)(void);

/* disable the INTERRUPT register (HW_INTERRUPT = 0, which also clears the
   line), then install handler (NULL = the default handler, which only
   clears the line).  Call EnableInterrupts() afterwards. */
void SetIntHandler(void (*handler)(void));
/* 32-bit read of the INTERRUPT register: clears the line */
int GetInterrupts(void);
/* HW_INTERRUPT = 1 / 0 (also clear the line) */
void EnableInterrupts(void);
void DisableInterrupts(void);

/* CPU-side critical section: mstatus.MIE off, returns the old mstatus.
   Nests: irq_restore() sets MIE again only if it was set at irq_save(). */
static inline uint32_t irq_save(void)
{
    uint32_t s;
    __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(s) : : "memory");
    return s;
}

static inline void irq_restore(uint32_t s)
{
    __asm__ volatile("csrs mstatus, %0" : : "r"(s & 8u) : "memory");
}

#ifdef __cplusplus
}
#endif

#endif
