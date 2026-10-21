/* Host producer of the format-parity records (fmt_run.h), fmt_glibc:
 * sprintf of glibc, printf of ../rvlibc.c (over glibc's vsnprintf), the
 * capturing putchar below.  Native and -m32.
 * Records go to stdout with fwrite, never with a printf. */
#include <stdio.h>
#include <string.h>

static void fmt_write(const char *s, size_t n) { fwrite(s, 1, n, stdout); }

#define FMT_SPRINTF sprintf
#define FMT_PRINTF printf

#include "fmt_run.h"

int putchar(int c)
{
    fmt_cap_put(c);
    return c;
}

int main(void)
{
    fmt_run_all();
    return 0;
}
