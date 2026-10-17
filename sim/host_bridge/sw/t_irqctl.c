/* t_irqctl: cfide's interrupt controller (0xFFFFFF30..3C) through the bridge
 * and the firmware trap entry (fw/ctrl_rv/arch), real cfide.  The bench
 * drives vbl_int (bit 0), amiga_req (bit 2), i2c_ext_int (bit 3, the
 * ADV7511 INT pin) and irq_src[15:4] on the
 * checkpoints (STAMP n) listed in tb_host_bridge.v's t_irqctl block.
 *   1  reset values MASK = PENDING = RAW = MODE = 0 (PENDING also with MASK
 *      = 0xFFFF); legacy 0xFFFFFFA0 enable + one vblank pulse = one interrupt
 *   2  legacy off, MASK = bit 0: 8 vblank pulses = 8 interrupts, the handler
 *      reads PENDING = 0x0001 and then 0 each time
 *   3  vblank + bit 5 in one clk_28 cycle, amiga_req one later: one
 *      interrupt, one read returns 0x0025, the next 0
 *   4  "set wins" sweep (interrupts off, polled; checked by the bench too)
 *   5  bit 7 masked: no interrupt, PENDING read returns 0 and keeps it;
 *      unmasking raises the interrupt and the next read returns 0x0080
 *   6  bit 8 held high: one event, RAW bit 8 = 1 while high; low and high
 *      again: a second event
 *   7  RAW reads do not touch PENDING; writes to PENDING and RAW do nothing
 *   9  LEVEL mode, bit 9 held high: PENDING returns it on every read, the
 *      CPU line (mip.MEIP, cfide's output) stays up; the handler masks it;
 *      line low: PENDING bit 9 = 0, interrupt down
 *  10  bit 10 EDGE -> LEVEL -> EDGE with its line high, and EDGE -> LEVEL
 *      with an unread event and the line low (rule in rtl/host/cfide.vhd)
 *  11  MODE and MASK read back
 *  12  bit 3 (ADV7511 INT pin): EDGE, the line held high gives one
 *      interrupt; LEVEL, PENDING returns it on every read and the line stays
 *      up until the pin drops
 * (8, the mutants, is run.sh irqmut.)  Exit code: 0 = pass, else 100 * test
 * + the number of the failing check. */
#include <stdint.h>
#include "hb.h"
#include "irq.h"
#include "csr.h"

#define HB_REG(ofs) (*(volatile unsigned int *)(int)(ofs))
#define TIMER()     (HB_REG(HB_TIMER_OFS) & 0xffffu)
#define PENDING     HB_REG(HB_IRQ_PENDING_OFS)
#define MASK        HB_REG(HB_IRQ_MASK_OFS)
#define RAW         HB_REG(HB_IRQ_RAW_OFS)
#define MODE        HB_REG(HB_IRQ_MODE_OFS)
#define STAMP(n)    (HB_REG(HB_TIME_OFS) = (n))
#define MIP_MEIP    0x800u
#define MEIP()      (csr_read(mip) & MIP_MEIP)
#define CHECK(c, code) do { if (!(c)) return (code); } while (0)

#define NLOG     32
#define T4_ITER  25

enum { M_LEGACY, M_CTL, M_MASKOFF };

static volatile int      hmode;
static volatile unsigned n_irq;
static volatile unsigned log1[NLOG], log2[NLOG];

/* M_LEGACY: clear the 0xa0 flag, log a PENDING read (MASK = 0: reads 0)
   M_CTL:    two PENDING reads
   M_MASKOFF: two PENDING reads, then mask off bit 9 (a LEVEL source the
              handler cannot silence) */
static void handler(void)
{
    unsigned k = n_irq, a, b = 0;

    if (hmode == M_LEGACY) {
        GetInterrupts();
        a = PENDING;
    } else {
        a = PENDING;
        b = PENDING;
        if (hmode == M_MASKOFF)
            MASK = MASK & ~0x200u;
    }
    if (k < NLOG) {
        log1[k] = a;
        log2[k] = b;
    }
    n_irq = k + 1;
}

/* spin until `steps` TIMER steps (1024 clk_114 each) have passed */
static void wait_steps(unsigned steps)
{
    unsigned t0 = TIMER();

    while (((TIMER() - t0) & 0xffffu) < steps)
        ;
}

/* spin until n_irq >= want or `steps` TIMER steps have passed */
static void wait_irq(unsigned want, unsigned steps)
{
    unsigned t0 = TIMER();

    while (n_irq < want && ((TIMER() - t0) & 0xffffu) < steps)
        ;
}

