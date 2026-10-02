; cbwalk_ddr3.asm -- findings/copyback/plan.md: a copyback write-back must
; never meet a table walk on the master port (rtl/soc/TG68K.vhd's mux: the
; walker's wk_go takes the port and the next acknowledge).  Found on the
; board 2026-10-01: AmigaOS with fast RAM copyback hung at program load and
; exit, where CacheClearU's CPUSHA sweeps while the instruction fetch, past
; the CPUSHA, misses the ATC and walks.
; Data: DTT0, copyback (the DDR3 board's lines can be dirty).  Instructions:
; no ITT, so every code page is found by a table walk (tables in chip RAM).
; Ten times: 64 lines at BUF made dirty, PFLUSHA, then a call to a CPUSHA BC
; on the last word of page 1 -- the fetch past it walks for page 2 while the
; sweep writes the lines back.  Then CINVA DC and the 64 lines read from
; memory (fail 2: addr/expected/got).  MBOX = 1 when done, 99 on an
; exception.
BUF	equ	$41050000
MBOX	equ	$1000
ROOT	equ	$8000
PTR	equ	$8200
PAGE	equ	$8400
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
	; tables: logical 0-$3FFFF identity, 4K pages, U and M preset
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
	move.l	#$C0DE0000,d1
	moveq	#9,d5
.it:	lea	BUF,a0
	moveq	#63,d3
.d:	move.l	(a0),d2			; resident
	move.l	d1,(a0)			; dirty
	addq.l	#1,d1
	lea	16(a0),a0		; one longword in each of 64 lines (64 sets)
	dbra	d3,.d
	pflusha				; the ATC is empty: the fetches walk
	jsr	flush
	moveq	#20,d0			; progress for the bench's stall watchdog:
	sub.l	d5,d0			; phase 11..20, one per round
	move.l	d0,MBOX+$10
	dbra	d5,.it
	move.l	#4,MBOX+$10
	cinva	dc
	lea	BUF,a0
	moveq	#63,d3
	move.l	#$C0DE0000+9*64,d1
.k:	cmp.l	(a0),d1
	bne.s	.f2
	addq.l	#1,d1
	lea	16(a0),a0
	dbra	d3,.k
	move.l	#1,MBOX
.ok:	bra.s	.ok
.f2:	move.l	a0,MBOX+4
	move.l	d1,MBOX+8
	move.l	(a0),MBOX+12
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

; the CPUSHA on the last longword of page 1: the fetch runs on into page 2
; (the bench loads the first 8 KB of a program: nothing may lie above $1FFF)
	org	$1FFC
flush:	cpusha	bc
	rts
