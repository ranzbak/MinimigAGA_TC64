; IrqLat -- interrupt latency under load (README.md).
;
; The 68040 core stutters "The Cure"'s music in heavy moments with Turbo chip
; OFF only; the 68020 core never does.  This measures how late interrupts are
; taken while one chosen load runs, so the cores and images can be compared
; number for number.
;
;   IrqLat [LOAD=]NONE|CHIPWR|CHIPRD|CHIPCPY|FASTWR|BLIT|FPU [BPL] [FMODE=0..3]
;          [NASTY] [RATE=Hz] [SECS=s] [OS]
;
; Two interrupt sources run at once:
;  * CIA-B timer A, level 6 (what music players use), RATE per second.  The
;    handler's FIRST instruction reads the timer: the count is how far it ran
;    past the underflow, in E-clock ticks (709379 Hz PAL, 1.41 us).  The read
;    is done twice; the difference is what the reads themselves cost.
;  * the copper, level 3: our copper list requests COPER at lines $30, $70,
;    $B0, $F0, horizontal $10 (in the blanking, before any bitplane fetch).
;    The handler's first instruction reads VHPOSR: the distance from the
;    request in colour clocks (281.9 ns PAL) is the latency.
; Direct mode (default): Disable, all of INTENA off, our own level 3 and 6
; vectors at VBR+$6C/$78 (VBR read with MOVEC), nothing of the OS in the way.
; OS mode: the same requests through exec's server chain (AddIntServer) and
; ciab.resource (AddICRVector), with the OS's own interrupts left running.
; Run time SECS (default 5); the left mouse button stops the run early.
;
; The hardware part is run_direct/run_os/measure and the handlers; the rest
; (arguments, post-processing, report) is checked under vamos by
; test_irqlat.sh with -DVAMOS=1, which skips the graphics.library and
; ciab.resource calls and replaces the samples with a synthetic set.
; Every custom-chip access is a word access (the chip bus is 16 bits wide).

_LVOSupervisor	equ	-30
_LVODisable	equ	-120
_LVOEnable	equ	-126
_LVOForbid	equ	-132
_LVOPermit	equ	-138
_LVOAddIntServer equ	-168
_LVORemIntServer equ	-174
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOCloseLibrary equ	-414
_LVOOpenResource equ	-498
_LVOOpenLibrary	equ	-552
_LVOCacheClearU	equ	-636
_LVOVPrintf	equ	-954
_LVOReadArgs	equ	-798
_LVOFreeArgs	equ	-858
_LVOLoadView	equ	-222
_LVOWaitBlit	equ	-228
_LVOWaitTOF	equ	-270
_LVOOwnBlitter	equ	-456
_LVODisownBlitter equ	-462
_LVOAddICRVector equ	-6
_LVORemICRVector equ	-12
_LVOAbleICR	equ	-18

LIB_VERSION	equ	20
AttnFlags	equ	296
VBlankFrequency	equ	530
EClockFrequency	equ	568
gb_ActiView	equ	34
gb_copinit	equ	38
MEMF_CHIP	equ	2
MEMF_FAST	equ	4
MEMF_CLEAR	equ	$10000
INTB_COPER	equ	4

DMACONR		equ	$dff002
VPOSR		equ	$dff004
VHPOSR		equ	$dff006
INTENAR		equ	$dff01c
BLTCON0		equ	$dff040
BLTCON1		equ	$dff042
BLTAFWM		equ	$dff044
BLTALWM		equ	$dff046
BLTCPT		equ	$dff048
BLTBPT		equ	$dff04c
BLTAPT		equ	$dff050
BLTDPT		equ	$dff054
BLTSIZE		equ	$dff058
BLTCMOD		equ	$dff060
BLTBMOD		equ	$dff062
BLTAMOD		equ	$dff064
BLTDMOD		equ	$dff066
COP1LC		equ	$dff080
COPJMP1		equ	$dff088
DMACON		equ	$dff096
INTENA		equ	$dff09a
INTREQ		equ	$dff09c
CIAAPRA		equ	$bfe001
CIAATODLO	equ	$bfe801
CIAATODMID	equ	$bfe901
CIAATODHI	equ	$bfea01
CIABTALO	equ	$bfd400
CIABTAHI	equ	$bfd500
CIABTODLO	equ	$bfd800
CIABTODMID	equ	$bfd900
CIABTODHI	equ	$bfda00
CIABICR		equ	$bfdd00
CIABCRA		equ	$bfde00

CHIPSIZE	equ	131072		; load buffer: 2 x 64 KB
FASTSIZE	equ	65536
PLANESIZE	equ	10240		; 320 x 256 lores
PLANEMEM	equ	8*PLANESIZE+16384 ; slack: an over-long fetch reads past
MAXSAMP		equ	262144		; per source, 8 bytes each
LD_FASTWR	equ	4
LD_FPU		equ	6

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
	bra.s	.close
.args:	bsr	parse
	bne.s	.close
	bsr	setup
	bne.s	.free
	bsr	header
	tst.b	osmode
	bne.s	.os
	bsr	run_direct
	bra.s	.rep
.os:	bsr	run_os
.rep:	bsr	report
	clr.l	rc
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
; returns d0 = 0 (Z set) when the options are good, else prints why
parse:	movem.l	d2-d3/a2-a3,-(sp)
	moveq	#0,d2			; LOAD index
	lea	loadtab(pc),a3
	move.l	argv,d0
	beq.s	.ld
	move.l	d0,a2
.lt:	move.l	(a3),d0
	beq	.badload
	move.l	d0,a1
	move.l	a2,a0
	bsr	stricmp
	beq.s	.ld
	addq.l	#1,d2
	addq.l	#8,a3
	bra.s	.lt
.ld:	move.l	d2,loadidx
	move.l	(a3)+,loadname
	move.l	(a3),loadfn
	tst.l	argv+4
	sne	bpl
	moveq	#3,d0
	move.l	argv+8,d1
	beq.s	.fm
	move.l	d1,a0
	move.l	(a0),d0
	cmp.l	#3,d0
	bhi	.badfm
.fm:	move.l	d0,fmode
	tst.l	argv+12
	sne	nasty
	move.l	#1000,d0
	move.l	argv+16,d1
	beq.s	.rt
	move.l	d1,a0
	move.l	(a0),d0
