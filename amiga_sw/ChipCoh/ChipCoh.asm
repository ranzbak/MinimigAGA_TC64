; ChipCoh -- chip RAM coherency between the CPU (caches, store buffer), the
; blitter and the copper (README.md).
;
; Open issue: garbage / stripes in TBL "Ocean Machine" and the Roots2
; rotozoomer, 68040 core only.  Suspects: the data cache missing a chipset
; write (the CPU reads a stale chip RAM copy), the instruction cache running
; generated code without a flush, CPU chip writes reaching chip RAM after the
; blitter has read it.  Each test below checks itself and reports PASS/FAIL
; with the first wrong address, the expected and the read value, and the
; value read again after CacheClearU plus a read of another chip RAM line
; (that also displaces the SDRAM controller's turbo-chip line buffer):
; again = expected -> the memory was right, the CPU's copy was stale;
; again = got -> the memory itself is wrong.
;
;   ChipCoh [ROUNDS=n] [ONLY=AS|DCOFF|ICOFF|OFF|FORCED]
;
; Cache states (68040; other CPUs run AS only):
;   AS      caches and MMU as found
;   DCOFF   data cache off, ICOFF instruction cache off, OFF both off
;   FORCED  both caches on and the test's chip RAM pages made cacheable
;           (write-through) in the MMU's page tables -- a stress test of the
;           core's snooping; a real 68040 does not snoop Amiga DMA and is
;           expected to fail BLITSTALE/COPBLIT here.  Needs the MMU on and no
;           TTR over chip RAM.
; Tests (4 KB buffers, ROUNDS rounds each, default 20):
;   BLITCPY    CPU fills src, blitter copies src -> dst, CPU reads dst
;   BLITSTALE  the same, but the CPU read dst before the blit (stale copy)
;   BLITRMW    CPU writes dst, then at once dst = src EOR dst by the blitter:
;              did the CPU's (posted) stores reach chip RAM before the blit?
;   STORESIZE  2048 byte/word/long stores at any alignment to src (and a fast
;              shadow), then at once a blit src -> dst; CPU reads src, dst
;   COPBLIT    the copper writes the blitter registers and starts the blit
;              while the CPU holds a stale dst copy; CPU reads dst
;   CODEF-CHIP / CODEF-FAST   256 generated MOVEQ #k,D0/RTS routines, written,
;              CacheClearU, called: each must return its k
;   CODEN-CHIP / CODEN-FAST   rewritten WITHOUT CacheClearU and called: INFO,
;              how many ran the new and how many the old code (a real 68040
;              with its instruction cache on runs old code from cacheable
;              memory; that is not a bug)
; The program runs under Forbid with the blitter owned; COPBLIT briefly
; Disables (one frame of the display skips the OS copper list).
;
; -DVAMOS=1 (test_chipcoh.sh): no graphics.library calls, the blits done in
; software after the register writes; -DFAULT=1 flips a bit in every blit.

_LVOSupervisor	equ	-30
_LVODisable	equ	-120
_LVOEnable	equ	-126
_LVOForbid	equ	-132
_LVOPermit	equ	-138
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552
_LVOCacheClearU	equ	-636
_LVOVPrintf	equ	-954
_LVOReadArgs	equ	-798
_LVOFreeArgs	equ	-858
_LVOWaitBlit	equ	-228
_LVOOwnBlitter	equ	-456
_LVODisownBlitter equ	-462

AttnFlags	equ	296
gb_LOFlist	equ	50
MEMF_CHIP	equ	2
MEMF_FAST	equ	4

DMACONR		equ	$dff002
VPOSR		equ	$dff004
VHPOSR		equ	$dff006
INTREQR		equ	$dff01e
COPCON		equ	$dff02e
BLTCON0		equ	$dff040
BLTCON1		equ	$dff042
BLTAFWM		equ	$dff044
BLTALWM		equ	$dff046
BLTCPT		equ	$dff048
BLTAPT		equ	$dff050
BLTDPT		equ	$dff054
BLTSIZE		equ	$dff058
BLTCMOD		equ	$dff060
BLTAMOD		equ	$dff064
BLTDMOD		equ	$dff066
COP2LC		equ	$dff084
COPJMP2		equ	$dff08a
INTREQ		equ	$dff09c

BUFL		equ	1024		; longs per buffer (4 KB)
NROUT		equ	256		; generated routines, 4 bytes each
CHIPAREA	equ	16384		; whole MMU pages (4 or 8 KB), ours only
O_SRC		equ	0
O_DST		equ	4096
O_CODE		equ	8192
O_COP		equ	9216
O_DISP		equ	12288		; read to displace the line buffer
BLT_COPY	equ	$09f0		; A, D: D = A
BLT_XOR		equ	$0b5a		; A, C, D: D = A EOR C
KSTEP		equ	$9e3779b9

	section	code,code
start:	movem.l	d2-d7/a2-a6,-(sp)
	move.l	4.w,a6
	move.l	a6,sysbase
	moveq	#10,d0
	move.l	d0,rc
	lea	dosname(pc),a1
	moveq	#37,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,dosbase
	beq	.exit
	move.l	d0,a6
	lea	template(pc),a0
	move.l	a0,d1
	move.l	#argv,d2
	moveq	#0,d3
	jsr	_LVOReadArgs(a6)
	move.l	d0,rdargs
	bne.s	.args
	lea	msg_usage(pc),a0
	bsr	puts
	bra	.close
.args:	bsr	parse
	bne	.close
	bsr	setup
	bne	.free
	bsr	report_found
	move.l	sysbase,a6
	jsr	_LVOForbid(a6)
	ifnd	VAMOS
	move.l	gfxbase,a6
	jsr	_LVOOwnBlitter(a6)
	jsr	_LVOWaitBlit(a6)
	endc
	tst.b	cpu040
	bne.s	.all
	lea	msg_asonly(pc),a0
	bsr	puts
.all:	lea	states(pc),a4
	moveq	#0,d6
.st:	tst.b	cpu040
	bne.s	.st1
	tst.l	d6			; not a 68040: AS only
	bne.s	.stn
.st1:	move.l	only,d0
	bmi.s	.st2
	cmp.l	d0,d6
	bne.s	.stn
.st2:	move.l	d6,d0
	bsr	run_state
.stn:	addq.l	#1,d6
	cmp.l	#5,d6
	blo.s	.st
	ifnd	VAMOS
	move.l	gfxbase,a6
	jsr	_LVODisownBlitter(a6)
	endc
	move.l	sysbase,a6
	jsr	_LVOPermit(a6)
	move.l	nfail,args
	lea	fmt_done(pc),a0
	lea	args,a1
	bsr	printf
	moveq	#0,d0
	tst.l	nfail
	beq.s	.rc
	moveq	#5,d0
.rc:	move.l	d0,rc
.free:	bsr	cleanup
.close:	move.l	dosbase,a6
	move.l	rdargs,d1
	beq.s	.nofa
	jsr	_LVOFreeArgs(a6)
.nofa:	move.l	sysbase,a6
	move.l	dosbase,a1
	jsr	_LVOCloseLibrary(a6)
.exit:	move.l	rc,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;---------------------------------------------------------------- arguments
parse:	movem.l	d2/a2-a3,-(sp)
	moveq	#20,d0
	move.l	argv,d1
	beq.s	.r
	move.l	d1,a0
	move.l	(a0),d0
	beq.s	.badr
	cmp.l	#10000,d0
	bhi.s	.badr
.r:	move.l	d0,rounds
	moveq	#-1,d2
	move.l	argv+4,d0
	beq.s	.o
	move.l	d0,a2
	moveq	#0,d2
	lea	states(pc),a3
.ol:	move.l	(a3)+,a1
	move.l	a2,a0
	bsr	stricmp
	beq.s	.o
	addq.l	#1,d2
	cmp.l	#5,d2
	blo.s	.ol
	move.l	a2,args
	lea	msg_badonly(pc),a0
	bra.s	.err
.o:	move.l	d2,only
	moveq	#0,d0
.ret:	movem.l	(sp)+,d2/a2-a3
	tst.l	d0
	rts
.badr:	lea	msg_badrounds(pc),a0
.err:	lea	args,a1
	bsr	printf
	moveq	#1,d0
	bra.s	.ret

stricmp: movem.l d0-d1/a0-a1,-(sp)
.l:	move.b	(a0)+,d0
	move.b	(a1)+,d1
	cmp.b	#'a',d0
	blo.s	.1
	cmp.b	#'z',d0
	bhi.s	.1
	sub.b	#32,d0
.1:	cmp.b	#'a',d1
	blo.s	.2
	cmp.b	#'z',d1
	bhi.s	.2
	sub.b	#32,d1
.2:	cmp.b	d1,d0
	bne.s	.x
	tst.b	d0
	bne.s	.l
.x:	movem.l	(sp)+,d0-d1/a0-a1
	rts

;---------------------------------------------------------------- setup
setup:	movem.l	d2-d7/a2-a6,-(sp)
	move.l	sysbase,a6
	move.w	AttnFlags(a6),d0
	moveq	#0,d1			; the CPU's middle digit: 680x0
	btst	#0,d0
	beq.s	.c2
	moveq	#1,d1
.c2:	btst	#1,d0
	beq.s	.c3
	moveq	#2,d1
.c3:	btst	#2,d0
	beq.s	.c4
	moveq	#3,d1
.c4:	btst	#3,d0
	beq.s	.c6
	moveq	#4,d1
	st	cpu040
.c6:	btst	#7,d0
	beq.s	.cd
	moveq	#6,d1
	sf	cpu040			; a 68060's CACR is another layout
.cd:	move.l	d1,cpudigit
	cmp.l	#2,d1
	blo.s	.nosv
	lea	sv_read(pc),a5
	jsr	_LVOSupervisor(a6)
.nosv:
; the chip area, aligned to 8 KB so its pages hold nothing but ours
	move.l	#CHIPAREA+8192,d0
	moveq	#MEMF_CHIP,d1
	bsr	alloc
	beq	.nomem
	add.l	#8191,d0
	and.l	#-8192,d0
	move.l	d0,chip
	move.l	#BUFL*4,d0
	moveq	#MEMF_FAST,d1
	bsr	alloc_pref
	move.l	d0,expect
	beq	.nomem
	move.l	#NROUT*4,d0
	moveq	#MEMF_FAST,d1
	bsr	alloc_pref
	move.l	d0,fcode
	beq	.nomem
	ifnd	VAMOS
	lea	gfxname(pc),a1
	moveq	#39,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,gfxbase
	beq.s	.nogfx
	endc
; the copper list for COPBLIT
	lea	cop_tpl(pc),a0
	move.l	chip,a1
	add.l	#O_COP,a1
	moveq	#(cop_end-cop_tpl)/2-1,d0
.cl:	move.w	(a0)+,(a1)+
	dbf	d0,.cl
	moveq	#0,d0
.ret:	movem.l	(sp)+,d2-d7/a2-a6
	tst.l	d0
	rts
	ifnd	VAMOS
.nogfx:	lea	msg_nogfx(pc),a0
	bra.s	.err
	endc
.nomem:	lea	msg_nomem(pc),a0
.err:	lea	args,a1
	bsr	printf
	moveq	#1,d0
	bra.s	.ret

; d0 = size, d1 = preferred type: that, or any memory
alloc_pref:
	move.l	d0,-(sp)
	bsr.s	alloc
	bne.s	.x
	move.l	(sp),d0
	moveq	#0,d1
	bsr.s	alloc
.x:	addq.l	#4,sp
	tst.l	d0
	rts
; d0 = size, d1 = flags: d0 = memory or 0 (Z set); remembered for cleanup
alloc:	movem.l	d1-d2/a0-a1/a6,-(sp)
	move.l	d0,d2
	move.l	sysbase,a6
	jsr	_LVOAllocMem(a6)
	tst.l	d0
	beq.s	.x
	move.l	nalloc,d1
	lea	alloctab,a0
	move.l	d0,(a0,d1.l*8)
	move.l	d2,4(a0,d1.l*8)
	addq.l	#1,nalloc
.x:	movem.l	(sp)+,d1-d2/a0-a1/a6
	tst.l	d0
	rts

cleanup: movem.l d2/a2/a6,-(sp)
	move.l	sysbase,a6
	ifnd	VAMOS
	move.l	gfxbase,d0
	beq.s	.ng
	move.l	d0,a1
	jsr	_LVOCloseLibrary(a6)
.ng:
	endc
	lea	alloctab,a2
	move.l	nalloc,d2
	bra.s	.f1
.f:	move.l	(a2)+,a1
	move.l	(a2)+,d0
	jsr	_LVOFreeMem(a6)
.f1:	dbf	d2,.f
	movem.l	(sp)+,d2/a2/a6
	rts

;---------------------------------------------------------------- found state
report_found:
	movem.l	d2-d4/a2,-(sp)
	lea	args,a1
	move.l	cpudigit,(a1)
	move.l	f_cacr,4(a1)
	lea	fmt_cpu(pc),a0
	tst.b	cpu040
	beq.s	.p
	move.l	f_tc,8(a1)
	move.l	f_itt0,12(a1)
	move.l	f_itt1,16(a1)
	move.l	f_dtt0,20(a1)
	move.l	f_dtt1,24(a1)
	move.l	f_urp,28(a1)
	lea	fmt_cpu40(pc),a0
.p:	bsr	printf
	move.l	chip,d0
	move.l	d0,(a1)
	add.l	#O_DST,d0
	move.l	d0,4(a1)
	add.l	#O_CODE-O_DST,d0
	move.l	d0,8(a1)
	move.l	fcode,12(a1)
	move.l	expect,16(a1)
	lea	fmt_bufs(pc),a0
	bsr	printf
; how the data side of chip RAM is cached as found
	lea	msg_not040(pc),a0
	tst.b	cpu040
	beq	.say
	move.l	chip,d1
	moveq	#0,d2
	move.l	f_dtt0,d0
	bsr	tt_match
	beq.s	.tt
	moveq	#1,d2
	move.l	f_dtt1,d0
	bsr	tt_match
	beq.s	.tt
	move.l	f_tc,d0
	btst	#15,d0
	beq.s	.off
	move.l	chip,walk_addr
	lea	sv_walk(pc),a5
	move.l	sysbase,a6
	jsr	_LVOSupervisor(a6)
	lea	args,a1
	tst.l	walk_desc_at
	beq.s	.wf
	move.l	walk_desc,d0
	lsr.l	#5,d0
	and.l	#3,d0
	move.l	d0,(a1)
	bsr	cmname
	move.l	d0,4(a1)
	lea	fmt_pagecm(pc),a0
	bra.s	.say
.wf:	move.l	chip,(a1)
	lea	fmt_walkfail(pc),a0
	bra.s	.say
.tt:	move.l	d2,(a1)
	lsr.l	#5,d0
	and.l	#3,d0
	move.l	d0,4(a1)
	bsr	cmname
	move.l	d0,8(a1)
	lea	fmt_ttcm(pc),a0
	bra.s	.say
.off:	lea	msg_mmuoff(pc),a0
.say:	lea	args,a1
	bsr	printf
	movem.l	(sp)+,d2-d4/a2
	rts

; d0 = CM (0..3): d0 = its name
cmname:	lea	cmnames(pc),a0
	move.l	(a0,d0.l*4),d0
	rts

; d0 = a TTR, d1 = address: Z set if the TTR covers the address for user
; data accesses; d0 kept
tt_match:
	movem.l	d1-d4,-(sp)
	btst	#15,d0			; E
	beq.s	.no
	move.w	d0,d2
	and.w	#$6000,d2
	cmp.w	#$2000,d2		; S = 01: supervisor only
	beq.s	.no
	rol.l	#8,d1			; address bits 31-24
	move.l	d0,d3
	rol.l	#8,d3			; logical address base
	eor.b	d3,d1
	move.l	d0,d4
	swap	d4			; logical address mask
	not.b	d4
	and.b	d4,d1			; Z set if all unmasked bits equal
	bra.s	.x
.no:	moveq	#1,d1			; Z clear
.x:	movem.l	(sp)+,d1-d4
	rts

;---------------------------------------------------------------- supervisor
sv_read: movec	cacr,d0
	move.l	d0,f_cacr
	tst.b	cpu040
	beq.s	.x
	movec	tc,d0
	move.l	d0,f_tc
	movec	itt0,d0
	move.l	d0,f_itt0
	movec	itt1,d0
	move.l	d0,f_itt1
	movec	dtt0,d0
	move.l	d0,f_dtt0
	movec	dtt1,d0
	move.l	d0,f_dtt1
	movec	urp,d0
	move.l	d0,f_urp
.x:	rte

sv_cacr: cpusha	bc			; push dirty lines before a cache goes off
	move.l	new_cacr,d0
	movec	d0,cacr
	movec	cacr,d0
	move.l	d0,new_cacr
	rte

sv_walk: movem.l d0/a1,-(sp)
	bsr.s	walk
	move.l	a1,walk_desc_at
	move.l	d0,walk_desc
	movem.l	(sp)+,d0/a1
	rte

; The 68040's three-level table walk for user data (URP): root index =
; address bits 31-25, pointer 24-18, page 17-12 (4 KB pages) or 17-13 (8 KB).
; Assumes the tables are mapped 1:1, as MMULib and 68040.library set them up.
; walk_addr: a1 = the page descriptor's address (0 if not resident), d0 = it
walk:	movem.l	d1-d2/a0,-(sp)
	move.l	walk_addr,d2
	move.l	f_urp,a1
	move.l	d2,d1
	rol.l	#7,d1
	and.l	#$7f,d1
	move.l	(a1,d1.l*4),d0		; root descriptor: UDT 1x = resident
	btst	#1,d0
	beq	.bad
	and.l	#$fffffe00,d0
	move.l	d0,a1
	move.l	d2,d1
	moveq	#18,d0
	lsr.l	d0,d1
	and.l	#$7f,d1
	move.l	(a1,d1.l*4),d0		; pointer descriptor
	btst	#1,d0
	beq	.bad
	move.l	d2,d1
	btst	#14,f_tc+2		; P: 8 KB pages
	bne.s	.p8
	and.l	#$ffffff00,d0
	moveq	#12,d2
	lsr.l	d2,d1
	and.l	#$3f,d1
	bra.s	.pg
.p8:	and.l	#$ffffff80,d0
	moveq	#13,d2
	lsr.l	d2,d1
	and.l	#$1f,d1
.pg:	move.l	d0,a1
	lea	(a1,d1.l*4),a1
	move.l	(a1),d0			; page descriptor: PDT 00 invalid, 10 indirect
	move.l	d0,d1
	and.l	#3,d1
	beq	.bad
	cmp.l	#2,d1
	bne.s	.ok
	and.l	#$fffffffc,d0
	move.l	d0,a1
	move.l	(a1),d0
	move.l	d0,d1
	and.l	#3,d1
	beq	.bad
	cmp.l	#2,d1
	beq	.bad
.ok:	movem.l	(sp)+,d1-d2/a0
	rts
.bad:	sub.l	a1,a1
	moveq	#0,d0
	bra.s	.ok

; FORCED: the chip area's page descriptors to CM = 00 (cacheable,
; write-through), both caches on.  patch_n = pages patched, -1 on failure.
sv_force:
	movem.l	d1-d3/a1-a2,-(sp)
	lea	patchtab,a2
	clr.l	patch_n
	move.l	#4096,d3
	btst	#14,f_tc+2
	beq.s	.ps
	move.l	#8192,d3
