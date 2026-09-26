; FPUFixTest -- directed tests for the pipelined 68040's FPU fixes
; (findings/fpu-fixes/plan.md), run from the CLI on the board.
;
; Normal software never reaches these cases -- compilers do not emit
; memory-indirect FP modes, and packed stores to a register are malformed
; encodings -- so this runs them on purpose and prints one line per case:
;
;   P1   memory-indirect FP effective addresses EXECUTE (M68040UM 10.7.2).
;        Before the fix each one took the F-line with a format $4 frame
;        ("got" shows the frame word, e.g. 0000402C).
;   P2   FMOVE.P FPn,Dn is the unsupported data type: vector 55, format $3,
;        frame word $30DC.  Before the fix: $402C (static k) / $202C (dynamic).
;   P2b  FMOVE.P FPn,An is the plain F-line: frame word $002C.  Before: $202C.
;
; The cases run in supervisor mode (exec Supervisor()) with VBR pointed at a
; private copy of the vector table whose F-line (11) and FP-unsupported-data-
; type (55) entries are this program's, so 68040.library's FPSP never sees
; them and the raw frame is what gets reported.  VBR is restored before
; returning.  The FPU state of this task is reset (FRESTORE of a NULL frame)
; after each trap.
;
; Needs an FPU (AttnFlags 68881/68882/FPU40); on an LC040 image it says so
; and exits.  Return code 0 when every case passes, 5 (WARN) otherwise.
;
; Self-contained: offsets and LVOs are written out, no NDK needed.
; Build: see Makefile.

_LVOSupervisor	equ	-30
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552
_LVOVPrintf	equ	-954		; dos.library V36
AttnFlags	equ	296		; UWORD
AFF_ANYFPU	equ	$70		; 68881 | 68882 | FPU40

NCASES		equ	10
RETURN_OK	equ	0
RETURN_WARN	equ	5
RETURN_FAIL	equ	20

	section	code,code

start:
	movem.l	d2-d7/a2-a6,-(sp)
	moveq	#RETURN_FAIL,d7
	move.l	4.w,a6
	lea	dosname,a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	tst.l	d0
	beq	.exit
	move.l	d0,a4			; DOSBase

	move.w	AttnFlags(a6),d0
	and.w	#AFF_ANYFPU,d0
	bne.s	.fpu
	move.l	#msg_nofpu,d1
	moveq	#0,d2
	move.l	a4,a6
	jsr	_LVOVPrintf(a6)
	bra	.close

.fpu:	move.l	#msg_head,d1
	moveq	#0,d2
	move.l	a4,a6
	jsr	_LVOVPrintf(a6)

	move.l	4.w,a6
	lea	super,a5
	jsr	_LVOSupervisor(a6)

	; one line per case: name, expected, got, verdict
	moveq	#0,d6			; failures
	moveq	#0,d5			; case index
	lea	names,a2
	lea	expv,a3
	lea	gotv,a5
.line:	move.l	(a2)+,argv		; name
	move.l	(a3)+,d0
	move.l	d0,argv+4		; expected
	move.l	(a5)+,d1
	move.l	d1,argv+8		; got
	move.l	#s_pass,argv+12
	cmp.l	d0,d1
	beq.s	.pr
	move.l	#s_fail,argv+12
	addq.l	#1,d6
.pr:	move.l	#fmt_line,d1
	move.l	#argv,d2
	move.l	a4,a6
	jsr	_LVOVPrintf(a6)
	addq.l	#1,d5
	cmp.l	#NCASES,d5
	blo.s	.line

	moveq	#RETURN_OK,d7
	move.l	#msg_allok,d1
	tst.l	d6
	beq.s	.sum
	moveq	#RETURN_WARN,d7
	move.l	#msg_fails,d1
.sum:	move.l	d6,argv
	move.l	#argv,d2
	move.l	a4,a6
	jsr	_LVOVPrintf(a6)

.close:	move.l	a4,a1
	move.l	4.w,a6
	jsr	_LVOCloseLibrary(a6)
.exit:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;--------------------------------------------------------------- supervisor part
; Entered through Supervisor(): ends with RTE.
super:
	movem.l	d0-d7/a0-a6,-(sp)
	movec	vbr,d0
	move.l	d0,old_vbr
	move.l	d0,a0
	lea	vtab,a1
	move.w	#255,d1
