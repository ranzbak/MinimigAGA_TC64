; CBTest -- findings/copyback: the copyback data cache on the board.
; cb1/cb2 crashed AmigaOS with CopyBack on (F-line / illegal instruction
; when a program starts) while every SoC simulation passed.  This runs the
; simulation's scenarios on the real machine, with the OS (interrupts,
; multitasking) alive, and reports the first wrong address and value
; instead of a Guru.
;
;   CBTest [N|T|W] [rounds]     (output: redirect to a file, e.g. >DH0:cb.log)
;     N  leave the MMU as it is (run MuSetCacheMode ... CopyBack first)
;     T  DTT1 = copyback over the 16 MB of the test buffer (whole DDR3 board)
;     W  DTT1 = write-through there: the control, must always pass
;
; Buffers: A (64 KB) and B (64 KB) and C (4 KB of code) from the memory
; header with the HIGHEST address (the DDR3 board), S (64 KB) in chip RAM,
; the shadow: every operation is done on A and on S, then they are compared.
; Per round:
;   1/2  fill A with a per-round sequence; check; CacheClearU; check
;   3/4  read-modify-write every longword of A; check; CacheClearU; check
;   5/6  A copied to S, then 8192 random byte/word/long stores at any
;        alignment (line-crossing: the non-mergeable path) to A and S,
;        with read-compares in between (5); CacheClearU; A == S (6)
;   7/8  CopyMem A -> B (MOVE16 under 68040.library); B == S; CacheClearU; again
;   9    256 routines written into C ("MOVEQ #0,D0" then relocated by an
;        ADD.W to the opcode), CacheClearU, each called: D6 must be its k
; An error line: test, round, address, expected, got, and the value read
; again after another CacheClearU (same = memory wrong, differs = cache).
; The first error also writes $BAD0 to $DFF1FE (custom NO-OP), an ILA
; trigger.  CTRL-C stops after the current round.
; Data lives in the code hunk: PC-relative reads cannot cross hunks.

_LVOSupervisor	equ	-30
_LVOForbid	equ	-132
_LVOPermit	equ	-138
_LVOAllocate	equ	-186
_LVODeallocate	equ	-192
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOSetSignal	equ	-306
_LVOCloseLibrary equ	-414
_LVORawDoFmt	equ	-522
_LVOOpenLibrary	equ	-552
_LVOCopyMem	equ	-624
_LVOCacheClearU	equ	-636
_LVOPutStr	equ	-948
MemList		equ	322
mh_Lower	equ	20
mh_Upper	equ	24
MEMF_CHIP	equ	2
ASIZE		equ	65536+16	; random stores may run 3 bytes past 64 KB
CSIZE		equ	4096
NROUT		equ	256
KSTEP		equ	$9E3779B9

	section	code,code
start:	move.l	a0,a2			; command line
	move.l	d0,d2
	move.l	4.w,a6
	lea	dosname(pc),a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,dosbase
	beq	.x
; arguments: an optional mode letter, then an optional decimal round count
	move.b	#'N',mode
	move.l	#2000,rounds
.sk:	subq.l	#1,d2
	bmi.s	.argd
	move.b	(a2)+,d0
	cmp.b	#' ',d0
	beq.s	.sk
	move.b	d0,d1
	and.b	#$df,d1			; upper case
	cmp.b	#'T',d1
	beq.s	.md
	cmp.b	#'W',d1
	beq.s	.md
	cmp.b	#'N',d1
	bne.s	.num0
.md:	move.b	d1,mode
.sk2:	subq.l	#1,d2
	bmi.s	.argd
	move.b	(a2)+,d0
	cmp.b	#' ',d0
	beq.s	.sk2
.num0:	moveq	#0,d1
.num:	sub.b	#'0',d0
	bcs.s	.numd
	cmp.b	#9,d0
	bhi.s	.numd
	mulu.l	#10,d1
	and.l	#$ff,d0
	add.l	d0,d1
	subq.l	#1,d2
	bmi.s	.numd
	move.b	(a2)+,d0
	bra.s	.num