.ps:	move.l	chip,walk_addr
	move.l	#CHIPAREA,d2
.l:	bsr	walk
	move.l	a1,d1
	beq.s	.fail
	move.l	a1,(a2)+
	move.l	d0,(a2)+
	and.l	#$ffffff9f,d0
	move.l	d0,(a1)
	addq.l	#1,patch_n
	add.l	d3,walk_addr
	sub.l	d3,d2
	bhi.s	.l
	cpusha	bc
	pflusha
	move.l	f_cacr,d0
	or.l	#$80008000,d0
	movec	d0,cacr
	movec	cacr,d0
	move.l	d0,new_cacr
	movem.l	(sp)+,d1-d3/a1-a2
	rte
.fail:	bsr.s	unpatch
	move.l	#-1,patch_n
	movem.l	(sp)+,d1-d3/a1-a2
	rte

sv_unforce:
	bsr.s	unpatch
	move.l	f_cacr,d0
	movec	d0,cacr
	rte

unpatch: movem.l d0-d1/a0-a1,-(sp)
	cpusha	bc
	lea	patchtab,a0
	move.l	patch_n,d1
	ble.s	.d
	bra.s	.e
.l:	move.l	(a0)+,a1
	move.l	(a0)+,(a1)
.e:	dbf	d1,.l
.d:	cpusha	bc
	pflusha
	movem.l	(sp)+,d0-d1/a0-a1
	rts

