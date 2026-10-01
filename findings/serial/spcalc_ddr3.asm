; spcalc_ddr3.asm -- findings/serial: serial.device 3.1.4's SERPER code
; (devs/serial.device $11ae-$11f2, PAL), instruction for instruction, on
; sim/ddr3_cpu.  Expected 368 / 92 / 30 for 9600 / 38400 / 115200; the
; board's line runs as if SERPER were ~$7B6E at the Prefs setting.
; The tail is the device's too: the result is stored to the device base
; (464(a6), here in DDR3 fast RAM, pre-filled with $7B6E) and read straight
; back -- store-to-load forwarding -- before it goes to $DFF032 (here to the
; mailbox instead).
; MBOX = 1 pass, 2 fail (MBOX+4.. = the three results), 99 exception.
MBOX	equ	$1000
DEV	equ	$41050000
	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr
start:	moveq	#0,d0
	move.l	d0,MBOX
	move.l	#1,MBOX+$10
	lea	MBOX+4,a2
	lea	DEV,a6
	move.w	#$7B6E,464(a6)		; a stale SERPER
	move.b	#8,68(a6)		; 8 data bits
	move.b	#0,71(a6)
	move.b	#$20,474(a6)
	move.l	#9600,d0
	bsr	spcalc
	move.l	#38400,d0
	bsr	spcalc
	move.l	#115200,d0
	bsr	spcalc
	move.l	#2,MBOX+$10
	cmp.l	#368,MBOX+4
	bne.s	.f
	cmp.l	#92,MBOX+8
	bne.s	.f
	cmp.l	#30,MBOX+12
	bne.s	.f
	move.l	#1,MBOX
.ok:	bra.s	.ok
.f:	move.l	#2,MBOX
.ff:	bra.s	.ff
spcalc:	move.l	d0,d1
	lsl.l	#3,d0
	sub.l	d1,d0
	move.l	#24772416,d1
	cmpi.l	#65535,d0
	ble.s	.small
	lsr.l	#5,d0
	divu.w	d0,d1
	and.l	#65535,d1
	lsr.l	#5,d1
	bra.s	.st
.small:	divu.w	d0,d1
.st:	move.w	d1,464(a6)		; serial.device $11f2..$121a
	move.w	464(a6),d0
	bclr	#5,474(a6)
	cmpi.b	#8,68(a6)
	bne.s	.w
	btst	#0,71(a6)
	beq.s	.w
	bset	#15,d0
	bset	#5,474(a6)
.w:	and.l	#65535,d0
	move.l	d0,(a2)+		; what would go to $DFF032
	rts
except:	move.l	#99,MBOX
.e:	bra.s	.e
