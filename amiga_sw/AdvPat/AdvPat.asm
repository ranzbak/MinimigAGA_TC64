; AdvPat -- test screens for the HDMI output (ADV7511), README.md.
;
; The ADV7511 takes 24-bit pixels over a 12-bit DDR bus: on one clock edge
; {G3..G0, B7..B0}, on the other {R7..R0, G7..G4}, on the same 12 pins.  The
; bus is hold-limited (blue noise on dark greys at the -0.8 ns clock delay,
; gone at -1.2 ns).  These screens are the eye scan: for each OSD "HDMI clock
; delay" step, note which patterns show noise.  Also the flashing-demo case
; (sync loss when the whole screen changes colour from frame to frame).
;
;   AdvPat [PAT=n] [LIST] [DUMP=n]
;     PAT=n   start at pattern n (default 0)
;     LIST    print the patterns and exit
;     DUMP=n  print pattern n's 256 colours (hex RRGGBB) and exit
; On screen: left mouse button / space / cursor right: next pattern;
; right button / backspace / cursor left: previous; both buttons or ESC: exit.
;
; Own copper list, AGA 24-bit palette (BPLCON3 banks, LOCT), 8 lores
; bitplanes for the ramps, one plane of $5555 for the single-pixel stripes in
; lores, hires and superhires, no planes for the solid and flash screens
; (COLOR00 fills the whole screen, borders included).  Forbid + LoadView(NULL)
; while it runs; the OS keeps its interrupts (keyboard).
;
; -DVAMOS=1 (test_advpat.sh): no graphics.library, no beam waits, no input:
; shows every pattern from PAT on for four frames each, then exits.

_LVOForbid	equ	-132
_LVOPermit	equ	-138
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552
_LVOVPrintf	equ	-954
_LVOReadArgs	equ	-798
_LVOFreeArgs	equ	-858
_LVOLoadView	equ	-222
_LVOWaitTOF	equ	-270

VBlankFrequency	equ	530
gb_ActiView	equ	34
gb_copinit	equ	38
MEMF_CHIP	equ	2
MEMF_CLEAR	equ	$10000

DMACONR		equ	$dff002
VPOSR		equ	$dff004
VHPOSR		equ	$dff006
POTGOR		equ	$dff016
COP1LC		equ	$dff080
COPJMP1		equ	$dff088
DMACON		equ	$dff096
BPLCON3		equ	$dff106
COLOR00		equ	$dff180
CIAAPRA		equ	$bfe001
CIAASDR		equ	$bfec01

NPAT		equ	24
PLANESIZE	equ	40*256		; lores 320 x 256
STRIPESIZE	equ	160*256+2048	; one superhires-wide plane, and slack
CLSIZE		equ	128		; one copper list
DMA_OURS	equ	$0380		; DMAEN, BPLEN, COPEN
; modes (copper lists)
M_RAMP		equ	0		; 8 planes lores, the ramp image
M_LO		equ	1		; 1 plane of stripes, lores
M_HI		equ	2		; hires
M_SH		equ	3		; superhires
M_NONE		equ	4		; no planes: COLOR00 everywhere
; palette kinds
K_RAMP		equ	0		; pal[i] = (i & a2) * a1
K_DARK4		equ	1		; strips of 0..63: red, green, blue, grey
K_BARS		equ	2		; eight colour bars
K_PAIR		equ	3		; pal[0] = a1, pal[1] = a2
K_SOLID		equ	4		; pal[0] = a1
K_FLASH		equ	5		; a1 = colours, a2 = count << 16 | frames each
; ESC, space, return, backspace, cursor right / left (raw key codes)
KEY_ESC		equ	$45
KEY_SPACE	equ	$40
KEY_RETURN	equ	$44
KEY_BS		equ	$41
KEY_RIGHT	equ	$4e
KEY_LEFT	equ	$4f

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
.args:	tst.l	argv+4
	beq.s	.nolist
	bsr	list
	clr.l	rc
	bra	.close
.nolist: move.l	argv+8,d0
	beq.s	.nodump
	move.l	d0,a0
	move.l	(a0),d0
	cmp.l	#NPAT,d0
	bhs	.badpat
	bsr	dump
	clr.l	rc
	bra	.close
.nodump: moveq	#0,d0
	move.l	argv,d1
	beq.s	.p
	move.l	d1,a0
	move.l	(a0),d0
	cmp.l	#NPAT,d0
	bhs.s	.badpat