.cp:	move.l	(a0)+,(a1)+
	dbra	d1,.cp
	lea	vtab,a1
	move.l	#h_trap,11*4(a1)	; F-line
	move.l	#h_trap,55*4(a1)	; FP unsupported data type
	movec	a1,vbr

	; preset every result: a case that never writes its own shows this
	lea	gotv,a0
	moveq	#NCASES-1,d1
.pre:	move.l	#$EEEEEEEE,(a0)+
	dbra	d1,.pre

;------------------------------------- P1-1 source through ([bd])
	move.l	sp,save_sp
	move.l	#c1e,resume
	clr.l	trap_word
	fmove.l	#10,fp5
	fdiv.w	([p_five]),fp5		; 10 / 5
	fmove.l	fp5,d0
	move.l	d0,gotv+0
c1e:	bsr	trapped
	beq.s	c2
	move.l	trap_word,gotv+0

;------------------------------------- P1-2 ([bd,An,Xn],od) behind a released FDIV
c2:	move.l	sp,save_sp
	move.l	#c2e,resume
	clr.l	trap_word
	fmove.l	#10,fp5
	fdiv.l	#5,fp5			; released: the FADD below waits for it
	lea	ptab,a0
	moveq	#1,d1
	fadd.x	([0,a0,d1.l*4],8),fp5	; 2 + 3.0
	fmove.l	fp5,d0
	move.l	d0,gotv+4
c2e:	bsr	trapped
	beq.s	c3
	move.l	trap_word,gotv+4

;------------------------------------- P1-3 store through a pointer
c3:	move.l	sp,save_sp
	move.l	#c3e,resume
	clr.l	trap_word
	move.l	#$DEADBEEF,outl
	fmove.l	#5,fp5
	fmove.l	fp5,([p_outl])
	move.l	outl,gotv+8
c3e:	bsr	trapped
	beq.s	c4
	move.l	trap_word,gotv+8

;------------------------------------- P1-4 FScc through a pointer
c4:	move.l	sp,save_sp
	move.l	#c4e,resume
	clr.l	trap_word
	move.l	#$00112233,sbyte
	fmove.l	#5,fp5
	ftst.x	fp5
	fsne	([p_sbyte])		; 5 <> 0: the byte = $FF
	move.l	sbyte,gotv+12
c4e:	bsr	trapped
	beq.s	c5
	move.l	trap_word,gotv+12

;------------------------------------- P1-5 FMOVE FPCR through a pointer
c5:	move.l	sp,save_sp
	move.l	#c5e,resume
	clr.l	trap_word
	fmove.l	fpcr,d0
	move.l	d0,expv+16		; expected: whatever FPCR holds now
	move.l	#$DEADBEEF,crl
	fmove.l	fpcr,([p_crl])
	move.l	crl,gotv+16
c5e:	bsr	trapped
	beq.s	c6
	move.l	trap_word,gotv+16

;------------------------------------- P1-6 FSAVE/FRESTORE through a pointer
c6:	move.l	sp,save_sp
	move.l	#c6e,resume
	clr.l	trap_word
	fmove.l	#1,fp0			; the unit is used: not a NULL frame
	fsave	([p_fsb])
	frestore ([p_fsb])
	move.l	fsb,d0
	and.l	#$FF000000,d0		; the version byte
	move.l	d0,gotv+20
c6e:	bsr	trapped
	beq.s	c7
	move.l	trap_word,gotv+20

;------------------------------------- P1-7 a word at an ODD pointed-to address
c7:	move.l	sp,save_sp
	move.l	#c7e,resume
	clr.l	trap_word
	fmove.l	#3,fp4
	fmul.w	([p_odd]),fp4		; 3 * 7
	fmove.l	fp4,d0
	move.l	d0,gotv+24
c7e:	bsr	trapped
	beq.s	c8
	move.l	trap_word,gotv+24

