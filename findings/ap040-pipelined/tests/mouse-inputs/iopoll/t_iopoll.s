; t_iopoll.s - the Amiga reads its mouse buttons from $BFE001 bit 6 (CIA-A
; PRA) and $DFF016 bit 10 (POTGOR).  Every read must return what the pin
; says NOW: never a cached copy, never a value forwarded from an earlier
; read.  Caches ON (DE+IE), as AmigaOS runs with 68040.library.
;
; The bench (tb_ap040_pipe_compat.v, IOPOLL) serves both registers and a
; control word at $DFF1E0: bit 0 -> PRA bit 6, bit 1 -> POTGOR bit 10,
; bit 15 = freeze the free-running toggler.
;
;   1  handshake, move.b abs.l      : set PRA6, read it back, 64 flips
;   2  handshake, btst #6,(a0)      : same through (An)
;   3  handshake, move.w $dff016    : POTGOR bit 10
;   4  handshake, tst.b 1(a1)       : PRA via d16(An), bmi/bpl shape
;   5  free-running toggler, move.b $bfe001 in a tight loop: bit 6 must be
;      seen to change at least MINCHG times in LOOPS reads (a cached or
;      frozen answer changes zero times)
;   6  same for POTGOR bit 10
; $F100 = failing check, $F102 = $600D / $BAD0.

FAILREG	equ	$F100
DONEREG	equ	$F102
CTRL	equ	$DFF1E0
PRA	equ	$BFE001
POTGOR	equ	$DFF016
LOOPS	equ	400
MINCHG	equ	8

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#$80008000,d0		; DE + IE
	movec	d0,cacr
	cinva	bc
	lea	PRA,a0
	lea	PRA-1,a1
	lea	POTGOR,a2

	moveq	#3,d6			; four passes: the later ones are hot
.pass:
; 1: move.b abs.l
	moveq	#63,d5
.l1:	move.w	d5,d1
	and.w	#1,d1
	or.w	#$8000,d1
	move.w	d1,CTRL
	move.b	PRA,d0
	lsr.b	#6,d0
	and.b	#1,d0
	cmp.b	d1,d0
	beq.s	.ok1
	moveq	#1,d7
	bra	fail_all
.ok1:	dbra	d5,.l1
; 2: btst #6,(a0)
	moveq	#63,d5
.l2:	move.w	d5,d1
	and.w	#1,d1
	or.w	#$8000,d1
	move.w	d1,CTRL
	btst	#6,(a0)
	sne	d0
	and.b	#1,d0
	cmp.b	d1,d0
	beq.s	.ok2
	moveq	#2,d7
	bra	fail_all
.ok2:	dbra	d5,.l2
; 3: POTGOR bit 10
	moveq	#63,d5
.l3:	move.w	d5,d1
	and.w	#1,d1
	move.w	d1,d2
	add.w	d2,d2			; bit 1
	or.w	#$8000,d2
	move.w	d2,CTRL
	move.w	POTGOR,d0
	btst	#10,d0
	sne	d0
	and.b	#1,d0
	cmp.b	d1,d0
	beq.s	.ok3
	moveq	#3,d7
	bra	fail_all
.ok3:	dbra	d5,.l3
; 4: tst.b 1(a1), the sign bit is PRA bit 7 (held 1): bit 6 via move/and
	moveq	#63,d5
.l4:	move.w	d5,d1
	and.w	#1,d1
	or.w	#$8000,d1
	move.w	d1,CTRL
	move.b	1(a1),d0
	and.b	#$40,d0
	sne	d0
	and.b	#1,d0
	cmp.b	d1,d0
	beq.s	.ok4
	moveq	#4,d7
	bra	fail_all
.ok4:	dbra	d5,.l4
	dbra	d6,.pass

; 5: free-running, PRA
	move.w	#$0003,CTRL		; unfreeze
	moveq	#0,d4			; changes seen
	move.b	PRA,d3
	move.w	#LOOPS-1,d5
.l5:	move.b	PRA,d0
	move.b	d0,d2
	eor.b	d3,d2
	btst	#6,d2
	beq.s	.s5
	addq.l	#1,d4
.s5:	move.b	d0,d3
	dbra	d5,.l5
	cmp.l	#MINCHG,d4
	bge.s	.ok5
	moveq	#5,d7
	bra	fail_all
.ok5:
; 6: free-running, POTGOR
	moveq	#0,d4
	move.w	POTGOR,d3
	move.w	#LOOPS-1,d5
.l6:	move.w	POTGOR,d0
	move.w	d0,d2
	eor.w	d3,d2
	btst	#10,d2
	beq.s	.s6
	addq.l	#1,d4
.s6:	move.w	d0,d3
	dbra	d5,.l6
	cmp.l	#MINCHG,d4
	bge.s	.ok6
	moveq	#6,d7
	bra	fail_all
.ok6:
	move.w	#$8003,CTRL		; freeze again
	move.w	#$600D,DONEREG
.hang:	bra.s	.hang

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
.h:	bra.s	.h

unexp:	moveq	#99,d7
	bra	fail_all