.p:	move.l	d0,cur
	bsr	setup
	bne.s	.free
	move.l	cur,args
	lea	msg_keys(pc),a0
	lea	args,a1
	bsr	printf
	bsr	run
	move.l	cur,d0
	move.l	d0,args
	bsr	entry
	move.l	(a0),args+4
	lea	msg_last(pc),a0
	lea	args,a1
	bsr	printf
	clr.l	rc
.free:	bsr	cleanup
	bra.s	.close
.badpat: lea	msg_badpat(pc),a0
	bsr	puts
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

; d0 = pattern: a0 = its table entry
entry:	lea	pattab(pc),a0
	move.l	d0,-(sp)
	lsl.l	#4,d0
	add.l	d0,a0
	move.l	(sp)+,d0
	rts

list:	lea	msg_listhdr(pc),a0
	bsr	puts
	moveq	#0,d2
.l:	move.l	d2,d0
	bsr	entry
	move.l	d2,args
	move.l	(a0),args+4
	lea	fmt_list(pc),a0
	lea	args,a1
	bsr	printf
	addq.l	#1,d2
	cmp.l	#NPAT,d2
	blo.s	.l
	rts

; d0 = pattern: its name, then its 256 colours, eight a line
dump:	move.l	d0,d2
	bsr	make_pal
	move.l	d2,d0
	bsr	entry
	move.l	d2,args
	move.l	(a0),args+4
	lea	fmt_dumphdr(pc),a0
	lea	args,a1
	bsr	printf
	lea	pal,a2
	moveq	#31,d3
.l:	lea	args,a1
	moveq	#7,d0
.c:	move.l	(a2)+,(a1)+
	dbf	d0,.c
	lea	fmt_dump(pc),a0
	lea	args,a1
	bsr	printf
	dbf	d3,.l
	rts

;---------------------------------------------------------------- palettes
; d0 = pattern: pal[0..255] = its colours ($00RRGGBB)
make_pal:
	movem.l	d2-d5/a2-a3,-(sp)
	bsr	entry
	move.l	a0,a3
	lea	pal,a2
	move.l	a2,a0
	move.w	#255,d0
.z:	clr.l	(a0)+
	dbf	d0,.z
	moveq	#0,d2			; i
	move.w	6(a3),d0		; kind
	cmp.w	#K_RAMP,d0
	beq.s	.ramp
	cmp.w	#K_DARK4,d0
	beq.s	.dark4
	cmp.w	#K_BARS,d0
	beq.s	.bars
	cmp.w	#K_FLASH,d0
	beq.s	.flash
	move.l	8(a3),(a2)		; PAIR, SOLID
	cmp.w	#K_PAIR,d0
	bne.s	.x
	move.l	12(a3),4(a2)
	bra.s	.x
.ramp:	move.l	d2,d0
	and.l	12(a3),d0
	mulu.l	8(a3),d0
	move.l	d0,(a2)+
	addq.l	#1,d2
	cmp.l	#256,d2
	blo.s	.ramp
	bra.s	.x
.dark4:	lea	dark4mul(pc),a0
.d4:	move.l	d2,d0
	and.l	#63,d0
	move.l	d2,d1
	lsr.l	#6,d1
	mulu.l	(a0,d1.l*4),d0
	move.l	d0,(a2)+
	addq.l	#1,d2
	cmp.l	#256,d2
	blo.s	.d4
	bra.s	.x
.bars:	lea	bars(pc),a0
.b:	move.l	d2,d0
	and.l	#63,d0
	lsr.l	#3,d0
	move.l	(a0,d0.l*4),(a2)+
	addq.l	#1,d2
	cmp.l	#256,d2
	blo.s	.b
	bra.s	.x
.flash:	move.l	8(a3),a0
	move.w	12(a3),d0		; count
	subq.w	#1,d0
.f:	move.l	(a0)+,(a2)+
	dbf	d0,.f
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

; d0 = $00RRGGBB: d1 = its high nibbles as $0RGB (AGA, BPLCON3 LOCT = 0)
hi4:	move.l	d0,-(sp)
	lsr.l	#4,d0
	bra.s	nib
