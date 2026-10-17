/* Interrupt API (irq.h): the handler pointer rv_trap dispatches through and
 * the INTERRUPT register accessors.  Port of fw/ctrl_832/interrupts.c. */
#include "irq.h"

static void rv_irq_default(void)
{
    GetInterrupts();
}

void (*volatile _InterruptVector)(void) = rv_irq_default;

void SetIntHandler(void (*handler)(void))
{
    /* disable first: no event can reach the old handler once the pointer
       changes (the store order is program order on this core) */
    HW_INTERRUPT(REG_INTERRUPT_CTRL) = 0;
    _InterruptVector = handler ? handler : rv_irq_default;
}

/* as the 832's intconstructor (priority 100 there; 0-100 are reserved
   to the implementation in GCC): start with interrupts off, default handler */
__attribute__((constructor(101))) static void irq_constructor(void)
{
    SetIntHandler(rv_irq_default);
}

int GetInterrupts(void)
{
    return (int)HW_INTERRUPT(REG_INTERRUPT_CTRL);
}

void EnableInterrupts(void)
{
    HW_INTERRUPT(REG_INTERRUPT_CTRL) = 1;
}

void DisableInterrupts(void)
{
    HW_INTERRUPT(REG_INTERRUPT_CTRL) = 0;
}

/* ---- interrupt controller (cfide 0xFFFFFF30..3C) */
#define NIRQ 16

static void (*irq_handlers[NIRQ])(void);

void IrqSetHandler(unsigned bit, void (*handler)(void))
{
    if (bit < NIRQ)
        irq_handlers[bit] = handler;
}

void IrqSetMode(unsigned bit, int level)
{
    uint32_t s;

    if (bit >= NIRQ)
        return;
    s = irq_save();
    if (level)
        HW_IRQ_MODE = HW_IRQ_MODE | (1u << bit);
    else
        HW_IRQ_MODE = HW_IRQ_MODE & ~(1u << bit);
    irq_restore(s);
}

void IrqEnable(unsigned bit)
{
    uint32_t s;

    if (bit >= NIRQ)
        return;
    s = irq_save();
    HW_IRQ_MASK = HW_IRQ_MASK | (1u << bit);
    irq_restore(s);
}

void IrqDisable(unsigned bit)
{
    uint32_t s;

    if (bit >= NIRQ)
        return;
    s = irq_save();
    HW_IRQ_MASK = HW_IRQ_MASK & ~(1u << bit);
    irq_restore(s);
}

uint32_t IrqRaw(void)
{
    return HW_IRQ_RAW;
}

static void irq_dispatch(void)
{
    uint32_t p;
    unsigned b;

    while ((p = HW_IRQ_PENDING) != 0) {
        for (b = 0; b < NIRQ; b++)
            if ((p & (1u << b)) && irq_handlers[b])
                irq_handlers[b]();
    }
}

void IrqInstall(void)
{
    SetIntHandler(irq_dispatch);
}
