/* t_irqapi: the interrupt-controller API of fw/ctrl/arch (irq.h: IrqInstall,
 * IrqSetHandler, IrqSetMode, IrqEnable, IrqDisable, IrqRaw) against the real
 * cfide controller.  Same bench stimuli as t_irqctl (STAMP n, table in
 * tb_host_bridge.v).  Exit code: 100 * test + the number of the failing check.
 *   1  the legacy SetIntHandler path, dispatcher not installed (STAMP 10)
 *   2  vblank handler: 8 pulses = 8 calls (STAMP 20)
 *   3  vblank + bit 5 in one clk_28 cycle, bit 2 one later: each handler once,
 *      bit 0 first (STAMP 30)
 *   4  a masked spare edge (bit 7) is delivered on IrqEnable, once; a NULL
 *      handler masks its bit off; bit 9 pulse (STAMP 50, 70)
 *   5  LEVEL bit 8 held high (STAMP 60/61): called until the handler drops it,
 *      twice in a row
 *   6  LEVEL bit 3 (the ADV7511 INT pin, STAMP 120/121)
 *   8  EnableInterrupts() after IrqInstall(): no storm, one vblank call
 *   9  LEVEL bit with a NULL handler: masked off, no hang
 *   7  IrqEnable/IrqDisable/IrqSetMode read-modify-write, bit >= 16 ignored
 *  10  SetIntHandler(legacy handler) with MASK != 0 clears MASK: a vblank then
 *      reaches the legacy handler once, no storm (STAMP 10) */
#include <stdint.h>
#include "hb.h"
#include "irq.h"

#define HB_REG(ofs) (*(volatile unsigned int *)(int)(ofs))
#define TIMER()     (HB_REG(HB_TIMER_OFS) & 0xffffu)
#define STAMP(n)    (HB_REG(HB_TIME_OFS) = (n))
#define CHECK(c, code) do { if (!(c)) return (code); } while (0)

static volatile unsigned n_leg, n0, n2, n3, n5, n7, n8, n9;
static volatile unsigned drop_at;       /* LEVEL handlers drop the line at this call count */
static volatile unsigned raw_seen;
static volatile unsigned seq[8], nseq;

static void spin_steps(unsigned steps)
{
    unsigned t0 = TIMER();

    while (((TIMER() - t0) & 0xffffu) < steps)
        ;
}

static void wait_ge(volatile unsigned *n, unsigned want, unsigned steps)
{
    unsigned t0 = TIMER();

    while (*n < want && ((TIMER() - t0) & 0xffffu) < steps)
        ;
}

static void log_bit(unsigned b)
{
    if (nseq < 8)
        seq[nseq] = b;
    nseq++;
}

static void leg_handler(void) { n_leg++; GetInterrupts(); }
static void h0(void)          { n0++; log_bit(0); }
static void h2(void)          { n2++; log_bit(2); }
static void h5(void)          { n5++; log_bit(5); }
static void h7(void)          { n7++; }
static void h9(void)          { n9++; }
static void h8(void)
{
    raw_seen |= IrqRaw();
    if (++n8 == drop_at)
        STAMP(61);
}
static void h3(void)
{
    raw_seen |= IrqRaw();
    if (++n3 == drop_at)
        STAMP(121);
}

static int pos(unsigned b)
{
    unsigned i;

    for (i = 0; i < nseq && i < 8; i++)
        if (seq[i] == b)
            return (int)i;
    return -1;
}

static int test1(void)
{
    SetIntHandler(leg_handler);
    EnableInterrupts();
    STAMP(10);
    wait_ge(&n_leg, 1, 20);
    CHECK(n_leg == 1, 101);
    spin_steps(4);
    CHECK(n_leg == 1, 102);
    SetIntHandler(0);
    CHECK(HW_IRQ_MASK == 0, 103);
    return 0;
}