; d1 = its low nibbles as $0RGB (LOCT = 1)
lo4:	move.l	d0,-(sp)
nib:	move.l	d2,-(sp)
	moveq	#0,d1
	move.l	d0,d2
	swap	d2
	and.w	#$f,d2
	lsl.w	#8,d2
	or.w	d2,d1			; R
	move.w	d0,d2
	lsr.w	#4,d2
	and.w	#$f0,d2
	or.w	d2,d1			; G
	move.w	d0,d2
	and.w	#$f,d2
	or.w	d2,d1			; B
	move.l	(sp)+,d2
	move.l	(sp)+,d0
	rts

; all 256 colours: per bank of 32, high nibbles (LOCT = 0, which also sets
; the low nibbles to the same), then low nibbles (LOCT = 1)
load_pal:
	movem.l	d0-d3/a0-a1,-(sp)
	lea	pal,a0
	moveq	#0,d2			; bank
.b:	move.w	d2,d3
	ror.w	#3,d3			; bank << 13
	or.w	#$0c00,d3		; PF2OF = 3 (the default)
	move.w	d3,BPLCON3
	lea	COLOR00,a1
	moveq	#31,d1
.h:	move.l	(a0)+,d0
	move.l	d1,-(sp)
	bsr	hi4
	move.w	d1,(a1)+
	move.l	(sp)+,d1
	dbf	d1,.h
	lea	-128(a0),a0
	or.w	#$0200,d3		; LOCT
	move.w	d3,BPLCON3
	lea	COLOR00,a1
	moveq	#31,d1
.l:	move.l	(a0)+,d0
	move.l	d1,-(sp)
	bsr	lo4
	move.w	d1,(a1)+
	move.l	(sp)+,d1
	dbf	d1,.l
	addq.w	#1,d2
	cmp.w	#8,d2
	blo.s	.b
	move.w	#$0c00,BPLCON3
	movem.l	(sp)+,d0-d3/a0-a1
	rts

; d0 = colour: COLOR00 = d0 (the flash screens)
set_col0:
	move.l	d1,-(sp)
	move.w	#$0c00,BPLCON3
	bsr	hi4
	move.w	d1,COLOR00
	move.w	#$0e00,BPLCON3
	bsr	lo4
	move.w	d1,COLOR00
	move.w	#$0c00,BPLCON3
	move.l	(sp)+,d1
	rts

;---------------------------------------------------------------- setup
setup:	movem.l	d2-d7/a2-a6,-(sp)
	move.l	sysbase,a6
	move.l	#300,vbl_line		; PAL: the display ends at line $2C+256
	cmp.b	#60,VBlankFrequency(a6)
	bne.s	.pal
	move.l	#250,vbl_line
.pal:	move.l	#8*PLANESIZE,d0
	move.l	#MEMF_CHIP|MEMF_CLEAR,d1
	bsr	alloc
	move.l	d0,planes
	beq	.nomem
	move.l	#STRIPESIZE,d0
	moveq	#MEMF_CHIP,d1
	bsr	alloc
	move.l	d0,stripes
	beq	.nomem
	move.l	#5*CLSIZE,d0
	moveq	#MEMF_CHIP,d1
	bsr	alloc
	move.l	d0,coplists
	beq	.nomem
	ifnd	VAMOS
	lea	gfxname(pc),a1
	moveq	#39,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,gfxbase
	beq	.nogfx
	endc
	bsr	build_ramp
; stripes: $5555 everywhere, so any fetch alignment still gives 0101...
	move.l	stripes,a0
	move.l	#STRIPESIZE/4-1,d0
.s:	move.l	#$55555555,(a0)+
	subq.l	#1,d0
	bpl.s	.s
; the five copper lists
	lea	cl_modes(pc),a2
	move.l	coplists,a1
	moveq	#4,d7
.cl:	movem.w	(a2)+,d0-d4		; BPLCON0, DDFSTRT, DDFSTOP, modulo, planes
	move.l	planes,d5
	move.l	#PLANESIZE,d6
	cmp.w	#1,d4
	bne.s	.cb
	move.l	stripes,d5
.cb:	move.l	a1,-(sp)
	bsr	build_cl
	move.l	(sp)+,a1
	lea	CLSIZE(a1),a1
	dbf	d7,.cl
	moveq	#0,d0
.ret:	movem.l	(sp)+,d2-d7/a2-a6
	tst.l	d0
	rts
	ifnd	VAMOS
.nogfx:	lea	msg_nogfx(pc),a0
	bra.s	.err
	endc
.nomem:	lea	msg_nomem(pc),a0
.err:	bsr	puts
	moveq	#1,d0
	bra.s	.ret

