; cbtab_ddr3.asm -- findings/copyback: translation tables in a COPYBACK page
; on sim/ddr3_cpu (the real TG68K master mux, where the walker and the
; cache's write-backs share one port).  M68040UM 3.2.5: a table search
; reads a descriptor through the data cache, and its read-modify-write
; pushes the line first; MuSetCacheMode over a whole fast RAM board can
; leave MMULib's tables in a copyback page.  The core's walker reads
; memory, so the cache pushes a dirty line under a descriptor before the
; walker's transaction goes out (lib/AP68040-pipelined t_cbtab_pipe.s is
; the same on the flat bench, whose walker has a port of its own).
; Tables in the DDR3 board; data: DTT0, copyback; instructions: no ITT,
; every code page is found by a table walk.
;   1  logical page 3 -> physical page 0 ($3F00 runs MOVEQ #1); the
;      descriptor rewritten to physical page 1 (MOVEQ #2), dirty, PFLUSHA:
;      the call must return 2
;   2  the same back to page 0 with U clear: the walk's U-bit update; after
;      CPUSHA and CINVA the descriptor in memory has U set
; MBOX = 1 when done, 2 + MBOX+4 the case, MBOX+8 what came back; 99 on
; an exception (MBOX+4 the vector, MBOX+8 the PC).
ROOT	equ	$41060000
PTR	equ	$41060200
PAGE	equ	$41060400
MBOX	equ	$1000
	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr
	org	$400
start:	move.l	#$80008000,d0
	movec	d0,cacr
	moveq	#0,d0
	move.l	d0,MBOX
	move.l	#2,MBOX+$10
	; tables (translation off, no TTR: write-through, in memory)
	lea	ROOT,a0
	move.w	#127,d1
.cr:	clr.l	(a0)+
	dbra	d1,.cr
	move.l	#PTR|3,ROOT
	lea	PTR,a0
	move.w	#127,d1
.cp:	clr.l	(a0)+
	dbra	d1,.cp
	move.l	#PAGE|3,PTR
	lea	PAGE,a0
	moveq	#0,d0
	moveq	#63,d1
.pt:	move.l	d0,d2
	or.l	#$19,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$0000|$19,PAGE+4*3	; logical page 3 -> physical page 0
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	moveq	#0,d0
	movec	d0,itt0
	movec	d0,itt1
	movec	d0,dtt1
	move.l	#$00ffc020,d0		; data: everything, copyback
	movec	d0,dtt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	move.l	#3,MBOX+$10
; 1: the walk finds the dirty descriptor
	jsr	$3F00
	moveq	#10,d7
	cmp.l	#1,d0
	bne	.f
	move.l	PAGE+4*3,d1		; resident
	move.l	#$1000|$19,PAGE+4*3	; physical page 1: dirty
	pflusha
	jsr	$3F00
	moveq	#1,d7
	cmp.l	#2,d0
	bne	.f
	move.l	#4,MBOX+$10
; 2: the U-bit update of a dirty descriptor
	move.l	PAGE+4*3,d1
	move.l	#$0000|$11,PAGE+4*3	; physical page 0, U clear: dirty
	pflusha
	jsr	$3F00
	moveq	#2,d7
	cmp.l	#1,d0
	bne	.f
	cpusha	dc
	cinva	dc
	move.l	PAGE+4*3,d0		; from memory
	moveq	#3,d7
	cmp.l	#$0000|$19,d0
	bne	.f
	move.l	#1,MBOX
.ok:	bra.s	.ok
.f:	move.l	d7,MBOX+4
	move.l	d0,MBOX+8
	move.l	#2,MBOX
.ff:	bra.s	.ff
except:	moveq	#0,d0			; MBOX+4: the vector, MBOX+8: the PC
	move.w	6(sp),d0
	and.w	#$fff,d0
	lsr.w	#2,d0
	move.l	d0,MBOX+4
	move.l	2(sp),MBOX+8
	move.l	#99,MBOX
.e:	bra.s	.e

; physical page 0 and 1: the two routines logical page 3 is mapped to
; (the bench loads the first 8 KB of a program: nothing above $1FFF)
	org	$0F00
	moveq	#1,d0
	rts
	org	$1F00
	moveq	#2,d0
	rts
