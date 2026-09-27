; audit_tests.i -- the AuditTest cases, handlers and MMU set-up, shared by
; AuditTest.asm (the Amiga program) and a bare-metal wrapper that runs them
; on the core's compat bench.  The includer provides the equates (V1, V2,
; PD_OK, PD_WP, TTR0, TTR1) and the variables (root, pagetab, page1, page2,
; cur_test, gotv, old_*, save_sp, resume, cnt_*, last_*, fix_*, tlog_ptr,
; trace_log, adr_sr, adr_fmt, vtab).
;
; super is entered as an exec Supervisor() function: it ends with RTE.

;=============================================================== supervisor
super:	movem.l	d0-d7/a0-a6,-(sp)
	move.w	#$2700,sr
	movec	vbr,d0
	move.l	d0,old_vbr
	move.l	d0,a0
	lea	vtab,a1
	move.w	#255,d1
.cp:	move.l	(a0)+,(a1)+
	dbra	d1,.cp
	lea	vtab,a1
	move.l	#h_aerr,2*4(a1)
	move.l	#h_adr,3*4(a1)
	move.l	#h_trace,9*4(a1)
	move.l	#h_flin,11*4(a1)
	movec	a1,vbr
	bsr	mmu_on
	move.l	cur_test,a0
	jsr	(a0)
	bsr	mmu_off
	move.l	old_vbr,d0
	movec	d0,vbr
	movem.l	(sp)+,d0-d7/a0-a6
	rte

mmu_on:	cpusha	bc
	movec	tc,d0
	move.l	d0,old_tc
	movec	urp,d0
	move.l	d0,old_urp
	movec	srp,d0
	move.l	d0,old_srp
	movec	itt0,d0
	move.l	d0,old_itt0
	movec	itt1,d0
	move.l	d0,old_itt1
	movec	dtt0,d0
	move.l	d0,old_dtt0
	movec	dtt1,d0
	move.l	d0,old_dtt1
	moveq	#0,d0
	movec	d0,tc
	move.l	#TTR0,d0
	movec	d0,itt0
	movec	d0,dtt0
	move.l	#TTR1,d0
	movec	d0,itt1
	movec	d0,dtt1
	move.l	root,d0
	movec	d0,urp
	movec	d0,srp
	pflusha
	move.l	#$8000,d0		; E, 4K pages
	movec	d0,tc
	rts

mmu_off:
	moveq	#0,d0
	movec	d0,tc
	pflusha
	move.l	old_itt0,d0
	movec	d0,itt0
	move.l	old_itt1,d0
	movec	d0,itt1
	move.l	old_dtt0,d0
	movec	d0,dtt0
	move.l	old_dtt1,d0
	movec	d0,dtt1
	move.l	old_urp,d0
	movec	d0,urp
	move.l	old_srp,d0
	movec	d0,srp
	pflusha
	move.l	old_tc,d0
	movec	d0,tc
	pflusha
	cpusha	bc
	rts

; set page descriptor n (0/1) of the test table to d0, flush the ATC
setpd0:	move.l	a0,-(sp)
	move.l	pagetab,a0
	move.l	d0,(a0)
	pflusha
	move.l	(sp)+,a0
	rts
setpd1:	move.l	a0,-(sp)
	move.l	pagetab,a0
	move.l	d0,4(a0)
	pflusha
	move.l	(sp)+,a0
	rts
; the handler repairs descriptor n with d0
fixpd0:	move.l	pagetab,fix_desc
	move.l	d0,fix_val
	rts
fixpd1:	move.l	pagetab,d1
	addq.l	#4,d1
	move.l	d1,fix_desc
	move.l	d0,fix_val
	rts
clrcnt:	clr.l	cnt_aerr
	clr.l	cnt_trace
	clr.l	cnt_flin
	move.l	#trace_log,tlog_ptr
	rts

;------------------------------------------------ #5 RTE to an odd PC
t5:	move.l	sp,save_sp
	move.l	#.r,resume
	move.w	#$0000,-(sp)		; format $0
	move.l	#t5_odd+1,-(sp)		; an ODD PC
	move.w	#$8700,-(sp)		; T1, user, IPL 7
	rte
.r:	moveq	#0,d0
	move.w	adr_sr,d0
	move.l	d0,gotv+0*4
	moveq	#0,d0
	move.w	adr_fmt,d0
	move.l	d0,gotv+1*4
	rts
t5_odd:	nop

;------------------------------------------------ #4 locked RMW, protected page
t4:	move.l	page1,a0
	clr.l	$10(a0)
	move.l	#$12345678,(a0)
	move.l	#$33333333,4(a0)
	move.l	page1,d0
	or.w	#PD_WP,d0
	bsr	setpd0
	move.l	page1,d0
	or.w	#PD_OK,d0
	bsr	fixpd0
	bsr	clrcnt
	lea	V1+$10,a1
