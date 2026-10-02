; cbstress_ddr3.asm -- findings/copyback/plan.md: the copyback cache on
; sim/ddr3_cpu (the real TG68K, SDRAM and DDR3 paths), shaped like what
; AmigaOS does when it loads a program.  DTT0 makes data accesses copyback
; (CM = 01; the wrapper limits copyback to the DDR3 board's window), ITT0
; write-through, translation on.
;   phase 2  64 routines written to DDR3 (store misses: write-through),
;            then "relocated": each one's first word read (the line becomes
;            resident) and rewritten (a hit: the line is dirty), with
;            custom-chip and CIA reads in between (they bypass the cache and
;            push the dirty lines of their sets).  CPUSHA BC, then every
;            routine is called: d6 = 1 + 2 + ... + 64 = 2080 (fail 2).
;   phase 3  2 KB at SRC read (resident) and rewritten (dirty), copied to
;            DST with MOVE16, CINVA DC (which writes back first), then DST
;            and SRC read from memory and checked (fail 3 DST, 4 SRC).
; MBOX = 1 when done, 99 on an exception.
CODE	equ	$41020000
SRC	equ	$41030000
DST	equ	$41040000
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
	move.l	#$00ffc020,d0		; data: copyback
	movec	d0,dtt0
	move.l	#$00ffc000,d0		; instructions: write-through
	movec	d0,itt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
; phase 2: the routines, each one line: MOVEQ #k,D0 / ADD.L D0,D6 / 5 NOPs / RTS
	lea	CODE,a0
	moveq	#0,d1
	moveq	#63,d3
.w:	move.w	d1,d2
	or.w	#$7000,d2
	move.w	d2,(a0)+
	move.w	#$DC80,(a0)+
	move.w	#$4E71,(a0)+
	move.w	#$4E71,(a0)+
	move.w	#$4E71,(a0)+
	move.w	#$4E71,(a0)+
	move.w	#$4E71,(a0)+
	move.w	#$4E75,(a0)+
	addq.w	#1,d1
	dbra	d3,.w
	; relocate: MOVEQ #k becomes MOVEQ #k+1 (a store hit: dirty)
	lea	CODE,a0
	moveq	#63,d3
.r:	move.w	(a0),d2
	addq.w	#1,d2
	move.w	d2,(a0)
	move.w	$dff006,d4		; bypass reads: set 0
	move.b	$bfd100,d4		; set $10
	move.w	$dff01c,d4		; set 1
	lea	16(a0),a0
	dbra	d3,.r
	cpusha	bc
	move.l	#3,MBOX+$10
	moveq	#0,d6
	lea	CODE,a0
	moveq	#63,d3
.c:	jsr	(a0)
	lea	16(a0),a0
	dbra	d3,.c
	cmp.l	#2080,d6
	beq.s	.p3
	move.l	#CODE,MBOX+4
	move.l	#2080,MBOX+8
	move.l	d6,MBOX+12
	move.l	#2,MBOX
.f2:	bra.s	.f2
; phase 3: MOVE16 from dirty lines
.p3:	lea	SRC,a0
	move.w	#511,d3
	move.l	#$5A5A0000,d1
.s:	move.l	(a0),d2			; resident
	move.l	d1,(a0)+		; dirty
	addq.l	#1,d1
	dbra	d3,.s
	move.l	#4,MBOX+$10
	lea	SRC,a0
	lea	DST,a1
	move.w	#127,d3
.m:	move16	(a0)+,(a1)+
	dbra	d3,.m
	cinva	dc
	move.l	#5,MBOX+$10
	lea	DST,a1
	move.w	#511,d3
	move.l	#$5A5A0000,d1
.k:	cmp.l	(a1)+,d1
	bne.s	.f3
	addq.l	#1,d1
	move.w	d3,d4			; progress every 256 longwords (the bench's
	and.w	#255,d4			; stall watchdog): phase 6, 7, 6, ...
	bne.s	.k1
	eori.l	#1,MBOX+$10
	ori.l	#6,MBOX+$10
.k1:	dbra	d3,.k
	lea	SRC,a1
	move.w	#511,d3
	move.l	#$5A5A0000,d1
.k2:	cmp.l	(a1)+,d1
	bne.s	.f4
	addq.l	#1,d1
	move.w	d3,d4
	and.w	#255,d4
	bne.s	.k3
	eori.l	#1,MBOX+$10
	ori.l	#6,MBOX+$10
.k3:	dbra	d3,.k2
	move.l	#1,MBOX
.ok:	bra.s	.ok
.f3:	moveq	#3,d7
	bra.s	.fx
.f4:	moveq	#4,d7
.fx:	subq.l	#4,a1
	move.l	a1,MBOX+4
	move.l	d1,MBOX+8
	move.l	(a1),MBOX+12
	move.l	d7,MBOX
.ff:	bra.s	.ff
except:	move.l	#99,MBOX
.e:	bra.s	.e