; a1 = list, d0 = BPLCON0, d1 = DDFSTRT, d2 = DDFSTOP, d3 = modulo,
; d4 = planes, d5 = first plane, d6 = plane stride
build_cl:
	move.l	d7,-(sp)
	lea	cl_common(pc),a0
	moveq	#(cl_common_end-cl_common)/2-1,d7
.c:	move.w	(a0)+,(a1)+
	dbf	d7,.c
	move.w	#$100,(a1)+
	move.w	d0,(a1)+
	move.w	#$092,(a1)+
	move.w	d1,(a1)+
	move.w	#$094,(a1)+
	move.w	d2,(a1)+
	move.w	#$108,(a1)+
	move.w	d3,(a1)+
	move.w	#$10a,(a1)+
	move.w	d3,(a1)+
	move.w	#$0e0,d7		; BPL1PTH
	bra.s	.p1
.p:	move.w	d7,(a1)+
	swap	d5
	move.w	d5,(a1)+
	addq.w	#2,d7
	move.w	d7,(a1)+
	swap	d5
	move.w	d5,(a1)+
	addq.w	#2,d7
	add.l	d6,d5
.p1:	dbf	d4,.p
	move.l	#$fffffffe,(a1)+
	move.l	(sp)+,d7
	rts

; the ramp image: pixel (x, y) = (y / 64) * 64 + x / 5, so 64 bands of five
; lores pixels in four strips of 64 lines; each strip's first line is built
; bit by bit, the other 63 are copies
build_ramp:
	movem.l	d2-d7/a2-a3,-(sp)
	moveq	#0,d7			; strip
.s:	move.l	d7,d5
	mulu.w	#64*40,d5		; the strip's first line, in each plane
	moveq	#0,d6			; x
.x:	move.l	d6,d0
	divu.w	#5,d0
	and.l	#$ffff,d0
	move.l	d7,d1
	lsl.l	#6,d1
	or.l	d1,d0			; the colour index
	move.l	d6,d2
	lsr.l	#3,d2
	move.l	d6,d3
	not.l	d3
	and.l	#7,d3			; bit 7 - (x & 7)
	move.l	planes,a0
	add.l	d5,a0
	add.l	d2,a0
	moveq	#0,d4			; plane
.pl:	btst	d4,d0
	beq.s	.n
	bset	d3,(a0)
.n:	lea	PLANESIZE(a0),a0
	addq.l	#1,d4
	cmp.l	#8,d4
	blo.s	.pl
	addq.l	#1,d6
	cmp.l	#320,d6
	blo.s	.x
	move.l	planes,a2		; copy the line down the strip, every plane
	add.l	d5,a2
	moveq	#7,d4
.cp:	lea	40(a2),a3
	move.w	#63*10-1,d0
	move.l	a2,a0
.c:	move.l	(a0)+,(a3)+
	dbf	d0,.c
	lea	PLANESIZE(a2),a2
	dbf	d4,.cp
	addq.l	#1,d7
	cmp.l	#4,d7
	blo	.s
	movem.l	(sp)+,d2-d7/a2-a3
	rts

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

;---------------------------------------------------------------- display
run:	movem.l	d2-d7/a2-a6,-(sp)
	ifnd	VAMOS
	move.l	sysbase,a6
	jsr	_LVOForbid(a6)
	move.l	gfxbase,a6
	move.l	gb_ActiView(a6),oldview
	sub.l	a1,a1
	jsr	_LVOLoadView(a6)
	jsr	_LVOWaitTOF(a6)
	jsr	_LVOWaitTOF(a6)
	endc
	move.w	DMACONR,dmacon_save
	move.w	#$0020,DMACON		; sprites off: our lists set no pointers
	move.w	#$8000|DMA_OURS,DMACON
	ifd	VAMOS
	move.l	cur,d7			; every pattern from PAT on, 4 frames each
.v:	move.l	d7,d0
	bsr	show
	moveq	#3,d6
.vf:	bsr	frame
	dbf	d6,.vf
	addq.l	#1,d7
	cmp.l	#NPAT,d7
	blo.s	.v
	else
	moveq	#0,d0			; buttons held now do not count
	bsr	buttons
	or.b	#$80,d0
	move.b	d0,held
	move.b	CIAASDR,sdr_old
	move.l	cur,d0
	bsr	show