;------------------------------------- P2 FMOVE.P FP0,D0{#0}: vector 55
c8:	move.l	sp,save_sp
	move.l	#c8e,resume
	clr.l	trap_word
	fmove.l	#1,fp0
	dc.w	$F200,$6C00
c8e:	move.l	trap_word,gotv+28

;------------------------------------- P2 FMOVE.P FP0,D0{D1}: vector 55
c9:	move.l	sp,save_sp
	move.l	#c9e,resume
	clr.l	trap_word
	fmove.l	#1,fp0
	moveq	#0,d1
	dc.w	$F200,$7C10
c9e:	move.l	trap_word,gotv+32

;------------------------------------- P2b FMOVE.P FP0,A0{D1}: F-line
c10:	move.l	sp,save_sp
	move.l	#c10e,resume
	clr.l	trap_word
	fmove.l	#1,fp0
	moveq	#0,d1
	dc.w	$F208,$7C10
c10e:	move.l	trap_word,gotv+36

	move.l	old_vbr,d0
	movec	d0,vbr
	movem.l	(sp)+,d0-d7/a0-a6
	rte

; Z clear when the case trapped
trapped:
	tst.l	trap_word
	rts

; vector 11 or 55: record the frame word, clear the unit's exception state,
; and resume at the case's end with the stack as the case found it (not RTE:
; a format the core should not have produced must not take the format error)
h_trap:
	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,trap_word
	fsave	fsb_trap
	clr.l	-(sp)
	frestore (sp)+			; NULL: reset the unit
	move.l	save_sp,sp
	move.l	resume,a0
	jmp	(a0)

;--------------------------------------------------------------- data
	section	data,data

dosname:	dc.b	"dos.library",0
msg_nofpu:	dc.b	"FPUFixTest: no FPU on this image (LC040?) -- nothing to test.",10,0
msg_head:	dc.b	"FPUFixTest -- pipelined 68040 FPU fixes (P1, P2, P2b)",10,0
fmt_line:	dc.b	"%-40s expect %08lx got %08lx  %s",10,0
msg_allok:	dc.b	"All cases passed.",10,0
msg_fails:	dc.b	"%ld case(s) FAILED.",10,0
s_pass:		dc.b	"PASS",0
s_fail:		dc.b	"FAIL",0
n1:	dc.b	"P1  FDIV.W ([bd]),FP5",0
n2:	dc.b	"P1  FADD.X ([0,A0,D1.L*4],8),FP5",0
n3:	dc.b	"P1  FMOVE.L FP5,([bd])",0
n4:	dc.b	"P1  FSNE ([bd])",0
n5:	dc.b	"P1  FMOVE.L FPCR,([bd])",0
n6:	dc.b	"P1  FSAVE/FRESTORE ([bd]) (version)",0
n7:	dc.b	"P1  FMUL.W ([bd]) at an odd address",0
n8:	dc.b	"P2  FMOVE.P FP0,D0{#0} (frame word)",0
n9:	dc.b	"P2  FMOVE.P FP0,D0{D1} (frame word)",0
n10:	dc.b	"P2b FMOVE.P FP0,A0{D1} (frame word)",0
	even
names:	dc.l	n1,n2,n3,n4,n5,n6,n7,n8,n9,n10
expv:	dc.l	2, 5, 5, $FF112233, 0, $41000000, 21, $30DC, $30DC, $002C

; the pointers the memory-indirect cases read
p_five:	dc.l	five
p_outl:	dc.l	outl
p_sbyte: dc.l	sbyte
p_crl:	dc.l	crl
p_fsb:	dc.l	fsb
p_odd:	dc.l	oddw+1
ptab:	dc.l	0, xbase		; P1-2: A0 + D1*4 -> xbase
five:	dc.w	5
oddw:	dc.b	0, 0, 7, 0		; the word at oddw+1 is $0007
xbase:	dc.l	0, 0			; od 8 skips these
	dc.l	$40000000, $C0000000, $00000000	; 3.0 extended

	section	bss,bss

old_vbr:	ds.l	1
save_sp:	ds.l	1
resume:		ds.l	1
trap_word:	ds.l	1
outl:		ds.l	1
sbyte:		ds.l	1
crl:		ds.l	1
argv:		ds.l	4
gotv:		ds.l	NCASES
fsb:		ds.l	32		; FSAVE frames: up to 100 bytes
fsb_trap:	ds.l	32
vtab:		ds.l	256
