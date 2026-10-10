; SerRx -- receive a known byte pattern through serial.device and report
; exactly what arrived: lost bytes (overrun / buffer overflow), changed bytes
; (bit errors) or filtered bytes (XON/XOFF).  The PC sends byte i = i & 255
; (sertx.py).  See README.md.
;
;   SerRx [BAUD=n] [COUNT=n] [TIMEOUT=s] [IDLE=s] [BUF=n] [UNIT=n] [XON]
;         [SHARED] [BOOGIE|NOBOOGIE] [SAVE=file] [FROM=file] [SELFTEST]
;
; Receive loop: SDCMD_QUERY says how many bytes the device holds; read exactly
; that many with CMD_READ (DoIO, completes at once).  When it holds none, send a
; 1-byte CMD_READ and a timer.device request and Wait for either (or ^C).  The
; timer is TIMEOUT before the first byte, IDLE after it.
;
; FROM=file analyses a saved stream instead of the serial port; SELFTEST
; analyses a built-in damaged stream.  Both run under vamos (test_serrx.sh).
; Self-contained, no NDK.  Build: Makefile (vasmm68k_mot, 68020+).

_LVOOpenLibrary	equ	-552
_LVOCloseLibrary equ	-414
_LVOCreateMsgPort equ	-666
_LVODeleteMsgPort equ	-672
_LVOCreateIORequest equ	-654
_LVODeleteIORequest equ	-660
_LVOOpenDevice	equ	-444
_LVOCloseDevice	equ	-450
_LVODoIO	equ	-456
_LVOSendIO	equ	-462
_LVOCheckIO	equ	-468
_LVOWaitIO	equ	-474
_LVOAbortIO	equ	-480
_LVOWait	equ	-318
_LVOSetSignal	equ	-306
_LVOAllocVec	equ	-684
_LVOFreeVec	equ	-690
_LVOOpen	equ	-30
_LVOClose	equ	-36
_LVORead	equ	-42
_LVOWrite	equ	-48
_LVODateStamp	equ	-192
_LVOVPrintf	equ	-954
_LVOReadArgs	equ	-798
_LVOFreeArgs	equ	-858

; exec/io.i, devices/serial.i (NDK 3.5), devices/timer.i
io_Command	equ	28
io_Flags	equ	30
io_Error	equ	31
io_Actual	equ	32
io_Length	equ	36
io_Data		equ	40
io_CtlChar	equ	48
io_RBufLen	equ	52
io_ExtFlags	equ	56
io_Baud		equ	60
io_BrkTime	equ	64
io_ReadLen	equ	76
io_WriteLen	equ	77
io_StopBits	equ	78
io_SerFlags	equ	79
io_Status	equ	80
IOEXTSER_SIZE	equ	82
tv_secs		equ	32
tv_micro	equ	36
IOTV_SIZE	equ	40
MP_SIGBIT	equ	15
CMD_READ	equ	2
CMD_CLEAR	equ	5
SDCMD_QUERY	equ	9
SDCMD_SETPARAMS	equ	11
TR_ADDREQUEST	equ	9
UNIT_VBLANK	equ	1
SERF_XDISABLED	equ	$80
SERF_SHARED	equ	$20
SERF_RAD_BOOGIE	equ	$10
SERF_7WIRE	equ	$04
SER_DEFAULT_CTLCHAR equ	$11130000
IOERR_ABORTED	equ	-2
SIGBREAKB_CTRL_C equ	12
MEMF_CLEAR	equ	$10000
MODE_OLDFILE	equ	1005
MODE_NEWFILE	equ	1006
PAL_CLK		equ	3546895
MAXLIST		equ	16		; errors, events, mismatches listed

STOP_COUNT	equ	0
STOP_IDLE	equ	1
STOP_TIMEOUT	equ	2
STOP_CTRLC	equ	3
STOP_ERRORS	equ	4
MAXERR		equ	1000
EV_CHG		equ	0
EV_SKIP		equ	1
EV_INS		equ	2

GETN	macro			; GETN argindex,var: a /N option, if given
	move.l	argv+4*\1,d0
	beq	.g\@
	move.l	d0,a0
	move.l	(a0),\2
.g\@:
	endm
GETS	macro			; GETS argindex,bytevar: a /S switch
	tst.l	argv+4*\1
	sne	\2
	endm

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
	move.l	#template,d1
	move.l	#argv,d2
	moveq	#0,d3
	jsr	_LVOReadArgs(a6)
	move.l	d0,rdargs
	bne	.args
	lea	msg_usage(pc),a0
	bsr	puts
	bra	.close
.args:	bsr	parse
	bne	.close
	bsr	allocbuf
	bne	.close
	tst.b	selftest
	beq	.nst
	bsr	gen_selftest
	bra	.ana
.nst:	tst.l	fromname
	beq	.ser
	bsr	load_file
	bne	.free
	bra	.ana
.ser:	bsr	receive
	bne	.free
.ana:	bsr	save_file
	bsr	analyse
.free:	bsr	freebuf
.close:	move.l	dosbase,a6
	move.l	rdargs,d1
	beq	.nofa
	jsr	_LVOFreeArgs(a6)
.nofa:	move.l	sysbase,a6
	move.l	dosbase,a1
	jsr	_LVOCloseLibrary(a6)
.exit:	move.l	rc,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;---------------------------------------------------------------- arguments
; d0 = 0 (Z) when the options are good, else prints why
parse:	move.l	#57600,baud
	move.l	#4096,count
	moveq	#10,d0
	move.l	d0,timeout
	moveq	#2,d0
	move.l	d0,idle
	move.l	#65536,rbuflen
	clr.l	unit
	GETN	0,baud
	GETN	1,count
	GETN	2,timeout
	GETN	3,idle
	GETN	4,rbuflen
	GETN	5,unit
	GETS	6,xon
	GETS	7,shared
	move.l	argv+4*10,savename
	move.l	argv+4*11,fromname
	GETS	12,selftest
	tst.b	selftest
	beq	.c
	move.l	#4096,count