.loop:	bsr	frame
	bsr	input
	tst.l	d0
	beq.s	.loop
	cmp.l	#2,d0
	beq.s	.done
	add.l	cur,d0
	bpl.s	.w1
	moveq	#NPAT-1,d0
.w1:	cmp.l	#NPAT,d0
	blo.s	.w2
	moveq	#0,d0
.w2:	bsr	show
	bra.s	.loop
.done:
	endc
	moveq	#0,d0			; the OS's copper list
	ifnd	VAMOS
	move.l	gfxbase,a0
	move.l	gb_copinit(a0),d0
	endc
	bsr	set_cop
	move.w	#DMA_OURS,d0		; off what we switched on, on what was on
	move.w	dmacon_save,d1
	not.w	d1
	and.w	d1,d0
	move.w	d0,DMACON
	move.w	dmacon_save,d0
	or.w	#$8000,d0
	move.w	d0,DMACON
	ifnd	VAMOS
	move.l	gfxbase,a6
	move.l	oldview,a1
	jsr	_LVOLoadView(a6)
	jsr	_LVOWaitTOF(a6)
	jsr	_LVOWaitTOF(a6)
	move.l	sysbase,a6
	jsr	_LVOPermit(a6)
	endc
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; d0 = pattern: in the next vertical blank, its copper list and colours
show:	movem.l	d0-d1/a0,-(sp)
	move.l	d0,cur
	bsr	make_pal
	move.l	cur,d0
	bsr	entry
	move.l	a0,curent
	clr.l	fcnt
	clr.l	fstep
	bsr	wait_vbl
	move.w	4(a0),d0		; mode
	mulu.w	#CLSIZE,d0
	add.l	coplists,d0
	bsr	set_cop
	bsr	load_pal
	movem.l	(sp)+,d0-d1/a0
	rts

; d0 = copper list: COP1LC (two word writes), and restart the copper there
set_cop: swap	d0
	move.w	d0,COP1LC
	swap	d0
	move.w	d0,COP1LC+2
	move.w	d0,COPJMP1
	rts

; one frame: wait for the vertical blank; the flash screens change colour
frame:	movem.l	d0-d1/a0,-(sp)
	bsr	wait_vbl
	move.l	curent,a0
	cmp.w	#K_FLASH,6(a0)
	bne.s	.x
	addq.l	#1,fcnt
	move.l	fcnt,d0
	cmp.w	14(a0),d0		; frames per colour
	blo.s	.x
	clr.l	fcnt
	move.l	fstep,d0
	addq.l	#1,d0
	cmp.w	12(a0),d0		; colours in the sequence
	blo.s	.s
	moveq	#0,d0
.s:	move.l	d0,fstep
	move.l	8(a0),a0
	move.l	(a0,d0.l*4),d0
	bsr	set_col0
.x:	movem.l	(sp)+,d0-d1/a0
	rts

; wait until the beam is past the display (line vbl_line), once per frame
wait_vbl:
	ifnd	VAMOS
	move.l	d0,-(sp)
.a:	bsr.s	line
	cmp.l	vbl_line,d0		; still in the last blank: wait it out
	bhs.s	.a
.b:	bsr.s	line
	cmp.l	vbl_line,d0
	blo.s	.b
	move.l	(sp)+,d0
	endc
	rts
	ifnd	VAMOS
line:	move.w	VPOSR,d0
	and.l	#1,d0
	lsl.w	#8,d0
	move.b	VHPOSR,d0
	rts

; d0 = buttons pressed: bit 0 left, bit 1 right
buttons: moveq	#0,d0
	btst	#6,CIAAPRA
	bne.s	.r
	bset	#0,d0
.r:	move.w	d1,-(sp)
	move.w	POTGOR,d1
	btst	#10,d1
	bne.s	.x
	bset	#1,d0
.x:	move.w	(sp)+,d1
	rts

; d0 = 0 nothing, 1 next, -1 previous, 2 exit.  A button acts when it is
; released (so pressing both means exit, not next and exit); keys act when
; pressed.  The keyboard's last byte is in CIA-A's SDR (keyboard.device does
; the handshake): code = NOT byte, rotated right one; bit 7 set = released.
input:	movem.l	d1-d2,-(sp)
	bsr.s	buttons
	tst.b	d0
	beq.s	.rel
	or.b	d0,held
	bra.s	.keys
