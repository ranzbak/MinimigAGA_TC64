; siloop_ddr3.asm -- SysInfo 4.4's SPEED loop on sim/ddr3_cpu (the SoC bench:
; the real rtl/soc/TG68K.vhd crossing, ap040_ram_seq, sdram_ctrl + SDRAM
; model, and the DDR3 island).  PLAN M11, 2026-09-24.
;
; The loop block (mk_siloop.py, for base BASE) is carried in this image at
; BLKSRC and copied to BASE+$30A4 at run time -- the bench preloads only the
; first 8 KB into chip RAM -- with its table at BASE+$45C4 and the iteration
; bound at BASE+$480C (a4), exactly where SysInfo's hunk keeps them.  The stack
; is in the same memory, as a task's would be.
;
;   BASE $41000000  Zorro III board 3 = the DDR3 island (cacheable window 1)
;   BASE $00200000  Zorro II fast RAM = SDRAM (cacheable, cache_z2_ena)
;
; Mailbox as ddr3_cpu_test.asm: $1000 status (1 = PASS), $1010 phase.
; Phase 1 = copied and warmed up (one iteration), 2 = NITER measured
; iterations running (the perf probe's window), 3 = done.
	ifnd	BASE
BASE	equ	$41000000
	endif
	ifnd	NITER
NITER	equ	3
	endif
	ifnd	CACRV
CACRV	equ	$80008000
	endif
MBOX	equ	$1000
BLKLEN	equ	696

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr

start:	move.l	#CACRV,d0
	movec	d0,cacr
	moveq	#0,d0
	move.l	d0,MBOX
	move.l	d0,MBOX+$10
	lea	blk,a0			; copy the loop block
	lea	BASE+$30a4,a1
	move.w	#BLKLEN/2-1,d1
.c1:	move.w	(a0)+,(a1)+
	dbra	d1,.c1
	lea	tab,a0			; ... and its 16-byte table
	lea	BASE+$45c4,a1
	moveq	#3,d1
.c2:	move.l	(a0)+,(a1)+
	dbra	d1,.c2
	lea	BASE+$8000,sp		; the task stack, in the same memory
	lea	BASE+$480c,a4
	moveq	#0,d7
	move.l	#1,(a4)			; warm-up
	jsr	BASE+$30a4
	move.l	#1,MBOX+$10
	moveq	#0,d7
	move.l	#NITER,(a4)
	move.l	#2,MBOX+$10		; the measured window
	jsr	BASE+$30a4
	move.l	#3,MBOX+$10
	cmp.l	#NITER,d7
	bne.s	except
	move.l	#1,MBOX
.h:	bra.s	.h
except:	move.l	#99,MBOX
.x:	bra.s	.x

	cnop	0,4
blk:	incbin	"siloop_blk.bin"
tab:	incbin	"siloop_blk.bin.tab"