.c:	move.l	baud,d0
	move.l	#112,d1
	move.l	#1000000,d2
	lea	err_baud(pc),a0
	bsr	range
	bne	.bad
	move.l	count,d0
	moveq	#1,d1
	move.l	#16777216,d2
	lea	err_count(pc),a0
	bsr	range
	bne	.bad
	move.l	timeout,d0
	moveq	#1,d1
	move.l	#3600,d2
	lea	err_timeout(pc),a0
	bsr	range
	bne	.bad
	move.l	idle,d0
	moveq	#1,d1
	move.l	#600,d2
	lea	err_idle(pc),a0
	bsr	range
	bne	.bad
	move.l	rbuflen,d0
	moveq	#64,d1
	move.l	#16777216,d2
	lea	err_buf(pc),a0
	bsr	range
	bne	.bad
	tst.l	argv+4*8
	beq	.nb
	tst.l	argv+4*9
	beq	.nb
	lea	err_boogie(pc),a0
	bsr	puts
	bra	.bad
.nb:	moveq	#0,d0			; default: BOOGIE above 38400 without XON
	cmp.l	#38400,baud
	bls	.bd
	tst.b	xon
	bne	.bd
	moveq	#-1,d0
.bd:	tst.l	argv+4*8
	beq	.b1
	moveq	#-1,d0
.b1:	tst.l	argv+4*9
	beq	.b2
	moveq	#0,d0
.b2:	move.b	d0,boogie
	moveq	#0,d0
	rts
.bad:	moveq	#1,d0
	rts

; d0 value, d1 min, d2 max (unsigned), a0 message: Z if in range
range:	cmp.l	d1,d0
	blo	.no
	cmp.l	d2,d0
	bhi	.no
	moveq	#0,d0
	rts
.no:	bsr	puts
	moveq	#1,d0
	rts

;---------------------------------------------------------------- buffer
allocbuf:
	move.l	sysbase,a6
	move.l	count,d0
	add.l	#16,d0
	move.l	#MEMF_CLEAR,d1
	jsr	_LVOAllocVec(a6)
	move.l	d0,buf
	bne	.ok
	lea	err_mem(pc),a0
	bsr	puts
	moveq	#1,d0
	rts
.ok:	moveq	#0,d0
	rts

freebuf:
	move.l	sysbase,a6
	move.l	buf,a1
	jmp	_LVOFreeVec(a6)		; NULL is fine

;---------------------------------------------------------------- sources
; the self test stream: the pattern for expected 0..4085 (the last 10 never
; arrive) with expected 100..102 lost, bit 7 flipped at 300, bit 2 at 700,
; $11 and $13 dropped in 1024..2047 and one extra $55 before 2500
gen_selftest:
	move.l	buf,a0
	moveq	#0,d2
.l:	cmp.l	#4086,d2
	bhs	.d
	cmp.l	#2500,d2
	bne	.1
	move.b	#$55,(a0)+
.1:	cmp.l	#100,d2
	blo	.2
	cmp.l	#103,d2
	blo	.n
.2:	cmp.l	#1024,d2
	blo	.3
	cmp.l	#2048,d2
	bhs	.3
	cmp.b	#$11,d2
	beq	.n
	cmp.b	#$13,d2
	beq	.n
.3:	move.b	d2,d0
	cmp.l	#300,d2
	bne	.4
	eor.b	#$80,d0
.4:	cmp.l	#700,d2
	bne	.5
	eor.b	#$04,d0
.5:	move.b	d0,(a0)+
.n:	addq.l	#1,d2
	bra	.l
.d:	suba.l	buf,a0
	move.l	a0,got
	lea	msg_selftest(pc),a0
	bra	puts

load_file:
	move.l	dosbase,a6
	move.l	fromname,d1
	move.l	#MODE_OLDFILE,d2
	jsr	_LVOOpen(a6)
	move.l	d0,d4
	beq	.err
	move.l	d4,d1
	move.l	buf,d2
	move.l	count,d3
	jsr	_LVORead(a6)
	move.l	d0,d5
	move.l	d4,d1
	jsr	_LVOClose(a6)
	tst.l	d5
	bmi	.err
	move.l	d5,got
	lea	args,a1
	move.l	fromname,(a1)
	move.l	d5,4(a1)
	lea	fmt_from(pc),a0
	bsr	printf
	moveq	#0,d0
	rts
.err:	lea	args,a1
	move.l	fromname,(a1)
	lea	err_from(pc),a0
	bsr	printf
	moveq	#1,d0
	rts

save_file:
	move.l	savename,d1
	beq	.x
	move.l	dosbase,a6
	move.l	#MODE_NEWFILE,d2
	jsr	_LVOOpen(a6)
	move.l	d0,d4
	beq	.err
	move.l	d4,d1
	move.l	buf,d2
	move.l	got,d3
	jsr	_LVOWrite(a6)
	move.l	d0,d5
	move.l	d4,d1
	jsr	_LVOClose(a6)
	cmp.l	got,d5
	bne	.err
	lea	args,a1
	move.l	savename,(a1)
	move.l	d5,4(a1)
	lea	fmt_saved(pc),a0
	bra	printf
.err:	lea	args,a1
	move.l	savename,(a1)
	lea	err_save(pc),a0
	bra	printf
.x:	rts

;---------------------------------------------------------------- receive
; d0 = 0 (Z) when the device could be opened and set up (whatever arrived)
receive:
	move.l	sysbase,a6
	jsr	_LVOCreateMsgPort(a6)
	move.l	d0,port
	beq	.nomem
	move.l	d0,a0
	moveq	#IOEXTSER_SIZE,d0
	jsr	_LVOCreateIORequest(a6)
	move.l	d0,serreq
	beq	.nomem
	move.l	port,a0
	moveq	#IOTV_SIZE,d0
	jsr	_LVOCreateIORequest(a6)
	move.l	d0,tmrreq
	beq	.nomem
	lea	timername(pc),a0
	moveq	#UNIT_VBLANK,d0
	move.l	tmrreq,a1
	moveq	#0,d1
	jsr	_LVOOpenDevice(a6)
	tst.l	d0
	beq	.tok
	lea	err_timer(pc),a0
	bsr	puts
	bra	.fail