.rel:	move.b	held,d2
	clr.b	held
	moveq	#1,d0
	cmp.b	#1,d2
	beq.s	.x
	moveq	#-1,d0
	cmp.b	#2,d2
	beq.s	.x
	moveq	#2,d0
	cmp.b	#3,d2
	beq.s	.x
.keys:	moveq	#0,d0
	move.b	CIAASDR,d2
	cmp.b	sdr_old,d2
	beq.s	.x
	move.b	d2,sdr_old
	not.b	d2
	ror.b	#1,d2
	btst	#7,d2
	bne.s	.x
	moveq	#2,d0
	cmp.b	#KEY_ESC,d2
	beq.s	.x
	moveq	#1,d0
	cmp.b	#KEY_SPACE,d2
	beq.s	.x
	cmp.b	#KEY_RETURN,d2
	beq.s	.x
	cmp.b	#KEY_RIGHT,d2
	beq.s	.x
	moveq	#-1,d0
	cmp.b	#KEY_BS,d2
	beq.s	.x
	cmp.b	#KEY_LEFT,d2
	beq.s	.x
	moveq	#0,d0
.x:	movem.l	(sp)+,d1-d2
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
; each: name, mode, palette kind, a1, a2 (16 bytes)
pattab:	dc.l	n0
	dc.w	M_RAMP,K_RAMP
	dc.l	$010101,63
	dc.l	n1
	dc.w	M_RAMP,K_DARK4
	dc.l	0,0
	dc.l	n2
	dc.w	M_RAMP,K_RAMP
	dc.l	$010101,255
	dc.l	n3
	dc.w	M_RAMP,K_RAMP
	dc.l	$010000,255
	dc.l	n4
	dc.w	M_RAMP,K_RAMP
	dc.l	$000100,255
	dc.l	n5
	dc.w	M_RAMP,K_RAMP
	dc.l	$000001,255
	dc.l	n6
	dc.w	M_RAMP,K_BARS
	dc.l	0,0
	dc.l	n7
	dc.w	M_LO,K_PAIR
	dc.l	$555555,$aaaaaa
	dc.l	n8
	dc.w	M_HI,K_PAIR
	dc.l	$555555,$aaaaaa
	dc.l	n9
	dc.w	M_SH,K_PAIR
	dc.l	$555555,$aaaaaa
	dc.l	n10
	dc.w	M_LO,K_PAIR
	dc.l	$00ff00,$ff00ff
	dc.l	n11
	dc.w	M_HI,K_PAIR
	dc.l	$00ff00,$ff00ff
	dc.l	n12
	dc.w	M_SH,K_PAIR
	dc.l	$00ff00,$ff00ff
	dc.l	n13
	dc.w	M_LO,K_PAIR
	dc.l	$fff000,$000fff
	dc.l	n14
	dc.w	M_HI,K_PAIR
	dc.l	$fff000,$000fff
	dc.l	n15
	dc.w	M_SH,K_PAIR
	dc.l	$fff000,$000fff
	dc.l	n16
	dc.w	M_NONE,K_SOLID
	dc.l	$fff000,0
	dc.l	n17
	dc.w	M_NONE,K_SOLID
	dc.l	$000fff,0
	dc.l	n18
	dc.w	M_NONE,K_FLASH
	dc.l	seq_bw,2<<16|1
	dc.l	n19
	dc.w	M_NONE,K_FLASH
	dc.l	seq_bw,2<<16|2
	dc.l	n20
	dc.w	M_NONE,K_FLASH
	dc.l	seq_bw,2<<16|4
	dc.l	n21
	dc.w	M_NONE,K_FLASH
	dc.l	seq_8,8<<16|1
	dc.l	n22
	dc.w	M_NONE,K_FLASH
	dc.l	seq_8,8<<16|2
	dc.l	n23
	dc.w	M_NONE,K_FLASH
	dc.l	seq_8,8<<16|4

dark4mul: dc.l	$010000,$000100,$000001,$010101
bars:	dc.l	$ffffff,$ffff00,$00ffff,$00ff00,$ff00ff,$ff0000,$0000ff,$000000
seq_bw:	dc.l	$000000,$ffffff
seq_8:	dc.l	$000000,$ff0000,$00ff00,$0000ff,$ffffff,$ffff00,$00ffff,$ff00ff