.rt:	cmp.l	#20,d0			; below 20 Hz the ns arithmetic overflows
	blo.s	.badrate
	cmp.l	#20000,d0
	bhi.s	.badrate
	move.l	d0,rate
	moveq	#5,d0
	move.l	argv+20,d1
	beq.s	.sc
	move.l	d1,a0
	move.l	(a0),d0
.sc:	tst.l	d0
	beq.s	.badsecs
	cmp.l	#600,d0
	bhi.s	.badsecs
	move.l	d0,secs
	tst.l	argv+24
	sne	osmode
	moveq	#0,d0
.ret:	movem.l	(sp)+,d2-d3/a2-a3
	tst.l	d0
	rts
.badload:
	move.l	a2,args
	lea	msg_badload(pc),a0
	bra.s	.err
.badfm:	lea	msg_badfm(pc),a0
	bra.s	.err
.badrate:
	lea	msg_badrate(pc),a0
	bra.s	.err
.badsecs:
	lea	msg_badsecs(pc),a0
.err:	lea	args,a1
	bsr	printf
	moveq	#1,d0
	bra.s	.ret

; case-insensitive compare of the strings at a0 and a1: Z set if equal
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
; d0 = 0 (Z set) when everything is allocated and opened
setup:	movem.l	d2-d7/a2-a6,-(sp)
	move.l	sysbase,a6
; E clock: exec V36+ knows it; anything implausible is taken as PAL
	move.l	#709379,d0
	cmp.w	#36,LIB_VERSION(a6)
	blo.s	.e
	move.l	EClockFrequency(a6),d1
	cmp.l	#700000,d1
	blo.s	.e
	cmp.l	#720000,d1
	bhi.s	.e
	move.l	d1,d0
.e:	move.l	d0,eclock
	moveq	#50,d1
	cmp.b	#60,VBlankFrequency(a6)
	bne.s	.pal
	moveq	#60,d1
.pal:	move.l	d1,vfreq
	move.l	#313*227,framecc	; PAL: 313 lines of 227 colour clocks
	cmp.l	#60,d1
	bne.s	.fc
	move.l	#263*227,framecc
; timer latch: the count runs latch..0, so a period is latch+1 ticks
.fc:	move.l	rate,d1
	move.l	d1,d2
	lsr.l	#1,d2
	add.l	d0,d2
	divu.l	d1,d2
	subq.l	#1,d2
	move.l	d2,latch
; ns per tick, times 64: (1e9/E)*64 + ((1e9 mod E)*64)/E; a colour clock is E/5
	move.l	#1000000000,d1
	divul.l	d0,d2:d1
	lsl.l	#6,d1
	lsl.l	#6,d2
	divu.l	d0,d2
	add.l	d2,d1
	move.l	d1,k_tick
	addq.l	#2,d1
	divu.l	#5,d1
	move.l	d1,k_cc
; copper requests: line * 227 + $10, the position the WAITs in cop_tpl use
	lea	reqlines(pc),a0
	lea	reqpos,a1
	moveq	#3,d1
.rq:	move.w	(a0)+,d0
	mulu.w	#227,d0
	add.l	#$10,d0
	move.l	d0,(a1)+
	dbf	d1,.rq
; the run ends after SECS seconds of copper requests (4 a frame)
	move.l	vfreq,d0
	mulu.l	secs,d0
	lsl.l	#2,d0
	move.l	d0,cop_target
	add.l	#256,d0
	move.l	d0,cop_cap
	move.l	secs,d0
	addq.l	#1,d0
	mulu.l	rate,d0
	add.l	#64,d0
	cmp.l	#MAXSAMP,d0
	bls.s	.cc
	move.l	#MAXSAMP,d0
.cc:	move.l	d0,cia_cap
; DMA we switch on: copper, blitter, and bitplanes / blitter-nasty on request
	move.w	#$82c0,d0
	tst.b	bpl
	beq.s	.d1
	or.w	#$0100,d0
.d1:	tst.b	nasty
	beq.s	.d2
	or.w	#$0400,d0
.d2:	move.w	d0,dma_on
; the CPU: VBR and CACR (68010+/68020+ only), the FPU for LOAD=FPU
	move.w	AttnFlags(a6),d0
	btst	#1,d0
	beq.s	.nosv
	lea	sv_info(pc),a5
	jsr	_LVOSupervisor(a6)
.nosv:	cmp.l	#LD_FPU,loadidx
	bne.s	.fpok
	move.w	AttnFlags(a6),d0
	and.w	#$70,d0			; 68881, 68882, 68040 FPU
	beq	.nofpu
.fpok:
; memory
	move.l	#CHIPSIZE,d0
	move.l	#MEMF_CHIP|MEMF_CLEAR,d1
	bsr	alloc
	move.l	d0,chipbuf
	beq	.nomem
	move.l	#cop_end-cop_tpl,d0
	moveq	#MEMF_CHIP,d1
	bsr	alloc
	move.l	d0,coplist
	beq	.nomem
	move.l	cia_cap,d0
	lsl.l	#3,d0
	moveq	#0,d1
	bsr	alloc
	move.l	d0,ciabuf
	beq	.nomem
	move.l	cia_cap,d1
	lsl.l	#3,d1
	add.l	d1,d0
	move.l	d0,cia_end
	move.l	cop_cap,d0
	lsl.l	#3,d0
	moveq	#0,d1
	bsr	alloc
	move.l	d0,copbuf
	beq	.nomem
	move.l	cop_cap,d1
	lsl.l	#3,d1
	add.l	d1,d0
	move.l	d0,copb_end
	cmp.l	#LD_FASTWR,loadidx
	bne.s	.nf
	move.l	#FASTSIZE,d0
	moveq	#MEMF_FAST,d1
	bsr	alloc
	move.l	d0,fastbuf
	beq	.nofast
.nf:	tst.b	bpl
	beq.s	.np
	move.l	#PLANEMEM,d0
	moveq	#MEMF_CHIP,d1
	bsr	alloc
	move.l	d0,planes
	beq	.nomem