.tok:	st	tmropen
	move.l	serreq,a1
	moveq	#0,d0			; SHARED and 7WIRE count at OpenDevice
	tst.b	shared
	beq	.ex
	moveq	#SERF_SHARED,d0
.ex:	move.b	d0,io_SerFlags(a1)
	lea	sername(pc),a0
	move.l	unit,d0
	moveq	#0,d1
	jsr	_LVOOpenDevice(a6)
	tst.l	d0
	beq	.sok
	ext.w	d0			; OpenDevice returns io_Error
	ext.l	d0
	lea	args,a1
	move.l	unit,(a1)
	move.l	d0,4(a1)
	bsr	errname
	move.l	d0,8(a1)
	lea	err_open(pc),a0
	bsr	printf
	bra	.fail
.sok:	st	seropen
	move.l	serreq,a1
	move.l	io_Baud(a1),prefsbaud
	move.l	baud,io_Baud(a1)
	move.l	rbuflen,io_RBufLen(a1)
	move.l	#SER_DEFAULT_CTLCHAR,io_CtlChar(a1)
	clr.l	io_ExtFlags(a1)
	move.b	#8,io_ReadLen(a1)
	move.b	#8,io_WriteLen(a1)
	move.b	#1,io_StopBits(a1)
	moveq	#0,d0
	tst.b	shared
	beq	.f1
	or.b	#SERF_SHARED,d0
.f1:	tst.b	xon
	bne	.f2
	or.b	#SERF_XDISABLED,d0
.f2:	tst.b	boogie
	beq	.f3
	or.b	#SERF_RAD_BOOGIE,d0
.f3:	move.b	d0,io_SerFlags(a1)
	move.w	#SDCMD_SETPARAMS,io_Command(a1)
	jsr	_LVODoIO(a6)
	bsr	print_params
	bsr	print_serper
	move.l	serreq,a1
	tst.b	io_Error(a1)
	bne	.fail
	move.w	#CMD_CLEAR,io_Command(a1)	; drop anything that came before
	jsr	_LVODoIO(a6)
	lea	args,a1
	move.l	timeout,(a1)
	move.l	count,4(a1)
	move.l	idle,8(a1)
	lea	fmt_wait(pc),a0
	bsr	printf

	clr.l	got
.loop:	moveq	#0,d0
	move.l	#1<<SIGBREAKB_CTRL_C,d1
	jsr	_LVOSetSignal(a6)
	btst	#SIGBREAKB_CTRL_C,d0
	bne	.ctrlc
	cmp.l	#MAXERR,nerr		; a device that errors forever
	bhs	.errs
	move.l	got,d0
	cmp.l	count,d0
	bhs	.full
	move.l	serreq,a1
	move.w	#SDCMD_QUERY,io_Command(a1)
	jsr	_LVODoIO(a6)
	move.l	serreq,a1
	moveq	#'Q',d2
	bsr	querystat
	move.l	io_Actual(a1),d0
	beq	.wait
	move.l	count,d1
	sub.l	got,d1
	cmp.l	d1,d0
	bls	.rd
	move.l	d1,d0
.rd:	move.l	d0,io_Length(a1)
	move.l	buf,d0
	add.l	got,d0
	move.l	d0,io_Data(a1)
	move.w	#CMD_READ,io_Command(a1)
	jsr	_LVODoIO(a6)
	move.l	serreq,a1
	bsr	gotdata
	bra	.loop
.wait:	moveq	#1,d0
	move.l	d0,io_Length(a1)
	move.l	buf,d0
	add.l	got,d0
	move.l	d0,io_Data(a1)
	move.w	#CMD_READ,io_Command(a1)
	jsr	_LVOSendIO(a6)
	st	ser_out
	move.l	tmrreq,a1
	move.w	#TR_ADDREQUEST,io_Command(a1)
	move.l	idle,d0
	tst.b	started
	bne	.t
	move.l	timeout,d0
.t:	move.l	d0,tv_secs(a1)
	clr.l	tv_micro(a1)
	jsr	_LVOSendIO(a6)
	st	tmr_out
.w:	move.l	serreq,a1
	jsr	_LVOCheckIO(a6)
	tst.l	d0
	bne	.serdone
	move.l	tmrreq,a1
	jsr	_LVOCheckIO(a6)
	tst.l	d0
	bne	.tmrdone
	move.l	port,a0
	moveq	#0,d1
	move.b	MP_SIGBIT(a0),d1
	moveq	#0,d0
	bset	d1,d0
	bset	#SIGBREAKB_CTRL_C,d0
	jsr	_LVOWait(a6)
	btst	#SIGBREAKB_CTRL_C,d0
	beq	.w
.ctrlc:	move.b	#STOP_CTRLC,stopreason
	bsr	kill_ser
	bsr	kill_tmr
	bra	.end
.serdone:
	move.l	serreq,a1
	jsr	_LVOWaitIO(a6)
	clr.b	ser_out
	move.l	serreq,a1
	bsr	gotdata
	bsr	kill_tmr
	bra	.loop
.tmrdone:
	move.l	tmrreq,a1
	jsr	_LVOWaitIO(a6)
	clr.b	tmr_out
	moveq	#STOP_TIMEOUT,d0
	tst.b	started
	beq	.to
	moveq	#STOP_IDLE,d0
.to:	move.b	d0,stopreason
	bsr	kill_ser
	bra	.end
.errs:	move.b	#STOP_ERRORS,stopreason
	bra	.end
