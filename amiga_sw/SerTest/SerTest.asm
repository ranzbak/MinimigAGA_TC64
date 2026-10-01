; SerTest -- why the Amiga serial port runs at ~112 baud on the AP040 images
; (findings/serial).  Drives Paula directly, interrupts off, and sends four
; lines at 9600 8N1 (PAL SERPER $0170); each line also goes to the console.
;   A  SERPER written directly                 -> hardware write path
;   B  SERPER computed like serial.device does  -> CPU arithmetic
;      (EClock*5/baud - 1 via DIVU.L, DIVU.W and utility UDivMod32; the values
;      are printed, and line B is sent at the DIVU.L result)
;   C  SERPER written, then READ back once      -> Paula latches SERPER on any
;      cycle with reg_address $032 (agnus.v reg_address_cpu includes reads,
;      gary.v gives $FFFF on reads); a garbled C line = a read corrupts it
;   D  SERPER written, then POTGO ($DFF034) written
;   F  serial.device 3.1.4's SERPER code, copied instruction for instruction
;      (LSL/SUB/CMPI/BLE/LSR #5/DIVU.W/AND/LSR #5, then the store to the
;      device base and the load straight back), for 9600/38400/115200
; After C and D SERPER is rewritten, so a broken line does not hide the next.
; Capture at 9600 8N1, no handshake.  Self-contained, no NDK.  Build: Makefile.

_LVODisable     equ     -120
_LVOEnable      equ     -126
_LVOCloseLibrary equ    -414
_LVOOpenLibrary equ     -552
_LVORawDoFmt    equ     -522
_LVOPutStr      equ     -948            ; dos.library V36
_LVOUDivMod32   equ     -156            ; utility.library
ex_EClockFrequency equ  $238
VBlankFrequency equ     $212
AttnFlags       equ     $128

SERDATR         equ     $dff018
SERDAT          equ     $dff030
SERPER          equ     $dff032
POTGO           equ     $dff034
PER9600         equ     $0170           ; 3546895/9600 - 1

	section	code,code
start:	move.l	4.w,a6
	lea	dosname(pc),a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,dosbase
	beq	.nodos
	lea	utilname(pc),a1
	moveq	#36,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,utilbase

	; B's numbers, computed before interrupts go off
	lea	args(pc),a2
	move.l	4.w,a0
	move.l	ex_EClockFrequency(a0),d2
	move.l	d2,(a2)+		; EClock
	moveq	#0,d0
	move.b	VBlankFrequency(a0),d0
	move.l	d0,(a2)+		; VBlank
	move.w	AttnFlags(a0),d0
	move.l	d0,(a2)+		; AttnFlags
	move.l	d2,d3
	mulu.l	#5,d3			; colour clock
	move.l	d3,(a2)+
	move.l	d3,d0
	divu.l	#9600,d0		; DIVU.L 32/32
	subq.l	#1,d0
	move.l	d0,(a2)+
	move.l	d3,d0
	divu.w	#9600,d0		; DIVU.W 32/16 (quotient in low word)
	and.l	#$ffff,d0
	subq.l	#1,d0
	move.l	d0,(a2)+
	moveq	#-1,d0
	move.l	utilbase(pc),d1
	beq.s	.nou
	move.l	a6,-(sp)
	move.l	d1,a6
	move.l	d3,d0
	move.l	#9600,d1
	jsr	_LVOUDivMod32(a6)
	move.l	(sp)+,a6
	subq.l	#1,d0
.nou:	move.l	d0,(a2)+		; UDivMod32
	lea	fmtb(pc),a0
	lea	args(pc),a1
	bsr	format			; -> linebuf
	move.l	args+16(pc),d4		; the DIVU.L SERPER for line B

	; F: serial.device 3.1.4's own SERPER code (devs/serial.device $11ae-$11f2,
	; PAL clock), instruction for instruction, for 9600 / 38400 / 115200
	lea	fargs(pc),a2
	move.l	#9600,d0
	bsr	spcalc
	move.l	#38400,d0
	bsr	spcalc
	move.l	#115200,d0
	bsr	spcalc
	lea	fmtf(pc),a0
	lea	fargs(pc),a1
	lea	linef(pc),a3
	bsr	format2

	jsr	_LVODisable(a6)
	lea	$dff000,a5

	move.w	#PER9600,SERPER-$dff000(a5)
	lea	txta(pc),a0
	bsr	send

	move.w	d4,SERPER-$dff000(a5)
	lea	linebuf(pc),a0
	bsr	send

	move.w	#PER9600,SERPER-$dff000(a5)
	tst.w	SERPER-$dff000(a5)	; the read under test
	lea	txtc(pc),a0
	bsr	send
	move.w	#PER9600,SERPER-$dff000(a5)
	lea	txtc2(pc),a0
	bsr	send

	move.w	#PER9600,SERPER-$dff000(a5)
	move.w	#$ff00,POTGO-$dff000(a5)
	lea	txtd(pc),a0
	bsr	send
	move.w	#PER9600,SERPER-$dff000(a5)
	lea	linef(pc),a0
	bsr	send
	lea	txte(pc),a0
	bsr	send

	jsr	_LVOEnable(a6)

	; the same lines on the console
	move.l	dosbase(pc),a6
	lea	txta(pc),a0
	bsr	puts
	lea	linebuf(pc),a0
	bsr	puts
	lea	txtc(pc),a0
	bsr	puts
	lea	txtd(pc),a0
	bsr	puts
	lea	linef(pc),a0
	bsr	puts
	lea	txte(pc),a0
	bsr	puts
	move.l	4.w,a6
	move.l	utilbase(pc),d0
	beq.s	.nu2
	move.l	d0,a1
	jsr	_LVOCloseLibrary(a6)