.np:
	ifnd	VAMOS
	lea	gfxname(pc),a1
	moveq	#39,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,gfxbase
	beq	.nogfx
	lea	ciabname(pc),a1
	jsr	_LVOOpenResource(a6)
	move.l	d0,ciabbase
	beq	.nociab
	move.l	d0,a6
	moveq	#0,d0			; CIAICRB_TA
	lea	ciaint,a1
	jsr	_LVOAddICRVector(a6)
	tst.l	d0
	bne	.inuse
	st	icr_owned
	move.l	sysbase,a6
	endc
	bsr	build_cop
	moveq	#0,d0
.ret:	movem.l	(sp)+,d2-d7/a2-a6
	tst.l	d0
	rts
	ifnd	VAMOS
.nogfx:	lea	msg_nogfx(pc),a0
	bra.s	.err
.nociab: lea	msg_nociab(pc),a0
	bra.s	.err
.inuse:	move.l	d0,a0			; the owner's struct Interrupt
	move.l	10(a0),args		; ln_Name
	move.l	sysbase,a6
	lea	msg_inuse(pc),a0
	bra.s	.err
	endc
.nofpu:	lea	msg_nofpu(pc),a0
	bra.s	.err
.nomem:	lea	msg_nomem(pc),a0
	bra.s	.err
.nofast: lea	msg_nofast(pc),a0
.err:	lea	args,a1
	bsr	printf
	moveq	#1,d0
	bra.s	.ret

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
	ifnd	VAMOS
	tst.b	icr_owned
	beq.s	.ni
	move.l	ciabbase,a6
	moveq	#0,d0
	lea	ciaint,a1
	jsr	_LVORemICRVector(a6)
.ni:	move.l	sysbase,a6
	move.l	gfxbase,d0
	beq.s	.ng
	move.l	d0,a1
	jsr	_LVOCloseLibrary(a6)
.ng:
	endc
	move.l	sysbase,a6
	lea	alloctab,a2
	move.l	nalloc,d2
	bra.s	.f1
.f:	move.l	(a2)+,a1
	move.l	(a2)+,d0
	jsr	_LVOFreeMem(a6)
.f1:	dbf	d2,.f
	movem.l	(sp)+,d2/a2/a6
	rts

sv_info: movec	vbr,d0
	move.l	d0,v_vbr
	movec	cacr,d0
	move.l	d0,v_cacr
	rte

; our copper list: display set-up, then the four COPER requests
build_cop:
	lea	cop_tpl(pc),a0
	move.l	coplist,a1
	move.w	#(cop_end-cop_tpl)/2-1,d0
.c:	move.w	(a0)+,(a1)+
	dbf	d0,.c
	tst.b	bpl
	beq.s	.x
	move.l	coplist,a1
	move.l	fmode,d0
	move.w	d0,cop_fm-cop_tpl+2(a1)
	move.w	#$0211,cop_bc0-cop_tpl+2(a1)	; 8 planes lores, colour, ECSENA
; DDFSTOP = $38 + 160 - fetch unit: 8 colour clocks (FMODE 0), 16 (1, 2), 32 (3)
	move.w	#$00d0,d1
	tst.l	d0
	beq.s	.dd
	move.w	#$00c8,d1
	cmp.l	#3,d0
	bne.s	.dd
	move.w	#$00b8,d1
.dd:	move.w	d1,cop_ddf-cop_tpl+2(a1)
	lea	cop_bpl-cop_tpl+2(a1),a1
	move.l	planes,d0
	moveq	#7,d1
.p:	swap	d0
	move.w	d0,(a1)
	swap	d0
	move.w	d0,4(a1)
	addq.l	#8,a1
	add.l	#PLANESIZE,d0
	dbf	d1,.p
; something to look at: noise in the planes
	move.l	planes,a0
	move.l	#PLANEMEM/4-1,d1
	move.l	#$12345678,d0
.f:	move.l	d0,(a0)+
	mulu.l	#1664525,d0
	add.l	#1013904223,d0
	subq.l	#1,d1
	bpl.s	.f
.x:	rts

;---------------------------------------------------------------- report
header:	lea	args,a1
	move.l	#s_direct,(a1)
	tst.b	osmode
	beq.s	.m
	move.l	#s_os,(a1)
.m:	move.l	loadname,4(a1)
	lea	fmt_hdr1(pc),a0
	bsr	printf
	lea	s_off(pc),a0
	tst.b	bpl
	beq.s	.b
	move.l	fmode,(a1)
	lea	fmt_hdr2(pc),a0
.b:	bsr	printf
	move.l	#s_empty,(a1)
	tst.b	nasty
	beq.s	.n
	move.l	#s_nasty,(a1)
.n:	move.l	rate,4(a1)
	move.l	latch,8(a1)
	move.l	secs,12(a1)
	move.l	eclock,16(a1)
	move.l	#s_pal,20(a1)
	cmp.l	#50,vfreq
	beq.s	.p
	move.l	#s_ntsc,20(a1)
.p:	move.l	v_vbr,24(a1)
	move.l	v_cacr,28(a1)
	lea	fmt_hdr3(pc),a0
	bra	printf

report:	movem.l	d2-d7/a2-a6,-(sp)
; CIA-B timer A: expected = E ticks elapsed / period; a line is 227/5 E ticks
	move.l	ciabuf,a2
	move.l	cia_n,d7
	cmp.l	cia_cap,d7
	bls.s	.c1
	move.l	cia_cap,d7
.c1:	bsr	conv_cia
	move.l	ciabuf,a2
	bsr	stats
	move.l	lines,d1
	mulu.l	#227,d1
	divu.l	#5,d1
	move.l	latch,d0
	addq.l	#1,d0
	divu.l	d0,d1
	move.l	cia_n,d0
	lea	s_cia(pc),a0
	lea	s_ciard(pc),a1
	bsr	print_block
; copper: 4 requests a frame, frames from CIA-A's TOD (it counts VSYNC)
	move.l	copbuf,a2
	move.l	cop_n,d7
	cmp.l	cop_cap,d7
	bls.s	.c2
	move.l	cop_cap,d7
.c2:	bsr	conv_cop
	move.l	copbuf,a2
	bsr	stats
	move.l	frames,d1
	lsl.l	#2,d1
	move.l	cop_n,d0
	lea	s_cop(pc),a0
	lea	s_coprd(pc),a1
	bsr	print_block
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; CIA samples (hA, lo, hB, hA2, lo2, hB2) -> (latency ns, read cost ns).
; a2 = samples, d7 = count.  The count runs down; latency = latch - count.
conv_cia:
	movem.l	d2-d7/a2,-(sp)
	move.l	latch,d6
	move.l	k_tick,d5
	subq.l	#1,d7
	bmi.s	.x