;---------------------------------------------------------------- states
; d0 = state index (states table)
run_state:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	d0,d6
	move.l	sysbase,a6
	lea	states(pc),a0
	move.l	(a0,d6.l*4),statename
	sf	forced
	move.l	f_cacr,d0
	cmp.l	#1,d6
	bne.s	.s2
	and.l	#$7fffffff,d0		; DCOFF: DE (bit 31) off
.s2:	cmp.l	#2,d6
	bne.s	.s3
	and.l	#$ffff7fff,d0		; ICOFF: IE (bit 15) off
.s3:	cmp.l	#3,d6
	bne.s	.s4
	and.l	#$7fff7fff,d0
.s4:	move.l	d0,new_cacr
	cmp.l	#4,d6
	beq.s	.force
	tst.l	d6
	beq.s	.go
	lea	sv_cacr(pc),a5
	jsr	_LVOSupervisor(a6)
	bra.s	.go
.force:	lea	msg_forced_mmu(pc),a0	; FORCED needs the MMU on ...
	move.l	f_tc,d0
	btst	#15,d0
	beq	.skip
	move.l	chip,d1			; ... and no TTR deciding chip RAM's caching
	moveq	#0,d2
	move.l	f_dtt0,d0
	bsr	tt_match
	beq.s	.ttc
	moveq	#1,d2
	move.l	f_dtt1,d0
	bsr	tt_match
	beq.s	.ttc
	lea	sv_force(pc),a5
	jsr	_LVOSupervisor(a6)
	move.l	patch_n,d0
	bmi.s	.wfail
	st	forced
	bra.s	.go
