; sim/ap040_bridge: the bridge's instruction-cacheable window and its
; instruction-cache invalidations (rtl/soc/ap68040_minimig.sv ICHIP;
; findings/aga-perf/fix.md).  Every test runs; a failure sets its bit in
; the bench's mask ($DE0000) and the program goes on.
; assembled with vasmm68k_mot -Fbin -m68040
;
;   1  a tight loop in chip RAM runs from the instruction cache: its
;      fetches over 1000 iterations are one line fill (<= 8 transfers)
;   2  a store into a cached chip-RAM routine, then a call of it at once,
;      ten times: the new code runs (the bridge's self-snoop)
;   3  a chipset DMA write into a cached chip-RAM routine (the program
;      polls for the DMA's end): the new code runs (the snoop)
;   4  data from chip RAM is not cached (the data cache is on): a read
;      after a DMA write sees the new value
;   5  the loop in fast RAM ($200000) runs from the cache
;   6  ... in the ROM ($F80000)
;   7  ... in slow RAM ($C00000, configured)
;   8  ... NOT outside the windows: $A00000, and $C80000 (slow RAM not
;      configured there): every iteration fetches
;   9  ... NOT in chip RAM while ichip_ena is low (a smaller chip RAM, or
;      the ROM overlay)
;  10  the page filter: DMA and processor writes to a chip page no fetch
;      has cached push no invalidation; a DMA write to a code page does

FAILREG	equ	$DE0000
DONEREG	equ	$DE0002
WLO	equ	$DE0010
WHI	equ	$DE0014
FCNT	equ	$DE0018
XCNT	equ	$DE001C
PKDATA	equ	$DE0020
PKADDR	equ	$DE0024
ICHIPEN	equ	$DE0028
PKBUSY	equ	$DE002C

STUB	equ	$8000		; chip RAM routines, far from the program
STUB3	equ	$8400
DATA4	equ	$9000
LOOP9	equ	$A000		; never executed before test 9
NOCODE	equ	$100000		; a chip page no fetch touches

tfail	macro
	move.w	#\1,(FAILREG).l
	endm

; the loop at \1 (copied there): 1000 iterations, the fetch count in D2
runloop	macro
	move.l	#$528151C8,(\1).l	; addq.l #1,d1 ; dbra d0,*-2
	move.l	#$FFFC4E75,(\1+4).l	; ... ; rts
	cpusha	bc			; (fast RAM: the code out of the data cache)
	move.l	#\1,(WLO).l
	move.l	#\1+16,(WHI).l
	clr.l	(FCNT).l
	move.w	#999,d0
	jsr	(\1).l
	move.l	(FCNT).l,d2
	endm

; poke \1 = \2 behind the processor's back, wait for the DMA's end
poke	macro
	move.l	\2,(PKDATA).l
	move.l	#\1,(PKADDR).l
.w\@:	tst.l	(PKBUSY).l
	bne.s	.w\@
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	move.l	#$80008000,d0		; data and instruction caches on
	movec	d0,cacr
	cinva	bc

;----------------------------------------------- 1 a chip-RAM loop, cached
	move.l	#loop1,(WLO).l
	move.l	#loop1e,(WHI).l
	clr.l	(FCNT).l
	move.w	#999,d0
	bra.s	loop1
	cnop	0,16
loop1:	addq.l	#1,d1
	dbra	d0,loop1
loop1e:	move.l	(FCNT).l,d2
	cmp.l	#8,d2
	bls.s	t2
	tfail	1

;------------------------------------------- 2 a store, then a call at once
t2:	move.l	#$70014E75,(STUB).l	; moveq #1,d0 ; rts
	moveq	#0,d0
	jsr	(STUB).l
	moveq	#9,d5
	move.l	#$70204E75,d1
.l2:	move.l	d1,(STUB).l
	moveq	#0,d0
	jsr	(STUB).l
	bsr	expect
	beq.s	.k2
	tfail	2
.k2:	add.l	#$00010000,d1
	dbra	d5,.l2

;------------------------------------------------- 3 a DMA write, snooped
	move.l	#$70014E75,(STUB3).l
	moveq	#0,d0
	jsr	(STUB3).l
	moveq	#9,d5
	move.l	#$70304E75,d1
.l3:	poke	STUB3,d1
	moveq	#0,d0
	jsr	(STUB3).l
	bsr	expect
	beq.s	.k3
	tfail	3
.k3:	add.l	#$00010000,d1
	dbra	d5,.l3

;------------------------------------------------ 4 chip data not cached
	move.l	#$11111111,(DATA4).l
	move.l	(DATA4).l,d2
	move.l	(DATA4).l,d2
	move.l	#$22222222,d3
	poke	DATA4,d3
	move.l	(DATA4).l,d2
	cmp.l	d3,d2
	beq.s	t5
	tfail	4

;------------------------------------------- 5-7 loops in the other windows
t5:	runloop	$200100
	cmp.l	#8,d2
	bls.s	t6
	tfail	5
t6:	runloop	$F80100
	cmp.l	#8,d2
	bls.s	t7
	tfail	6
t7:	runloop	$C00100
	cmp.l	#8,d2
	bls.s	t8
	tfail	7

;----------------------------------------------- 8 outside: every fetch
t8:	runloop	$A00100
	cmp.l	#1000,d2
	bcc.s	.k8
	tfail	8
.k8:	runloop	$C80100
	cmp.l	#1000,d2
	bcc.s	t9
	tfail	8

;---------------------------------------------- 9 chip RAM, ichip_ena low
t9:	move.w	#0,(ICHIPEN).l
	runloop	LOOP9
	move.w	#1,(ICHIPEN).l
	cmp.l	#1000,d2
	bcc.s	t10
	tfail	9

;------------------------------------------------------ 10 the page filter
t10:	clr.l	(XCNT).l
	moveq	#19,d5
.l10:	poke	NOCODE,d5		; DMA into a page with no code
	move.l	d5,(NOCODE+4).l		; ... and the processor
	dbra	d5,.l10
	move.l	(XCNT).l,d2
	beq.s	.k10
	tfail	10
.k10:	move.l	#$70014E75,d3
	poke	STUB3,d3		; a code page: pushed
	move.l	(XCNT).l,d2
	bne.s	done
	tfail	10

done:
	move.w	#$600D,(DONEREG).l
	bra.s	*

; D0 must be the immediate of the MOVEQ in D1's upper word (Z set if so)
expect:
	move.l	d1,d2
	swap	d2
	ext.w	d2
	ext.l	d2
	cmp.l	d2,d0
	rts

unexp:
	tfail	31
	bra	done
