/* lib_test: rvlibc.c on the host, against glibc's vsnprintf and a mock
 * putchar().  Native and -m32 (make -C fw/ctrl_rv/test lib_test).
 *
 * The format-parity records (fmt_host.c, gold/fmtcheck.py) are the Makefile's
 * `fmt.ok` step; lib_test needs it, so a red parity check fails the build of
 * lib_test.  What this program checks:
 *   - printf/vprintf output and return value equal vsnprintf's
 *   - a line of RV_PRINTF_BUF - 1 bytes passes, longer is cut to exactly
 *     RV_PRINTF_BUF - 1 bytes and counted once, the return value stays the
 *     length vsnprintf wants
 *   - a printf issued from inside putchar (the interrupt handler's Akiko
 *     trace): both lines arrive intact, the second one inside the first, and
 *     the first line is not disturbed; the second uses RV_PRINTF_IRQ_BUF
 *   - the nesting count returns to 0 (the next printf has the full buffer)
 *   - the heap stubs return NULL and count
 * rvlibc.c has no string helpers (README, "String semantics audit"). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rvlibc.h"

void *_malloc_r(void *reent, size_t size);
void *_realloc_r(void *reent, void *ptr, size_t size);
void _free_r(void *reent, void *ptr);

static char out[4096];
static size_t out_n;
static const char *hook_line;   /* printed from inside putchar after hook_after bytes */
static size_t hook_after;
static int hook_armed;
static int hook_ret;

int putchar(int c)
{
    if (out_n < sizeof out - 1)
        out[out_n++] = (char)c;
    out[out_n] = 0;
    if (hook_armed && out_n == hook_after) {
        hook_armed = 0;
        hook_ret = printf("%s", hook_line);
    }
    return c;
}

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "lib_test: FAIL line %d: ", __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        failures++; \
    } \
} while (0)

static void reset(void)
{
    out_n = 0;
    out[0] = 0;
    hook_armed = 0;
}