.nu2:	move.l	dosbase(pc),a1
	jsr	_LVOCloseLibrary(a6)
	moveq	#0,d0
	rts
.nodos:	moveq	#20,d0
	rts

; send: a0 = NUL-terminated string, polled, 8N1; waits for the last stop bit
send:	moveq	#0,d0
	move.b	(a0)+,d0
	beq.s	.sd
.tbe:	btst	#13-8,SERDATR-$dff000(a5)	; TBE (byte read of the high byte)
	beq.s	.tbe
	or.w	#$0100,d0		; one stop bit
	move.w	d0,SERDAT-$dff000(a5)
	bra.s	send
.sd:	btst	#12-8,SERDATR-$dff000(a5)	; TSRE
	beq.s	.sd
	rts

; spcalc: d0 = baud -> (a2)+ = SERPER as serial.device 3.1.4 computes it
spcalc:	move.l	d0,d1
	lsl.l	#3,d0
	sub.l	d1,d0			; baud * 7
	move.l	#24772416,d1		; PAL: 7 * colour clock
	cmpi.l	#65535,d0
	ble.s	.small
	lsr.l	#5,d0
	divu.w	d0,d1
	and.l	#65535,d1
	lsr.l	#5,d1
	bra.s	.st
.small:	divu.w	d0,d1
.st:	move.l	a6,-(sp)		; serial.device $11f2..$121a: through the
	lea	devbuf(pc),a6		; device base (fast RAM), stored and read
	move.w	#$7B6E,464(a6)		; straight back; $7B6E = a stale value
	move.b	#8,68(a6)
	move.w	d1,464(a6)
	move.w	464(a6),d0
	bclr	#5,474(a6)
	cmpi.b	#8,68(a6)
	bne.s	.w
	btst	#0,71(a6)
	beq.s	.w
	bset	#15,d0
	bset	#5,474(a6)
.w:	move.l	(sp)+,a6
	and.l	#65535,d0
	move.l	d0,(a2)+
	rts

; puts: a0 = string, a6 = dosbase
puts:	move.l	a0,d1
	jmp	_LVOPutStr(a6)

; format: RawDoFmt(a0 fmt, a1 args) into linebuf; format2: into (a3)
format:	lea	linebuf(pc),a3
format2: movem.l	a2-a3/a6,-(sp)
	move.l	4.w,a6
	lea	.pc(pc),a2
	jsr	_LVORawDoFmt(a6)
	movem.l	(sp)+,a2-a3/a6
	rts
.pc:	move.b	d0,(a3)+
	rts

dosbase:	dc.l	0
utilbase:	dc.l	0
args:		ds.l	8
dosname:	dc.b	"dos.library",0
utilname:	dc.b	"utility.library",0
txta:	dc.b	"A SERPER=$0170 written directly: this line is readable at 9600",13,10,0
fmtb:	dc.b	"B EClock=%ld VBlank=%ld Attn=$%lx cck=%ld DIVU.L=%ld DIVU.W=%ld UDivMod32=%ld (all should be 368)",13,10,0
txtc:	dc.b	"C after one READ of $DFF032 (garbled = a read corrupts SERPER)",13,10,0
txtc2:	dc.b	"C2 SERPER rewritten",13,10,0
txtd:	dc.b	"D after a POTGO write",13,10,0
fmtf:	dc.b	"F serial.device code: 9600->%ld 38400->%ld 115200->%ld (should be 368 92 30)",13,10,0
txte:	dc.b	"E end of SerTest",13,10,0
	even
fargs:		ds.l	4
devbuf:		ds.b	480
linebuf:	ds.b	160
linef:		ds.b	160
