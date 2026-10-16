/* Dhrystone for the RISC-V host CPU: UART output, TIMER, and the few C
 * library functions Dhrystone needs (the build is freestanding, -nostdlib).
 * See hw.h. */
#include <stdarg.h>
#include <stddef.h>
#include "hw.h"

/* No TX-ready poll: rtl/host/cfide.vhd has no such bit.  A 16-bit read of
   0xFFFFFFF0 returns the SPI data register (IOdata <= sd_in), so a poll on bit
   8 would spin forever; a write is held (no ack) until the transmitter is free,
   so no character is lost (sim/host_bridge/README.md, "The UART costs ..."). */
static void hw_putc(int c)
{
    *(volatile unsigned char *)HW_UART_ADDR = (unsigned char)c;
}

#ifndef L1
/* Milliseconds since the first call: the 16-bit TIMER difference is
   accumulated, so a wrap between two calls (380 s) costs nothing as long as
   the calls are closer than that. */
long hw_ms(void)
{
    static unsigned last, acc, started;
    unsigned now = *(volatile unsigned short *)HW_TIMER_ADDR;
    if (!started) { started = 1; last = now; }
    acc += (now - last) & 0xFFFF;
    last = now;
    return (long)((unsigned long long)acc * HW_TIMER_US / 1000);
}
#endif

/* ---- printf: %d %i %u %x %c %s %%, l/h/z modifiers ignored, no width */
static void put_num(unsigned long v, unsigned base, int neg)
{
    char buf[12];
    int n = 0;
    do { buf[n++] = "0123456789abcdef"[v % base]; v /= base; } while (v);
    if (neg) hw_putc('-');
    while (n) hw_putc(buf[--n]);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int count = 0;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { hw_putc(*fmt); count++; continue; }
        fmt++;
        while (*fmt == 'l' || *fmt == 'h' || *fmt == 'z') fmt++;
        switch (*fmt) {
        case 'd': case 'i': {
            int v = va_arg(ap, int);
            put_num(v < 0 ? -(unsigned long)v : (unsigned long)v, 10, v < 0);
            break; }
        case 'u': put_num(va_arg(ap, unsigned), 10, 0); break;
        case 'x': put_num(va_arg(ap, unsigned), 16, 0); break;
        case 'c': hw_putc(va_arg(ap, int)); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            while (*s) hw_putc(*s++);
            break; }
        case '%': hw_putc('%'); break;
        default: hw_putc('%'); hw_putc(*fmt); break;
        }
        count++;
    }
    va_end(ap);
    return count;
}

/* ---- string functions (byte loops; compiled with the benchmark's -O level) */
char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++))
        ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

/* gcc turns copy loops into calls to memcpy/memset: not in these two */
__attribute__((optimize("no-tree-loop-distribute-patterns")))
void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

__attribute__((optimize("no-tree-loop-distribute-patterns")))
void *memset(void *d, int c, size_t n)
{
    unsigned char *dp = d;
    while (n--) *dp++ = (unsigned char)c;
    return d;
}