.numd:	tst.l	d1
	beq.s	.argd
	move.l	d1,rounds
.argd:
; the MMU and cache state as found
	lea	sv_read(pc),a5
	jsr	_LVOSupervisor(a6)
	lea	regs(pc),a0
	lea	args(pc),a1
	moveq	#5,d0
.cp:	move.l	(a0)+,(a1)+
	dbf	d0,.cp
	lea	fmtreg(pc),a0
	bsr	say
	move.l	regs+24(pc),args
	move.l	regs+28(pc),args+4
	lea	fmtrp(pc),a0
	bsr	say
; the memory header with the highest address
	jsr	_LVOForbid(a6)
	move.l	MemList(a6),a0
	sub.l	a1,a1
.ml:	tst.l	(a0)
	beq.s	.mld
	move.l	a1,d0
	beq.s	.take
	move.l	mh_Lower(a0),d0
	cmp.l	mh_Lower(a1),d0
	bls.s	.nxt
.take:	move.l	a0,a1
.nxt:	move.l	(a0),a0
	bra.s	.ml
.mld:	move.l	a1,mhdr
	move.l	a1,a0
	move.l	#ASIZE,d0
	jsr	_LVOAllocate(a6)
	move.l	d0,bufA
	move.l	mhdr(pc),a0
	move.l	#ASIZE,d0
	jsr	_LVOAllocate(a6)
	move.l	d0,bufB
	move.l	mhdr(pc),a0
	move.l	#CSIZE,d0
	jsr	_LVOAllocate(a6)
	move.l	d0,bufC
	jsr	_LVOPermit(a6)
	ifd	VAMOS			; the emulator check: no memory list
	move.l	#ASIZE,d0
	moveq	#0,d1
	jsr	_LVOAllocMem(a6)
	move.l	d0,bufA
	move.l	#ASIZE,d0
	moveq	#0,d1
	jsr	_LVOAllocMem(a6)
	move.l	d0,bufB
	move.l	#CSIZE,d0
	moveq	#0,d1
	jsr	_LVOAllocMem(a6)
	move.l	d0,bufC
	endif
	move.l	#ASIZE,d0
	moveq	#MEMF_CHIP,d1
	jsr	_LVOAllocMem(a6)
	move.l	d0,bufS
	move.l	mhdr(pc),a0
	move.l	mh_Lower(a0),args
	move.l	mh_Upper(a0),args+4
	move.l	bufA(pc),args+8
	move.l	bufB(pc),args+12
	move.l	bufC(pc),args+16
	move.l	bufS(pc),args+20
	moveq	#0,d0
	move.b	mode(pc),d0
	move.l	d0,args+24
	move.l	rounds(pc),args+28
	lea	fmtmem(pc),a0
	bsr	say
	tst.l	bufA
	beq	.free
	tst.l	bufB
	beq	.free
	tst.l	bufC
	beq	.free
	tst.l	bufS
	beq	.free
; mode T/W: DTT1 over the test buffer's 16 MB
	move.b	mode(pc),d0
	cmp.b	#'N',d0
	beq.s	.go
	move.l	bufA(pc),d1
	and.l	#$ff000000,d1
	or.l	#$0000c000,d1		; E, S ignored, CM = 00 write-through
	cmp.b	#'T',d0
	bne.s	.setw
	or.w	#$0020,d1		; CM = 01 copyback
.setw:	move.l	d1,newdtt
	lea	sv_set(pc),a5
	jsr	_LVOSupervisor(a6)
	move.l	newdtt(pc),args
	lea	fmtset(pc),a0
	bsr	say