static int test2(void)
{
    IrqSetHandler(IRQ_VBLANK, h0);
    IrqEnable(IRQ_VBLANK);      /* installs the dispatcher; the vblank test 1
                                   latched (MASK was 0) is delivered once now */
    IrqInstall();               /* idempotent */
    wait_ge(&n0, 1, 4);
    spin_steps(2);
    CHECK(n0 == 1, 205);
    CHECK(HW_IRQ_MASK == 0x0001, 201);
    STAMP(20);
    wait_ge(&n0, 9, 40);
    CHECK(n0 == 9, 202);
    spin_steps(6);
    CHECK(n0 == 9, 203);
    CHECK(n_leg == 1, 204);
    return 0;
}

static int test3(void)
{
    IrqSetHandler(5, h5);
    IrqSetHandler(IRQ_AKIKO, h2);
    IrqEnable(5);
    IrqEnable(IRQ_AKIKO);
    CHECK(HW_IRQ_MASK == 0x0025, 301);
    nseq = 0;
    STAMP(30);
    wait_ge(&nseq, 3, 10);
    spin_steps(4);
    CHECK(nseq == 3, 302);
    CHECK(n0 == 10 && n5 == 1 && n2 == 1, 303);
    CHECK(pos(0) >= 0 && pos(5) >= 0 && pos(2) >= 0, 304);
    CHECK(pos(0) < pos(5) && pos(0) < pos(2), 305);     /* bit 0 first */
    IrqDisable(5);
    IrqDisable(IRQ_AKIKO);
    CHECK(HW_IRQ_MASK == 0x0001, 306);
    return 0;
}

static int test4(void)
{
    unsigned base;

    IrqSetHandler(7, h7);
    STAMP(50);                  /* masked: stays pending */
    spin_steps(3);
    CHECK(n7 == 0, 401);
    IrqEnable(7);
    wait_ge(&n7, 1, 4);
    CHECK(n7 == 1, 402);
    spin_steps(4);
    CHECK(n7 == 1, 403);
    IrqSetHandler(7, 0);        /* NULL: the dispatcher still consumes it */
    STAMP(50);
    spin_steps(4);
    CHECK(n7 == 1, 404);
    CHECK(HW_IRQ_RAW == 0, 405);
    CHECK(!(HW_IRQ_MASK & 0x80), 409);  /* no handler: masked off */
    IrqDisable(7);
    IrqSetHandler(9, h9);
    IrqEnable(9);
    base = n9;
    STAMP(70);
    wait_ge(&n9, base + 1, 4);
    CHECK(n9 == base + 1, 406);
    spin_steps(4);
    CHECK(n9 == base + 1, 407);
    IrqDisable(9);
    CHECK(HW_IRQ_MASK == 0x0001, 408);
    return 0;
}

static int test5(void)
{
    unsigned base, k;

    IrqSetHandler(8, h8);
    IrqSetMode(8, 1);
    CHECK(HW_IRQ_MODE == 0x0100, 501);
    IrqEnable(8);
    for (k = 0; k < 2; k++) {
        base = n8;
        drop_at = base + 2;
        raw_seen = 0;
        STAMP(60);              /* bit 8 high; the handler drops it on its 2nd call */
        wait_ge(&n8, base + 2, 8);
        CHECK(n8 >= base + 2, 502);
        spin_steps(4);
        CHECK(n8 == base + 2 || n8 == base + 3, 503);   /* sync latency: one extra */
        base = n8;
        spin_steps(4);
        CHECK(n8 == base, 504);
        CHECK(raw_seen & 0x0100, 505);
        CHECK(IrqRaw() == 0, 506);
        CHECK(HW_IRQ_PENDING == 0, 507);
    }
    IrqDisable(8);
    IrqSetMode(8, 0);
    CHECK(HW_IRQ_MODE == 0, 508);
    return 0;
}

static int test6(void)
{
    IrqSetHandler(IRQ_ADV7511, h3);
    IrqSetMode(IRQ_ADV7511, 1);
    IrqEnable(IRQ_ADV7511);
    CHECK(HW_IRQ_MASK == 0x0009, 601);
    drop_at = n3 + 1;
    raw_seen = 0;
    STAMP(120);
    wait_ge(&n3, 1, 8);
    CHECK(n3 >= 1, 602);
    spin_steps(4);
    CHECK(n3 == 1 || n3 == 2, 603);
    CHECK(raw_seen & 0x0008, 604);
    CHECK(IrqRaw() == 0, 605);
    IrqDisable(IRQ_ADV7511);
    IrqSetMode(IRQ_ADV7511, 0);
    CHECK(HW_IRQ_MASK == 0x0001, 606);
    CHECK(HW_IRQ_MODE == 0, 607);
    return 0;
}

