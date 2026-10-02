; sdsetpar_ddr3.asm -- findings/serial: serial.device 3.1.4's own SERPER
; routine ($11AE-$1222 of devs/serial.device, with the bytes that follow its
; RTS), incbin'd byte for byte and called with BSR the way the device does,
; on sim/ddr3_cpu.  SerTest on the board proved that ONE read of $DFF032
; corrupts SERPER (Paula latches on any cycle with that register address, as
; the real chipset does); serprobe_ddr3.sv shows whether this code makes one.
; The device base (a6) is in DDR3; 100(a6) points at a fake ExecBase whose
; PowerSupplyFrequency (531) is 50.  Three calls: 9600, 38400, 115200.
; MMU=1 (vasm -DMMU=1, sdsetpar_mmu_ddr3.asm): translation on, data
; transparent-translated COPYBACK (DTT0 $00FFC020, as MuSetCacheMode leaves
; Z3 fast RAM on the board), instructions write-through: the board, under
; Workbench, wrote $7B6D to SERPER for 38400 from exactly this code.
; The three results also go to MBOX+4.. (what would go to $DFF032), and
; MBOX = 2 when one is wrong.
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
	ifd	MMU
	move.l	#$80008000,d0
	movec	d0,cacr
	move.l	#$00ffc020,d0		; data: copyback
	movec	d0,dtt0
	move.l	#$00ffc000,d0		; instructions: write-through
	movec	d0,itt0
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	endif
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
	move.w	464(a6),MBOX+6
	move.l	#2,MBOX+$10
	move.l	#38400,452(a6)
	bsr	setper
	move.w	464(a6),MBOX+10
	move.l	#3,MBOX+$10
	move.l	#115200,452(a6)
	bsr	setper
	move.w	464(a6),MBOX+14
	move.l	#4,MBOX+$10
	cmp.w	#368,MBOX+6
	bne.s	.bad
	cmp.w	#92,MBOX+10
	bne.s	.bad
	cmp.w	#30,MBOX+14
	bne.s	.bad
	move.l	#1,MBOX
.ok:	bra.s	.ok
.bad:	move.l	#2,MBOX
	bra.s	.bad
except:	move.l	#99,MBOX
.e:	bra.s	.e
	cnop	0,16
setper:	incbin	"serial314.code",$11ae,$1240-$11ae
