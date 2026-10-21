	.section .text.start
	.global _start
_start:
	li sp, 0x10000
	jal ra, main
	li a0, 0x20000004
	sw zero, 0(a0)
1:	j 1b
