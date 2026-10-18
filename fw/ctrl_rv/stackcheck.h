#ifndef STACKCHECK_H
#define STACKCHECK_H

/* Stack high-water mark.  The stack starts at 0x2000 (arch/firmware.ld,
   __stack_top) and grows down into the boot BRAM.  The boot ROM image ends
   below STACK_FLOOR (make check), so everything from STACK_FLOOR up to the
   stack top is the firmware's. */
#define STACK_FLOOR   0x1400u
#define STACK_PATTERN 0x5A5AA5A5u

/* Fill [STACK_FLOOR, sp - 64) with STACK_PATTERN.  Call once, first thing in
   main(): everything above the fill is live frames. */
void StackFill(void);

/* The lowest address (word aligned) in the filled region that no longer
   holds the pattern, i.e. how far the stack has reached.  Equals the end of
   the filled region when the stack never got below it. */
unsigned int StackHighWater(void);

#endif
