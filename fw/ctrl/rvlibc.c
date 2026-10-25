/* rvlibc: printf/vprintf over newlib-nano's vsnprintf, and the heap stubs.
 * No stdio FILE layer, no heap, no syscalls (README, "C library"). */
#include <stdarg.h>
#include <stdio.h>
#include "rvlibc.h"

volatile unsigned int rv_printf_truncations;
volatile unsigned int rv_libc_heap_calls;

static char printf_buf[RV_PRINTF_BUF];
static char printf_irq_buf[RV_PRINTF_IRQ_BUF];

/* Number of vprintf calls that are formatting or sending right now.  A call
 * that starts while another is in progress (the interrupt handler runs
 * between two bytes of the interrupted line) must not touch that call's
 * buffer, so it takes the second one.  The handler runs with MIE clear, so
 * the nesting is one level deep; deeper calls would share the second buffer. */
static volatile unsigned int printf_depth;

int vprintf(const char *fmt, va_list ap)
{
    unsigned int depth = printf_depth;
    char *buf = depth ? printf_irq_buf : printf_buf;
    size_t size = depth ? sizeof printf_irq_buf : sizeof printf_buf;
    size_t send;
    size_t i;
    int n;

    printf_depth = depth + 1;
    n = vsnprintf(buf, size, fmt, ap);
    if (n < 0) {
        send = 0;
    } else if ((size_t)n >= size) {
        send = size - 1;
        rv_printf_truncations++;
    } else {
        send = (size_t)n;
    }
    for (i = 0; i < send; i++)
        putchar((unsigned char)buf[i]);
    printf_depth = depth;
    return n;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

/* newlib-nano's vsnprintf references these for the asprintf/open_memstream
 * case, which a fixed buffer never takes.  Defined so that no allocator (and
 * with it _sbrk) is linked. */
void *_malloc_r(void *reent, size_t size)
{
    (void)reent;
    (void)size;
    rv_libc_heap_calls++;
    return NULL;
}

void *_realloc_r(void *reent, void *ptr, size_t size)
{
    (void)reent;
    (void)ptr;
    (void)size;
    rv_libc_heap_calls++;
    return NULL;
}

void _free_r(void *reent, void *ptr)
{
    (void)reent;
    (void)ptr;
    rv_libc_heap_calls++;
}
