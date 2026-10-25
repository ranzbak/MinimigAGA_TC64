/* mock_int.h: what mock_hw.c (the card, the clock, the TIMER, cfide's SPI)
 * and mock_sdc.c (the SD peripheral, the Gayle bridge, the interrupt
 * controller) share.  Not for tests: they use mock_hw.h. */
#ifndef MOCK_INT_H
#define MOCK_INT_H

#include <stddef.h>

/* mock_hw.c */
struct buf { unsigned char *p; size_t n, cap; };    /* growing byte buffer */
void mock_die(const char *what);
void mock_buf_put(struct buf *b, const void *d, size_t n);
const char *mock_buf_str(struct buf *b);
unsigned mock_crc16(unsigned c, unsigned char b);
unsigned char mock_card_xchg_sdc(unsigned char out);   /* one byte with the card, from the peripheral */
void mock_card_sel_update(void);                        /* after the peripheral's CS changed */
void mock_time_cycles(unsigned long long c);            /* time passes, in clk_114 cycles */
void mock_time_counts(unsigned n);                      /* time passes, in TIMER counts */

/* mock_sdc.c */
void mock_sdc_run(unsigned long long until);            /* the peripheral up to that time */
int mock_sdc_cs_now(void);                              /* its CS (CFG bit 8) */
void mock_gayle_cs_open(void);                          /* cfide opened cs 0x10 */
void mock_sdc_reset(void);

#endif