.full:	move.b	#STOP_COUNT,stopreason
.end:	move.l	serreq,a1		; last look: status, bytes left over
	move.w	#SDCMD_QUERY,io_Command(a1)
	jsr	_LVODoIO(a6)
	move.l	serreq,a1
	moveq	#'Q',d2
	bsr	querystat
	move.l	io_Actual(a1),leftover
	bsr	print_rx
	moveq	#0,d7
	bra	.close
.nomem:	lea	err_mem(pc),a0
	bsr	puts
.fail:	moveq	#1,d7
.close:	move.l	sysbase,a6
	tst.b	seropen
	beq	.c1
	move.l	serreq,a1
	jsr	_LVOCloseDevice(a6)
.c1:	tst.b	tmropen
	beq	.c2
	move.l	tmrreq,a1
	jsr	_LVOCloseDevice(a6)
.c2:	move.l	serreq,d0
	beq	.c3
	move.l	d0,a0
	jsr	_LVODeleteIORequest(a6)
.c3:	move.l	tmrreq,d0
	beq	.c4
	move.l	d0,a0
	jsr	_LVODeleteIORequest(a6)
.c4:	move.l	port,d0
	beq	.c5
	move.l	d0,a0
	jsr	_LVODeleteMsgPort(a6)
.c5:	move.l	d7,d0
	rts

kill_ser:
	tst.b	ser_out
	beq	.x
	move.l	serreq,a1
	jsr	_LVOAbortIO(a6)
	move.l	serreq,a1
	jsr	_LVOWaitIO(a6)
	clr.b	ser_out
	move.l	serreq,a1
	bsr	gotdata			; a byte may have come in anyway
.x:	rts

kill_tmr:
	tst.b	tmr_out
	beq	.x
	move.l	tmrreq,a1
	jsr	_LVOAbortIO(a6)
	move.l	tmrreq,a1
	jsr	_LVOWaitIO(a6)
	clr.b	tmr_out
.x:	rts

; a1 = serreq after CMD_READ: count the bytes, note an error
gotdata:
	movem.l	d0-d2/a0-a1,-(sp)
	move.b	io_Error(a1),d0
	ext.w	d0
	ext.l	d0
	beq	.ok
	moveq	#IOERR_ABORTED,d1
	cmp.l	d1,d0
	beq	.ok
	move.l	got,d1
	add.l	io_Actual(a1),d1
	moveq	#'R',d2
	bsr	noteerr
.ok:	move.l	io_Actual(a1),d0
	beq	.x
	add.l	d0,got
	tst.b	started
	bne	.s
	st	started
	lea	ds_first,a0
	bsr	datestamp
.s:	lea	ds_last,a0
	bsr	datestamp
.x:	movem.l	(sp)+,d0-d2/a0-a1
	rts

; a1 = serreq after SDCMD_QUERY, d2 = 'Q'
querystat:
	movem.l	d0-d1,-(sp)
	move.b	io_Error(a1),d0
	ext.w	d0
	ext.l	d0
	beq	.ok
	move.l	got,d1
	bsr	noteerr
.ok:	moveq	#0,d0
	move.w	io_Status(a1),d0
	move.l	d0,laststat
	or.l	d0,orstat
	movem.l	(sp)+,d0-d1
	rts

; d0 = io_Error, d1 = byte offset, d2 = 'R' (CMD_READ) or 'Q' (SDCMD_QUERY)
noteerr:
	movem.l	d3/a0,-(sp)
	move.l	nerr,d3
	addq.l	#1,nerr
	cmp.l	#MAXLIST,d3
	bhs	.x
	mulu.w	#12,d3
	lea	errtab,a0
	add.l	d3,a0
	move.l	d1,(a0)+
	move.l	d0,(a0)+
	move.l	d2,(a0)
.x:	movem.l	(sp)+,d3/a0
	rts

; a0 = 3 longs
datestamp:
	movem.l	d0-d1/a0-a1/a6,-(sp)
	move.l	a0,d1
	move.l	dosbase,a6
	jsr	_LVODateStamp(a6)
	movem.l	(sp)+,d0-d1/a0-a1/a6
	rts

; d0 = io_Error (signed) -> d0 = its name
errname:
	cmp.l	#-4,d0
	blt	.u
	cmp.l	#15,d0
	bgt	.u
	move.l	a0,-(sp)
	lea	errnames(pc),a0
	move.l	4*4(a0,d0.l*4),d0
	move.l	(sp)+,a0
	rts
.u:	move.l	#s_unk,d0
	rts

print_params:
	move.l	serreq,a2
	lea	args,a1
	move.l	unit,(a1)
	move.l	#s_excl,4(a1)
	tst.b	shared
	beq	.p1
	move.l	#s_shared,4(a1)
.p1:	move.l	prefsbaud,8(a1)
	lea	fmt_open(pc),a0
	bsr	printf
	lea	args,a1
	moveq	#0,d0
	move.b	io_Error(a2),d0
	ext.w	d0
	ext.l	d0
	move.l	d0,(a1)
	bsr	errname
	move.l	d0,4(a1)
	move.l	io_Baud(a2),8(a1)
	move.l	io_RBufLen(a2),12(a1)
	moveq	#0,d0
	move.b	io_ReadLen(a2),d0
	move.l	d0,16(a1)
	move.b	io_WriteLen(a2),d0
	move.l	d0,20(a1)
	move.b	io_StopBits(a2),d0
	move.l	d0,24(a1)
	move.l	io_ExtFlags(a2),28(a1)
	move.l	io_CtlChar(a2),32(a1)
	lea	fmt_set(pc),a0
	bsr	printf
	moveq	#0,d1
	move.b	io_SerFlags(a2),d1
	lea	args,a1
	move.l	d1,(a1)+
	moveq	#7,d0			; XDISABLED
	bsr	onoff
	moveq	#4,d0			; RAD_BOOGIE
	bsr	onoff
	moveq	#2,d0			; 7WIRE
	bsr	onoff
	moveq	#5,d0			; SHARED
	bsr	onoff
	moveq	#0,d0			; PARTY_ON
	bsr	onoff
	moveq	#6,d0			; EOFMODE
	bsr	onoff
	lea	args,a1
	lea	fmt_flags(pc),a0
	bra	printf