.l:	moveq	#0,d0
	moveq	#0,d1
	moveq	#0,d2
	move.b	3(a2),d0
	move.b	4(a2),d1
	move.b	5(a2),d2
	bsr.s	cia_count
	move.l	d0,d3			; second read
	moveq	#0,d0
	move.b	(a2),d0
	move.b	1(a2),d1
	move.b	2(a2),d2
	bsr.s	cia_count		; first read
	move.l	d6,d4
	sub.l	d0,d4
	bpl.s	.e
	moveq	#0,d4
.e:	mulu.l	d5,d4
	lsr.l	#6,d4
	move.l	d0,d1
	sub.l	d3,d1			; ticks between the two reads
	bpl.s	.r
	add.l	d6,d1			; the timer reloaded in between
	addq.l	#1,d1
.r:	mulu.l	d5,d1
	lsr.l	#6,d1
	move.l	d4,(a2)+
	move.l	d1,(a2)+
	subq.l	#1,d7
	bpl.s	.l
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; The timer's two bytes cannot be read at once.  Reading hi, lo, hi again: if
; the two hi reads differ, the low byte borrowed in between, and lo tells on
; which side of the borrow it was read (just after it lo is near $FF).
; d0 = hA, d1 = lo, d2 = hB (zero-extended): d0 = the count at the lo read
cia_count:
	cmp.b	d0,d2
	beq.s	.s
	cmp.b	#$80,d1
	blo.s	.s
	move.l	d2,d0
.s:	lsl.l	#8,d0
	or.l	d1,d0
	rts

; copper samples (VHPOSR, VPOSR, VHPOSR again) -> (latency ns, read cost ns)
conv_cop:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	k_cc,d5
	lea	reqpos,a3
	subq.l	#1,d7
	bmi	.x
.l:	moveq	#0,d0
	move.w	(a2),d0			; VHPOSR: V7-V0, H8-H1
	moveq	#0,d1
	move.w	2(a2),d1		; VPOSR: bit 0 = V8
	moveq	#0,d2
	move.w	4(a2),d2
	and.w	#1,d1
	lsl.w	#8,d1
	move.l	d0,d3
	lsr.w	#8,d3
	or.w	d1,d3			; line
	mulu.w	#227,d3
	moveq	#0,d1
	move.b	d0,d1
	add.l	d1,d3			; position in the frame, colour clocks
	moveq	#3,d4			; the last request at or before it
.f:	cmp.l	(a3,d4.l*4),d3
	bhs.s	.fd
	dbf	d4,.f
	add.l	framecc,d3		; before the first: the previous frame's last
	moveq	#3,d4
.fd:	sub.l	(a3,d4.l*4),d3
	mulu.l	d5,d3
	lsr.l	#6,d3
	move.l	d2,d4			; read cost: second VHPOSR - first
	lsr.w	#8,d4
	move.l	d0,d6
	lsr.w	#8,d6
	sub.w	d6,d4
	and.l	#$ff,d4
	mulu.w	#227,d4
	moveq	#0,d6
	move.b	d2,d6
	add.l	d6,d4
	moveq	#0,d6
	move.b	d0,d6
	sub.l	d6,d4
	mulu.l	d5,d4
	lsr.l	#6,d4
	move.l	d3,(a2)+
	move.l	d4,(a2)+
	subq.l	#1,d7
	bpl	.l
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; a2 = (latency, read) records, d7 = count: min, max, averages, histogram,
; the five worst (latency, index), largest first, earliest first on a tie
stats:	movem.l	d2-d7/a2-a4,-(sp)
	move.l	d7,st_n
	moveq	#-1,d0
	move.l	d0,st_min
	clr.l	st_max
	clr.l	st_rdmax
	lea	st_hist,a0
	moveq	#11,d0
.ch:	clr.l	(a0)+
	dbf	d0,.ch
	lea	st_worst,a0
	moveq	#4,d0
.cw:	move.l	#-1,(a0)+
	move.l	#-1,(a0)+
	dbf	d0,.cw
	moveq	#0,d2			; latency sum, 64 bits: d2:d3
	moveq	#0,d3
	moveq	#0,d4			; read cost sum: d4:d5
	moveq	#0,d5
	moveq	#0,d6			; index
	tst.l	d7
	beq	.done
.l:	move.l	(a2)+,d0
	move.l	(a2)+,d1
	cmp.l	st_min,d0
	bhs.s	.1
	move.l	d0,st_min
.1:	cmp.l	st_max,d0
	bls.s	.2
	move.l	d0,st_max
.2:	cmp.l	st_rdmax,d1
	bls.s	.3
	move.l	d1,st_rdmax
.3:	add.l	d0,d3
	bcc.s	.4
	addq.l	#1,d2
.4:	add.l	d1,d5
	bcc.s	.5
	addq.l	#1,d4
.5:	lea	st_hist,a4		; bucket: < 1 us, < 2, < 4 ... < 1024, more
	move.l	#1000,d1
.h:	cmp.l	d1,d0
	blo.s	.hd
	addq.l	#4,a4
	add.l	d1,d1
	cmp.l	#st_hist+44,a4
	blo.s	.h
.hd:	addq.l	#1,(a4)
	lea	st_worst+32,a3		; slot 4, the smallest kept
	cmp.l	(a3),d0
	ble.s	.wd
	moveq	#3,d1
.w:	cmp.l	-8(a3),d0
	ble.s	.ws
	move.l	-8(a3),(a3)
	move.l	-4(a3),4(a3)
	subq.l	#8,a3
	dbf	d1,.w
.ws:	move.l	d0,(a3)
	move.l	d6,4(a3)
.wd:	addq.l	#1,d6
	cmp.l	d7,d6
	blo	.l
	divu.l	d7,d2:d3
	divu.l	d7,d4:d5
.done:	move.l	d3,st_avg
	move.l	d5,st_rdavg
	movem.l	(sp)+,d2-d7/a2-a4
	rts

