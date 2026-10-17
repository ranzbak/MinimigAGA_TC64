#include "uart.h"
#include "interrupts.h"

static void dummy_handler()
{
	GetInterrupts();
}


void SetIntHandler(void(*handler)())
{
	HW_INTERRUPT(REG_INTERRUPT_CTRL)=0;
	*(void **)13=(void *)handler;
}

__constructor(100.interrupts) void intconstructor()
{
	SetIntHandler(dummy_handler);
}


volatile int GetInterrupts()
{
	return(HW_INTERRUPT(REG_INTERRUPT_CTRL));
}


void EnableInterrupts()
{
	HW_INTERRUPT(REG_INTERRUPT_CTRL)=1;
}


void DisableInterrupts()
{
	HW_INTERRUPT(REG_INTERRUPT_CTRL)=0;
}

