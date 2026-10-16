/* fwtest: the test firmware of the L2 boot run (RV32OSDA.BIN).
 *
 * The committed boot ROM (fw/ctrl_boot_rv) loads this image from the SD card
 * model to 0x2000 through dBus + hostcache, runs fence.i and jumps to
 * _start (fw/ctrl_rv/arch/crt0.S).  main then prints:
 *   FW OK                  the image runs: the load, the be32() byte order
 *                          of spi.c and fence.i all worked
 *   PAT 0011..EEFF         fw_pattern[] read byte by byte from SDRAM; the
 *                          bytes must be in file order (exit code 1 if the
 *                          word view is not little-endian 0x33221100 ..)
 *   IMG <len> <sum>        length and 32-bit word sum of .text + .rodata
 *                          (0x2000 .. __init_array_start) as loaded; run.sh
 *                          compares it with the sum of the same bytes of
 *                          the file (build/img.txt)
 *   IRQ <n>                the t_irq check (sim/host_bridge/sw/t_irq.c)
 *                          with cfide's vbl_int: 20 pulses, 20 handler
 *                          calls (exit code 2 / 3 otherwise)
 * then writes DONE with the exit code.  fw_fill (fwfill.S) is 1280 bytes of
 * .rodata so that the image spans three FAT clusters (2 sectors each on the
 * 8 MB card): the boot ROM must follow the cluster chain. */
#include <stdint.h>
#include "hb.h"
#include "irq.h"

#define NPULSE 20
#define HB_REG(ofs) (*(volatile unsigned int *)(int)(ofs))
#define TIMER()     (HB_REG(HB_TIMER_OFS) & 0xffffu)

void rv_putc(int c);                    /* fw/ctrl_rv/arch/trap.c: cfide UART */

extern const char _start[], __init_array_start[];
extern const volatile uint32_t fw_fill[];

/* Bytes 00 11 22 .. FF in file order.  volatile: every read goes to memory. */
static const volatile uint8_t fw_pattern[16] __attribute__((aligned(4))) = {
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
};

static volatile unsigned n_irq;

static void puts_(const char *s)
{
    while (*s)
        rv_putc(*s++);
}

static void puthex(uint32_t v, int digits)
{
    while (digits--)
        rv_putc("0123456789ABCDEF"[(v >> (4 * digits)) & 15]);
}

static void putdec(unsigned v)
{
    char b[10];
    int n = 0;

    do
        b[n++] = (char)('0' + v % 10);
    while (v /= 10);
    while (n)
        rv_putc(b[--n]);
}

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

static int check_pattern(void)
{
    const volatile uint32_t *w = (const volatile uint32_t *)fw_pattern;
    int i;

    puts_("PAT ");
    for (i = 0; i < 16; i++)
        puthex(fw_pattern[i], 2);
    rv_putc('\n');
    return w[0] == 0x33221100u && w[1] == 0x77665544u &&
           w[2] == 0xBBAA9988u && w[3] == 0xFFEEDDCCu;
}

static void image_sum(void)
{
    const volatile uint32_t *p = (const volatile uint32_t *)_start;
    const volatile uint32_t *e = (const volatile uint32_t *)__init_array_start;
    uint32_t sum = fw_fill[0] & 0;      /* keeps fw_fill linked */

    while (p < e)
        sum += *p++;
    puts_("IMG ");
    puthex((uint32_t)(__init_array_start - _start), 8);
    rv_putc(' ');
    puthex(sum, 8);
    rv_putc('\n');
}

static int irq_check(void)
{
    int rc = 0;

    SetIntHandler(handler);
    EnableInterrupts();
    HB_REG(HB_TIME_OFS) = 1;            /* bench: start the vbl_int pulses */
    wait_timer(NPULSE, 100);
    if (n_irq != NPULSE)
        rc = 2;
    else {
        wait_timer(NPULSE + 1, 6);
        if (n_irq != NPULSE)
            rc = 3;
    }
    HB_REG(HB_TIME_OFS) = 2;            /* bench: all pulses sent */
    DisableInterrupts();
    puts_("IRQ ");
    putdec(n_irq);
    rv_putc('\n');
    return rc;
}

int main(void)
{
    int rc, irq_rc;

    puts_("FW OK\n");
    rc = check_pattern() ? 0 : 1;
    image_sum();
    irq_rc = irq_check();
    if (!rc)
        rc = irq_rc;
    HB_REG(HB_DONE_OFS) = (unsigned)rc;
    for (;;)
        ;
}