.wfail:	move.l	walk_addr,args
	lea	msg_forced_walk(pc),a0
	bra.s	.skip
.ttc:	move.l	d2,args
	lea	msg_forced_tt(pc),a0
.skip:	lea	args+4,a1
	move.l	args,(a1)
	move.l	statename,-(a1)
	bsr	printf
	bra	.x
.go:	lea	args,a1
	move.l	statename,(a1)
	move.l	new_cacr,4(a1)
	move.l	#s_empty,8(a1)
	tst.b	forced
	beq.s	.g1
	move.l	#s_forced,8(a1)
.g1:	tst.l	d6
	bne.s	.g2
	move.l	f_cacr,4(a1)
.g2:	lea	fmt_state(pc),a0
	bsr	printf
	lea	tests(pc),a4
.t:	tst.l	(a4)
	beq.s	.td
	bsr	run_test
	lea	12(a4),a4
	bra.s	.t
.td:	tst.b	forced
	beq.s	.nf
	lea	sv_unforce(pc),a5
	jsr	_LVOSupervisor(a6)
	bra.s	.x
.nf:	tst.l	d6
	beq.s	.x
	move.l	f_cacr,new_cacr
	lea	sv_cacr(pc),a5
	jsr	_LVOSupervisor(a6)
.x:	movem.l	(sp)+,d2-d7/a2-a6
	rts