; a0 = title, a1 = what the read cost covers, d0 = taken, d1 = expected
print_block:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a1,a3
	lea	args,a1
	move.l	a0,(a1)
	move.l	d0,4(a1)
	move.l	d1,8(a1)
	sub.l	d0,d1
	bcc.s	.m
	moveq	#0,d1
.m:	move.l	d1,12(a1)
	move.l	st_n,16(a1)
	lea	fmt_src(pc),a0
	bsr	printf
	tst.l	st_n
	bne.s	.have
	lea	msg_none(pc),a0
	bsr	puts
	bra	.x
.have:	move.l	st_min,d0
	bsr	us2
	move.l	st_avg,d0
	bsr	us2
	move.l	st_max,d0
	bsr	us2
	lea	fmt_lat(pc),a0
	lea	args,a1
	bsr	printf
	move.l	a3,(a1)+
	move.l	st_rdavg,d0
	bsr	us2
	move.l	st_rdmax,d0
	bsr	us2
	lea	fmt_rd(pc),a0
	lea	args,a1
	bsr	printf
	lea	st_hist,a0
	moveq	#11,d0
.hc:	move.l	(a0)+,(a1)+
	dbf	d0,.hc
	lea	fmt_hist(pc),a0
	lea	args,a1
	bsr	printf
	lea	fmt_worst(pc),a0
	bsr	puts
	lea	st_worst,a2
	moveq	#4,d2
.wl:	tst.l	4(a2)
	bmi.s	.wn
	move.l	(a2),d0
	bsr	us2
	move.l	4(a2),(a1)
	lea	fmt_w1(pc),a0
	lea	args,a1
	bsr	printf
.wn:	addq.l	#8,a2
	dbf	d2,.wl
	lea	s_nl(pc),a0
	bsr	puts
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; d0 = ns -> (a1)+ = whole microseconds, (a1)+ = hundredths
us2:	move.l	d1,-(sp)
	divul.l	#1000,d1:d0
	move.l	d0,(a1)+
	divu.l	#10,d1
	move.l	d1,(a1)+
	move.l	(sp)+,d1
	rts

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

;---------------------------------------------------------------- hardware
; Direct: Disable, INTENA all off, our own vectors, nothing of the OS runs.
run_direct:
	movem.l	d2-d7/a2-a6,-(sp)
	ifnd	VAMOS
	bsr	gfx_take
	move.l	ciabbase,a6		; the CIA-B ICR mask as the OS has it
	moveq	#0,d0
	jsr	_LVOAbleICR(a6)
	move.b	d0,icr_save
	endc
	move.l	sysbase,a6
	jsr	_LVODisable(a6)
	move.w	DMACONR,dmacon_save
	move.w	INTENAR,intena_save
	move.w	#$7fff,INTENA
	move.w	#$7fff,DMACON
	move.w	dma_on,DMACON
	move.l	v_vbr,a0
	move.l	$6c(a0),old6c
	move.l	$78(a0),old78
	move.l	#l3_direct,$6c(a0)
	move.l	#l6_direct,$78(a0)
	jsr	_LVOCacheClearU(a6)
	bsr	cop_on
	move.b	#$7f,CIABICR		; every CIA-B source off, flags cleared
	tst.b	CIABICR
	move.w	#$e010,int_on		; INTEN, EXTER, COPER
	move.w	#$7fff,int_off
	bsr	measure
	move.b	#$7f,CIABICR
	tst.b	CIABICR
	move.b	icr_save,d0
	or.b	#$80,d0
	move.b	d0,CIABICR
	move.l	v_vbr,a0
	move.l	old6c,$6c(a0)
	move.l	old78,$78(a0)
	jsr	_LVOCacheClearU(a6)
	bsr	cop_off
	move.w	#$7fff,DMACON
	move.w	dmacon_save,d0
	or.w	#$8000,d0
	move.w	d0,DMACON
	move.w	#$2010,INTREQ
	move.w	intena_save,d0		; INTEN is off in it (Disable); Enable sets it
	or.w	#$8000,d0
	move.w	d0,INTENA
	jsr	_LVOEnable(a6)
	ifnd	VAMOS
	bsr	gfx_give
	endc
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; OS: the same requests, through exec's COPER server chain and ciab.resource
run_os:	movem.l	d2-d7/a2-a6,-(sp)
	ifnd	VAMOS
	bsr	gfx_take
	endc
	move.w	DMACONR,dmacon_save
	move.w	INTENAR,intena_save
	move.w	#$0020,DMACON		; sprites off (our list sets no pointers)
	move.w	dma_on,DMACON
	move.l	sysbase,a6
	moveq	#INTB_COPER,d0
	lea	copint,a1
	jsr	_LVOAddIntServer(a6)
	bsr	cop_on
	move.w	#$8010,int_on
	clr.w	int_off
	bsr	measure
	move.w	intena_save,d0
	btst	#4,d0
	bne.s	.keep
	move.w	#$0010,INTENA
.keep:	moveq	#INTB_COPER,d0
	lea	copint,a1
	jsr	_LVORemIntServer(a6)
	bsr	cop_off
	move.w	dma_on,d0		; off what we switched on, on what was on
	and.w	#$07ff,d0
	move.w	dmacon_save,d1
	not.w	d1
	and.w	d1,d0
	move.w	d0,DMACON
	move.w	dmacon_save,d0
	or.w	#$8000,d0
	move.w	d0,DMACON
	ifnd	VAMOS
	bsr	gfx_give
	endc
	movem.l	(sp)+,d2-d7/a2-a6
	rts

	ifnd	VAMOS
gfx_take:
	move.l	sysbase,a6
	jsr	_LVOForbid(a6)
	move.l	gfxbase,a6
	move.l	gb_ActiView(a6),oldview
	sub.l	a1,a1
	jsr	_LVOLoadView(a6)
	jsr	_LVOWaitTOF(a6)
	jsr	_LVOWaitTOF(a6)
	jsr	_LVOOwnBlitter(a6)
	jsr	_LVOWaitBlit(a6)
	rts
gfx_give:
	move.l	gfxbase,a6
	jsr	_LVODisownBlitter(a6)
	move.l	oldview,a1
	jsr	_LVOLoadView(a6)
	jsr	_LVOWaitTOF(a6)
	jsr	_LVOWaitTOF(a6)
	move.l	sysbase,a6
	jsr	_LVOPermit(a6)
	rts
	endc

