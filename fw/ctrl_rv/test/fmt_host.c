/* Host producer of the format-parity records (fmt_run.h).
 *   fmt_glibc: sprintf of glibc, printf of ../rvlibc.c (over glibc's
 *              vsnprintf), the capturing putchar below.  Native and -m32.
 *   fmt_832:   -DFMT_REF832, the same cases through lib832's small_printf.c
 *              (the 832's printf, compiled -std=gnu17 -m32 with the renames of
 *              the Makefile) and its putchar capture.
 * Records go to stdout with fwrite, never with a printf. */
#include <stdio.h>
#include <string.h>

static void fmt_write(const char *s, size_t n) { fwrite(s, 1, n, stdout); }

#ifdef FMT_REF832
int ref832_printf(const char *fmt, ...);
int ref832_sprintf(char *buf, const char *fmt, ...);
#define FMT_SPRINTF ref832_sprintf
#define FMT_PRINTF ref832_printf
#else
#define FMT_SPRINTF sprintf
#define FMT_PRINTF printf
#endif

#include "fmt_run.h"

#ifdef FMT_REF832
int ref832_putchar(int c)
#else
int putchar(int c)
#endif
{
    fmt_cap_put(c);
    return c;
}

int main(void)
{
    fmt_run_all();
    return 0;
}