; bit d0 of d1 -> "on"/"off" pointer at (a1)+
onoff:	move.l	#s_off,(a1)
	btst	d0,d1
	beq	.x
	move.l	#s_on,(a1)
.x:	addq.l	#4,a1
	rts

print_serper:
	lea	args,a1
	move.l	baud,d2
	move.l	#PAL_CLK,d0		; truncated: PAL_CLK / baud - 1
	divu.l	d2,d0
	bsr	.one
	move.l	d2,d0			; rounded: (PAL_CLK + baud/2) / baud - 1
	lsr.l	#1,d0
	add.l	#PAL_CLK,d0
	divu.l	d2,d0
	bsr	.one
	lea	args,a1
	lea	fmt_serper(pc),a0
	bra	printf
; d0 = SERPER+1: store SERPER, the rate, and its error as sign, whole, frac, '%'
.one:	move.l	d0,d1
	subq.l	#1,d1
	move.l	d1,(a1)+
	move.l	#PAL_CLK,d1
	divu.l	d0,d1
	move.l	d1,(a1)+
	sub.l	d2,d1
	muls.l	#10000,d1
	divs.l	d2,d1
	moveq	#'+',d0
	tst.l	d1
	bpl	.pos
	moveq	#'-',d0
	neg.l	d1
.pos:	move.l	d0,(a1)+
	divul.l	#100,d0:d1
	move.l	d1,(a1)+
	move.l	d0,(a1)+
	move.l	#'%',(a1)+
	rts

print_rx:
	lea	args,a1
	moveq	#0,d0
	move.b	stopreason,d0
	lea	stopnames(pc),a0
	move.l	(a0,d0.w*4),(a1)
	move.l	got,4(a1)
	lea	fmt_stop(pc),a0
	bsr	printf
	tst.b	started
	beq	.nt
	movem.l	ds_last,d0-d2		; ticks first..last byte
	sub.l	ds_first,d0
	sub.l	ds_first+4,d1
	sub.l	ds_first+8,d2
	mulu.l	#4320000,d0
	mulu.l	#3000,d1
	add.l	d1,d0
	add.l	d2,d0
	lea	args,a1
	move.l	d0,d3
	divul.l	#50,d1:d0
	move.l	d0,(a1)
	add.l	d1,d1
	move.l	d1,4(a1)
	moveq	#0,d0
	tst.l	d3
	beq	.nr
	move.l	got,d0
	subq.l	#1,d0			; bytes after the first one
	mulu.l	#50,d0
	divu.l	d3,d0
.nr:	move.l	d0,8(a1)
	move.l	baud,d0
	divu.l	#10,d0
	move.l	d0,12(a1)
	lea	fmt_time(pc),a0
	bsr	printf
.nt:	lea	args,a1
	move.l	nerr,(a1)
	lea	fmt_nerr(pc),a0
	bsr	printf
	move.l	nerr,d4
	cmp.l	#MAXLIST,d4
	bls	.e0
	moveq	#MAXLIST,d4
.e0:	lea	errtab,a2
	moveq	#0,d5
	bra	.ee
.el:	lea	args,a1
	addq.l	#1,d5
	move.l	d5,(a1)
	move.l	(a2)+,4(a1)
	move.l	#s_cmdread,8(a1)
	move.l	(a2)+,d0
	move.l	(a2)+,d1
	cmp.b	#'R',d1
	beq	.er
	move.l	#s_cmdquery,8(a1)
.er:	move.l	d0,12(a1)
	bsr	errname
	move.l	d0,16(a1)
	lea	fmt_err(pc),a0
	bsr	printf
.ee:	dbf	d4,.el
	lea	args,a1
	move.l	laststat,d1
	move.l	d1,(a1)+
	move.l	orstat,d1
	lsr.l	#8,d1
	move.l	d1,(a1)+
	moveq	#0,d0			; IOST_OVERRUN
	bsr	onoff
	moveq	#2,d0			; IOST_READBREAK
	bsr	onoff
	moveq	#4,d0			; IOST_XOFFREAD
	bsr	onoff
	moveq	#3,d0			; IOST_XOFFWRITE
	bsr	onoff
	move.l	leftover,(a1)+
	lea	args,a1
	lea	fmt_status(pc),a0
	bra	printf

;---------------------------------------------------------------- analysis
; buf[0..got-1] against byte i = i & 255, i < count.  Sets rc 0 or 5.
analyse:
	move.l	buf,a5
	move.l	got,d7
	lea	args,a1
	move.l	d7,(a1)
	move.l	count,4(a1)
	lea	fmt_recv(pc),a0
	bsr	printf
; same-offset comparison
	move.l	d7,d4
	cmp.l	count,d4
	bls	.m
	move.l	count,d4
.m:	moveq	#0,d2
	moveq	#0,d3
	lea	dmtab,a2
.dl:	cmp.l	d4,d2
	bhs	.dd
	move.b	(a5,d2.l),d0
	cmp.b	d2,d0
	beq	.dn
	addq.l	#1,d3
	cmp.l	#MAXLIST,d3
	bhi	.dn
	move.l	d2,(a2)+
	moveq	#0,d1
	move.b	d2,d1
	move.l	d1,(a2)+
	move.b	d0,d1
	move.l	d1,(a2)+
	eor.b	d2,d1
	move.l	d1,(a2)+
.dn:	addq.l	#1,d2
	bra	.dl
.dd:	lea	args,a1
	move.l	d3,(a1)
	lea	fmt_dm(pc),a0
	bsr	printf
	cmp.l	#MAXLIST,d3
	bls	.d0
	moveq	#MAXLIST,d3
