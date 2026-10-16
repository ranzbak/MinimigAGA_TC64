/* Boot ROM startup for the OSD host CPU (VexRiscv RV32IMC), 8 KB boot BRAM at 0.
   0x00  reset vector: j _start
   0x20  boot trap entry (mtvec): report the trap on the UART, park
   Stack top 0x2000 (the end of the BRAM), .bss cleared, then main(). */
	.section .text.start,"ax",@progbits
	.globl _start
	.globl boot_trap
	.type _start,@function
_reset:
	.option push
	.option norvc
	j	_start			/* 4 bytes, so the vector cannot move */
	.option pop

	.org	0x20
boot_trap:
	/* Save nothing: the ROM never resumes.  Fresh stack, then report. */
	li	sp, 0x2000
	csrr	a0, mcause
	csrr	a1, mepc
	csrr	a2, mtval
	call	boot_trap_c
1:	j	1b

_start:
	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop
	li	sp, 0x2000
	la	t0, boot_trap
	csrw	mtvec, t0
	csrwi	mstatus, 0		/* machine interrupts off */
	la	t0, __bss_start
	la	t1, _end
2:	bgeu	t0, t1, 3f
	sw	zero, 0(t0)
	addi	t0, t0, 4
	j	2b
3:	li	a0, 0
	li	a1, 0
	call	main
4:	j	4b