; a4 = test entry (name, routine, kind 0 = PASS/FAIL, 1 = INFO)
run_test:
	movem.l	d2-d7/a2-a6,-(sp)
	clr.l	t_bad
	clr.l	t_nerr
	clr.l	t_first
	clr.l	i_fresh
	clr.l	i_stale
	clr.l	i_other
	sf	timeout
	moveq	#0,d7
.r:	move.l	sysbase,a6
	move.l	4(a4),a0
	jsr	(a0)
	add.l	d0,t_nerr
	tst.l	d0
	beq.s	.ok
	addq.l	#1,t_bad
.ok:	addq.l	#1,d7
	cmp.l	rounds,d7
	blo.s	.r
	lea	args,a1
	move.l	(a4),(a1)
	tst.b	timeout
	bne.s	.tmo
	tst.l	8(a4)
	bne.s	.info
	tst.l	t_bad
	bne.s	.fail
	move.l	rounds,4(a1)
	lea	fmt_pass(pc),a0
	bra.s	.p
.fail:	move.l	t_bad,4(a1)
	move.l	rounds,8(a1)
	move.l	t_nerr,12(a1)
	move.l	t_addr,16(a1)
	move.l	t_exp,20(a1)
	move.l	t_got,24(a1)
	move.l	t_again,28(a1)
	lea	fmt_fail(pc),a0
	addq.l	#1,nfail
	bra.s	.p
.tmo:	lea	fmt_tmo(pc),a0
	addq.l	#1,nfail
	bra.s	.p
.info:	move.l	i_fresh,4(a1)
	move.l	i_stale,8(a1)
	move.l	i_other,12(a1)
	move.l	#s_empty,16(a1)
	tst.l	i_other
	beq.s	.i1
	move.l	#s_otherfail,16(a1)
	addq.l	#1,nfail
.i1:	lea	fmt_info(pc),a0
.p:	bsr	printf
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;---------------------------------------------------------------- tests
; Each: d7 = round, a6 = ExecBase; returns d0 = wrong longs this round.
; May use d0-d6/a0-a5.

t_blitcpy:
	bsr	prep			; src = f, dst = g, expect = f, flushed
	bsr	blit_copy
	bra	chk_dst

t_blitstale:
	bsr	prep
	bsr	preread
	bsr	blit_copy
	bra	chk_dst

t_blitrmw:
	moveq	#3,d0
	bsr	seed
	move.l	chip,a0
	bsr	fill			; src = f
	move.l	expect,a0
	bsr	fill			; expect = f
	moveq	#4,d0
	bsr	seed
	move.l	expect,a0
	bsr	xorfill			; expect = f ^ g
	jsr	_LVOCacheClearU(a6)
	moveq	#4,d0
	bsr	seed
	move.l	chip,a0
	add.l	#O_DST,a0
	bsr	fill			; dst = g: posted stores, no flush ...
	move.l	chip,a0			; ... and the blit reads dst as C at once
	move.l	a0,a1
	add.l	#O_DST,a1
	move.l	a1,a2
	move.w	#BLT_XOR,d0
	bsr	blit
	bra	chk_dst

t_storesize:
	moveq	#5,d0
	bsr	seed
	move.l	chip,a0
	bsr	fill
	move.l	expect,a0
	bsr	fill
	jsr	_LVOCacheClearU(a6)
	move.l	chip,a2
	move.l	expect,a3
	moveq	#6,d0
	bsr	seed
	move.l	d0,d2
	move.w	#2047,d3
.st:	mulu.l	#1664525,d2
	add.l	#1013904223,d2
	move.l	d2,d1
	swap	d1
	and.l	#4095,d1		; offset, any alignment
	move.l	d2,d0
	rol.l	#7,d0			; the value
	move.b	d2,d4
	and.b	#3,d4
	beq.s	.b
	subq.b	#1,d4
	beq.s	.w
	cmp.l	#4092,d1		; longs (2 of 4)
	bls.s	.l
	subq.l	#4,d1
.l:	move.l	d0,(a2,d1.l)
	move.l	d0,(a3,d1.l)
	bra.s	.n
.w:	cmp.l	#4094,d1
	bls.s	.w1
	subq.l	#2,d1
.w1:	move.w	d0,(a2,d1.l)
	move.w	d0,(a3,d1.l)
	bra.s	.n
.b:	move.b	d0,(a2,d1.l)
	move.b	d0,(a3,d1.l)
.n:	dbf	d3,.st
	bsr	blit_copy		; no flush in between
	move.l	chip,a0			; the CPU's view of src ...
	move.l	expect,a1
	bsr	check
	move.l	d0,-(sp)
	bsr	chk_dst			; ... and the blitter's copy of it
	add.l	(sp)+,d0
	rts

t_copblit:
	bsr	prep
	bsr	preread
	move.l	chip,a3			; the list's BLTAPT / BLTDPT words
	lea	O_COP+cop_a-cop_tpl+2(a3),a0
	move.l	a3,d0
	swap	d0
	move.w	d0,(a0)
	swap	d0
	move.w	d0,4(a0)
	lea	O_COP+cop_d-cop_tpl+2(a3),a0
	add.l	#O_DST,d0
	swap	d0
	move.w	d0,(a0)
	swap	d0
	move.w	d0,4(a0)
	jsr	_LVOCacheClearU(a6)	; the copper list out of any cache
	bsr	wait_blit
	ifnd	VAMOS
