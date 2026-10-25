/* Interrupt API (irq.h): the handler pointer rv_trap dispatches through and
 * the INTERRUPT register accessors. */
#include "irq.h"

static void rv_irq_default(void)
{
    GetInterrupts();
}

void (*volatile _InterruptVector)(void) = rv_irq_default;

static void irq_dispatch(void);

void SetIntHandler(void (*handler)(void))
{
    /* disable first: no event can reach the old handler once the pointer
       changes (the store order is program order on this core) */
    HW_INTERRUPT(REG_INTERRUPT_CTRL) = 0;
    /* a legacy handler never reads IRQ_PENDING: no controller source may
       reach it (endless trap).  Legacy users have MASK = 0 anyway. */
    if (handler != irq_dispatch)
        HW_IRQ_MASK = 0;
    _InterruptVector = handler ? handler : rv_irq_default;
}

/* priority 101 (0-100 are reserved to the implementation in GCC): start
   with interrupts off, default handler */
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
    IrqInstall();               /* the dispatcher must be there before a source can fire */
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
    uint32_t p = HW_IRQ_PENDING;
    unsigned b;

    if (p == 0) {
        /* spurious: the legacy flag (EnableInterrupts() after IrqInstall()):
           clear and disable it */
        DisableInterrupts();
        return;
    }
    do {
        for (b = 0; b < NIRQ; b++) {
            if (!(p & (1u << b)))
                continue;
            if (irq_handlers[b])
                irq_handlers[b]();
            else
                HW_IRQ_MASK = HW_IRQ_MASK & ~(1u << b);  /* no handler: mask it off, no livelock */
        }
    } while ((p = HW_IRQ_PENDING) != 0);
}

void IrqInstall(void)
{
    if (_InterruptVector != irq_dispatch)
        SetIntHandler(irq_dispatch);    /* also switches the legacy register off */
}
