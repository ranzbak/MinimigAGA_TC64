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

/* interrupt controller (cfide, 16-bit registers, see "Interrupt controller
   API" in README.md) */
#define IRQCTLBASE         0xFFFFFF30
#define HW_IRQ_PENDING     (*(volatile unsigned int *)(IRQCTLBASE + 0x0))
#define HW_IRQ_MASK        (*(volatile unsigned int *)(IRQCTLBASE + 0x4))
#define HW_IRQ_RAW         (*(volatile unsigned int *)(IRQCTLBASE + 0x8))
#define HW_IRQ_MODE        (*(volatile unsigned int *)(IRQCTLBASE + 0xC))

/* source bits */
#define IRQ_VBLANK         0   /* vertical blank, EDGE */
#define IRQ_I2C            1   /* I2C master transfer event; the handler must
                                  access 0xFFFFFFA0 (GetInterrupts()) to clear it */
#define IRQ_AKIKO          2   /* Akiko request, EDGE */
#define IRQ_ADV7511        3   /* ADV7511 INT pin, LEVEL */
/* 4..15: spare (cfide's irq_src port) */

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

/* ---- interrupt controller: per-source handlers, edge/level mode, mask.
 * IrqInstall() installs the dispatcher with SetIntHandler (which switches the
 * legacy INTERRUPT register off); it is idempotent and IrqEnable() calls it.
 * After IrqInstall() do not use EnableInterrupts() (the dispatcher turns a
 * stray legacy flag off again).  SetIntHandler(h) with any other handler
 * clears MASK, so a legacy handler never sees a controller source.
 * The dispatcher reads IRQ_PENDING (already masked by the hardware; the read
 * clears the EDGE bits it returns), calls the handler of each set bit in bit
 * order (bit 0 first) and repeats until a read returns 0.  Configure level
 * sources (IRQ_ADV7511, IDE requests, the I2C flag) as LEVEL with
 * IrqSetMode(bit, 1); pulse sources (vblank, Akiko) stay EDGE, the reset
 * mode of every bit.  A LEVEL source keeps the CPU interrupt up until the
 * device is serviced, so no IrqRaw() re-check is needed.  A LEVEL handler
 * may be called once more right after its line dropped (synchroniser
 * latency); handlers must tolerate it.  The handler of IRQ_I2C must access
 * 0xFFFFFFA0 to clear its source.  A pending bit with a NULL handler has its
 * MASK bit cleared by the dispatcher (no livelock).  Bits >= 16 are ignored. */
void IrqSetHandler(unsigned bit, void (*handler)(void));
void IrqSetMode(unsigned bit, int level);   /* level != 0: LEVEL, else EDGE */
void IrqEnable(unsigned bit);               /* MASK |= 1 << bit */
void IrqDisable(unsigned bit);              /* MASK &= ~(1 << bit) */
uint32_t IrqRaw(void);                      /* synchronised source levels */
void IrqInstall(void);

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
