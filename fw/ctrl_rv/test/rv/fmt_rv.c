/* fmt_rv: the format-parity cases (fmt_run.h) on the RISC-V target libc, plus
 * newlib-nano's mem and str functions at every source/destination alignment, run on the
 * L1 bench (sim/rv_l1/run.sh fmt).
 *
 * rvlibc.c (printf, vprintf, heap stubs) and newlib-nano's sprintf are linked
 * as in the firmware; this program defines the capturing putchar() and writes
 * its output with l1_putc(), never through printf.  A misaligned access traps
 * (VexRiscv), which ends the run with "=== FAIL 80xx" (crt0_l1.S).
 * Output: one "FMT <n> S|P h=<digest>" line per record (fmt_run.h, FMT_DIGEST:
 * `fmtcheck.py digest` makes the same lines from the host's full records), then
 * "MEMSTR ..." and "HEAP ..." lines, then "PASS" or "FAIL ...". */
#define FMT_DIGEST 1
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "l1.h"
#include "rvlibc.h"

static void fmt_write(const char *s, size_t n)
{
    while (n--)
        l1_putc(*s++);
}

#define FMT_SPRINTF sprintf
#define FMT_PRINTF printf
int sprintf(char *, const char *, ...);
int printf(const char *, ...);

#include "../fmt_run.h"

int putchar(int c)
{
    fmt_cap_put(c);
    return c;
}

static int fails;

static void say(const char *s) { fmt_str(s); }

static void bad(const char *what, unsigned a, unsigned b, unsigned n)
{
    say("MEMSTR FAIL ");
    say(what);
    say(" src+");
    fmt_dec(a);
    say(" dst+");
    fmt_dec(b);
    say(" n=");
    fmt_dec(n);
    say("\n");
    fails++;
}

/* reference loops: byte at a time, volatile so that the compiler leaves them
 * alone */
static void ref_copy(volatile unsigned char *d, const volatile unsigned char *s, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
        d[i] = s[i];
}

#define BUFN 64
static unsigned char A[BUFN] __attribute__((aligned(4)));
static unsigned char B[BUFN] __attribute__((aligned(4)));
static unsigned char R[BUFN] __attribute__((aligned(4)));

static void fill(unsigned char *p, unsigned seed)
{
    unsigned i;
    for (i = 0; i < BUFN; i++)
        p[i] = (unsigned char)((i * 37 + seed * 11 + 5) | 1);   /* never 0 */
}

