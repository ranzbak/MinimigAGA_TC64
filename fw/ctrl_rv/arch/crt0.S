/* Firmware start-up for the RISC-V host CPU.  The boot ROM jumps here
 * (0x2000) with mstatus.MIE clear and mtvec on its own trap entry.
 *   gp = __global_pointer$, sp = __stack_top, clear .bss, mtvec = trap_entry,
 *   run the constructors (.init_array), set mie.MEIE and mstatus.MIE, call
 *   main; if main returns, spin.
 * Only linker symbols, no fixed addresses: the L2 bench links this into a
 * boot ROM image (sim/host_bridge/sw/rom.ld) as well.  __global_pointer$ is
 * weak: a layout without it (rom.ld) gets gp = 0 and has no gp-relative
 * code (the linker relaxes to gp only when the symbol exists). */
    .weak   __global_pointer$

    .section .text.start, "ax", @progbits
    .globl  _start
    .type   _start, @function
_start:
    csrci   mstatus, 8                  /* no interrupts until we are ready */
    .option push
    .option norelax
    lui     gp, %hi(__global_pointer$)
    addi    gp, gp, %lo(__global_pointer$)
    .option pop
    la      sp, __stack_top

    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

2:  la      t0, trap_entry
    csrw    mtvec, t0

    la      s0, __init_array_start      /* s0, s1 survive the calls */
    la      s1, __init_array_end
3:  bgeu    s0, s1, 4f
    lw      t0, 0(s0)
    jalr    t0
    addi    s0, s0, 4
    j       3b

4:  li      t0, 0x800                   /* mie.MEIE: cfide's interrupt */
    csrs    mie, t0
    csrsi   mstatus, 8                  /* mstatus.MIE */
    li      a0, 0
    li      a1, 0
    call    main
5:  j       5b
    .size   _start, . - _start
