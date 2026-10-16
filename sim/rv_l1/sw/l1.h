/* L1 bench MMIO map (sim/rv_l1/mem_model.v).  Usable from C and from .S.
 *
 * Everything with bit 23 set is the hw window: 16-bit registers, value in
 * bits 15:0 of the bus word, no lane swap; reads return {16'h0, value}.
 * Unmapped hw reads return 0.  The firmware reaches the window with
 * x0-relative 12-bit offsets (the *_OFS values), e.g. "sw a0, L1_DONE_OFS(zero)".
 */
#ifndef L1_H
#define L1_H

#define L1_TIME_ADDR    0xFFFFFF00  /* W: print "=== TIME <value> cycle <n>"        */
#define L1_DONE_ADDR    0xFFFFFF04  /* W: end the run, 0 = PASS, else FAIL <code>   */
#define L1_IRQAT_ADDR   0xFFFFFF08  /* W: interrupt event <value> cycles from now   */
#define L1_SCRATCH_ADDR 0xFFFFFF0C  /* R/W: 16-bit scratch register (sel honoured)  */
#define L1_INTR_ADDR    0xFFFFFFA0  /* W bit 0 = enable; any access clears pending  */
#define L1_UART_ADDR    0xFFFFFFF0  /* W: character out; R: 0x0100 (TX ready)       */

#define L1_TIME_OFS     (-256)
#define L1_DONE_OFS     (-252)
#define L1_IRQAT_OFS    (-248)
#define L1_SCRATCH_OFS  (-244)
#define L1_INTR_OFS     (-96)
#define L1_UART_OFS     (-16)

#ifndef __ASSEMBLER__
#define L1_REG(a) (*(volatile unsigned int *)(a))

static inline void l1_time(unsigned tag)   { L1_REG(L1_TIME_ADDR) = tag; }
static inline void l1_irq_at(unsigned n)   { L1_REG(L1_IRQAT_ADDR) = n; }
static inline void l1_putc(char c)         { *(volatile unsigned char *)L1_UART_ADDR = (unsigned char)c; }
static inline void l1_puts(const char *s)  { while (*s) l1_putc(*s++); }
static inline __attribute__((noreturn)) void l1_done(unsigned code)
{
    L1_REG(L1_DONE_ADDR) = code;
    for (;;)
        ;
}
#endif

#endif
