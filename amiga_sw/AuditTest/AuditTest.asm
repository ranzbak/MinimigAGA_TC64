; AuditTest -- board test for the pipelined 68040's manual-audit fixes
; (audit 2026-09-27; lib/AP68040-pipelined branch manual-audit-fixes).
;
;   #5  RTE to an odd PC: the address error stacks the SR with S set ($A700)
;   #4  TAS / CAS2 on a write-protected page fault on the locked READ
;   #3  FSAVE whose last frame longword faults still writes the saved frame
;   #2  a traced store whose write faults: no hang, the trace survives (CT)
;   #1  an FP load from an invalid page takes the access error and restarts
;
; The faults are made with the MMU: in supervisor mode, interrupts off, the
; program saves the OS's MMU setup, maps everything transparently through the
; TTRs (non-cachable) except two 4K test pages at $C0000000/$C0001000, which
; its own page table makes valid, invalid or write-protected, and points VBR
; at a private vector table whose access-error, address-error, trace and
; F-line entries are its own (68040.library never sees them).  Everything is
; restored after each test.
;
; Each test is a separate Supervisor() call and prints its lines before the
; next one starts, because on an image WITHOUT the fixes #2 and #1 hang the
; machine (they run last).  #3 and #1 need an FPU (skipped on an LC040).
; Return code 0 when every check passes, 5 (WARN) otherwise.
;
; Self-contained: offsets and LVOs are written out.  Build: see Makefile.

_LVOSupervisor	equ	-30
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552
_LVODelay	equ	-198		; dos.library
_LVOVPrintf	equ	-954		; dos.library V36
AttnFlags	equ	296
AFF_ANYFPU	equ	$70
MEMF_PUBLIC	equ	1
MEMF_CLEAR	equ	$10000
BUFSIZE		equ	16384

V1		equ	$C0000000	; test page 1
V2		equ	$C0001000	; test page 2
PD_OK		equ	$43		; page descriptor: resident, non-cachable
PD_WP		equ	$47		; ... write-protected
TTR0		equ	$007FC040	; $00000000-$7FFFFFFF transparent, non-cachable
TTR1		equ	$803FC040	; $80000000-$BFFFFFFF transparent, non-cachable

NCHK		equ	22

	section	code,code

start:
	movem.l	d2-d7/a2-a6,-(sp)
	moveq	#20,d7
	move.l	4.w,a6
	lea	dosname,a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	tst.l	d0
	beq	.exit
	move.l	d0,dosbase
	move.l	#BUFSIZE,d0
	move.l	#MEMF_PUBLIC|MEMF_CLEAR,d1
	jsr	_LVOAllocMem(a6)
	tst.l	d0
	beq	.close
	move.l	d0,buf
	; tables and pages, aligned inside the buffer
	add.l	#511,d0
	and.l	#~511,d0
	move.l	d0,root
	add.l	#512,d0
	move.l	d0,ptrtab
	add.l	#512,d0
	move.l	d0,pagetab
	move.l	root,d0
	add.l	#2048+4095,d0
	and.l	#~4095,d0
	move.l	d0,page1
	add.l	#4096,d0
	move.l	d0,page2
	cmp.l	#$80000000,d0		; must lie in the TTR0 range
	bhs	.nobuf
	move.l	root,a0			; root[$60] -> ptrtab, ptrtab[0] -> pagetab
	move.l	ptrtab,d0
	or.w	#3,d0
	move.l	d0,$60*4(a0)
	move.l	ptrtab,a0
	move.l	pagetab,d0
	or.w	#3,d0
	move.l	d0,(a0)

	move.l	#msg_head,d1
	bsr	print
	move.w	AttnFlags(a6),d0
	and.w	#AFF_ANYFPU,d0
	sne	hasfpu

	lea	tests,a2
.tl:	move.l	(a2)+,d0		; test function (0 = end)
	beq	.sum
	move.l	(a2)+,d4		; title
	move.l	(a2)+,d5		; first check
	move.l	(a2)+,d6		; last check
	move.l	(a2)+,d3		; needs an FPU
	move.l	d0,cur_test
	move.l	d4,d1
	bsr	print
	tst.l	d3
	beq.s	.run
	tst.b	hasfpu
	bne.s	.run
	move.l	#msg_skip,d1
	bsr	print
	bra.s	.tl
.run:	move.l	dosbase,a6		; let the line reach the screen first
	moveq	#10,d1
	jsr	_LVODelay(a6)
	move.l	4.w,a6
	lea	super,a5
	jsr	_LVOSupervisor(a6)
.cl:	cmp.l	d6,d5			; print checks d5..d6
	bhi.s	.tl
	move.l	d5,d0
	lsl.l	#2,d0
	lea	names,a0
	move.l	(a0,d0.l),argv
	lea	expv,a0
	move.l	(a0,d0.l),d1
	move.l	d1,argv+4
	lea	gotv,a0
	move.l	(a0,d0.l),d2
	move.l	d2,argv+8
	move.l	#s_pass,argv+12
	cmp.l	d1,d2
	beq.s	.pr
	move.l	#s_fail,argv+12
	addq.l	#1,nfail
.pr:	move.l	#fmt_line,d1
	move.l	#argv,d2
	move.l	dosbase,a6
	jsr	_LVOVPrintf(a6)
	addq.l	#1,d5
	bra.s	.cl