static int call_vprintf(const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

#define CMP_VSNPRINTF(...) do { \
    char want[160]; \
    int w, g; \
    w = snprintf(want, sizeof want, __VA_ARGS__); \
    reset(); \
    g = printf(__VA_ARGS__); \
    CHECK(g == w, "%s: return %d want %d", #__VA_ARGS__, g, w); \
    CHECK(strcmp(out, want) == 0, "%s: out '%s' want '%s'", #__VA_ARGS__, out, want); \
    reset(); \
    g = call_vprintf(__VA_ARGS__); \
    CHECK(g == w && strcmp(out, want) == 0, "vprintf %s: '%s' (%d)", #__VA_ARGS__, out, g); \
} while (0)

static void test_equals_vsnprintf(void)
{
    CMP_VSNPRINTF("plain\r\n");
    CMP_VSNPRINTF("%d|%d", -12, 7);
    CMP_VSNPRINTF("%08lX", 0xABCDEFUL);
    CMP_VSNPRINTF("%.3s|%5d", "abcdef", 7);
    CMP_VSNPRINTF("%u %x", 0x80000000U, 0x80000000U);
    CMP_VSNPRINTF("%s", "");
}

static void test_overflow(void)
{
    static char line[RV_PRINTF_BUF + 64];
    unsigned int before;
    int n;
    size_t i;

    for (i = 0; i < sizeof line - 1; i++)
        line[i] = (char)('a' + i % 26);

    /* RV_PRINTF_BUF - 1 bytes fit */
    line[RV_PRINTF_BUF - 1] = 0;
    reset();
    before = rv_printf_truncations;
    n = printf("%s", line);
    CHECK(n == RV_PRINTF_BUF - 1, "fit: return %d", n);
    CHECK(out_n == RV_PRINTF_BUF - 1 && memcmp(out, line, out_n) == 0, "fit: out %zu bytes", out_n);
    CHECK(rv_printf_truncations == before, "fit: counter moved");

    /* RV_PRINTF_BUF bytes do not: the prefix of RV_PRINTF_BUF - 1 bytes, once */
    line[RV_PRINTF_BUF - 1] = (char)('a' + (RV_PRINTF_BUF - 1) % 26);
    line[RV_PRINTF_BUF] = 0;
    reset();
    before = rv_printf_truncations;
    n = printf("%s", line);
    CHECK(n == RV_PRINTF_BUF, "cut: return %d", n);
    CHECK(out_n == RV_PRINTF_BUF - 1 && memcmp(out, line, out_n) == 0, "cut: out %zu bytes", out_n);
    CHECK(rv_printf_truncations == before + 1, "cut: counter %u -> %u", before, rv_printf_truncations);

    /* much longer: still the same prefix, counted once */
    line[RV_PRINTF_BUF] = (char)('a' + RV_PRINTF_BUF % 26);
    line[RV_PRINTF_BUF + 60] = 0;
    reset();
    before = rv_printf_truncations;
    n = printf("%s", line);
    CHECK(n == RV_PRINTF_BUF + 60, "long: return %d", n);
    CHECK(out_n == RV_PRINTF_BUF - 1 && memcmp(out, line, out_n) == 0, "long: out %zu bytes", out_n);
    CHECK(rv_printf_truncations == before + 1, "long: counter");
}

static void test_nested(void)
{
    static const char first[] = "Main line, kept intact: 0123456789\r\n";
    static const char irq[] = "Akiko read: 1A2B\n";
    size_t flen = strlen(first), k;
    static const size_t points[] = { 1, 5, 20 };
    size_t pi;
    char want[256];
    unsigned int before = rv_printf_truncations;

    for (pi = 0; pi < sizeof points / sizeof points[0] + 1; pi++) {
        k = pi < sizeof points / sizeof points[0] ? points[pi] : flen;
        reset();
        hook_line = irq;
        hook_after = k;
        hook_armed = 1;
        hook_ret = -99;
        printf("%s", first);
        memcpy(want, first, k);
        memcpy(want + k, irq, strlen(irq));
        memcpy(want + k + strlen(irq), first + k, flen - k + 1);
        CHECK(strcmp(out, want) == 0, "nested after %zu: '%s'", k, out);
        CHECK(hook_ret == (int)strlen(irq), "nested return %d", hook_ret);
    }
    CHECK(rv_printf_truncations == before, "nested: counter moved");

    /* the nested line uses the smaller buffer: RV_PRINTF_IRQ_BUF - 1 bytes fit,
     * one more is cut and counted; the interrupted line is intact either way */
    {
        static char big[RV_PRINTF_IRQ_BUF + 8];
        memset(big, 'Z', sizeof big - 1);
        big[RV_PRINTF_IRQ_BUF] = 0;
        reset();
        hook_line = big;
        hook_after = 3;
        hook_armed = 1;
        printf("%s", "ABCDEF");
        CHECK(memcmp(out, "ABC", 3) == 0 && memcmp(out + 3, big, RV_PRINTF_IRQ_BUF - 1) == 0
              && strcmp(out + 3 + RV_PRINTF_IRQ_BUF - 1, "DEF") == 0,
              "nested cut: '%s'", out);
        CHECK(rv_printf_truncations == before + 1, "nested cut: counter %u", rv_printf_truncations);
    }

    /* the nesting count is back to 0: a line longer than the IRQ buffer
     * passes whole */
    {
        static char mid[RV_PRINTF_IRQ_BUF + 20];
        memset(mid, 'Y', sizeof mid - 1);
        reset();
        printf("%s", mid);
        CHECK(strcmp(out, mid) == 0, "after nested: line cut to %zu", out_n);
    }
}

static void test_heap_stubs(void)
{
    unsigned int before = rv_libc_heap_calls;
    CHECK(_malloc_r(NULL, 16) == NULL, "_malloc_r");
    CHECK(_realloc_r(NULL, NULL, 16) == NULL, "_realloc_r");
    _free_r(NULL, NULL);
    CHECK(rv_libc_heap_calls == before + 3, "heap calls %u", rv_libc_heap_calls - before);
}

int main(void)
{
    test_equals_vsnprintf();
    test_overflow();
    test_nested();
    test_heap_stubs();
    if (failures) {
        fprintf(stderr, "lib_test: %d FAILED\n", failures);
        return 1;
    }
    fprintf(stderr, "lib_test: PASS (%d-bit)\n", (int)(8 * sizeof(void *)));
    return 0;
}
