Copper1 equ $8e680
Copper2 equ $8e69c
bpl1	equ $80000
bpl2	equ	$85000
BLITS	equ 64

	org	0
tag:
	dc.l	0
	dc.l	8
start:
	move.w #$0000,$dff1fc  ; FMODE, slow fetch mode for AGA compatibility
	move.w #$0002,$dff02e  ; COPCON, enable danger mode
	move.l #Copper1,$dff080  ; COP1LCH, copper 1 pointer
	move.l #Copper2,$dff084  ; CPO2LCH, copper 2 pointer

	move.w #$2c81,$dff08e  ; DIWSTRT, screen upper left corner
	move.w #$f4c1,$dff090  ; DIWSTOP, screen lower right corner
	move.w #$003c,$dff092  ; DDFSTRT, display data fetch start
	move.w #$00d4,$dff094  ; DDFSTOP, display data fetch stop
	move.w #$87c0,$dff096  ; DMACON, enable important bits
	move.w #$0000,$dff098  ; CLXCON, TODO
	move.w #$7fff,$dff09a  ; INTENA, disable all interrupts
	move.w #$7fff,$dff09c  ; INTREQ, disable all interrupts
	move.w #$0000,$dff09e  ; ADKCON, TODO

	move.w #(bpl1>>16)&$ffff,$dff0e0  ; BPL1PTH
	move.w #bpl1&$ffff,$dff0e2    ; BPL1PTL
	move.w #(bpl2>>16)&$ffff,$dff0e4  ; BPL2PTH
	move.w #bpl2&$ffff,$dff0e6    ; BPL2PTL

	move.w #$a200,$dff100  ; BPLCON0, two bitplanes & colorburst enabled
	move.w #$0000,$dff102  ; BPLCON1, bitplane control scroll value
	move.w #$0000,$dff104  ; BPLCON2, misc bitplane bits
	move.w #$0000,$dff106  ; BPLCON3, TODO
	move.w #$0000,$dff108  ; BPL1MOD, bitplane modulo for odd planes
	move.w #$0000,$dff10a  ; BPL2MOD, bitplane modulo for even planes

	move.w #$09f0,$dff040  ; BLTCON0
	move.w #$0000,$dff042  ; BLTCON1
	move.w #$ffff,$dff044  ; BLTAFWM, blitter first word mask for srcA
	move.w #$ffff,$dff046  ; BLTALWM, blitter last word mask for srcA

	move.w #$0000,$dff064  ; BLTAMOD
	move.w #BLITS,$dff066  ; BLTDMOD

	move.w #$0000,$dff180  ; COLOR00
	move.w #$0aaa,$dff182  ; COLOR01
	move.w #$0a00,$dff184  ; COLOR02
	move.w #$000a,$dff186  ; COLOR03

	move.w #$0000,$dff088  ; COPJMP1, restart copper at location 1 
.endloop
	bra.s	.endloop