t4_tas:	tas	(a1)
	move.l	cnt_aerr,gotv+2*4
	move.l	last_pc,gotv+3*4
	move.l	last_ssw,d0
	and.l	#$0600,d0
	move.l	d0,gotv+4*4
	move.l	last_wb1s,gotv+5*4
	moveq	#0,d0
	move.b	V1+$10,d0
	move.l	d0,gotv+6*4
	move.l	page1,d0		; CAS2, compare fails, operands protected
	or.w	#PD_WP,d0
	bsr	setpd0
	bsr	clrcnt
	lea	V1,a3
	lea	V1+4,a4
	move.l	#$0BADBAD0,d3
	move.l	#$33333333,d4
	move.l	#$55555555,d5
	move.l	#$66666666,d6
	cas2.l	d3:d4,d5:d6,(a3):(a4)
	move.l	cnt_aerr,gotv+7*4
	clr.l	fix_desc
	rts

;------------------------------------------------ #3 FSAVE, last longword faults
t3:	move.l	page1,d0
	or.w	#PD_OK,d0
	bsr	setpd0
	moveq	#0,d0			; page 2 invalid
	bsr	setpd1
	move.l	page2,d0
	or.w	#PD_OK,d0
	bsr	fixpd1
	bsr	clrcnt
	fmove.l	#1,fp0
	dc.w	$F200,$000E		; FSIN.X FP0: unimplemented -> state
	lea	V2-48,a0		; the 13th longword is on page 2
	fsave	(a0)
	move.l	cnt_aerr,gotv+8*4
	move.l	V2-48,gotv+9*4		; the frame header
	lea	V1+$100,a0
	fsave	(a0)			; extracted once: IDLE now
	move.l	V1+$100,gotv+10*4
	clr.l	-(sp)
	frestore (sp)+			; leave the unit reset
	clr.l	fix_desc
	rts

;------------------------------------------------ #2 traced store faults
t2:	moveq	#0,d0			; page 2 invalid
	bsr	setpd1
	move.l	page2,d0
	or.w	#PD_OK,d0
	bsr	fixpd1
	bsr	clrcnt
	move.l	#$11223344,d0
	lea	V2,a0
	ori.w	#$8000,sr		; T1
t2_st:	move.l	d0,(a0)			; traced; the write faults
t2_an:	andi.w	#$7FFF,sr		; traced; T1 off
t2_aft:	nop
	move.l	cnt_aerr,gotv+11*4
	move.l	last_ssw,d0
	and.l	#$2000,d0
	move.l	d0,gotv+12*4
	move.l	cnt_trace,gotv+13*4
	move.l	trace_log,gotv+14*4
	move.l	trace_log+4,gotv+15*4
	move.l	V2,gotv+16*4
	clr.l	fix_desc
	rts

;------------------------------------------------ #1 FP load from an invalid page
t1:	fmove.l	fpcr,old_fpcr
	move.l	page2,a0		; 3.0 extended at page 2 +0, $10 at +$20
	move.l	#$40000000,(a0)
	move.l	#$C0000000,4(a0)
	clr.l	8(a0)
	move.l	#$00000010,$20(a0)
	moveq	#0,d0
	bsr	setpd1
	move.l	page2,d0
	or.w	#PD_OK,d0
	bsr	fixpd1
	bsr	clrcnt
	lea	V2,a0
t1_fm:	fmove.x	(a0),fp1
	fmove.l	fp1,d0
	move.l	d0,gotv+19*4
	move.l	cnt_aerr,gotv+17*4
	move.l	last_pc,gotv+18*4
	moveq	#0,d0			; invalid again
	bsr	setpd1
	bsr	clrcnt
	fmove.l	V2+$20,fpcr
	fmove.l	fpcr,d0
	move.l	d0,gotv+21*4
	move.l	cnt_aerr,gotv+20*4
	fmove.l	old_fpcr,fpcr
	clr.l	fix_desc
	rts

;------------------------------------------------ handlers (frame at 12(sp))
h_aerr:	movem.l	d0-d1/a0,-(sp)
	addq.l	#1,cnt_aerr
	moveq	#0,d0
	move.w	12+$0C(sp),d0
	move.l	d0,last_ssw
	move.l	12+$14(sp),last_fa
	move.l	12+2(sp),last_pc
	moveq	#0,d0
	move.w	12+$12(sp),d0
	and.w	#$0080,d0
	move.l	d0,last_wb1s
	move.l	fix_desc,d0		; repair the page
	beq.s	.nf
	move.l	d0,a0
	move.l	fix_val,(a0)
	pflusha
.nf:	move.w	12+$12(sp),d0		; WB1 valid: complete the write
	btst	#7,d0
	beq.s	.nw
	move.l	12+$28(sp),a0
	move.l	12+$2C(sp),d1
	and.w	#$0060,d0		; SIZE
	beq.s	.wl
	cmp.w	#$0020,d0
	beq.s	.wb
	move.w	d1,(a0)
	bra.s	.nw
.wb:	move.b	d1,(a0)
	bra.s	.nw
.wl:	move.l	d1,(a0)
.nw:	movem.l	(sp)+,d0-d1/a0
	rte

h_trace:
	move.l	a0,-(sp)
	addq.l	#1,cnt_trace
	move.l	tlog_ptr,a0
	cmp.l	#trace_log+16,a0
	bhs.s	.full
	move.l	4+2(sp),(a0)+
	move.l	a0,tlog_ptr
.full:	move.l	(sp)+,a0
	rte

h_flin:	addq.l	#1,cnt_flin
	rte				; format $2: the next instruction

h_adr:	move.w	(sp),adr_sr
	move.w	6(sp),adr_fmt
	move.l	save_sp,sp
	move.l	resume,a0
	jmp	(a0)