; every list starts with these (register, value)
cl_common:
	dc.w	$1fc,0			; FMODE: 16-bit fetches
	dc.w	$102,0,$104,0		; BPLCON1 (no scroll), BPLCON2
	dc.w	$10c,$0011		; BPLCON4: no colour XOR, sprite banks
	dc.w	$08e,$2c81,$090,$2cc1	; DIWSTRT, DIWSTOP: 320 x 256 from $2C
cl_common_end:
; per mode: BPLCON0, DDFSTRT, DDFSTOP, modulo, planes.  Every mode fetches 20
; sequences of 8 colour clocks: 320, 640, 1280 pixels; the stripes plane is
; 160 bytes wide, so the modulo skips what a lores/hires line does not fetch
cl_modes:
	dc.w	$0211,$0038,$00d0,0,8	; ramp: 8 planes lores, colour, ECSENA
	dc.w	$1201,$0038,$00d0,120,1	; stripes lores
	dc.w	$9201,$003c,$00d4,80,1	; stripes hires
	dc.w	$1241,$003c,$00d4,0,1	; stripes superhires
	dc.w	$0201,$0038,$00d0,0,0	; no planes

sysbase: dc.l	0
dosbase: dc.l	0
gfxbase: dc.l	0
rdargs:	dc.l	0
rc:	dc.l	0
argv:	ds.l	3
args:	ds.l	10
cur:	dc.l	0
curent:	dc.l	0
fcnt:	dc.l	0
fstep:	dc.l	0
vbl_line: dc.l	300
oldview: dc.l	0
planes:	dc.l	0
stripes: dc.l	0
coplists: dc.l	0
nalloc:	dc.l	0
alloctab: ds.l	8
pal:	ds.l	256
dmacon_save: dc.w 0
held:	dc.b	0
sdr_old: dc.b	0

template: dc.b	"PAT/K/N,LIST/S,DUMP/K/N",0
dosname: dc.b	"dos.library",0
gfxname: dc.b	"graphics.library",0
n0:	dc.b	"dark grey 0-63, 4 strips",0
n1:	dc.b	"dark red/green/blue/grey 0-63",0
n2:	dc.b	"grey 0-255",0
n3:	dc.b	"red 0-255",0
n4:	dc.b	"green 0-255",0
n5:	dc.b	"blue 0-255",0
n6:	dc.b	"colour bars",0
n7:	dc.b	"stripes 555555/AAAAAA lores",0
n8:	dc.b	"stripes 555555/AAAAAA hires",0
n9:	dc.b	"stripes 555555/AAAAAA superhires",0
n10:	dc.b	"stripes 00FF00/FF00FF lores",0
n11:	dc.b	"stripes 00FF00/FF00FF hires",0
n12:	dc.b	"stripes 00FF00/FF00FF superhires",0
n13:	dc.b	"stripes FFF000/000FFF lores",0
n14:	dc.b	"stripes FFF000/000FFF hires",0
n15:	dc.b	"stripes FFF000/000FFF superhires",0
n16:	dc.b	"solid FFF000: all 12 pins toggle each edge",0
n17:	dc.b	"solid 000FFF: all 12 pins toggle each edge",0
n18:	dc.b	"flash black/white every frame",0
n19:	dc.b	"flash black/white every 2nd frame",0
n20:	dc.b	"flash black/white every 4th frame",0
n21:	dc.b	"flash 8 colours every frame",0
n22:	dc.b	"flash 8 colours every 2nd frame",0
n23:	dc.b	"flash 8 colours every 4th frame",0
fmt_list: dc.b	"%3ld  %s",10,0
fmt_dumphdr: dc.b "pattern %ld: %s",10,0
fmt_dump: dc.b	"%06lx %06lx %06lx %06lx %06lx %06lx %06lx %06lx",10,0
msg_listhdr: dc.b "AdvPat patterns (left button/space next, right button/backspace"
	dc.b	" previous, both buttons/ESC exit):",10,0
msg_keys: dc.b	"AdvPat: pattern %ld; left button/space next, right button/backspace"
	dc.b	" previous, both buttons/ESC exit",10,0
msg_last: dc.b	"AdvPat: last pattern %ld (%s)",10,0
msg_usage: dc.b	"Usage: AdvPat [PAT=n] [LIST] [DUMP=n]",10,0
msg_badpat: dc.b "AdvPat: PAT and DUMP must be 0..23",10,0
msg_nomem: dc.b	"AdvPat: not enough chip memory",10,0
msg_nogfx: dc.b	"AdvPat: no graphics.library V39 (needs AGA Kickstart 3.x)",10,0
	even
