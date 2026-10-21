/* refill: I$ line refills under direct-mapped conflicts.
 *
 * 24 functions of 244 bytes, each aligned to 256 bytes (6 KB, more than the
 * 4 KB direct-mapped I$), once in .text (SDRAM region, latency WS) and once
 * in .text.rom (0x100, ROM region, latency ROMWS).  Each body is 40 pairs of
 * a 4-byte and a 2-byte addi, so 4-byte instructions straddle words and
 * 32-byte lines.  Every round calls each function twice: in address order,
 * then ping-ponging between functions k and k + 16, exactly 4 KB apart: all
 * eight I$ lines of one evict the other's.  A wrong word in any refill
 * changes the sum.
 * Exit code: 0 = pass, 1 = SDRAM set wrong, 2 = ROM set wrong. */
#include "l1.h"

#define ROUNDS 3
#define NFUNC  24

/* f_k returns k + 40 * ((k + 100) + (k + 1)) */
#define FVAL(k) ((k) + 40 * (((k) + 100) + ((k) + 1)))

#define FDEF(pfx, sec, k)                                                  \
    __attribute__((noinline, aligned(256), section(sec)))                  \
    static int pfx##k(void)                                                \
    {                                                                      \
        int v = (k);                                                       \
        __asm__ volatile(".rept 40\n\t"                                    \
                         "addi %0, %0, %1\n\t" /* imm > 31: 4 bytes */     \
                         "addi %0, %0, %2\n\t" /* c.addi: 2 bytes   */     \
                         ".endr"                                           \
                         : "+r"(v)                                         \
                         : "i"((k) + 100), "i"((k) + 1));                  \
        return v;                                                          \
    }

#define FSET(pfx, sec)                                                       \
    FDEF(pfx, sec, 0)  FDEF(pfx, sec, 1)  FDEF(pfx, sec, 2)  FDEF(pfx, sec, 3)  \
    FDEF(pfx, sec, 4)  FDEF(pfx, sec, 5)  FDEF(pfx, sec, 6)  FDEF(pfx, sec, 7)  \
    FDEF(pfx, sec, 8)  FDEF(pfx, sec, 9)  FDEF(pfx, sec, 10) FDEF(pfx, sec, 11) \
    FDEF(pfx, sec, 12) FDEF(pfx, sec, 13) FDEF(pfx, sec, 14) FDEF(pfx, sec, 15) \
    FDEF(pfx, sec, 16) FDEF(pfx, sec, 17) FDEF(pfx, sec, 18) FDEF(pfx, sec, 19) \
    FDEF(pfx, sec, 20) FDEF(pfx, sec, 21) FDEF(pfx, sec, 22) FDEF(pfx, sec, 23)

#define FTAB(pfx)                                                             \
    { pfx##0,  pfx##1,  pfx##2,  pfx##3,  pfx##4,  pfx##5,  pfx##6,  pfx##7,  \
      pfx##8,  pfx##9,  pfx##10, pfx##11, pfx##12, pfx##13, pfx##14, pfx##15, \
      pfx##16, pfx##17, pfx##18, pfx##19, pfx##20, pfx##21, pfx##22, pfx##23 }

FSET(fs_, ".text.sdram")
FSET(fr_, ".text.rom")

typedef int (*fn_t)(void);
static fn_t const tab_sdram[NFUNC] = FTAB(fs_);
static fn_t const tab_rom[NFUNC]   = FTAB(fr_);

/* address order, then the 4 KB conflict pairs (k, k + 16) back to back
 * (256-byte stride: function k + 16 is 4096 bytes after function k) */
static const unsigned char order[2 * NFUNC] = {
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11,
    12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    0,  16, 1,  17, 2,  18, 3,  19, 4,  20, 5,  21,
    6,  22, 7,  23, 8,  9,  10, 11, 12, 13, 14, 15,
};

#define FSUM                                                                  \
    (FVAL(0) + FVAL(1) + FVAL(2) + FVAL(3) + FVAL(4) + FVAL(5) + FVAL(6) +    \
     FVAL(7) + FVAL(8) + FVAL(9) + FVAL(10) + FVAL(11) + FVAL(12) +           \
     FVAL(13) + FVAL(14) + FVAL(15) + FVAL(16) + FVAL(17) + FVAL(18) +        \
     FVAL(19) + FVAL(20) + FVAL(21) + FVAL(22) + FVAL(23))

/* computed by the compiler: each function twice per round */
static const int expected = ROUNDS * 2 * FSUM;
_Static_assert(ROUNDS * 2 * FSUM == 715896, "expected sum");

static int run(fn_t const *tab)
{
    int sum = 0;
    for (int r = 0; r < ROUNDS; r++)
        for (unsigned i = 0; i < sizeof(order); i++)
            sum += tab[order[i]]();
    return sum;
}

_Static_assert(NFUNC * 256 <= 0x2000 - 0x100, ".text.rom fits below 0x2000");

int main(void)
{
    if (run(tab_sdram) != expected)
        return 1;
    if (run(tab_rom) != expected)
        return 2;
    return 0;
}
