; misstress_ddr3.asm -- findings/loadstore/plan.md step 3 (DFP_MIS + MIS):
; misaligned accesses on sim/ddr3_cpu (the real TG68K, SDRAM and DDR3
; paths).  With the switch, a misaligned read inside a 4K page fills its
; line(s) and a misaligned store merges into the resident longwords; chip
; RAM is data-cacheable, so its line fills are new traffic on the SDRAM
; side (implementation report section 5, the board risk).
;
; For each of four passes -- DDR3 then chip RAM, data write-through
; (DTT0 CM = 00) then copyback (CM = 01; the wrapper keeps chip RAM
; write-through) -- 256 random operations on a 260-byte buffer A:
; byte/word/long stores and reads at any offset 0..255 (so any alignment,
; line-crossing included).  Every store is mirrored into a shadow S with
; BYTE stores only (never misaligned); every read of A is compared with the
; bytes of S (fail 10+pass).  Then A == S longword by longword from the
; cache after CPUSHA DC (fail 20+pass) and from memory after CINVA DC
; (fail 30+pass).  Custom-chip and CIA reads in between (they bypass the
; cache).  MBOX = 1 when done, 99 on an exception; MBOX+4 the address,
; +8 expected, +12 got.  The test body runs from DDR3 (CODE): code in the
; bench's chip RAM is not instruction-cached and too slow for its 4 ms
; TIMEOUT.  Run: ./run_ddr3_prog.sh <tag> misstress_ddr3.asm
A_DDR	equ	$41050000
S_DDR	equ	$41060000
A_CHIP	equ	$00018000		; the bench's chip RAM is 128 KB
S_CHIP	equ	$41070000
CODE	equ	$41020000
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
	move.l	#$00ffc000,d0		; instructions: write-through
	movec	d0,itt0
	move.l	#$00ffc000,d0		; data: write-through (pass 0, 1)
	movec	d0,dtt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
; copy the body to DDR3 and run it there
	lea	body(pc),a0
	lea	CODE,a1
	move.w	#(bodyend-body)/4,d0
.cp:	move.l	(a0)+,(a1)+
	dbra	d0,.cp
	cpusha	bc
	jmp	CODE

	cnop	0,4
body:	move.l	#$1D872B41,d5		; LFSR seed
	moveq	#0,d4			; pass 0..3
.pass:	cmp.w	#2,d4
	bne.s	.cm
	cpusha	dc
	move.l	#$00ffc020,d0		; data: copyback (pass 2, 3)
	movec	d0,dtt0
	pflusha
.cm:	lea	A_DDR,a0
	lea	S_DDR,a1
	btst	#0,d4
	beq.s	.reg
	lea	A_CHIP,a0
	lea	S_CHIP,a1
; fill A and S with the same pattern (aligned longs)
.reg:	moveq	#64,d3
	move.l	#$C0DE0000,d1
	add.l	d4,d1
	moveq	#0,d0
.fi:	move.l	d1,(a0,d0.w)
	move.l	d1,(a1,d0.w)
	rol.l	#7,d1
	addq.l	#1,d1
	addq.w	#4,d0
	dbra	d3,.fi
	move.w	#255,d6
.op:	lsr.l	#1,d5			; Galois LFSR, x^32+x^22+x^2+x+1
	bcc.s	.l1
	eori.l	#$80200003,d5
.l1:	move.l	d5,d1
	and.w	#255,d1			; offset 0..255
	move.l	d5,d2
	swap	d2
	and.w	#3,d2			; size: 0 byte, 1 word, 2/3 long
	move.l	d5,d3			; value
	rol.l	#5,d3
	eor.l	d6,d3
	move.l	d5,d0
	lsr.l	#8,d0
	and.w	#3,d0			; 0..2 store, 3 read and compare
	cmp.w	#3,d0
	beq	.rd
	tst.w	d2
	beq.s	.sb
	cmp.w	#1,d2
	beq.s	.sw
	move.l	d3,(a0,d1.w)		; misaligned long store
	moveq	#4,d0
	bra.s	.sh
.sw:	move.w	d3,(a0,d1.w)		; word store, odd offsets too
	swap	d3			; the shadow writes from the MSB down
	moveq	#2,d0
	bra.s	.sh
.sb:	move.b	d3,(a0,d1.w)
	ror.l	#8,d3
	moveq	#1,d0
; shadow: d0 bytes of d3, most significant first, at S+d1 (bytes only)
.sh:	move.w	d1,d7
	cmp.w	#4,d0
	beq.s	.s4
	cmp.w	#2,d0
	beq.s	.s2
	bra.s	.s1
.s4:	rol.l	#8,d3
	move.b	d3,(a1,d7.w)
	addq.w	#1,d7
	rol.l	#8,d3
	move.b	d3,(a1,d7.w)
	addq.w	#1,d7
.s2:	rol.l	#8,d3
	move.b	d3,(a1,d7.w)
	addq.w	#1,d7
.s1:	rol.l	#8,d3
	move.b	d3,(a1,d7.w)
	bra	.next
; read A at d1 with size d2, assemble the same bytes from S, compare
.rd:	moveq	#0,d3
	moveq	#0,d0
	tst.w	d2
	beq.s	.rb
	cmp.w	#1,d2
	beq.s	.rw
	move.l	(a0,d1.w),d3		; misaligned long read
	moveq	#4,d7
	bra.s	.as
.rw:	move.w	(a0,d1.w),d3
	moveq	#2,d7
	bra.s	.as
.rb:	move.b	(a0,d1.w),d3
	moveq	#1,d7
.as:	move.l	d1,-(sp)
	subq.w	#1,d7
.a1:	lsl.l	#8,d0
	move.b	(a1,d1.w),d0
	addq.w	#1,d1
	dbra	d7,.a1
	move.l	(sp)+,d1
	cmp.l	d0,d3
	beq.s	.next
	lea	(a0,d1.w),a2
	move.l	a2,MBOX+4
	move.l	d0,MBOX+8
	move.l	d3,MBOX+12
	moveq	#10,d7
	add.l	d4,d7
	move.l	d7,MBOX
.f1:	bra.s	.f1
.next:	move.w	d6,d0
	and.w	#31,d0
	bne.s	.n2
	move.w	$dff006,d0		; bypass reads between the operations
	move.b	$bfd100,d0
	eori.l	#1,MBOX+$10		; progress for the bench's stall watchdog
	ori.l	#2,MBOX+$10
.n2:	dbra	d6,.op
; A == S from the cache, then from memory
	cpusha	dc
	moveq	#20,d7
	bsr	cmpas
	cinva	dc
	moveq	#30,d7
	bsr	cmpas
	addq.l	#1,d4
	move.l	d4,d0
	add.l	#4,d0
	move.l	d0,MBOX+$10
	cmp.w	#4,d4
	bne	.pass
	move.l	#1,MBOX
.ok:	bra.s	.ok

; compare 260 bytes of A and S as longwords; fail d7+pass
cmpas:	moveq	#64,d3
	moveq	#0,d0
.c:	move.l	(a0,d0.w),d1
	move.l	(a1,d0.w),d2
	cmp.l	d1,d2
	bne.s	.cf
	addq.w	#4,d0
	dbra	d3,.c
	rts
.cf:	lea	(a0,d0.w),a2
	move.l	a2,MBOX+4
	move.l	d2,MBOX+8
	move.l	d1,MBOX+12
	add.l	d4,d7
	move.l	d7,MBOX
.cff:	bra.s	.cff
	cnop	0,4
bodyend:
except:	move.l	#99,MBOX
.e:	bra.s	.e
