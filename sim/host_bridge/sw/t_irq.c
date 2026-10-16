/* t_irq: cfide's interrupt through the bridge to the firmware trap entry
 * (fw/ctrl_rv/arch: crt0, trap_entry, rv_trap, irq API), with the real
 * cfide INTERRUPT register at 0xFFFFFFA0.
 *   SetIntHandler(handler), EnableInterrupts(), then STAMP 1: the bench
 *   pulses cfide's vbl_int 20 times (one clk_28 cycle each, 2000 clk_114
 *   apart).  The handler counts and clears the line with GetInterrupts().
 *   1  the count reaches 20 within 100 TIMER steps (~102,000 clk_114)
 *   2  it is still 20 six TIMER steps (~6,000 clk_114, three pulse
 *      distances) later: one trap per pulse, none extra
 *   STAMP 2: the bench checks it sent the 20 pulses.
 * Linked with sw/reset_fw.S (reset, trap 0x20, register clear) and the
 * firmware start-up; main prints PASS/FAIL and writes DONE itself.
 * Exit code: 0 = pass, else the number of the failing check. */
#include <stdint.h>
#include "hb.h"
#include "irq.h"

#define NPULSE 20
#define HB_REG(ofs) (*(volatile unsigned int *)(int)(ofs))
#define TIMER()     (HB_REG(HB_TIMER_OFS) & 0xffffu)

static volatile unsigned n_irq;

static void handler(void)
{
    GetInterrupts();
    n_irq = n_irq + 1;
}

/* spin until n_irq >= want or `steps` TIMER steps have passed */
static void wait_timer(unsigned want, unsigned steps)
{
    unsigned t0 = TIMER();

    while (n_irq < want && ((TIMER() - t0) & 0xffffu) < steps)
        ;
}

static int run(void)
{
    SetIntHandler(handler);
    EnableInterrupts();
    HB_REG(HB_TIME_OFS) = 1;            /* bench: start the pulses */
    wait_timer(NPULSE, 100);
    if (n_irq != NPULSE)
        return 1;
    wait_timer(NPULSE + 1, 6);
    if (n_irq != NPULSE)
        return 2;
    HB_REG(HB_TIME_OFS) = 2;            /* bench: 20 pulses sent */
    DisableInterrupts();
    return 0;
}

int main(void)
{
    int rc = run();
    const char *s = rc ? "FAIL\n" : "PASS\n";

    while (*s)
        *(volatile uint8_t *)(int)HB_UART_OFS = (uint8_t)*s++;
    HB_REG(HB_DONE_OFS) = (unsigned)rc;
    for (;;)
        ;
}