static void mem_tests(void)
{
    /* lengths around the word and the unrolled-loop sizes of newlib's versions */
    static const unsigned lens[] = { 0, 1, 3, 4, 5, 8, 9, 17 };
    static const unsigned shifts[] = { 1, 3, 4, 7 };
    unsigned sa, da, n, k, li, ki;

    for (sa = 0; sa < 4; sa++)
        for (da = 0; da < 4; da++)
            for (li = 0; li < sizeof lens / sizeof lens[0]; li++) {
                n = lens[li];
                /* memcpy */
                fill(A, 1); fill(B, 2); fill(R, 2);
                ref_copy(R + 8 + da, A + 8 + sa, n);
                memcpy(B + 8 + da, A + 8 + sa, n);
                if (memcmp(B, R, BUFN)) bad("memcpy", sa, da, n);

                /* memmove, no overlap */
                fill(A, 1); fill(B, 2); fill(R, 2);
                ref_copy(R + 8 + da, A + 8 + sa, n);
                memmove(B + 8 + da, A + 8 + sa, n);
                if (memcmp(B, R, BUFN)) bad("memmove", sa, da, n);

                /* memset */
                fill(B, 2); fill(R, 2);
                for (k = 0; k < n; k++)
                    R[8 + da + k] = 0xA5;
                memset(B + 8 + da, 0xA5, n);
                if (memcmp(B, R, BUFN)) bad("memset", sa, da, n);

                /* memcmp: equal, then the last byte one above and one below */
                fill(A, 1); fill(B, 7);
                ref_copy(B + da, A + sa, n);
                if (memcmp(A + sa, B + da, n)) bad("memcmp equal", sa, da, n);
                if (n) {
                    unsigned char last = A[sa + n - 1];
                    B[da + n - 1] = (unsigned char)(last - 1);
                    if (memcmp(A + sa, B + da, n) <= 0) bad("memcmp greater", sa, da, n);
                    if (last < 255) {
                        B[da + n - 1] = (unsigned char)(last + 1);
                        if (memcmp(A + sa, B + da, n) >= 0) bad("memcmp less", sa, da, n);
                    }
                }

                /* strlen, strcmp, strncmp, strncat, strncpy on a string of length n */
                fill(A, 3);
                A[sa + n] = 0;
                if (strlen((char *)A + sa) != n) bad("strlen", sa, da, n);
                fill(B, 3);
                ref_copy(B + da, A + sa, n + 1);
                if (strcmp((char *)A + sa, (char *)B + da)) bad("strcmp equal", sa, da, n);
                if (strncmp((char *)A + sa, (char *)B + da, n + 5)) bad("strncmp equal", sa, da, n);
                if (n) {
                    B[da + n - 1] ^= 0x01;
                    if (strcmp((char *)A + sa, (char *)B + da) == 0) bad("strcmp differs", sa, da, n);
                    if (strncmp((char *)A + sa, (char *)B + da, n) == 0) bad("strncmp differs", sa, da, n);
                    if (strncmp((char *)A + sa, (char *)B + da, n - 1)) bad("strncmp prefix", sa, da, n);
                }
                fill(B, 5); fill(R, 5);
                B[da] = 'x'; B[da + 1] = 0; R[da] = 'x'; R[da + 1] = 0;
                ref_copy(R + da + 1, A + sa, n + 1);
                strncat((char *)B + da, (char *)A + sa, n + 4);
                if (memcmp(B, R, BUFN)) bad("strncat", sa, da, n);
                fill(B, 4); fill(R, 4);
                ref_copy(R + 8 + da, A + sa, n + 1);
                for (k = n + 1; k < n + 9; k++)
                    R[8 + da + k] = 0;         /* newlib pads with NULs */
                strncpy((char *)B + 8 + da, (char *)A + sa, n + 9);
                if (memcmp(B, R, BUFN)) bad("strncpy", sa, da, n);
            }

    /* memmove overlapping: the destination above and below the source */
    for (sa = 0; sa < 4; sa++)
        for (li = 1; li < sizeof lens / sizeof lens[0]; li++) {
                n = lens[li];
                for (ki = 0; ki < sizeof shifts / sizeof shifts[0]; ki++) {
                    k = shifts[ki];
                    /* forward overlap: dst = src + k */
                    fill(A, 5); fill(R, 5);
                    for (size_t i = n; i-- > 0;)
                        R[8 + sa + k + i] = R[8 + sa + i];
                    memmove(A + 8 + sa + k, A + 8 + sa, n);
                    if (memcmp(A, R, BUFN)) bad("memmove dst>src", sa, k, n);
                    /* backward overlap: dst = src - k */
                    fill(A, 6); fill(R, 6);
                    for (size_t i = 0; i < n; i++)
                        R[8 + sa + i] = R[8 + sa + k + i];
                    memmove(A + 8 + sa, A + 8 + sa + k, n);
                    if (memcmp(A, R, BUFN)) bad("memmove dst<src", sa, k, n);
                }
            }
}

int main(void)
{
    fmt_run_all();

    mem_tests();
    say(fails ? "MEMSTR failures " : "MEMSTR ok, failures ");
    fmt_dec(fails);
    say("\n");

    say("HEAP calls=");
    fmt_dec((long)rv_libc_heap_calls);
    say("\n");
    if (rv_libc_heap_calls)
        fails++;

    say(fails ? "FAIL\n" : "PASS\n");
    return fails ? 1 : 0;
}
