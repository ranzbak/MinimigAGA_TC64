; sdsetpar_ddr3.asm -- findings/serial: serial.device 3.1.4's own SERPER
; routine ($11AE-$1222 of devs/serial.device, with the bytes that follow its
; RTS), incbin'd byte for byte and called with BSR the way the device does,
; on sim/ddr3_cpu.  SerTest on the board proved that ONE read of $DFF032
; corrupts SERPER (Paula latches on any cycle with that register address, as
; the real chipset does); serprobe_ddr3.sv shows whether this code makes one.
; The device base (a6) is in DDR3; 100(a6) points at a fake ExecBase whose
; PowerSupplyFrequency (531) is 50.  Three calls: 9600, 38400, 115200.
MBOX	equ	$1000
DEV	equ	$41050000
EXB	equ	$41060000
	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr
start:	moveq	#0,d0
	move.l	d0,MBOX
	move.l	#1,MBOX+$10
	lea	DEV,a6
	lea	EXB,a0
	move.l	a0,100(a6)
	move.b	#50,531(a0)
	move.b	#8,68(a6)
	move.b	#0,71(a6)
	move.b	#0,474(a6)
	move.l	#9600,452(a6)
	bsr	setper
	move.l	#2,MBOX+$10
	move.l	#38400,452(a6)
	bsr	setper
	move.l	#3,MBOX+$10
	move.l	#115200,452(a6)
	bsr	setper
	move.l	#4,MBOX+$10
	move.l	#1,MBOX
.ok:	bra.s	.ok
except:	move.l	#99,MBOX
.e:	bra.s	.e
	cnop	0,16
setper:	incbin	"serial314.code",$11ae,$1240-$11ae