static int test7(void)
{
    IrqEnable(4);
    IrqEnable(12);
    IrqDisable(4);
    CHECK(HW_IRQ_MASK == 0x1001, 701);
    IrqSetMode(4, 1);
    IrqSetMode(12, 1);
    IrqSetMode(4, 0);
    CHECK(HW_IRQ_MODE == 0x1000, 702);
    IrqEnable(16);
    IrqDisable(31);
    IrqSetMode(16, 1);
    IrqSetHandler(16, h0);
    CHECK(HW_IRQ_MASK == 0x1001, 703);
    CHECK(HW_IRQ_MODE == 0x1000, 704);
    IrqSetMode(12, 0);
    IrqDisable(12);
    IrqDisable(IRQ_VBLANK);
    CHECK(HW_IRQ_MASK == 0, 705);
    CHECK(HW_IRQ_MODE == 0, 706);
    return 0;
}

/* SetIntHandler() of a legacy handler while MASK != 0: MASK becomes 0, so
   no controller bit reaches a handler that never reads IRQ_PENDING (without
   that, the vblank below would trap endlessly into leg_handler) */
static int test10(void)
{
    unsigned base_leg = n_leg, base0 = n0;

    IrqSetHandler(IRQ_VBLANK, h0);
    IrqEnable(IRQ_VBLANK);
    CHECK(HW_IRQ_MASK == 0x0001, 1001);
    SetIntHandler(leg_handler);
    CHECK(HW_IRQ_MASK == 0, 1002);
    EnableInterrupts();
    STAMP(10);
    wait_ge(&n_leg, base_leg + 1, 20);
    spin_steps(6);
    CHECK(n_leg == base_leg + 1, 1003);
    CHECK(n0 == base0, 1004);
    SetIntHandler(0);
    return 0;
}

/* EnableInterrupts() after IrqInstall(): the legacy flag must not storm */
static int test8(void)
{
    unsigned base = n0;

    EnableInterrupts();
    STAMP(10);
    wait_ge(&n0, base + 1, 8);
    spin_steps(6);
    CHECK(n0 == base + 1, 801);
    CHECK(HW_IRQ_MASK == 0x0001, 802);
    return 0;
}

/* a LEVEL bit with a NULL handler: masked off by the dispatcher, no hang */
static int test9(void)
{
    IrqSetHandler(8, 0);
    IrqSetMode(8, 1);
    IrqEnable(8);
    STAMP(60);
    spin_steps(6);
    CHECK(HW_IRQ_MASK == 0x0001, 901);
    STAMP(61);
    spin_steps(2);
    IrqSetMode(8, 0);
    CHECK(HW_IRQ_MODE == 0, 902);
    CHECK(HW_IRQ_RAW == 0, 903);
    return 0;
}

static int run(void)
{
    int rc;

    if ((rc = test1()) != 0) return rc;
    if ((rc = test2()) != 0) return rc;
    if ((rc = test3()) != 0) return rc;
    if ((rc = test4()) != 0) return rc;
    if ((rc = test5()) != 0) return rc;
    if ((rc = test6()) != 0) return rc;
    if ((rc = test8()) != 0) return rc;
    if ((rc = test9()) != 0) return rc;
    if ((rc = test7()) != 0) return rc;
    if ((rc = test10()) != 0) return rc;
    STAMP(99);
    return 0;
}

int main(void)
{
    int rc = run();
    const char *s = rc ? "FAIL\n" : "PASS\n";

    SetIntHandler(0);
    while (*s)
        *(volatile uint8_t *)(int)HB_UART_OFS = (uint8_t)*s++;
    HB_REG(HB_DONE_OFS) = (unsigned)rc;
    for (;;)
        ;
}