.d0:	lea	dmtab,a1
	lea	fmt_dme(pc),a0
	bra	.pe
.pl:	bsr	printf
	lea	16(a1),a1
.pe:	dbf	d3,.pl

; aligned walk: i = d2 (received), e = d3 (expected stream position)
	moveq	#0,d2
	moveq	#0,d3
.wl:	cmp.l	d7,d2
	bhs	.wend
	move.b	(a5,d2.l),d0
	cmp.b	d3,d0
	bne	.bad
	addq.l	#1,d2
	addq.l	#1,d3
	bra	.wl
.bad:	move.l	d7,d6			; window m = min(4, n - i)
	sub.l	d2,d6
	moveq	#4,d0
	cmp.l	d0,d6
	bls	.m4
	move.l	d0,d6
.m4:	move.l	d2,d0			; one byte changed, the rest goes on?
	addq.l	#1,d0
	move.l	d3,d1
	addq.l	#1,d1
	move.l	d6,d5
	subq.l	#1,d5
	bsr	match
	beq	.chg
	moveq	#1,d4			; k bytes lost?
.sk:	move.l	d2,d0
	move.l	d3,d1
	add.l	d4,d1
	move.l	d6,d5
	bsr	match
	beq	.skip
	addq.l	#1,d4
	cmp.l	#256,d4
	blo	.sk
	moveq	#1,d4			; j extra bytes?
.in:	move.l	d2,d0
	add.l	d4,d0
	cmp.l	d7,d0
	bhs	.fb
	move.l	d7,d5
	sub.l	d0,d5
	moveq	#4,d1
	cmp.l	d1,d5
	bls	.i4
	move.l	d1,d5
.i4:	move.l	d3,d1
	bsr	match
	beq	.ins
	addq.l	#1,d4
	cmp.l	#9,d4
	blo	.in
; fallback (m >= 2 here): two gaps inside the window, e.g. $11 and $13 both
; filtered.  Next byte = e+1: this one changed.  Else a small forward step
; from e to this byte and from this byte to the next: k bytes lost.
.fb:	move.b	1(a5,d2.l),d0
	move.b	d3,d1
	addq.b	#1,d1
	cmp.b	d1,d0
	beq	.chg
	moveq	#0,d4
	move.b	(a5,d2.l),d4
	sub.b	d3,d4			; k = (got - e) & 255, >= 1
	cmp.w	#64,d4
	bhi	.chg
	sub.b	(a5,d2.l),d0		; next - this
	beq	.chg
	cmp.b	#64,d0
	bls	.skip
.chg:	moveq	#0,d1
	move.b	(a5,d2.l),d1
	eor.b	d3,d1
	moveq	#EV_CHG,d0
	bsr	addev
	lea	xorhist,a0
	moveq	#7,d0
.xh:	btst	d0,d1
	beq	.xn
	addq.l	#1,(a0,d0.w*4)
.xn:	dbf	d0,.xh
	addq.l	#1,nchg
	addq.l	#1,d2
	addq.l	#1,d3
	bra	.wl
.skip:	move.l	d4,d1
	moveq	#EV_SKIP,d0
	bsr	addev
	addq.l	#1,ngap
	add.l	d4,nmiss
	lea	misshist,a0
	move.l	d4,d0
	subq.l	#1,d0
	move.l	d3,d1
.mh:	moveq	#0,d5
	move.b	d1,d5
	addq.l	#1,(a0,d5.l*4)
	addq.l	#1,d1
	dbf	d0,.mh
	add.l	d4,d3
	bra	.wl
.ins:	move.l	d4,d1
	moveq	#EV_INS,d0
	bsr	addev
	addq.l	#1,nins
	add.l	d4,ninsb
	add.l	d4,d2
	bra	.wl
.wend:	move.l	count,d0
	sub.l	d3,d0
	bhi	.tl
	moveq	#0,d0
.tl:	move.l	d0,tail

	lea	args,a1
	move.l	nchg,(a1)
	move.l	nmiss,4(a1)
	move.l	ngap,8(a1)
	move.l	ninsb,12(a1)
	move.l	nins,16(a1)
	move.l	tail,20(a1)
	lea	fmt_aligned(pc),a0
	bsr	printf
	move.l	nev,d4
	cmp.l	#MAXLIST,d4
	bls	.v0
	moveq	#MAXLIST,d4
.v0:	lea	evtab,a2
	bra	.ve
.vl:	lea	args,a1
	move.l	(a2)+,d0		; type
	move.l	(a2)+,(a1)		; offset
	lea	fmt_evchg(pc),a0
	tst.l	d0
	bne	.vs
	move.l	(a2)+,4(a1)		; exp got xor
	move.l	(a2)+,8(a1)
	move.l	(a2)+,12(a1)
	bra	.vp
.vs:	lea	fmt_evskip(pc),a0
	subq.l	#EV_SKIP,d0
	beq	.v1
	lea	fmt_evins(pc),a0
.v1:	move.l	(a2)+,8(a1)		; count exp got
	move.l	(a2)+,12(a1)
	move.l	(a2)+,4(a1)
.vp:	bsr	printf
.ve:	dbf	d4,.vl

	lea	args,a1			; xor bits, b7 first
	lea	xorhist+32,a0
	moveq	#7,d0
.xb:	move.l	-(a0),(a1)+
	dbf	d0,.xb
	lea	args,a1
	lea	fmt_xor(pc),a0
	bsr	printf
	lea	args,a1
	move.l	misshist+4*$11,d0
	move.l	d0,(a1)
	move.l	misshist+4*$13,d1
	move.l	d1,4(a1)
	move.l	nmiss,d5
	sub.l	d0,d5
	sub.l	d1,d5			; d5 = other lost values
	move.l	d5,8(a1)
	lea	fmt_lostv(pc),a0
	bsr	printf

	moveq	#0,d6			; d6: something wrong
	lea	args,a1
	move.l	nmiss,d0
	beq	.vc
	move.l	d0,(a1)
	move.l	ngap,4(a1)
	lea	fmt_vlost(pc),a0
	bsr	printf
	moveq	#1,d6
	tst.l	d5
	bne	.vc
	lea	msg_vfilt(pc),a0
	bsr	puts