.sum:	moveq	#0,d7
	move.l	#msg_allok,d1
	tst.l	nfail
	beq.s	.s1
	moveq	#5,d7
	move.l	#msg_fails,d1
.s1:	move.l	nfail,argv
	bsr	print
	bra.s	.free
.nobuf:	move.l	#msg_nobuf,d1
	bsr	print
.free:	move.l	4.w,a6
	move.l	buf,a1
	move.l	#BUFSIZE,d0
	jsr	_LVOFreeMem(a6)
.close:	move.l	4.w,a6
	move.l	dosbase,a1
	jsr	_LVOCloseLibrary(a6)
.exit:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; VPrintf(d1, argv)
print:	movem.l	d0-d2/a0-a1/a6,-(sp)
	move.l	#argv,d2
	move.l	dosbase,a6
	jsr	_LVOVPrintf(a6)
	movem.l	(sp)+,d0-d2/a0-a1/a6
	rts

	include	"audit_tests.i"

;=============================================================== data
	section	data,data

dosname:	dc.b	"dos.library",0
msg_head:	dc.b	"AuditTest -- pipelined 68040 manual-audit fixes (#1-#5)",10,0
msg_skip:	dc.b	"  (no FPU: skipped)",10,0
msg_nobuf:	dc.b	"AuditTest: no memory below $80000000 for the tables.",10,0
msg_allok:	dc.b	"All checks passed.",10,0
msg_fails:	dc.b	"%ld check(s) FAILED.",10,0
fmt_line:	dc.b	"  %-38s expect %08lx got %08lx  %s",10,0
s_pass:		dc.b	"PASS",0
s_fail:		dc.b	"FAIL",0
ti5:	dc.b	"#5 RTE to an odd PC",10,0
ti4:	dc.b	"#4 TAS/CAS2 on a write-protected page",10,0
ti3:	dc.b	"#3 FSAVE whose last longword faults",10,0
ti2:	dc.b	"#2 traced store whose write faults (old image: HANGS)",10,0
ti1:	dc.b	"#1 FP load from an invalid page (old image: HANGS)",10,0
n0:	dc.b	"stacked SR (S set)",0
n1:	dc.b	"format/vector",0
n2:	dc.b	"TAS: one fault",0
n3:	dc.b	"TAS: fault at the TAS (restart)",0
n4:	dc.b	"TAS: SSW ATC+LK",0
n5:	dc.b	"TAS: no pending write (WB1S)",0
n6:	dc.b	"TAS: result byte after restart",0
n7:	dc.b	"CAS2 compare fails: one fault",0
n8:	dc.b	"FSAVE: one fault",0
n9:	dc.b	"FSAVE: frame header",0
n10:	dc.b	"FSAVE: state extracted once (IDLE)",0
n11:	dc.b	"store: one fault",0
n12:	dc.b	"SSW CT set",0
n13:	dc.b	"traces taken",0
n14:	dc.b	"first trace PC (the ANDI)",0
n15:	dc.b	"second trace PC",0
n16:	dc.b	"store in memory",0
n17:	dc.b	"FMOVE.X: one fault",0
n18:	dc.b	"FMOVE.X: fault at the FMOVE",0
n19:	dc.b	"FMOVE.X: value after restart",0
n20:	dc.b	"FMOVE.L to FPCR: one fault",0
n21:	dc.b	"FPCR value after restart",0
	even
names:	dc.l	n0,n1,n2,n3,n4,n5,n6,n7,n8,n9,n10,n11,n12,n13,n14,n15,n16,n17,n18,n19,n20,n21
expv:	dc.l	$A700,$200C
	dc.l	1,t4_tas,$0600,0,$80,1
	dc.l	1,$41300000,$41000000
	dc.l	1,$2000,2,t2_an,t2_aft,$11223344
	dc.l	1,t1_fm,3,1,$10
; test, title, first check, last check, needs an FPU
tests:	dc.l	t5,ti5,0,1,0
	dc.l	t4,ti4,2,7,0
	dc.l	t3,ti3,8,10,1
	dc.l	t2,ti2,11,16,0
	dc.l	t1,ti1,17,21,1
	dc.l	0

	section	bss,bss

dosbase:	ds.l	1
buf:		ds.l	1
root:		ds.l	1
ptrtab:		ds.l	1
pagetab:	ds.l	1
page1:		ds.l	1
page2:		ds.l	1
cur_test:	ds.l	1
nfail:		ds.l	1
argv:		ds.l	4
gotv:		ds.l	NCHK
old_vbr:	ds.l	1
old_tc:		ds.l	1
old_urp:	ds.l	1
old_srp:	ds.l	1
old_itt0:	ds.l	1
old_itt1:	ds.l	1
old_dtt0:	ds.l	1
old_dtt1:	ds.l	1
old_fpcr:	ds.l	1
save_sp:	ds.l	1
resume:		ds.l	1
cnt_aerr:	ds.l	1
cnt_trace:	ds.l	1
cnt_flin:	ds.l	1
last_ssw:	ds.l	1
last_fa:	ds.l	1
last_pc:	ds.l	1
last_wb1s:	ds.l	1
fix_desc:	ds.l	1
fix_val:	ds.l	1
tlog_ptr:	ds.l	1
trace_log:	ds.l	4
adr_sr:		ds.w	1
adr_fmt:	ds.w	1
hasfpu:		ds.b	1
		even
vtab:		ds.l	256