static int test1(void)
{
    uint32_t s;

    CHECK(MASK == 0, 101);
    CHECK(PENDING == 0, 102);
    CHECK(RAW == 0, 103);
    CHECK(MODE == 0, 104);
    s = irq_save();
    MASK = 0xffff;
    CHECK(MASK == 0xffff, 105);
    CHECK(PENDING == 0, 106);
    MASK = 0;
    irq_restore(s);

    hmode = M_LEGACY;
    SetIntHandler(handler);
    EnableInterrupts();
    STAMP(10);
    wait_irq(1, 20);
    CHECK(n_irq == 1, 107);
    wait_steps(4);
    CHECK(n_irq == 1, 108);
    CHECK(log1[0] == 0, 109);
    DisableInterrupts();

    /* the controller latched that vblank too (MASK = 0): consume it */
    s = irq_save();
    MASK = 1;
    (void)PENDING;
    MASK = 0;
    irq_restore(s);
    return 0;
}

static int test2(void)
{
    unsigned base = n_irq, k;

    hmode = M_CTL;
    MASK = 0x0001;
    STAMP(20);
    wait_irq(base + 8, 40);
    CHECK(n_irq == base + 8, 201);
    wait_steps(6);
    CHECK(n_irq == base + 8, 202);
    for (k = base; k < base + 8; k++) {
        CHECK(log1[k] == 0x0001, 203);
        CHECK(log2[k] == 0, 204);
    }
    return 0;
}

static int test3(void)
{
    unsigned base = n_irq;

    MASK = 0x0025;
    STAMP(30);
    wait_irq(base + 1, 10);
    CHECK(n_irq == base + 1, 301);
    wait_steps(4);
    CHECK(n_irq == base + 1, 302);
    CHECK(log1[base] == 0x0025, 303);
    CHECK(log2[base] == 0, 304);
    CHECK(PENDING == 0, 305);
    CHECK(RAW == 0, 306);
    MASK = 0;
    return 0;
}

static int test4(void)
{
    uint32_t s = irq_save();
    unsigned i, r1, r2, r3;

    MASK = 0x0040;
    for (i = 0; i < T4_ITER; i++) {
        STAMP(40);
        (void)RAW;              /* distance for the bench's second pulse */
        (void)RAW;
        (void)RAW;
        (void)RAW;
        r1 = PENDING;
        wait_steps(2);
        r2 = PENDING;
        r3 = PENDING;
        CHECK(r1 == 0x0040, 401);
        CHECK(r2 == 0 || r2 == 0x0040, 402);
        CHECK(r3 == 0, 403);
    }
    STAMP(41);
    MASK = 0;
    irq_restore(s);
    return 0;
}

static int test5(void)
{
    unsigned base = n_irq;

    MASK = 0x0001;
    STAMP(50);
    wait_steps(3);
    CHECK(n_irq == base, 501);
    CHECK(PENDING == 0, 502);
    CHECK(RAW == 0, 503);
    MASK = 0x0081;
    wait_irq(base + 1, 4);
    CHECK(n_irq == base + 1, 504);
    CHECK(log1[base] == 0x0080, 505);
    CHECK(log2[base] == 0, 506);
    MASK = 0;
    return 0;
}

static int test6(void)
{
    unsigned base = n_irq;

    MASK = 0x0100;
    STAMP(60);                  /* bit 8 high, held */
    wait_irq(base + 1, 4);
    CHECK(n_irq == base + 1, 601);
    CHECK(log1[base] == 0x0100, 602);
    CHECK(log2[base] == 0, 603);
    wait_steps(4);
    CHECK(n_irq == base + 1, 604);
    CHECK(RAW == 0x0100, 605);
    CHECK(PENDING == 0, 606);
    STAMP(61);                  /* low */
    wait_steps(2);
    CHECK(RAW == 0, 607);
    CHECK(n_irq == base + 1, 608);
    STAMP(60);                  /* high again: a second event */
    wait_irq(base + 2, 4);
    CHECK(n_irq == base + 2, 609);
    CHECK(log1[base + 1] == 0x0100, 610);
    CHECK(log2[base + 1] == 0, 611);
    STAMP(61);
    wait_steps(2);
    CHECK(RAW == 0, 612);
    CHECK(n_irq == base + 2, 613);
    MASK = 0;
    return 0;
}

static int test7(void)
{
    uint32_t s = irq_save();

    MASK = 0x0200;
    STAMP(70);                  /* bit 9 pulse: pending */
    wait_steps(3);
    CHECK(RAW == 0, 701);
    CHECK(RAW == 0, 702);
    CHECK(RAW == 0, 703);
    PENDING = 0xffff;
    RAW = 0xffff;
    CHECK(MASK == 0x0200, 704);
    CHECK(MODE == 0, 705);
    MASK = 0xffff;
    CHECK(PENDING == 0x0200, 706);  /* still there, and no bit set by the writes */
    CHECK(PENDING == 0, 707);
    MASK = 0;
    irq_restore(s);
    return 0;
}

