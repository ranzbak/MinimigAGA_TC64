; SerTest2 -- findings/serial: where does serial.device's baud rate come from?
; The board's ILA caught serial.device writing SERPER = $7B6D for Prefs 38400:
; 24772416 / (7 * 112), i.e. the device was given io_Baud = 112 -- its own
; minimum -- instead of 38400.  This opens serial.device (shared) through the
; OS and prints, on the console:
;   the DEFAULT io_Baud the device hands out (what Prefs gave it)
;   io_Error and io_Baud after SDCMD_SETPARAMS with 38400, 115200 and 9600,
; and after each SETPARAMS sends a line with CMD_WRITE at that rate.
; Self-contained, no NDK.  Build: Makefile.

_LVOOpenLibrary  equ	-552
_LVOCloseLibrary equ	-414
_LVORawDoFmt     equ	-522
_LVOCreateMsgPort equ	-666
_LVODeleteMsgPort equ	-672
_LVOCreateIORequest equ	-654
_LVODeleteIORequest equ	-660
_LVOOpenDevice   equ	-444
_LVOCloseDevice  equ	-450
_LVODoIO         equ	-456
_LVOPutStr       equ	-948
; IOExtSer
io_Command	equ	28
io_Error	equ	31
io_Length	equ	36
io_Data		equ	40
io_Baud		equ	60
io_SerFlags	equ	79
IOEXTSER_SIZE	equ	82
SDCMD_SETPARAMS	equ	11
CMD_WRITE	equ	3
SERF_SHARED	equ	$20

	section	code,code
start:	move.l	4.w,a6
	lea	dosname(pc),a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,dosbase
	beq	.x
	jsr	_LVOCreateMsgPort(a6)
	move.l	d0,port
	beq	.nodos
	move.l	d0,a0
	moveq	#IOEXTSER_SIZE,d0
	jsr	_LVOCreateIORequest(a6)
	move.l	d0,ior
	beq	.noio
	move.l	d0,a1
	move.b	#SERF_SHARED,io_SerFlags(a1)
	lea	devname(pc),a0
	moveq	#0,d0
	moveq	#0,d1
	jsr	_LVOOpenDevice(a6)
	move.l	d0,args
	move.l	ior(pc),a1
	move.l	io_Baud(a1),args+4
	lea	fmt0(pc),a0
	bsr	say
	tst.l	args
	bne	.nodev

	move.l	#38400,d2
	lea	txt1(pc),a2
	bsr	trybaud
	move.l	#115200,d2
	lea	txt2(pc),a2
	bsr	trybaud
	move.l	#9600,d2
	lea	txt3(pc),a2
	bsr	trybaud

	move.l	ior(pc),a1
	jsr	_LVOCloseDevice(a6)
.nodev:	move.l	ior(pc),a0
	jsr	_LVODeleteIORequest(a6)
.noio:	move.l	port(pc),a0
	jsr	_LVODeleteMsgPort(a6)
.nodos:	move.l	dosbase(pc),a1
	jsr	_LVOCloseLibrary(a6)
.x:	moveq	#0,d0
	rts

; d2 = baud, a2 = line to send at that rate
trybaud: move.l	ior(pc),a1
	move.l	d2,io_Baud(a1)
	move.w	#SDCMD_SETPARAMS,io_Command(a1)
	jsr	_LVODoIO(a6)
	move.l	ior(pc),a1
	move.l	d2,args
	moveq	#0,d0
	move.b	io_Error(a1),d0
	move.l	d0,args+4
	move.l	io_Baud(a1),args+8
	lea	fmt1(pc),a0
	bsr	say
	move.l	ior(pc),a1
	move.w	#CMD_WRITE,io_Command(a1)
	move.l	a2,io_Data(a1)
	move.l	#-1,io_Length(a1)	; NUL-terminated
	jsr	_LVODoIO(a6)
	rts

; say: RawDoFmt(a0, args) into buf, PutStr it
say:	movem.l	a2-a3/a6,-(sp)
	lea	args(pc),a1
	lea	.pc(pc),a2
	lea	buf(pc),a3
	move.l	4.w,a6
	jsr	_LVORawDoFmt(a6)
	move.l	dosbase(pc),a6
	lea	buf(pc),a0
	move.l	a0,d1
	jsr	_LVOPutStr(a6)
	movem.l	(sp)+,a2-a3/a6
	rts
.pc:	move.b	d0,(a3)+
	rts

dosbase:	dc.l	0
port:		dc.l	0
ior:		dc.l	0
args:		ds.l	4
dosname:	dc.b	"dos.library",0
devname:	dc.b	"serial.device",0
fmt0:	dc.b	"OpenDevice=%ld  default io_Baud=%ld (Prefs value)",10,0
fmt1:	dc.b	"SETPARAMS %ld: io_Error=%ld io_Baud=%ld",10,0
txt1:	dc.b	"SerTest2 line at 38400",13,10,0
txt2:	dc.b	"SerTest2 line at 115200",13,10,0
txt3:	dc.b	"SerTest2 line at 9600",13,10,0
	even
buf:	ds.b	160
