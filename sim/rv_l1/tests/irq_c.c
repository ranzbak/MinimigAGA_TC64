/* irq_c: the C interrupt API of fw/ctrl/arch (irq.h) on the L1 bench's
 * cfide-like INTERRUPT register, started by the firmware crt0.
 *   1  a constructor ran (crt0 walks .init_array)
 *   2  crt0 left mstatus.MIE and mie.MEIE set
 *   -  the default handler (installed by irq.c's constructor) takes an event
 *      and clears the line: otherwise the trap re-enters forever (TIMEOUT)
 *   3  SetIntHandler(h1): an event reaches h1
 *   4  DisableInterrupts(): an event while disabled is lost, also after
 *      EnableInterrupts() (the line is gated by enable at event time)
 *   5  an event pending under irq_save() is dropped by DisableInterrupts()
 *      (any access clears the line), so irq_restore() takes no trap
 *   6  irq_save() returns MIE set at the outer level, clear at the inner one
 *   7  an event under nested irq_save(): the inner irq_restore() keeps MIE
 *      off (no trap), 8 the outer irq_restore() takes it
 *   9  SetIntHandler(h2) while h1 re-arms events: h2 gets them, 10 h1 gets
 *      none after SetIntHandler returned, and SetIntHandler disables the
 *      register before it changes the pointer: an event swept over every
 *      cycle of a SetIntHandler(h1 -> h2) call reaches h1 (before the
 *      disable) or nobody (after it: lost), never h2 before
 *      EnableInterrupts().  In the reversed order (pointer first) an event
 *      between the two stores reaches h2.
 * Exit code: 0 = pass, else the number of the failing check. */
#include <stdint.h>
#include "l1.h"
#include "irq.h"
#include "csr.h"

/* chained event distances, cycles: longer than a handler run at WS=8, so
   main still runs between two events */
#define H1_GAP 1000
#define H2_GAP 1100
/* check 10's sweep: event distances 1..SWEEP_MAX cycles after the IRQ_AT
   store, past the end of the SetIntHandler call that follows it.  A run
   copy with the order reversed hits h2 at d = 10..13 (WS=0 EXTRA_WS=0) up
   to d = 7..28 (WS=8 EXTRA_WS=3).  A spin() step is five instructions or
   more, so spin(SWEEP_MAX / 4) outlasts the event; were it shorter, the
   event would reach h1 or nobody in the next step (harmless). */
#define SWEEP_MAX 64

static volatile unsigned ctor_ran;
static volatile unsigned c1, c2, chain;

__attribute__((constructor)) static void irq_c_ctor(void)
{
    ctor_ran = 1;
}

static void h1(void)
{
    GetInterrupts();
    c1 = c1 + 1;
    if (chain)
        l1_irq_at(H1_GAP);
}

static void h2(void)
{
    GetInterrupts();
    c2 = c2 + 1;
    if (chain)
        l1_irq_at(H2_GAP);
}

static void spin(unsigned n)
{
    for (volatile unsigned i = 0; i < n; i++)
        ;
}

/* wait until *c reaches want, at most n spins; returns 1 if it did */
static int wait_for(volatile unsigned *c, unsigned want, unsigned n)
{
    while (n--)
        if (*c >= want)
            return 1;
    return *c >= want;
}

static int run(void)
{
    unsigned base, s1, s2, d;

    if (!ctor_ran)
        return 1;
    if (!(csr_read(mstatus) & MSTATUS_MIE) || !(csr_read(mie) & MIE_MEIE))
        return 2;

    /* default handler */
    EnableInterrupts();
    l1_irq_at(30);
    spin(200);

    /* 3: h1 */
    SetIntHandler(h1);
    EnableInterrupts();
    l1_irq_at(30);
    if (!wait_for(&c1, 1, 2000))
        return 3;

    /* 4: event while disabled is lost */
    DisableInterrupts();
    l1_irq_at(30);
    spin(200);
    EnableInterrupts();
    spin(200);
    if (c1 != 1)
        return 4;

    /* 5: pending under irq_save, dropped by DisableInterrupts */
    s1 = irq_save();
    l1_irq_at(20);
    spin(200);
    DisableInterrupts();
    irq_restore(s1);
    spin(200);
    if (c1 != 1)
        return 5;

    /* 6..8: nesting */
    EnableInterrupts();
    s1 = irq_save();
    s2 = irq_save();
    if (!(s1 & MSTATUS_MIE) || (s2 & MSTATUS_MIE))
        return 6;
    l1_irq_at(20);
    spin(200);
    irq_restore(s2);
    spin(200);
    if (c1 != 1)
        return 7;
    irq_restore(s1);
    if (!wait_for(&c1, 2, 2000))
        return 8;

    /* 9, 10: switch handlers while events keep coming */
    chain = 1;
    l1_irq_at(H1_GAP);
    if (!wait_for(&c1, 7, 20000))
        return 9;
    SetIntHandler(h2);
    base = c1;
    EnableInterrupts();
    l1_irq_at(H2_GAP);
    if (!wait_for(&c2, 5, 20000))
        return 9;
    chain = 0;
    DisableInterrupts();
    if (c1 != base)
        return 10;

    /* 10: the disable comes before the pointer change */
    base = c2;
    for (d = 1; d <= SWEEP_MAX; d++) {
        SetIntHandler(h1);
        EnableInterrupts();
        l1_irq_at(d);
        SetIntHandler(h2);
        spin(SWEEP_MAX / 4);
        if (c2 != base)
            return 10;
    }
    return 0;
}

int main(void)
{
    l1_done(run());
}
