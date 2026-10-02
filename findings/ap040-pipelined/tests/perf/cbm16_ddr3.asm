; cbm16_ddr3.asm -- the smallest case of cbstress_ddr3.asm's phase-3 failure
; (MOVE16's destination line read back with longword 3 at offset 0, with and
; without copyback).  Translation on, data through DTT0 (CM = 01: copyback
; when the core has it), instructions through ITT0.
;   1  one source line made resident and rewritten, MOVE16 to DST, CINVA DC,
;      DST read back (fail 3)
;   2  the control: four plain longword stores to DST2, CINVA DC, read back
;      (fail 4)
; MBOX = 1 when done, 99 on an exception; MBOX+4/8/12: address, expected, got.
SRC	equ	$41030000
DST	equ	$41040000
DST2	equ	$41040100
MBOX	equ	$1000
	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr
start:	move.l	#$80008000,d0
	movec	d0,cacr
	moveq	#0,d0
	move.l	d0,MBOX
	move.l	#2,MBOX+$10
	move.l	#$00ffc020,d0
	movec	d0,dtt0
	move.l	#$00ffc000,d0
	movec	d0,itt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	lea	SRC,a0
	move.l	(a0),d0
	move.l	#$5A5A0000,(a0)+
	move.l	#$5A5A0001,(a0)+
	move.l	#$5A5A0002,(a0)+
	move.l	#$5A5A0003,(a0)+
	lea	SRC,a0
	lea	DST,a1
	move16	(a0)+,(a1)+
	cinva	dc
	move.l	#3,MBOX+$10
	lea	DST,a1
	moveq	#3,d7
	bsr	check
	lea	DST2,a1
	move.l	#$5A5A0000,(a1)+
	move.l	#$5A5A0001,(a1)+
	move.l	#$5A5A0002,(a1)+
	move.l	#$5A5A0003,(a1)+
	cinva	dc
	move.l	#4,MBOX+$10
	lea	DST2,a1
	moveq	#4,d7
	bsr	check
	move.l	#1,MBOX
.ok:	bra.s	.ok
check:	move.l	#$5A5A0000,d1
	moveq	#3,d3
.k:	cmp.l	(a1)+,d1
	bne.s	.f
	addq.l	#1,d1
	dbra	d3,.k
	rts
.f:	subq.l	#4,a1
	move.l	a1,MBOX+4
	move.l	d1,MBOX+8
	move.l	(a1),MBOX+12
	move.l	d7,MBOX
.ff:	bra.s	.ff
except:	moveq	#0,d0
	move.w	6(sp),d0
	and.w	#$fff,d0
	lsr.w	#2,d0
	move.l	d0,MBOX+4
	move.l	2(sp),MBOX+8
	move.l	#99,MBOX
.e:	bra.s	.e
