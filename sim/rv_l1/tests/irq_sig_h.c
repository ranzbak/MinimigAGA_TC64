/* irq_sig's interrupt handler (tests/irq_sig.S), in C as a firmware handler
 * is: installed with SetIntHandler, called through rv_trap.  Counts the
 * events, clears the line, arms the next event at a pseudo-random distance
 * (IRQ_AT 20..275 cycles) until SIG_NEV events, then trashes the caller-saved
 * registers (sig_trash). */
#include "l1.h"
#include "irq.h"

#define SIG_NEV 50          /* = NEV in irq_sig.S */

volatile unsigned sig_count;
static unsigned lfsr = 0xACE1u;

void sig_trash(void);
void sig_handler(void);

void sig_handler(void)
{
    unsigned n;

    GetInterrupts();
    n = sig_count + 1;
    sig_count = n;
    if (n < SIG_NEV) {
        lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
        l1_irq_at(20 + (lfsr & 0xff));
    }
    sig_trash();
}