; no VBL in the next ms: the copper must not restart the OS list mid-test
.wl:	move.w	VPOSR,d0
	btst	#0,d0
	bne.s	.wl
	move.w	VHPOSR,d0
	lsr.w	#8,d0
	cmp.w	#32,d0
	blo.s	.wl
	cmp.w	#200,d0
	bhi.s	.wl
	endc
	jsr	_LVODisable(a6)
	move.w	#$0010,INTREQ		; COPER: the list raises it after BLTSIZE
	move.w	#2,COPCON		; CDANG: the copper may write the blitter
	move.l	chip,d0
	add.l	#O_COP,d0
	lea	COP2LC,a0
	bsr	wr_ptr
	move.w	d0,COPJMP2		; the copper runs our list now
	ifd	VAMOS
	move.l	chip,a0
	lea	O_DST(a0),a2
	move.w	#BLT_COPY,d0
	bsr	soft_blit
	else
	move.l	#2000000,d1
.p:	move.w	INTREQR,d0
	btst	#4,d0
	bne.s	.seen
	subq.l	#1,d1
	bne.s	.p
	st	timeout
.seen:
	endc
	bsr	wait_blit
	move.w	#$0010,INTREQ
	move.w	#0,COPCON
	moveq	#0,d0			; COP2LC back to the OS's list
	ifnd	VAMOS
	move.l	gfxbase,a0
	move.l	gb_LOFlist(a0),d0
	endc
	lea	COP2LC,a0
	bsr	wr_ptr
	jsr	_LVOEnable(a6)
	bra	chk_dst

t_codef_chip:
	move.l	chip,a2
	add.l	#O_CODE,a2
	bra.s	codef
t_codef_fast:
	move.l	fcode,a2
; write, CacheClearU, call: each routine must return its k
codef:	move.l	d7,d2
	mulu.l	#7,d2
	bsr	gencode
	jsr	_LVOCacheClearU(a6)
	moveq	#0,d5			; wrong
	moveq	#0,d3
.c:	lea	(a2,d3.l*4),a3
	bsr	callk			; d0 = what it returned, d1 = its k
	cmp.l	d1,d0
	beq.s	.ok
	addq.l	#1,d5
	tst.l	t_first
	bne.s	.ok
	move.l	d0,d4
	jsr	_LVOCacheClearU(a6)
	bsr	callk
	move.l	a3,a0
	exg	d0,d4			; d4 = again, d0 = got
	bsr	record
.ok:	addq.l	#1,d3
	cmp.l	#NROUT,d3
	blo.s	.c
	move.l	d5,d0
	rts

t_coden_chip:
	move.l	chip,a2
	add.l	#O_CODE,a2
	bra.s	coden
t_coden_fast:
	move.l	fcode,a2
; write k1, CacheClearU, call all (the I-cache holds them), write k2 without
; a flush, call all: new code = fresh, old = stale, anything else = other
coden:	move.l	d7,d2
	mulu.l	#7,d2
	bsr	gencode
	jsr	_LVOCacheClearU(a6)
	moveq	#0,d3
.w:	lea	(a2,d3.l*4),a3
	bsr	callk
	addq.l	#1,d3
	cmp.l	#NROUT,d3
	blo.s	.w
	add.l	#64,d2
	bsr	gencode
	moveq	#0,d3
.c:	lea	(a2,d3.l*4),a3
	bsr	callk
	cmp.l	d1,d0
	bne.s	.1
	addq.l	#1,i_fresh
	bra.s	.n
.1:	sub.l	#64,d1
	and.l	#$7f,d1
	cmp.l	d1,d0
	bne.s	.2
	addq.l	#1,i_stale
	bra.s	.n
.2:	addq.l	#1,i_other
.n:	addq.l	#1,d3
	cmp.l	#NROUT,d3
	blo.s	.c
	jsr	_LVOCacheClearU(a6)
	moveq	#0,d0
	rts

; a2 = code buffer, d2 = base: routine j = MOVEQ #((d2 + j) & $7f),D0 / RTS
gencode:
	movem.l	d0-d1/a0,-(sp)
	move.l	a2,a0
	moveq	#0,d1
.g:	move.l	d2,d0
	add.l	d1,d0
	and.w	#$7f,d0
	or.w	#$7000,d0
	move.w	d0,(a0)+
	move.w	#$4e75,(a0)+
	addq.l	#1,d1
	cmp.l	#NROUT,d1
	blo.s	.g
	movem.l	(sp)+,d0-d1/a0
	rts
; a3 = routine j (a2 + 4j), d2 = base: d0 = its result, d1 = the k written
callk:	moveq	#-1,d0
	jsr	(a3)
	move.l	a3,d1
	sub.l	a2,d1
	lsr.l	#2,d1
	add.l	d2,d1
	and.l	#$7f,d1
	rts

;---------------------------------------------------------------- helpers
; seed for this round and salt d0: d0
seed:	move.l	d7,d1
	mulu.l	#KSTEP,d1
	mulu.l	#$01000193,d0
	eor.l	d1,d0
	rts
; a0 = buffer, d0 = seed: BUFL longs of the LCG sequence (d0 kept)
fill:	movem.l	d0-d1/a0,-(sp)
	move.w	#BUFL-1,d1
.f:	mulu.l	#1664525,d0
	add.l	#1013904223,d0
	move.l	d0,(a0)+
	dbf	d1,.f
	movem.l	(sp)+,d0-d1/a0
	rts
xorfill: movem.l d0-d1/a0,-(sp)
	move.w	#BUFL-1,d1
.f:	mulu.l	#1664525,d0
	add.l	#1013904223,d0
	eor.l	d0,(a0)+
	dbf	d1,.f
	movem.l	(sp)+,d0-d1/a0
	rts