.vc:	move.l	nchg,d0
	beq	.vi
	move.l	d0,(a1)
	lea	fmt_vchg(pc),a0
	bsr	printf
	moveq	#1,d6
.vi:	move.l	nins,d0
	beq	.vt
	move.l	ninsb,(a1)
	move.l	d0,4(a1)
	lea	fmt_vins(pc),a0
	bsr	printf
	moveq	#1,d6
.vt:	move.l	tail,d0
	beq	.vd
	move.l	d0,(a1)
	lea	fmt_vshort(pc),a0
	bsr	printf
	moveq	#1,d6
.vd:	move.l	nerr,d0
	beq	.vok
	move.l	d0,(a1)
	lea	fmt_verr(pc),a0
	bsr	printf
	moveq	#1,d6
.vok:	moveq	#5,d0
	tst.l	d6
	bne	.rc
	lea	msg_perfect(pc),a0
	bsr	puts
	moveq	#0,d0
.rc:	move.l	d0,rc
	rts

; got[d0 ..] == d1, d1+1, ... (mod 256) for d5 bytes?  Z if so.  Trashes d0/d1/d5.
match:	subq.l	#1,d5
	bmi	.y
.l:	cmp.b	(a5,d0.l),d1
	bne	.n
	addq.l	#1,d0
	addq.b	#1,d1
	dbf	d5,.l
.y:	moveq	#0,d0
	rts
.n:	moveq	#1,d0
	rts

; event d0 = type, d1 = xor or count, at i = d2, e = d3
addev:	movem.l	d0/d5/a0,-(sp)
	move.l	nev,d5
	addq.l	#1,nev
	cmp.l	#MAXLIST,d5
	bhs	.x
	mulu.w	#20,d5
	lea	evtab,a0
	add.l	d5,a0
	move.l	d0,(a0)+
	move.l	d2,(a0)+
	moveq	#0,d0
	move.b	d3,d0
	move.l	d0,(a0)+
	move.b	(a5,d2.l),d0
	move.l	d0,(a0)+
	move.l	d1,(a0)
.x:	movem.l	(sp)+,d0/d5/a0
	rts

;---------------------------------------------------------------- output
puts:	move.l	a1,-(sp)
	lea	args,a1
	bsr	printf
	move.l	(sp)+,a1
	rts

; a0 = format, a1 = arguments; keeps every register
printf:	movem.l	d0-d2/a0-a1/a6,-(sp)
	move.l	dosbase,a6
	move.l	a0,d1
	move.l	a1,d2
	jsr	_LVOVPrintf(a6)
	movem.l	(sp)+,d0-d2/a0-a1/a6
	rts

errnames:
	dc.l	s_em4,s_em3,s_em2,s_em1,s_e0,s_e1,s_e2,s_unk,s_e4,s_e5,s_e6
	dc.l	s_unk,s_unk,s_e9,s_unk,s_e11,s_e12,s_e13,s_unk,s_e15
stopnames:
	dc.l	s_stcount,s_stidle,s_sttimeout,s_stctrlc,s_sterrs

dosname:	dc.b	"dos.library",0
sername:	dc.b	"serial.device",0
timername:	dc.b	"timer.device",0
template:	dc.b	"BAUD/K/N,COUNT/K/N,TIMEOUT/K/N,IDLE/K/N,BUF/K/N,UNIT/K/N,XON/S,SHARED/S,BOOGIE/S,NOBOOGIE/S,SAVE/K,FROM/K,SELFTEST/S",0
msg_usage:	dc.b	"Usage: SerRx [BAUD=n] [COUNT=n] [TIMEOUT=s] [IDLE=s] [BUF=n] [UNIT=n] [XON]",10
		dc.b	"             [SHARED] [BOOGIE|NOBOOGIE] [SAVE=file] [FROM=file] [SELFTEST]",10,0
