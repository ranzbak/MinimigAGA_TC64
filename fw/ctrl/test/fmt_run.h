/* Format-parity runner, shared by the producers (fmt_host.c as fmt_glibc,
 * rv/fmt_rv.c).  Header-only; the includer defines, before
 * including it:
 *   FMT_SPRINTF(buf, fmt, ...)  the sprintf under test
 *   FMT_PRINTF(fmt, ...)        the printf under test
 *   fmt_write(const char *s, size_t n)   one piece of the record text
 * and its putchar() calls fmt_cap_put(c).
 *
 * Every case of fmt_cases.h runs as sprintf and as printf, and gives
 *   FMT <n> C fmt=<hex> args=<hex>
 *   FMT <n> S ret=<r> buf=<hex> side=<hex>   side: bytes that reached putchar
 *                                             during the sprintf
 *   FMT <n> P ret=<r> out=<hex>              out: bytes that reached putchar
 * Text, written by the includer's fmt_write, never by a printf.
 *
 *
 * With FMT_DIGEST (the L1 bench) no record is written but one line per S and
 * P record,
 *   FMT <n> S h=<8 hex digits>   (and P)
 * h = 32-bit FNV-1a over: ret as decimal text, 0, the bytes of buf (S) or out
 * (P), 0, and for S the bytes of side, 0.  `gold/fmtcheck.py digest` makes the
 * same lines from a full record file.  With FMT_SUBSET (a case costs about
 * 30,000 cycles there and iverilog simulates about 5,500 cycles a second) only
 * the first and the last case of each run of equal format strings are run
 * (`fmtcheck.py digest --subset`). */
#ifndef FMT_RUN_H
#define FMT_RUN_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* argument types of the cases: 32 bits wherever the RV32 has them, so that
 * the LP64 host run prints what ILP32 prints */
#define I(x)  ((int)(x))
#define U(x)  ((unsigned int)(x))
#define L(x)  ((long)(int32_t)(x))
#define UL(x) ((unsigned long)(uint32_t)(x))

#define FMT_CAP_MAX 2048
static unsigned char fmt_cap[FMT_CAP_MAX];
static size_t fmt_cap_n;

static void fmt_cap_put(int c)
{
    if (fmt_cap_n < FMT_CAP_MAX)
        fmt_cap[fmt_cap_n++] = (unsigned char)c;
}

static void fmt_str(const char *s) { fmt_write(s, strlen(s)); }

#ifndef FMT_DIGEST
static void fmt_hex(const unsigned char *p, size_t n)
{
    static const char d[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < n; i++) {
        char two[2];
        two[0] = d[p[i] >> 4];
        two[1] = d[p[i] & 15];
        fmt_write(two, 2);
    }
}
#endif

