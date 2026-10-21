#include <stdint.h>

#include "stackcheck.h"

static uint32_t *fill_end;	// first word above the filled region

void StackFill(void)
{
	uintptr_t sp;
	__asm__ volatile("mv %0, sp" : "=r"(sp));
	// 64 bytes below the caller's sp stay unfilled: this function's own
	// frame and whatever the compiler spills around the call.
	fill_end = (uint32_t *)((sp - 64) & ~(uintptr_t)3);
	for (volatile uint32_t *p = (volatile uint32_t *)STACK_FLOOR; p < fill_end; p++)
		*p = STACK_PATTERN;
}

unsigned int StackHighWater(void)
{
	const volatile uint32_t *p = (const volatile uint32_t *)STACK_FLOOR;
	while (p < fill_end && *p == STACK_PATTERN)
		p++;
	return (unsigned int)(uintptr_t)p;
}