cop_on:	move.l	coplist,d0
	lea	COP1LC,a0
	bsr.s	wr_ptr
	move.w	d0,COPJMP1
	rts
cop_off:
	moveq	#0,d0
	ifnd	VAMOS
	move.l	gfxbase,a0
	move.l	gb_copinit(a0),d0
	endc
	lea	COP1LC,a0
	bsr.s	wr_ptr
	move.w	d0,COPJMP1
	rts
; a pointer register pair at a0 = d0, high word first, as two word writes
wr_ptr:	swap	d0
	move.w	d0,(a0)
	swap	d0
	move.w	d0,2(a0)
	rts

; One measurement: the timer is started last, stale requests are cleared,
; the load runs until the copper handler has seen SECS seconds (or the left
; mouse button), then the interrupts go off again.
measure:
	movem.l	d2-d7/a2-a6,-(sp)
	sf	done
	clr.l	cia_n
	clr.l	cop_n
	move.l	ciabuf,cia_ptr
	move.l	copbuf,cop_ptr
	bsr	tod_a
	move.l	d0,frames
	bsr	tod_b
	move.l	d0,lines
	bsr	timer_start
	tst.b	osmode
	bne.s	.os
	move.b	#$81,CIABICR		; timer A only
	move.w	#$2010,INTREQ
	move.w	#$2010,INTREQ
	bra.s	.on
.os:	move.w	#$0010,INTREQ
.on:	st	running
	move.w	int_on,INTENA
	ifd	VAMOS
	st	done			; each load loop runs one pass
	endc
	move.l	loadfn,a0
	jsr	(a0)
	move.w	int_off,INTENA
	sf	running
	bsr	timer_stop
	bsr	tod_a
	sub.l	frames,d0
	and.l	#$ffffff,d0
	move.l	d0,frames
	bsr	tod_b
	sub.l	lines,d0
	and.l	#$ffffff,d0
	move.l	d0,lines
	bsr	wait_blit
	ifd	VAMOS
	bsr	fake
	endc
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; CIA-B timer A: stop, latch low then high (loads the counter while stopped),
; then START | LOAD, continuous mode, counting the E clock
timer_start:
	move.b	CIABCRA,d0
	move.b	d0,cra_save
	and.b	#$c0,d0
	move.b	d0,CIABCRA
	move.l	latch,d1
	move.b	d1,CIABTALO
	lsr.w	#8,d1
	move.b	d1,CIABTAHI
	or.b	#$11,d0
	move.b	d0,CIABCRA
	rts
timer_stop:
	move.b	cra_save,d0
	and.b	#$ee,d0			; as found, but stopped and no LOAD strobe
	move.b	d0,CIABCRA
	rts

; TOD: reading the high byte latches the count until the low byte is read
tod_a:	moveq	#0,d0
	move.b	CIAATODHI,d0
	lsl.l	#8,d0
	move.b	CIAATODMID,d0
	lsl.l	#8,d0
	move.b	CIAATODLO,d0
	rts
tod_b:	moveq	#0,d0
	move.b	CIABTODHI,d0
	lsl.l	#8,d0
	move.b	CIABTODMID,d0
	lsl.l	#8,d0
	move.b	CIABTODLO,d0
	rts

wait_blit:
	move.w	DMACONR,d0		; the first BBUSY read can be stale
.w:	move.w	DMACONR,d0
	btst	#14,d0
	bne.s	.w
	rts

;---------------------------------------------------------------- handlers
; The first instruction samples the source.  Absolute memory destinations:
; no register has to be saved before the sample is taken.
	cnop	0,4
l6_direct:
	move.b	CIABTAHI,craw
	move.b	CIABTALO,craw+1
	move.b	CIABTAHI,craw+2
	move.b	CIABTAHI,craw+3
	move.b	CIABTALO,craw+4
	move.b	CIABTAHI,craw+5
	tst.b	CIABICR			; acknowledge: clears TA, releases /INT
	move.w	#$2000,INTREQ		; EXTER; twice, so it is in Paula before
	move.w	#$2000,INTREQ		; the RTE (a posted write could re-trigger)
	movem.l	d0/a0,-(sp)
	bsr.s	cia_store
	movem.l	(sp)+,d0/a0
	rte

; ciab.resource calls this (is_Code) after it has read the ICR
cia_os:	move.b	CIABTAHI,craw
	move.b	CIABTALO,craw+1
	move.b	CIABTAHI,craw+2
	move.b	CIABTAHI,craw+3
	move.b	CIABTALO,craw+4
	move.b	CIABTAHI,craw+5
cia_store:
	tst.b	running
	beq.s	.x
	move.l	cia_ptr,a0
	cmp.l	cia_end,a0
	bhs.s	.n
	move.l	craw,(a0)+
	move.l	craw+4,(a0)+
	move.l	a0,cia_ptr
.n:	addq.l	#1,cia_n
.x:	rts

l3_direct:
	move.w	VHPOSR,braw
	move.w	VPOSR,braw+2
	move.w	VHPOSR,braw+4
	move.w	#$0010,INTREQ		; COPER
	move.w	#$0010,INTREQ
	movem.l	d0/a0,-(sp)
	bsr.s	cop_store
	movem.l	(sp)+,d0/a0
	rte

; exec's COPER server chain calls this; Z set on return = not handled
cop_os:	move.w	VHPOSR,braw
	move.w	VPOSR,braw+2
	move.w	VHPOSR,braw+4
	bsr.s	cop_store
	moveq	#0,d0
	rts

cop_store:
	tst.b	running
	beq.s	.x
	move.l	cop_ptr,a0
	cmp.l	copb_end,a0
	bhs.s	.n
	move.l	braw,(a0)+
	move.l	braw+4,(a0)+
	move.l	a0,cop_ptr
.n:	addq.l	#1,cop_n
	move.l	cop_n,d0
	cmp.l	cop_target,d0
	blo.s	.m
	st	done
.m:	btst	#6,CIAAPRA		; left mouse button: stop
	bne.s	.x
	st	done
.x:	rts