static void fmt_dec(long v)
{
    char t[16];
    int n = 0;
    unsigned long u = v < 0 ? 0UL - (unsigned long)v : (unsigned long)v;
    if (v < 0)
        fmt_write("-", 1);
    do {
        t[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    while (n)
        fmt_write(&t[--n], 1);
}

/* cases: three passes over fmt_cases.h */
#define FMT_PASTE2(a, b) a##b
#define FMT_PASTE(a, b) FMT_PASTE2(a, b)

#define FMT_CASE(fmt, ...) \
    static int FMT_PASTE(fmt_s_, __LINE__)(char *b) { return FMT_SPRINTF(b, fmt __VA_OPT__(,) __VA_ARGS__); } \
    static int FMT_PASTE(fmt_p_, __LINE__)(void) { return FMT_PRINTF(fmt __VA_OPT__(,) __VA_ARGS__); }
#include "fmt_cases.h"
#undef FMT_CASE

struct fmt_case {
    const char *fmt;
    const char *args;
    int (*s)(char *);
    int (*p)(void);
};

#define FMT_CASE(fmt, ...) \
    { fmt, #__VA_ARGS__, FMT_PASTE(fmt_s_, __LINE__), FMT_PASTE(fmt_p_, __LINE__) },
static const struct fmt_case fmt_cases[] = {
#include "fmt_cases.h"
};
#undef FMT_CASE

#define FMT_NCASES (sizeof fmt_cases / sizeof fmt_cases[0])

static void fmt_record(size_t n, const char *kind)
{
    fmt_str("FMT ");
    fmt_dec((long)n);
    fmt_str(" ");
    fmt_str(kind);
}

#ifdef FMT_DIGEST
static uint32_t fmt_hash;

static void h_byte(unsigned char c)
{
    fmt_hash ^= c;
    fmt_hash *= 16777619u;
}

static void h_bytes(const unsigned char *p, size_t n)
{
    while (n--)
        h_byte(*p++);
    h_byte(0);
}

static void h_dec(long v)
{
    char t[16];
    int n = 0;
    unsigned long u = v < 0 ? 0UL - (unsigned long)v : (unsigned long)v;
    if (v < 0)
        h_byte('-');
    do {
        t[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    while (n)
        h_byte((unsigned char)t[--n]);
    h_byte(0);
}

static void fmt_digest_line(size_t n, const char *kind)
{
    static const char d[] = "0123456789abcdef";
    char h[8];
    int i;
    for (i = 0; i < 8; i++)
        h[i] = d[(fmt_hash >> (28 - 4 * i)) & 15];
    fmt_record(n, kind);
    fmt_str(" h=");
    fmt_write(h, 8);
    fmt_str("\n");
}

#ifdef FMT_SUBSET
/* run case n: the first or the last of a run of equal format strings */
static int fmt_selected(size_t n)
{
    return n == 0 || n + 1 == FMT_NCASES
        || strcmp(fmt_cases[n].fmt, fmt_cases[n - 1].fmt) != 0
        || strcmp(fmt_cases[n].fmt, fmt_cases[n + 1].fmt) != 0;
}
#endif
#endif

static void fmt_run_all(void)
{
    static char buf[1024];
    size_t n;

    for (n = 0; n < FMT_NCASES; n++) {
        const struct fmt_case *c = &fmt_cases[n];
        size_t len;
        int ret;

#ifdef FMT_DIGEST
#ifdef FMT_SUBSET
        if (!fmt_selected(n))
            continue;
#endif
#else
        fmt_record(n, "C fmt=");
        fmt_hex((const unsigned char *)c->fmt, strlen(c->fmt));
        fmt_str(" args=");
        fmt_hex((const unsigned char *)c->args, strlen(c->args));
        fmt_str("\n");
#endif

        memset(buf, 0xAA, sizeof buf);
        fmt_cap_n = 0;
        ret = c->s(buf);
        for (len = 0; len < sizeof buf && buf[len]; len++)
            ;
#ifdef FMT_DIGEST
        fmt_hash = 2166136261u;
        h_dec(ret);
        h_bytes((const unsigned char *)buf, len);
        h_bytes(fmt_cap, fmt_cap_n);
        fmt_digest_line(n, "S");
#else
        fmt_record(n, "S ret=");
        fmt_dec(ret);
        fmt_str(" buf=");
        fmt_hex((const unsigned char *)buf, len);
        fmt_str(" side=");
        fmt_hex(fmt_cap, fmt_cap_n);
        fmt_str("\n");
#endif

        fmt_cap_n = 0;
        ret = c->p();
#ifdef FMT_DIGEST
        fmt_hash = 2166136261u;
        h_dec(ret);
        h_bytes(fmt_cap, fmt_cap_n);
        fmt_digest_line(n, "P");
#else
        fmt_record(n, "P ret=");
        fmt_dec(ret);
        fmt_str(" out=");
        fmt_hex(fmt_cap, fmt_cap_n);
        fmt_str("\n");
#endif
    }
}

#endif