err_baud:	dc.b	"BAUD must be 112..1000000",10,0
err_count:	dc.b	"COUNT must be 1..16777216",10,0
err_timeout:	dc.b	"TIMEOUT must be 1..3600 s",10,0
err_idle:	dc.b	"IDLE must be 1..600 s",10,0
err_buf:	dc.b	"BUF must be 64..16777216",10,0
err_boogie:	dc.b	"BOOGIE and NOBOOGIE together make no sense",10,0
err_mem:	dc.b	"out of memory",10,0
err_from:	dc.b	"cannot read %s",10,0
err_save:	dc.b	"SAVE %s: write failed",10,0
err_timer:	dc.b	"cannot open timer.device",10,0
err_open:	dc.b	"OpenDevice serial.device unit %ld failed: io_Error %ld %s",10,0
fmt_from:	dc.b	"FROM %s: %ld bytes",10,0
fmt_saved:	dc.b	"SAVE %s: %ld bytes written",10,0
msg_selftest:	dc.b	"SELFTEST: built-in stream, COUNT 4096",10,0
fmt_open:	dc.b	"SerRx: serial.device unit %ld %s, Prefs default io_Baud %ld",10,0
fmt_set:	dc.b	"SETPARAMS io_Error %ld %s: io_Baud %ld io_RBufLen %ld io_ReadLen %ld io_WriteLen %ld io_StopBits %ld io_ExtFlags $%lx io_CtlChar $%08lx",10,0
fmt_flags:	dc.b	"io_SerFlags $%02lx: XDISABLED %s RAD_BOOGIE %s 7WIRE %s SHARED %s PARITY %s EOFMODE %s",10,0
fmt_serper:	dc.b	"SERPER (PAL 3546895 Hz; NTSC would be 3579545): 3546895/baud-1 = %ld -> %ld baud (%lc%ld.%02ld%lc), rounded %ld -> %ld baud (%lc%ld.%02ld%lc)",10,0
fmt_wait:	dc.b	"waiting up to %ld s for the first byte; stop at COUNT %ld or after %ld s without a byte; ^C stops",10,0
fmt_stop:	dc.b	"stop: %s, %ld bytes received",10,0
fmt_time:	dc.b	"first to last byte %ld.%02ld s, %ld bytes/s (8N1 line maximum %ld bytes/s)",10,0
fmt_nerr:	dc.b	"device errors %ld",10,0
fmt_err:	dc.b	"  #%ld at byte %ld: %s io_Error %ld %s",10,0
fmt_status:	dc.b	"io_Status last $%04lx, high byte ORed over the run $%02lx: overrun %s, break received %s, receive XOFFed %s, transmit XOFFed %s; bytes left unread %ld",10,0
fmt_recv:	dc.b	"received %ld expected %ld",10,0
fmt_dm:		dc.b	"same-offset mismatches %ld",10,0
fmt_dme:	dc.b	"  @%ld exp $%02lx got $%02lx xor $%02lx",10,0
fmt_aligned:	dc.b	"aligned: changed %ld, lost %ld in %ld gaps, extra %ld in %ld places, tail missing %ld",10,0
fmt_evchg:	dc.b	"  @%ld changed exp $%02lx got $%02lx xor $%02lx",10,0
fmt_evskip:	dc.b	"  @%ld lost %ld exp $%02lx got $%02lx",10,0
fmt_evins:	dc.b	"  @%ld extra %ld exp $%02lx got $%02lx",10,0
fmt_xor:	dc.b	"xor bits b7..b0: %ld %ld %ld %ld %ld %ld %ld %ld",10,0
fmt_lostv:	dc.b	"lost values: $11 %ld, $13 %ld, other %ld",10,0
fmt_vlost:	dc.b	"verdict: LOST %ld bytes in %ld gaps",10,0
msg_vfilt:	dc.b	"verdict: FILTERED -- every lost byte is $11/$13 (XON/XOFF)",10,0
fmt_vchg:	dc.b	"verdict: CHANGED %ld bytes (bit errors, see xor bits)",10,0
fmt_vins:	dc.b	"verdict: EXTRA %ld bytes in %ld places",10,0
fmt_vshort:	dc.b	"verdict: SHORT %ld bytes missing at the end",10,0
fmt_verr:	dc.b	"verdict: DEVICE ERRORS %ld (see above)",10,0
msg_perfect:	dc.b	"verdict: PERFECT",10,0
s_on:		dc.b	"on",0
s_off:		dc.b	"off",0
s_excl:		dc.b	"exclusive",0
s_shared:	dc.b	"shared",0
s_cmdread:	dc.b	"CMD_READ",0
s_cmdquery:	dc.b	"SDCMD_QUERY",0
s_stcount:	dc.b	"COUNT reached",0
s_stidle:	dc.b	"IDLE: no byte for IDLE s",0
s_sttimeout:	dc.b	"TIMEOUT: no byte at all",0
s_stctrlc:	dc.b	"^C",0
s_sterrs:	dc.b	"1000 device errors, giving up",0
s_unk:		dc.b	"(unknown)",0
s_em4:		dc.b	"IOERR_BADLENGTH",0
s_em3:		dc.b	"IOERR_NOCMD",0
s_em2:		dc.b	"IOERR_ABORTED",0
s_em1:		dc.b	"IOERR_OPENFAIL",0
s_e0:		dc.b	"ok",0
s_e1:		dc.b	"SerErr_DevBusy",0
s_e2:		dc.b	"SerErr_BaudMismatch",0
s_e4:		dc.b	"SerErr_BufErr",0
s_e5:		dc.b	"SerErr_InvParam",0
s_e6:		dc.b	"SerErr_LineErr (hardware overrun)",0
s_e9:		dc.b	"SerErr_ParityErr",0
s_e11:		dc.b	"SerErr_TimerErr",0
s_e12:		dc.b	"SerErr_BufOverflow (read buffer full)",0
s_e13:		dc.b	"SerErr_NoDSR",0
s_e15:		dc.b	"SerErr_DetectedBreak",0
	even

	section	vars,bss
sysbase:	ds.l	1
dosbase:	ds.l	1
rdargs:		ds.l	1
rc:		ds.l	1
argv:		ds.l	13
baud:		ds.l	1
count:		ds.l	1
timeout:	ds.l	1
idle:		ds.l	1
rbuflen:	ds.l	1
unit:		ds.l	1
savename:	ds.l	1
fromname:	ds.l	1
buf:		ds.l	1
got:		ds.l	1
port:		ds.l	1
serreq:		ds.l	1
tmrreq:		ds.l	1
prefsbaud:	ds.l	1
laststat:	ds.l	1
orstat:		ds.l	1
leftover:	ds.l	1
nerr:		ds.l	1
errtab:		ds.l	3*MAXLIST
nev:		ds.l	1
evtab:		ds.l	5*MAXLIST
dmtab:		ds.l	4*MAXLIST
xorhist:	ds.l	8
misshist:	ds.l	256
nchg:		ds.l	1
nmiss:		ds.l	1
ngap:		ds.l	1
nins:		ds.l	1
ninsb:		ds.l	1
tail:		ds.l	1
ds_first:	ds.l	3
ds_last:	ds.l	3
args:		ds.l	32
xon:		ds.b	1
shared:		ds.b	1
boogie:		ds.b	1
selftest:	ds.b	1
started:	ds.b	1
ser_out:	ds.b	1
tmr_out:	ds.b	1
seropen:	ds.b	1
tmropen:	ds.b	1
stopreason:	ds.b	1
