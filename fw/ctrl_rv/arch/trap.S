/* Trap entry (mtvec, direct mode) for the RISC-V host CPU firmware.
 * Saves the caller-saved registers (ra, t0-t6, a0-a7: 16 words, 64 bytes,
 * keeping sp 16-byte aligned) on the interrupted stack, calls
 *     rv_trap(mcause, mepc, mtval)            (trap.c)
 * restores them and returns with mret.  The callee-saved registers are kept
 * by rv_trap itself (C ABI); gp and tp are never changed by C code.  rv_trap
 * may change mepc (csrw) to resume elsewhere, e.g. after the faulting
 * instruction.  The hardware clears mstatus.MIE on entry and mret sets it
 * back from MPIE, so handlers do not nest. */
    .section .text.trap_entry, "ax", @progbits
    .balign 4
    .globl  trap_entry
    .type   trap_entry, @function
trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      t3, 16(sp)
    sw      t4, 20(sp)
    sw      t5, 24(sp)
    sw      t6, 28(sp)
    sw      a0, 32(sp)
    sw      a1, 36(sp)
    sw      a2, 40(sp)
    sw      a3, 44(sp)
    sw      a4, 48(sp)
    sw      a5, 52(sp)
    sw      a6, 56(sp)
    sw      a7, 60(sp)
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    rv_trap
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      t3, 16(sp)
    lw      t4, 20(sp)
    lw      t5, 24(sp)
    lw      t6, 28(sp)
    lw      a0, 32(sp)
    lw      a1, 36(sp)
    lw      a2, 40(sp)
    lw      a3, 44(sp)
    lw      a4, 48(sp)
    lw      a5, 52(sp)
    lw      a6, 56(sp)
    lw      a7, 60(sp)
    addi    sp, sp, 64
    mret
    .size   trap_entry, . - trap_entry
