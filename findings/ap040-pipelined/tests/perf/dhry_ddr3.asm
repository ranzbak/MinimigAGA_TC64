; dhry_ddr3.asm -- xSysInfo's Dhrystone on sim/ddr3_cpu (the SoC bench):
; clears 13K of DDR3 fast RAM at BASE (the program's .bss ends near
; $410030ee),
; copies the program (lib/AP68040-pipelined/tb/perf/dhry, dhry_soc.bin,
; linked at $41000000) to BASE and calls soc_main, which marks the
; measured window in the probe's mailbox ($1010 = 2) around NRUNS runs.
; Loader phases 4 (cleared) and 5 (copied); MBOX = 1 when done, 99 on an
; exception.
	ifnd	CACRV
CACRV	equ	$80008000
	endif
BASE	equ	$41000000
MBOX	equ	$1000
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
	lea	BASE,a1			; .bss and the rest: zero, 1K at a time,
	moveq	#13-1,d2		; a phase (6, 7, 6, ...) after each: the
	moveq	#6,d3			; loader runs from chip RAM and the
.zc:	move.w	#256-1,d1		; bench's stall watchdog counts phases
.z:	clr.l	(a1)+
	dbra	d1,.z
	move.l	d3,MBOX+$10
	eori.l	#1,d3
	dbra	d2,.zc
	move.l	#4,MBOX+$10		; (a phase: the bench's stall watchdog counts them)
	lea	blk,a0			; the program
	lea	BASE,a1
	move.w	#(blkend-blk)/2-1,d1
.c1:	move.w	(a0)+,(a1)+
	dbra	d1,.c1
	move.l	#5,MBOX+$10
	ifd	MMUON
	; translation on (TC.E), everything through DTT0/ITT0: base 0, mask $FF,
	; E, either FC2, cacheable write-through -- the core's and the MMU's
	; translation-on paths without page tables (68040.library uses tables)
	move.l	#$00ffc000,d0
	movec	d0,dtt0
	movec	d0,itt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	endif
	lea	BASE+$10000,sp		; the stack, in the same memory
	jsr	BASE			; soc_main
	move.l	#1,MBOX
.h:	bra.s	.h
except:	move.l	#99,MBOX
.x:	bra.s	.x
	cnop	0,4
blk:	incbin	"dhry_soc.bin"
blkend:
	cnop	0,2