static int test9(void)
{
    uint32_t s = irq_save();
    unsigned base, k;

    MODE = 0x0200;
    MASK = 0x0200;
    CHECK(PENDING == 0, 901);
    CHECK(!MEIP(), 902);
    STAMP(90);                  /* bit 9 high, held */
    wait_steps(2);
    CHECK(RAW == 0x0200, 903);
    for (k = 0; k < 4; k++) {
        CHECK(PENDING == 0x0200, 904);
        CHECK(MEIP(), 905);
    }
    STAMP(92);                  /* bench: interrupt output 1 */
    /* taken as an interrupt: the handler reads twice and masks it off */
    base = n_irq;
    hmode = M_MASKOFF;
    irq_restore(s);
    wait_irq(base + 1, 4);
    s = irq_save();
    CHECK(n_irq == base + 1, 906);
    CHECK(log1[base] == 0x0200, 907);
    CHECK(log2[base] == 0x0200, 908);
    CHECK(MASK == 0, 909);
    MASK = 0x0200;
    CHECK(PENDING == 0x0200, 910);
    STAMP(91);                  /* low */
    wait_steps(2);
    CHECK(PENDING == 0, 911);
    CHECK(!MEIP(), 912);
    STAMP(93);                  /* bench: interrupt output 0 */
    MASK = 0;
    MODE = 0;
    hmode = M_CTL;
    irq_restore(s);
    return 0;
}

static int test10(void)
{
    uint32_t s = irq_save();

    MASK = 0x0400;
    STAMP(100);                 /* bit 10 high, held */
    wait_steps(2);
    CHECK(PENDING == 0x0400, 1001);  /* EDGE: one event */
    CHECK(PENDING == 0, 1002);
    MODE = 0x0400;              /* -> LEVEL, line high: follows the line */
    CHECK(PENDING == 0x0400, 1003);
    CHECK(PENDING == 0x0400, 1004);
    MODE = 0;                   /* -> EDGE, line high: starts clear */
    CHECK(PENDING == 0, 1005);
    CHECK(!MEIP(), 1006);
    wait_steps(2);
    CHECK(PENDING == 0, 1007);
    CHECK(RAW == 0x0400, 1008);
    STAMP(101);                 /* low, then high: the new edge counts */
    wait_steps(2);
    CHECK(PENDING == 0, 1009);
    STAMP(100);
    wait_steps(2);
    CHECK(PENDING == 0x0400, 1010);
    CHECK(PENDING == 0, 1011);
    STAMP(101);
    wait_steps(2);
    STAMP(102);                 /* pulse: an unread EDGE event, line low */
    wait_steps(2);
    MODE = 0x0400;              /* -> LEVEL: the line (0), the event is gone */
    CHECK(PENDING == 0, 1012);
    MODE = 0;                   /* -> EDGE: still gone */
    CHECK(PENDING == 0, 1013);
    MASK = 0;
    irq_restore(s);
    return 0;
}

static int test11(void)
{
    uint32_t s = irq_save();

    MODE = 0xa5c3;
    CHECK(MODE == 0xa5c3, 1101);
    MODE = 0x5a3c;
    CHECK(MODE == 0x5a3c, 1102);
    MASK = 0x5a3c;
    CHECK(MASK == 0x5a3c, 1103);
    MASK = 0;
    CHECK(MASK == 0, 1104);
    MODE = 0;
    CHECK(MODE == 0, 1105);
    irq_restore(s);
    return 0;
}

static int test12(void)
{
    uint32_t s;
    unsigned base = n_irq;

    /* EDGE: one event for the pin held high */
    hmode = M_CTL;
    MASK = 0x0008;
    STAMP(120);                 /* i2c_ext_int high, held */
    wait_irq(base + 1, 4);
    CHECK(n_irq == base + 1, 1201);
    CHECK(log1[base] == 0x0008, 1202);
    CHECK(log2[base] == 0, 1203);
    wait_steps(4);
    CHECK(n_irq == base + 1, 1204);
    CHECK(RAW == 0x0008, 1205);
    STAMP(121);                 /* low */
    wait_steps(2);
    CHECK(RAW == 0, 1206);
    MASK = 0;

    /* LEVEL: asserted while the pin is high, not cleared by reads */
    s = irq_save();
    MODE = 0x0008;
    MASK = 0x0008;
    CHECK(PENDING == 0, 1207);
    STAMP(120);
    wait_steps(2);
    CHECK(PENDING == 0x0008, 1208);
    CHECK(PENDING == 0x0008, 1209);
    CHECK(MEIP(), 1210);
    STAMP(92);                  /* bench: interrupt output 1 */
    STAMP(121);
    wait_steps(2);
    CHECK(PENDING == 0, 1211);
    CHECK(!MEIP(), 1212);
    STAMP(93);                  /* bench: interrupt output 0 */
    MASK = 0;
    MODE = 0;
    irq_restore(s);
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
    if ((rc = test7()) != 0) return rc;
    if ((rc = test9()) != 0) return rc;
    if ((rc = test10()) != 0) return rc;
    if ((rc = test11()) != 0) return rc;
    if ((rc = test12()) != 0) return rc;
    STAMP(99);
    return 0;
}

int main(void)
{
    int rc = run();
    const char *s = rc ? "FAIL\n" : "PASS\n";

    DisableInterrupts();
    while (*s)
        *(volatile uint8_t *)(int)HB_UART_OFS = (uint8_t)*s++;
    HB_REG(HB_DONE_OFS) = (unsigned)rc;
    for (;;)
        ;
}
