; diff: --from-pc 402 --cycles 3000
; diff_smoke.s - differential smoke program for the pipelined vs reference
; AP68040 retire-trace harness (tb_ap040_pipe_trace.v / tb_ap040_ref_trace.v).
;
; Uses ONLY what the pipelined branch decodes at milestone 17 (MOVEQ,
; ADD.L Dn,Dn, Bcc, DBcc, Scc Dn, BSR/RTS, TRAP/RTE, MOVEC) so that any
; divergence in the trace is a semantic difference, not a missing opcode.
; Extend it one opcode at a time as the pipeline grows; the moment the
; traces diverge, compare_trace.py names the first differing instruction.
;
; assemble: vasmm68k_mot -Fbin -m68040 -no-opt -o diff_smoke.bin diff_smoke.s
;           python3 bin2hex.py diff_smoke.bin diff_smoke.hex

	org	0
	dc.l	$7C		; initial ISP (reference reads it; the program also MOVECs it so both cores agree)
	dc.l	start		; initial PC
	rept	30
	dc.l	unexp		; vectors 2-31
	endr
	dc.l	trap0h		; vector 32: TRAP #0
	rept	223
	dc.l	unexp		; vectors 33-255
	endr

	org	$400
start:
	moveq	#$7C,d0
	movec	d0,isp		; A7 = $7C on both cores (pipelined resets ISP to 0, reference loads vector 0)
	moveq	#5,d1
	moveq	#0,d2
loop:
	add.l	d1,d2		; d2 = 5+4+3+2+1+0 = 15
	dbf	d1,loop
	moveq	#0,d4		; Z=1
	seq	d3		; d3.b = $FF (rest of d3 untouched: 0 after reset)
	moveq	#-1,d5
	add.l	d5,d5		; d5 = -2, X N C set
	bsr.s	sub		; d4 = 7
	bcs.s	skip		; C survives BSR/RTS: taken
	moveq	#99,d6		; must not run
skip:
	moveq	#1,d7
	trap	#0		; d3 = -3 in the handler, RTE back here
after:
	moveq	#42,d6
halt:
	bra.s	halt		; +halt_pc=$0000042A stops both dumpers here

sub:
	moveq	#7,d4
	rts

trap0h:
	moveq	#-3,d3
	rte

unexp:
	moveq	#-2,d7
	bra.s	unexp
