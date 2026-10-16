/* L2 host-bridge bench start-up, run from the boot BRAM (OSDBoot_rv_ROM).
 *   0x0000  reset vector: jump to crt0
 *   0x0020  trap entry (mtvec reset value): DONE = 0x8000 | mcause[31] << 8
 *           | mcause[7:0], so an unexpected trap fails the run
 *   crt0    zero x1-x31 (the simulated register file starts as X; a prologue
 *           that saves an unused register would put X on the bus), sp =
 *           0x2000, clear .bss, call main, print "PASS"/"FAIL" on the cfide
 *           UART, DONE = main's return value (0 = PASS). */
#include "hb.h"

    .section .text.reset, "ax"
    .globl _reset
_reset:
    j       _crt0

    .section .text.trap, "ax"
    .globl _trap
_trap:
    csrr    t0, mcause
    andi    t1, t0, 0xff
    srli    t0, t0, 31
    slli    t0, t0, 8
    or      t0, t0, t1
    li      t1, 0x8000
    or      t0, t0, t1
    sw      t0, HB_DONE_OFS(zero)
1:  j       1b

    .section .text.crt0, "ax"
_crt0:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
    mv      s0, a0
    la      s1, msg_pass
    beqz    s0, 3f
    la      s1, msg_fail
3:  lbu     t0, 0(s1)
    beqz    t0, 4f
    sb      t0, HB_UART_OFS(zero)
    addi    s1, s1, 1
    j       3b
4:  sw      s0, HB_DONE_OFS(zero)
5:  j       5b

    .section .rodata.crt0, "a"
msg_pass: .asciz "PASS\n"
msg_fail: .asciz "FAIL\n"