.go:
; C: valid code before round 0 (MOVEQ #-1,D0 ... RTS everywhere)
	move.l	bufC(pc),a0
	move.w	#NROUT-1,d0
.c0:	move.l	#$70ffdc80,(a0)+
	move.l	#$4e714e71,(a0)+
	move.l	#$4e714e71,(a0)+
	move.l	#$4e714e75,(a0)+
	dbf	d0,.c0
	jsr	_LVOCacheClearU(a6)

	moveq	#0,d7			; round
.round:	bsr	t12
	bsr	t34
	bsr	t56
	bsr	t78
	bsr	t9
	addq.l	#1,d7
	move.l	d7,d0
	divul.l	#100,d1:d0
	tst.l	d1
	bne.s	.nopr
	move.l	d7,args
	move.l	nerr(pc),args+4
	lea	fmtprog(pc),a0
	bsr	say
.nopr:	moveq	#0,d0
	moveq	#0,d1
	jsr	_LVOSetSignal(a6)
	btst	#12,d0			; SIGBREAKB_CTRL_C
	bne.s	.brk
	cmp.l	rounds(pc),d7
	blo	.round
.brk:	move.l	d7,args
	move.l	nerr(pc),args+4
	lea	fmtend(pc),a0
	bsr	say
	move.b	mode(pc),d0
	cmp.b	#'N',d0
	beq.s	.free
	lea	sv_rest(pc),a5
	jsr	_LVOSupervisor(a6)
.free:	jsr	_LVOForbid(a6)
	move.l	bufA(pc),d0
	beq.s	.f1
	move.l	d0,a1
	move.l	mhdr(pc),a0
	move.l	#ASIZE,d0
	jsr	_LVODeallocate(a6)
.f1:	move.l	bufB(pc),d0
	beq.s	.f2
	move.l	d0,a1
	move.l	mhdr(pc),a0
	move.l	#ASIZE,d0
	jsr	_LVODeallocate(a6)
.f2:	move.l	bufC(pc),d0
	beq.s	.f3
	move.l	d0,a1
	move.l	mhdr(pc),a0
	move.l	#CSIZE,d0
	jsr	_LVODeallocate(a6)
.f3:	jsr	_LVOPermit(a6)
	move.l	bufS(pc),d0
	beq.s	.f4
	move.l	d0,a1
	move.l	#ASIZE,d0
	jsr	_LVOFreeMem(a6)
.f4:	move.l	dosbase(pc),a1
	jsr	_LVOCloseLibrary(a6)
.x:	moveq	#0,d0
	rts

;---------------------------------------------------------------- tests
; d7 = round throughout; a6 = ExecBase.  The OS calls keep d2-d7/a2-a6.

; the round's first sequence value: d2
seed:	move.l	d7,d2
	mulu.l	#KSTEP,d2
	eor.l	#$5a5a5a5a,d2
	rts

; 1/2: fill, check, CacheClearU, check
t12:	movem.l	d2-d6/a2-a5,-(sp)
	bsr	seed
	move.l	bufA(pc),a0
	move.w	#16383,d3
.f:	move.l	d2,(a0)+
	add.l	#KSTEP,d2
	dbf	d3,.f
	moveq	#0,d4
	moveq	#1,d0
	bsr	chkseq
	jsr	_LVOCacheClearU(a6)
	moveq	#2,d0
	bsr	chkseq
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; A against the round's sequence plus d4; d0 = test id
chkseq:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	d0,d5
	bsr	seed
	move.l	bufA(pc),a2
	move.w	#16383,d3
.c:	move.l	(a2)+,d6
	move.l	d2,d1
	add.l	d4,d1
	cmp.l	d1,d6
	beq.s	.ok
	move.l	d2,-(sp)
	lea	-4(a2),a0
	move.l	d5,d0
	move.l	d6,d2
	bsr	err
	move.l	(sp)+,d2
.ok:	add.l	#KSTEP,d2
	dbf	d3,.c
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; 3/4: every longword += d4 (a read-modify-write of each line)
t34:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	d7,d4
	mulu.l	#$01010101,d4
	addq.l	#1,d4
	move.l	bufA(pc),a0
	move.w	#16383,d3
.a:	add.l	d4,(a0)+
	dbf	d3,.a
	moveq	#3,d0
	bsr	chkseq
	jsr	_LVOCacheClearU(a6)
	moveq	#4,d0
	bsr	chkseq
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; 5/6: A -> S, then random stores to both, read-compares; CacheClearU; A == S
t56:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	bufA(pc),a2
	move.l	bufS(pc),a3
	move.l	a2,a0
	move.l	a3,a1
	move.w	#(ASIZE/4)-1,d3
.cp:	move.l	(a0)+,(a1)+
	dbf	d3,.cp
	bsr	seed
	move.w	#8191,d3
.op:	mulu.l	#1664525,d2		; LCG
	add.l	#1013904223,d2
	move.l	d2,d1
	swap	d1
	and.l	#$ffff,d1		; offset 0..65535 (16 bytes of slack)
	move.l	d2,d0
	rol.l	#7,d0			; the value
	move.b	d2,d5
	and.b	#3,d5
	beq.s	.sb
	subq.b	#1,d5
	beq.s	.sw
	subq.b	#1,d5
	beq.s	.sl
	move.l	(a2,d1.l),d6		; 3: read-compare
	move.l	(a3,d1.l),d5
	cmp.l	d5,d6
	beq.s	.nx
	move.l	d2,-(sp)
	lea	(a2,d1.l),a0
	move.l	d5,d1
	move.l	d6,d2
	moveq	#5,d0
	bsr	err
	move.l	(sp)+,d2
	bra.s	.nx
.sb:	move.b	d0,(a2,d1.l)
	move.b	d0,(a3,d1.l)
	bra.s	.nx
.sw:	move.w	d0,(a2,d1.l)
	move.w	d0,(a3,d1.l)
	bra.s	.nx
.sl:	move.l	d0,(a2,d1.l)
	move.l	d0,(a3,d1.l)
.nx:	dbf	d3,.op
	jsr	_LVOCacheClearU(a6)
	move.l	a2,a0
	moveq	#6,d0
	bsr	cmpS
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; a0 = buffer, d0 = test id: the buffer against S, longword by longword
cmpS:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	d0,d5
	move.l	a0,a2
	move.l	bufS(pc),a3
	move.w	#(ASIZE/4)-1,d3
.c:	move.l	(a2)+,d6
	move.l	(a3)+,d4
	cmp.l	d4,d6
	beq.s	.ok
	lea	-4(a2),a0
	move.l	d4,d1
	move.l	d6,d2
	move.l	d5,d0
	bsr	err
.ok:	dbf	d3,.c
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; 7/8: CopyMem A -> B; B == S; CacheClearU; again
t78:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	bufA(pc),a0
	move.l	bufB(pc),a1
	move.l	#ASIZE,d0
	jsr	_LVOCopyMem(a6)
	move.l	bufB(pc),a0
	moveq	#7,d0
	bsr	cmpS
	jsr	_LVOCacheClearU(a6)
	move.l	bufB(pc),a0
	moveq	#8,d0
	bsr	cmpS
	movem.l	(sp)+,d2-d6/a2-a5
	rts

; 9: code written, relocated, CacheClearU, called
t9:	movem.l	d2-d6/a2-a5,-(sp)
	move.l	bufC(pc),a2
	move.l	a2,a0
	move.w	#NROUT-1,d3
.w:	move.l	#$7000dc80,(a0)+	; MOVEQ #0,D0 / ADD.L D0,D6
	move.l	#$4e714e71,(a0)+
	move.l	#$4e714e71,(a0)+
	move.l	#$4e714e75,(a0)+	; ... / RTS
	dbf	d3,.w
	move.l	a2,a0			; relocate: k = (7 * round + j) & $7f
	moveq	#0,d3
.r:	move.l	d7,d0
	mulu.l	#7,d0
	add.l	d3,d0
	and.w	#$7f,d0
	add.w	d0,(a0)
	lea	16(a0),a0
	addq.w	#1,d3
	cmp.w	#NROUT,d3
	blo.s	.r
	jsr	_LVOCacheClearU(a6)
	move.l	a2,a3
	moveq	#0,d3
.call:	moveq	#0,d6
	jsr	(a3)
	move.l	d7,d0
	mulu.l	#7,d0
	add.l	d3,d0
	and.l	#$7f,d0
	cmp.l	d0,d6
	beq.s	.cok
	move.l	a3,a0
	move.l	d0,d1
	move.l	d6,d2
	moveq	#9,d0
	bsr	err
.cok:	lea	16(a3),a3
	addq.w	#1,d3
	cmp.w	#NROUT,d3
	blo.s	.call
	movem.l	(sp)+,d2-d6/a2-a5
	rts

;---------------------------------------------------------------- report
; err: d0 = test id, a0 = address, d1 = expected, d2 = got; keeps every register
err:	movem.l	d0-d7/a0-a6,-(sp)
	addq.l	#1,nerr
	cmp.l	#1,nerr
	bne.s	.nm
	move.w	#$bad0,$dff1fe		; ILA trigger: the first error
.nm:	cmp.l	#40,nerr
	bhi.s	.q
	movem.l	d0-d2/a0,-(sp)
	jsr	_LVOCacheClearU(a6)
	movem.l	(sp)+,d0-d2/a0
	move.l	d0,args
	move.l	d7,args+4
	move.l	a0,args+8
	move.l	d1,args+12
	move.l	d2,args+16
	move.l	(a0),args+20		; read again, after the push
	lea	fmterr(pc),a0
	bsr	say
.q:	movem.l	(sp)+,d0-d7/a0-a6
	rts

; say: RawDoFmt(a0, args) into buf, PutStr it
say:	movem.l	d0-d1/a0-a3/a6,-(sp)
	lea	args(pc),a1
	lea	.pc(pc),a2
	lea	buf(pc),a3
	move.l	4.w,a6
	jsr	_LVORawDoFmt(a6)
	move.l	dosbase(pc),a6
	lea	buf(pc),a0
	move.l	a0,d1
	jsr	_LVOPutStr(a6)
	movem.l	(sp)+,d0-d1/a0-a3/a6
	rts
.pc:	move.b	d0,(a3)+
	rts

;---------------------------------------------------------------- supervisor
sv_read: movec	cacr,d0
	move.l	d0,regs
	movec	tc,d0
	move.l	d0,regs+4
	movec	itt0,d0
	move.l	d0,regs+8
	movec	itt1,d0
	move.l	d0,regs+12
	movec	dtt0,d0
	move.l	d0,regs+16
	movec	dtt1,d0
	move.l	d0,regs+20
	movec	srp,d0
	move.l	d0,regs+24
	movec	urp,d0
	move.l	d0,regs+28
	rte
sv_set:	cpusha	bc
	move.l	newdtt(pc),d0
	movec	d0,dtt1
	cpusha	bc
	rte
sv_rest: cpusha	bc
	move.l	regs+20(pc),d0
	movec	d0,dtt1
	cpusha	bc
	rte

;---------------------------------------------------------------- data
	cnop	0,4
dosbase:	dc.l	0
mhdr:		dc.l	0
bufA:		dc.l	0
bufB:		dc.l	0
bufC:		dc.l	0
bufS:		dc.l	0
rounds:		dc.l	0
nerr:		dc.l	0
newdtt:		dc.l	0
regs:		ds.l	8
args:		ds.l	8
mode:		dc.b	0
dosname:	dc.b	"dos.library",0
fmtreg:	dc.b	"CBTest: CACR=%08lx TC=%08lx ITT0=%08lx ITT1=%08lx DTT0=%08lx DTT1=%08lx",10,0
fmtmem:	dc.b	"memory %08lx-%08lx  A=%08lx B=%08lx C=%08lx S=%08lx  mode %lc  rounds %ld",10,0
fmtrp:	dc.b	"SRP=%08lx URP=%08lx (the MMU tables' root)",10,0
fmtset:	dc.b	"DTT1 set to %08lx",10,0
fmtprog: dc.b	"round %ld  errors %ld",10,0
fmtend:	dc.b	"done: %ld rounds, %ld errors",10,0
fmterr:	dc.b	"ERR test %ld round %ld @%08lx exp %08lx got %08lx again %08lx",10,0
	even
buf:	ds.b	200
