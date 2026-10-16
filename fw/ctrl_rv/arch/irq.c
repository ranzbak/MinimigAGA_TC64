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
