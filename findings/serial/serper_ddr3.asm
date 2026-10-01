; serper_ddr3.asm -- findings/serial: on the board the Amiga serial port runs
; at ~112 baud whatever Prefs says (SERPER ends up ~$7B6E).  Paula latches
; SERPER on every 7 MHz enable while reg_address == $032, without a write
; strobe, so any chipset cycle at $DFF032 other than the intended word write
; (a read, or a write whose data changes mid-cycle) corrupts it.  This program
; writes SERPER/SERDAT in the ways serial.device could; serprobe_ddr3.sv logs
; every chipset-bus cycle in $DFF000-$DFF1FF.
MBOX	equ	$1000
	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	except
	endr
start:	moveq	#0,d0
	move.l	d0,MBOX
	move.l	#1,MBOX+$10
	move.w	#$005B,$dff032		; 1: abs.l, immediate
	move.l	#2,MBOX+$10
	lea	$dff000,a5
	move.w	#$0170,d0
	move.w	d0,$32(a5)		; 2: d16(An), register
	move.l	#3,MBOX+$10
	lea	$dff032,a0
	move.w	#$0171,(a0)		; 3: (An)
	move.l	#4,MBOX+$10
	move.l	#$0155005C,$30(a5)	; 4: long = SERDAT + SERPER
	move.l	#5,MBOX+$10
	move.w	$18(a5),d1		; 5: SERDATR read
	move.w	#$0155,$30(a5)		; 6: SERDAT
	move.l	#6,MBOX+$10
	move.l	#1,MBOX
.ok:	bra.s	.ok
except:	move.l	#99,MBOX
.e:	bra.s	.e
