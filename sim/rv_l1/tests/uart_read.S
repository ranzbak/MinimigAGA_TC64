/* uart_read (teeth for the memory model): a 16-bit read of the cfide UART
 * register 0xFFFFFFF0.  cfide never acks a UART read (its support state
 * machine serves UART writes only), so on the real bus the CPU would hang
 * there; the L1 model fails the run instead.  This program must end with
 * "=== FAIL uart read"; if the model let the read through, main would
 * return 0 and the run would PASS. */
#include "l1.h"

    .section .text.entry, "ax"
    .globl main
main:
    lhu     t0, L1_UART_OFS(zero)
    li      a0, 0
    ret