;---------------------------------------------------------------- loads
; Each runs until 'done'; the left mouse button also ends it (checked once a
; pass, so the button's CIA read does not become part of the load).
CHECK	macro
	tst.b	done
	bne.s	\1
	btst	#6,CIAAPRA
	bne	\2
	endm

ld_none:
.o:	move.w	#4095,d1
.i:	tst.b	done
	dbne	d1,.i
	CHECK	.x,.o
.x:	rts

; posted longword stores to chip RAM: the 040 store buffer case
ld_chipwr:
	move.l	chipbuf,a2
	moveq	#0,d0
.o:	move.l	a2,a0
	move.w	#65536/64-1,d1
.i:	rept	16
	move.l	d0,(a0)+
	endr
	dbf	d1,.i
	addq.l	#1,d0
	CHECK	.x,.o
.x:	rts

ld_chiprd:
	move.l	chipbuf,a2
.o:	move.l	a2,a0
	move.w	#65536/64-1,d1
.i:	rept	16
	move.l	(a0)+,d0
	endr
	dbf	d1,.i
	CHECK	.x,.o
.x:	rts

ld_chipcpy:
	move.l	chipbuf,a2
.o:	move.l	a2,a0
	lea	65536(a2),a1
	move.w	#65536/64-1,d1
.i:	rept	16
	move.l	(a0)+,(a1)+
	endr
	dbf	d1,.i
	CHECK	.x,.o
.x:	rts

ld_fastwr:
	move.l	fastbuf,a2
	moveq	#0,d0
.o:	move.l	a2,a0
	move.w	#FASTSIZE/64-1,d1
.i:	rept	16
	move.l	d0,(a0)+
	endr
	dbf	d1,.i
	addq.l	#1,d0
	CHECK	.x,.o
.x:	rts

; back-to-back 32 KB blits, all four channels (D = A ? B : C, in place in C)
ld_blit:
	move.l	chipbuf,d2
	move.w	DMACONR,d0
.o:	move.w	DMACONR,d0
	btst	#14,d0
	bne.s	.o
	move.w	#$0fca,BLTCON0
	move.w	#0,BLTCON1
	move.w	#$ffff,BLTAFWM
	move.w	#$ffff,BLTALWM
	move.w	#0,BLTAMOD
	move.w	#0,BLTBMOD
	move.w	#0,BLTCMOD
	move.w	#0,BLTDMOD
	move.l	d2,d0
	lea	BLTAPT,a0
	bsr	wr_ptr
	add.l	#32768,d0
	lea	BLTBPT,a0
	bsr	wr_ptr
	add.l	#32768,d0
	lea	BLTCPT,a0
	bsr	wr_ptr
	lea	BLTDPT,a0
	bsr	wr_ptr
	move.w	#256<<6,BLTSIZE		; 256 lines x 64 words: starts the blit
	CHECK	.x,.o
.x:	rts

; FMUL/FDIV/FSQRT, all in the 68040's FPU hardware; values stay bounded
ld_fpu:	fmove.s	#1.5,fp1
	fmove.s	#2.0,fp0
.o:	move.w	#4095,d1
.i:	fmul.x	fp1,fp0
	fdiv.x	fp1,fp0
	fsqrt.x	fp0,fp2
	fmul.x	fp2,fp2
	dbf	d1,.i
	CHECK	.x,.o
.x:	rts

;---------------------------------------------------------------- vamos
	ifd	VAMOS
; the synthetic samples test_irqlat.sh models: a borrow on either side of the
; low-byte read, zero latency, a reload between the two reads; requests at
; every line, V8 set, a sample from before the first request of a frame
fake:	lea	fake_cia(pc),a0
	move.l	ciabuf,a1
	moveq	#6*2-1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
	move.l	#6,cia_n
	lea	fake_cop(pc),a0
	move.l	copbuf,a1
	moveq	#5*2-1,d0
.p:	move.l	(a0)+,(a1)+
	dbf	d0,.p
	move.l	#5,cop_n
	move.l	#110,lines
	move.l	#2,frames
	rts
fake_cia:
	dc.b	2,$c2,2,2,$bf,2,0,0
	dc.b	2,$00,1,1,$fd,1,0,0
	dc.b	2,$fe,1,1,$fb,1,0,0
	dc.b	2,$c4,2,2,$c1,2,0,0
	dc.b	0,$08,0,0,$05,0,0,0
	dc.b	0,$01,0,2,$c3,2,0,0
fake_cop:
	dc.w	$3014,$a300,$3016,0
	dc.w	$7220,$a300,$7222,0
	dc.w	$0530,$a300,$0532,0
	dc.w	$1000,$a301,$1003,0
	dc.w	$b010,$a300,$b101,0
	endc

;---------------------------------------------------------------- data
	cnop	0,4
; the copper list template (word pairs: register, value)
cop_tpl:
cop_fm:	dc.w	$1fc,0			; FMODE
cop_bc0: dc.w	$100,$0201		; BPLCON0: no planes, colour, ECSENA
	dc.w	$102,0,$104,0,$10c,$0011 ; BPLCON1, BPLCON2, BPLCON4
	dc.w	$08e,$2c81,$090,$2cc1	; DIWSTRT, DIWSTOP
	dc.w	$092,$0038		; DDFSTRT
cop_ddf: dc.w	$094,$00d0		; DDFSTOP
	dc.w	$108,0,$10a,0		; BPL1MOD, BPL2MOD
cop_bpl: dc.w	$0e0,0,$0e2,0,$0e4,0,$0e6,0,$0e8,0,$0ea,0,$0ec,0,$0ee,0
	dc.w	$0f0,0,$0f2,0,$0f4,0,$0f6,0,$0f8,0,$0fa,0,$0fc,0,$0fe,0
	dc.w	$180,$0000		; COLOR00
	dc.w	$3011,$fffe,$09c,$8010	; WAIT line $30, h $10; INTREQ = COPER
	dc.w	$7011,$fffe,$09c,$8010
	dc.w	$b011,$fffe,$09c,$8010
	dc.w	$f011,$fffe,$09c,$8010
	dc.w	$ffff,$fffe
cop_end:
reqlines: dc.w	$30,$70,$b0,$f0

; the interrupt structures (ln_Succ, ln_Pred, ln_Type, ln_Pri, ln_Name,
; is_Data, is_Code); priority 127 = first in the COPER chain
copint:	dc.l	0,0
	dc.b	2,127
	dc.l	intname,0,cop_os
ciaint:	dc.l	0,0
	dc.b	2,0
	dc.l	intname,0,cia_os

loadtab: dc.l	n_none,ld_none,n_chipwr,ld_chipwr,n_chiprd,ld_chiprd
	dc.l	n_chipcpy,ld_chipcpy,n_fastwr,ld_fastwr,n_blit,ld_blit
	dc.l	n_fpu,ld_fpu,0

sysbase: dc.l	0
dosbase: dc.l	0
gfxbase: dc.l	0
ciabbase: dc.l	0
rdargs:	dc.l	0
rc:	dc.l	0
argv:	ds.l	7
args:	ds.l	16
loadidx: dc.l	0
loadname: dc.l	0
loadfn:	dc.l	0
fmode:	dc.l	3
rate:	dc.l	1000
secs:	dc.l	5
eclock:	dc.l	0
vfreq:	dc.l	50
framecc: dc.l	0
latch:	dc.l	0
k_tick:	dc.l	0
k_cc:	dc.l	0
v_vbr:	dc.l	0
v_cacr:	dc.l	0
oldview: dc.l	0
old6c:	dc.l	0
old78:	dc.l	0
chipbuf: dc.l	0
fastbuf: dc.l	0
planes:	dc.l	0
coplist: dc.l	0
ciabuf:	dc.l	0
cia_end: dc.l	0
cia_ptr: dc.l	0
cia_cap: dc.l	0
cia_n:	dc.l	0
copbuf:	dc.l	0
copb_end: dc.l	0
cop_ptr: dc.l	0
cop_cap: dc.l	0
cop_n:	dc.l	0
cop_target: dc.l 0
frames:	dc.l	0
lines:	dc.l	0
reqpos:	ds.l	4
nalloc:	dc.l	0
alloctab: ds.l	16
st_n:	dc.l	0
st_min:	dc.l	0
st_max:	dc.l	0
st_avg:	dc.l	0
st_rdavg: dc.l	0
st_rdmax: dc.l	0
st_hist: ds.l	12
st_worst: ds.l	10
craw:	ds.l	2
braw:	ds.l	2
dmacon_save: dc.w 0
intena_save: dc.w 0
dma_on:	dc.w	0
int_on:	dc.w	0
int_off: dc.w	0
cra_save: dc.b	0
icr_save: dc.b	0
bpl:	dc.b	0
nasty:	dc.b	0
osmode:	dc.b	0
done:	dc.b	0
running: dc.b	0
icr_owned: dc.b	0

template: dc.b	"LOAD,BPL/S,FMODE/K/N,NASTY/S,RATE/K/N,SECS/K/N,OS/S",0
dosname: dc.b	"dos.library",0
gfxname: dc.b	"graphics.library",0
ciabname: dc.b	"ciab.resource",0
intname: dc.b	"IrqLat",0
n_none:	dc.b	"NONE",0
n_chipwr: dc.b	"CHIPWR",0
n_chiprd: dc.b	"CHIPRD",0
n_chipcpy: dc.b	"CHIPCPY",0
n_fastwr: dc.b	"FASTWR",0
n_blit:	dc.b	"BLIT",0
n_fpu:	dc.b	"FPU",0
s_direct: dc.b	"DIRECT",0
s_os:	dc.b	"OS",0
s_nasty: dc.b	" nasty"
s_empty: dc.b	0
s_pal:	dc.b	"PAL",0
s_ntsc:	dc.b	"NTSC",0
s_cia:	dc.b	"CIA-B timer A (level 6)",0
s_ciard: dc.b	"3 CIA reads",0
s_cop:	dc.b	"Copper (level 3)",0
s_coprd: dc.b	"2 beam reads",0
s_off:	dc.b	"off",0
s_nl:	dc.b	10,0
fmt_hdr1: dc.b	"IrqLat: %s load %s bpl ",0
fmt_hdr2: dc.b	"8 FMODE %ld",0
fmt_hdr3: dc.b	"%s rate %ld Hz latch %ld secs %ld E %ld Hz %s VBR %08lx CACR %08lx",10,0
fmt_src: dc.b	"%s: taken %ld expected %ld missed %ld stored %ld",10,0
fmt_lat: dc.b	"  latency us: min %ld.%02ld avg %ld.%02ld max %ld.%02ld",10,0
fmt_rd:	dc.b	"  read (%s) us: avg %ld.%02ld max %ld.%02ld",10,0
fmt_hist: dc.b	"  hist us: <1 %ld <2 %ld <4 %ld <8 %ld <16 %ld <32 %ld <64 %ld"
	dc.b	" <128 %ld <256 %ld <512 %ld <1024 %ld >=1024 %ld",10,0
fmt_worst: dc.b	"  worst us:",0
fmt_w1:	dc.b	" %ld.%02ld#%ld",0
msg_none: dc.b	"  no samples",10,0
msg_usage: dc.b	"Usage: IrqLat [LOAD=]NONE|CHIPWR|CHIPRD|CHIPCPY|FASTWR|BLIT|FPU"
	dc.b	" [BPL] [FMODE=0..3] [NASTY] [RATE=Hz] [SECS=s] [OS]",10,0
msg_badload: dc.b "IrqLat: unknown LOAD %s (NONE CHIPWR CHIPRD CHIPCPY FASTWR BLIT FPU)",10,0
msg_badfm: dc.b	"IrqLat: FMODE must be 0..3",10,0
msg_badrate: dc.b "IrqLat: RATE must be 20..20000 Hz",10,0
msg_badsecs: dc.b "IrqLat: SECS must be 1..600",10,0
msg_nofpu: dc.b	"IrqLat: LOAD=FPU needs an FPU",10,0
msg_nofast: dc.b "IrqLat: LOAD=FASTWR needs fast RAM",10,0
msg_nomem: dc.b	"IrqLat: not enough memory",10,0
msg_nogfx: dc.b	"IrqLat: no graphics.library V39 (needs AGA Kickstart 3.x)",10,0
msg_nociab: dc.b "IrqLat: no ciab.resource",10,0
msg_inuse: dc.b	"IrqLat: CIA-B timer A is in use by %s",10,0
	even
