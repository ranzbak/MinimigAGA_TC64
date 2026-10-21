/* rvlibc: what the RISC-V firmware adds to newlib-nano (decision 12.12).
 * See README.md, "C library". */
#ifndef RVLIBC_H
#define RVLIBC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* printf formats into a static buffer, then sends the bytes through putchar().
 * RV_PRINTF_BUF is the buffer of the normal path, RV_PRINTF_IRQ_BUF the one of
 * a printf issued while another printf is still sending (the interrupt
 * handler's Akiko trace).  Both include the terminating NUL; the sizes are the
 * audited maximum output plus 1, rounded up to a multiple of 64 (README,
 * "printf buffer audit").  A line that does not fit is cut to size - 1 bytes
 * and counted in rv_printf_truncations. */
#ifndef RV_PRINTF_BUF
#define RV_PRINTF_BUF 320
#endif
#ifndef RV_PRINTF_IRQ_BUF
#define RV_PRINTF_IRQ_BUF 64
#endif

extern volatile unsigned int rv_printf_truncations;

/* Calls of the newlib-nano heap hooks (_malloc_r, _realloc_r, _free_r), which
 * rvlibc.c defines as stubs.  Nothing in the firmware may reach them. */
extern volatile unsigned int rv_libc_heap_calls;

#ifdef __cplusplus
}
#endif

#endif