; src = f, dst = g, expect = f; CacheClearU
prep:	moveq	#1,d0
	bsr	seed
	move.l	chip,a0
	bsr	fill
	move.l	expect,a0
	bsr	fill
	moveq	#2,d0
	bsr	seed
	move.l	chip,a0
	add.l	#O_DST,a0
	bsr	fill
	jsr	_LVOCacheClearU(a6)
	rts

; the CPU reads all of dst: a cacheable dst is now in the data cache
preread: move.l	chip,a0
	add.l	#O_DST,a0
	move.w	#BUFL-1,d1
	moveq	#0,d0
.r:	add.l	(a0)+,d0
	dbf	d1,.r
	move.l	d0,sink
	rts

blit_copy:
	move.l	chip,a0
	lea	O_DST(a0),a2
	move.w	#BLT_COPY,d0
; a0 = A, a1 = C (BLT_XOR only), a2 = D, d0 = BLTCON0; 32 lines x 64 words
blit:	movem.l	d0-d1/a0-a2,-(sp)
	bsr	wait_blit
	move.w	d0,BLTCON0
	move.w	#0,BLTCON1
	move.w	#$ffff,BLTAFWM
	move.w	#$ffff,BLTALWM
	move.w	#0,BLTAMOD
	move.w	#0,BLTCMOD
	move.w	#0,BLTDMOD
	move.l	a0,d1
	lea	BLTAPT,a0
	exg	d0,d1
	bsr	wr_ptr
	move.l	a1,d0
	lea	BLTCPT,a0
	bsr	wr_ptr
	move.l	a2,d0
	lea	BLTDPT,a0
	bsr	wr_ptr
	move.w	#32<<6,BLTSIZE		; starts the blit
	ifd	VAMOS
	movem.l	(sp),d0-d1/a0-a2
	bsr	soft_blit
	endc
	bsr	wait_blit
	movem.l	(sp)+,d0-d1/a0-a2
	rts

wait_blit:
	move.l	d0,-(sp)
	move.w	DMACONR,d0		; the first BBUSY read can be stale
.w:	move.w	DMACONR,d0
	btst	#14,d0
	bne.s	.w
	move.l	(sp)+,d0
	rts

; a0 = pointer register pair, d0 = value: high word, then low word
wr_ptr:	swap	d0
	move.w	d0,(a0)
	swap	d0
	move.w	d0,2(a0)
	rts

chk_dst: move.l	chip,a0
	add.l	#O_DST,a0
	move.l	expect,a1
; a0 = buffer, a1 = expected: d0 = wrong longs; the test's first is recorded
check:	movem.l	d1-d4/a0-a2,-(sp)
	moveq	#0,d3
	move.w	#BUFL-1,d2
.c:	move.l	(a0)+,d0
	move.l	(a1)+,d1
	cmp.l	d1,d0
	beq.s	.ok
	addq.l	#1,d3
	tst.l	t_first
	bne.s	.ok
	movem.l	d0-d1/a0-a1,-(sp)
	jsr	_LVOCacheClearU(a6)
	move.l	chip,a2			; another chip RAM line: displaces the
	move.l	O_DISP(a2),sink		; SDRAM controller's line buffer
	movem.l	(sp)+,d0-d1/a0-a1
	lea	-4(a0),a2
	move.l	(a2),d4			; again
	move.l	a2,a0			; d0 = got, d1 = expected
	bsr	record
	lea	4(a2),a0
.ok:	dbf	d2,.c
	move.l	d3,d0
	movem.l	(sp)+,d1-d4/a0-a2
	rts

; a0 = address, d1 = expected, d0 = got, d4 = again (first error of a test)
record:	move.l	a0,t_addr
	move.l	d1,t_exp
	move.l	d0,t_got
	move.l	d4,t_again
	st	t_first+3
	rts

	ifd	VAMOS
; what the blitter would have done: D = A (BLT_COPY) or D = A EOR C
soft_blit:
	movem.l	d0-d1/a0-a2,-(sp)
	move.w	#BUFL-1,d1
	cmp.w	#BLT_XOR,d0
	beq.s	.x
.c:	move.l	(a0)+,(a2)+
	dbf	d1,.c
	bra.s	.f
.x:	move.l	(a0)+,d0
	eor.l	d0,(a1)+		; C is D here
	addq.l	#4,a2
	dbf	d1,.x
.f:	movem.l	(sp),d0-d1/a0-a2
	ifd	FAULT
	eor.l	#1,17*4(a2)
	endc
	movem.l	(sp)+,d0-d1/a0-a2
	rts
	endc

; a0 = format, a1 = arguments; keeps every register
printf:	movem.l	d0-d2/a0-a1/a6,-(sp)
	move.l	dosbase,a6
	move.l	a0,d1
	move.l	a1,d2
	jsr	_LVOVPrintf(a6)
	movem.l	(sp)+,d0-d2/a0-a1/a6
	rts
puts:	move.l	a1,-(sp)
	lea	args,a1
	bsr.s	printf
	move.l	(sp)+,a1
	rts

;---------------------------------------------------------------- data
	cnop	0,4
; COPBLIT's copper list: the blitter registers, BLTSIZE, then COPER
cop_tpl: dc.w	$040,BLT_COPY,$042,0	; BLTCON0, BLTCON1
	dc.w	$044,$ffff,$046,$ffff	; BLTAFWM, BLTALWM
	dc.w	$064,0,$066,0		; BLTAMOD, BLTDMOD
cop_a:	dc.w	$050,0,$052,0		; BLTAPTH/L
cop_d:	dc.w	$054,0,$056,0		; BLTDPTH/L
	dc.w	$058,32<<6		; BLTSIZE: the blit starts
	dc.w	$09c,$8010		; INTREQ: COPER
	dc.w	$ffff,$fffe
cop_end:

states:	dc.l	s_as,s_dcoff,s_icoff,s_off,s_forced_n
tests:	dc.l	n_blitcpy,t_blitcpy,0
	dc.l	n_blitstale,t_blitstale,0
	dc.l	n_blitrmw,t_blitrmw,0
	dc.l	n_storesize,t_storesize,0
	dc.l	n_copblit,t_copblit,0
	dc.l	n_codefc,t_codef_chip,0
	dc.l	n_codeff,t_codef_fast,0
	dc.l	n_codenc,t_coden_chip,1
	dc.l	n_codenf,t_coden_fast,1
	dc.l	0
cmnames: dc.l	cm0,cm1,cm2,cm3

sysbase: dc.l	0
dosbase: dc.l	0
gfxbase: dc.l	0
rdargs:	dc.l	0
rc:	dc.l	0
argv:	ds.l	2
args:	ds.l	10
rounds:	dc.l	20
only:	dc.l	-1
cpudigit: dc.l	0
f_cacr:	dc.l	0
f_tc:	dc.l	0
f_itt0:	dc.l	0
f_itt1:	dc.l	0
f_dtt0:	dc.l	0
f_dtt1:	dc.l	0
f_urp:	dc.l	0
new_cacr: dc.l	0
walk_addr: dc.l	0
walk_desc: dc.l	0
walk_desc_at: dc.l 0
patch_n: dc.l	0
patchtab: ds.l	8
chip:	dc.l	0
expect:	dc.l	0
fcode:	dc.l	0
nalloc:	dc.l	0
alloctab: ds.l	16
statename: dc.l	0
nfail:	dc.l	0
t_bad:	dc.l	0
t_nerr:	dc.l	0
t_first: dc.l	0
t_addr:	dc.l	0
t_exp:	dc.l	0
t_got:	dc.l	0
t_again: dc.l	0
i_fresh: dc.l	0
i_stale: dc.l	0
i_other: dc.l	0
sink:	dc.l	0
cpu040:	dc.b	0
forced:	dc.b	0
timeout: dc.b	0

template: dc.b	"ROUNDS/K/N,ONLY/K",0
dosname: dc.b	"dos.library",0
gfxname: dc.b	"graphics.library",0
s_as:	dc.b	"AS",0
s_dcoff: dc.b	"DCOFF",0
s_icoff: dc.b	"ICOFF",0
s_off:	dc.b	"OFF",0
s_forced_n: dc.b "FORCED",0
s_forced: dc.b	" (chip test pages cacheable write-through)"
s_empty: dc.b	0
s_otherfail: dc.b " FAIL (other = neither the old nor the new code)",0
n_blitcpy: dc.b	"BLITCPY",0
n_blitstale: dc.b "BLITSTALE",0
n_blitrmw: dc.b	"BLITRMW",0
n_storesize: dc.b "STORESIZE",0
n_copblit: dc.b	"COPBLIT",0
n_codefc: dc.b	"CODEF-CHIP",0
n_codeff: dc.b	"CODEF-FAST",0
n_codenc: dc.b	"CODEN-CHIP",0
n_codenf: dc.b	"CODEN-FAST",0
cm0:	dc.b	"cacheable write-through",0
cm1:	dc.b	"cacheable copyback",0
cm2:	dc.b	"non-cacheable serialized",0
cm3:	dc.b	"non-cacheable",0
fmt_cpu: dc.b	"ChipCoh: CPU 680%ld0 CACR %08lx",10,0
fmt_cpu40: dc.b	"ChipCoh: CPU 680%ld0 CACR %08lx TC %08lx ITT0 %08lx ITT1 %08lx"
	dc.b	" DTT0 %08lx DTT1 %08lx URP %08lx",10,0
fmt_bufs: dc.b	"buffers: src %08lx dst %08lx chip code %08lx fast code %08lx expect %08lx",10,0
fmt_pagecm: dc.b "chip data caching as found: MMU on, page CM %ld (%s)",10,0
fmt_ttcm: dc.b	"chip data caching as found: DTT%ld CM %ld (%s)",10,0
fmt_walkfail: dc.b "chip data caching as found: MMU on, no resident page at %08lx",10,0
msg_mmuoff: dc.b "chip data caching as found: MMU off, no TT match: cacheable write-through by default",10,0
msg_not040: dc.b "chip data caching as found: not a 68040",10,0
msg_asonly: dc.b "states: AS only (CACR and MMU states need a 68040)",10,0
fmt_state: dc.b	"state %s: CACR %08lx%s",10,0
fmt_pass: dc.b	"  %-10s PASS %ld rounds",10,0
fmt_fail: dc.b	"  %-10s FAIL %ld/%ld rounds, %ld longs; first @%08lx exp %08lx got %08lx again %08lx",10,0
fmt_info: dc.b	"  %-10s INFO fresh %ld stale %ld other %ld%s",10,0
fmt_tmo: dc.b	"  %-10s TIMEOUT (the copper list never raised COPER)",10,0
fmt_done: dc.b	"ChipCoh: done, %ld failed",10,0
msg_forced_mmu: dc.b "state %s: skipped (MMU off: chip RAM caching follows the TTRs, see above)",10,0
msg_forced_tt: dc.b "state %s: skipped (DTT%ld covers chip RAM; changing it would make the custom chips cacheable)",10,0
msg_forced_walk: dc.b "state %s: skipped (no resident page descriptor for %08lx)",10,0
msg_usage: dc.b	"Usage: ChipCoh [ROUNDS=n] [ONLY=AS|DCOFF|ICOFF|OFF|FORCED]",10,0
msg_badrounds: dc.b "ChipCoh: ROUNDS must be 1..10000",10,0
msg_badonly: dc.b "ChipCoh: unknown ONLY %s (AS DCOFF ICOFF OFF FORCED)",10,0
msg_nomem: dc.b	"ChipCoh: not enough memory",10,0
msg_nogfx: dc.b	"ChipCoh: no graphics.library V39",10,0
	even
