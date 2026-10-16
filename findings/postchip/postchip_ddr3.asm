; postchip_ddr3.asm -- findings/postchip: chip RAM stores under the MMU on
; sim/ddr3_cpu (the real AP68040, TG68K.vhd, sdram_ctrl; with TURBOCHIP=0 the
; bench answers the chipset bus itself).  Run with
; findings/ap040-pipelined/tests/perf/run_ddr3_prog.sh (TURBOCHIP=0 for the
; chip bus, FASTCHIP=1 for Chip slots Fast, POSTCHIP=<n> for the core).
;
; The setup a demo written for an A1200/A4000 accelerator runs under: the
; code in fast RAM (here the DDR3 board), the 24-bit space -- chip RAM --
; noncachable, nonserialized through DTT0 = $0000C060 (The Cure does exactly
; this), the fast RAM write-through through DTT1, and (TCON = 1, default)
; translation on as MMULib leaves it, so every store goes through the core's
; stage 4 path; TCON = 0 runs the same with translation off (stage 1).
;
; Absolute addresses are loaded as immediates (move.l #x,An): vasm turns a
; "lea abs,An" into a PC-relative one, which points elsewhere once the loops
; run from the DDR3 board.
;
; Phases (the bench prints a timestamp for each; NITER stores per phase):
;   1  setup: the loops are copied to the DDR3 board, a table filled there
;   2  move.l d0,(a0)+ ; dbra             (a pure store burst)
;   3  ... with 4 ALU instructions per store
;   4  ... with 8
;   5  ... with 16
;   6  ... with 32
;   7  move.b d0,(a0)+ with 4 ALU instructions (audio-buffer-like)
;   8  a load from the fast RAM table, 3 ALU, a longword store to chip RAM
;      (The Cure's screen loop shape)
;   9  read back every 4th longword of every region (CI reads, slow)
; MBOX = 1 when all is well, 2 + region on a mismatch, 99 on an exception.

          ifnd      NITER
NITER     equ 128
          endif
          ifnd      TCON
TCON      equ 1
          endif
CACRV     equ $80008000
MBOX      equ $1000
CHIP0     equ $8000             ; region k at CHIP0 + k*$800 (k = 0..6)
RELOC     equ $41020000         ; the loops run from the DDR3 board
TAB       equ $41040000         ; phase 8's source table

alu       macro                 ; \1 ALU instructions, no memory
          rept      \1/4
          add.l     d2,d3
          eor.l     d4,d5
          addq.l    #3,d6
          sub.l     d5,d2
          endr
          endm

          org       0
          dc.l      $1f00
          dc.l      start
          rept      254
          dc.l      except
          endr

          org       $400
start:    moveq     #0,d0
          move.l    d0,MBOX
          move.l    #1,MBOX+$10
          move.l    #CACRV,d0
          movec     d0,cacr
          ; the loops to the DDR3 board
          lea       body(pc),a0
          lea       RELOC,a1
          move.w    #(body_end-body)/4,d7
.cp:      move.l    (a0)+,(a1)+
          dbra      d7,.cp
          ; phase 8's table
          move.l    #TAB,a1
          move.l    #$12340000,d1
          move.w    #NITER-1,d7
.tb:      move.l    d1,(a1)+
          add.l     #$00010001,d1
          dbra      d7,.tb
          cpusha    bc
          ; data: chip RAM (the 24-bit space) CM = 11, the Zorro III space
          ; write-through; instructions: everything cacheable
          move.l    #$0000c060,d0
          movec     d0,dtt0
          move.l    #$403fc000,d0
          movec     d0,dtt1
          move.l    #$00ffc000,d0
          movec     d0,itt0
          pflusha
          if        TCON
          move.l    #$8000,d0
          movec     d0,tc
          endif
          jmp       RELOC

          cnop      0,4
body:
; 2: a pure store burst
          move.l    #2,MBOX+$10
          move.l    #CHIP0,a0
          move.l    #$02000000,d0
          move.w    #NITER-1,d7
.p2:      move.l    d0,(a0)+
          addq.l    #1,d0
          dbra      d7,.p2
; 3: 4 ALU per store
          move.l    #3,MBOX+$10
          move.l    #CHIP0+$800,a0
          move.l    #$03000000,d0
          move.w    #NITER-1,d7
.p3:      move.l    d0,(a0)+
          addq.l    #1,d0
          alu       4
          dbra      d7,.p3
; 4: 8 ALU per store
          move.l    #4,MBOX+$10
          move.l    #CHIP0+$1000,a0
          move.l    #$04000000,d0
          move.w    #NITER-1,d7
.p4:      move.l    d0,(a0)+
          addq.l    #1,d0
          alu       8
          dbra      d7,.p4
; 5: 16 ALU per store
          move.l    #5,MBOX+$10
          move.l    #CHIP0+$1800,a0
          move.l    #$05000000,d0
          move.w    #NITER-1,d7
.p5:      move.l    d0,(a0)+
          addq.l    #1,d0
          alu       16
          dbra      d7,.p5
; 6: 32 ALU per store
          move.l    #6,MBOX+$10
          move.l    #CHIP0+$2000,a0
          move.l    #$06000000,d0
          move.w    #NITER-1,d7
.p6:      move.l    d0,(a0)+
          addq.l    #1,d0
          alu       32
          dbra      d7,.p6
; 7: byte stores, 4 ALU each
          move.l    #7,MBOX+$10
          move.l    #CHIP0+$2800,a0
          moveq     #0,d0
          move.w    #NITER-1,d7
.p7:      move.b    d0,(a0)+
          addq.l    #1,d0
          alu       4
          dbra      d7,.p7
; 8: load from fast RAM, 3 ALU, store to chip RAM
          move.l    #8,MBOX+$10
          move.l    #CHIP0+$3000,a0
          move.l    #TAB,a1
          move.l    #$11111111,d4
          move.l    #$0f0f0f0f,d6
          move.w    #NITER-1,d7
.p8:      move.l    (a1)+,d1
          add.l     d4,d1
          eor.l     d6,d1
          addq.l    #1,d2
          move.l    d1,(a0)+
          dbra      d7,.p8
; 9: read back every 4th longword
          move.l    #9,MBOX+$10
          moveq     #2,d3                   ; region (failure code 2 + k)
          move.l    #CHIP0,a0
          move.l    #$02000000,d0
.v:       move.l    a0,a2
          move.l    d0,d1
          move.w    #NITER/4-1,d7
.vl:      cmp.l     (a2),d1
          bne       .bad
          lea       16(a2),a2
          addq.l    #4,d1
          dbra      d7,.vl
          lea       $800(a0),a0
          add.l     #$01000000,d0
          addq.l    #1,d3
          cmp.w     #7,d3
          bne.s     .v
          ; the byte region: byte i = i (mod 256)
          move.l    #CHIP0+$2800,a2
          moveq     #0,d1
          move.w    #NITER/4-1,d7
.vb:      cmp.b     (a2),d1
          bne.s     .bad
          addq.l    #4,a2
          addq.l    #4,d1
          dbra      d7,.vb
          addq.l    #1,d3
          ; the table region: (TAB[i] + $11111111) ^ $0f0f0f0f
          move.l    #CHIP0+$3000,a2
          move.l    #$12340000,d1
          move.w    #NITER/4-1,d7
.vt:      move.l    d1,d2
          add.l     #$11111111,d2
          eor.l     #$0f0f0f0f,d2
          cmp.l     (a2),d2
          bne.s     .badt
          lea       16(a2),a2
          add.l     #$00040004,d1
          dbra      d7,.vt
          move.l    #1,MBOX
.ok:      bra.s     .ok
.badt:    move.l    d2,d1
.bad:     move.l    a2,MBOX+4
          move.l    d1,MBOX+8
          move.l    (a2),MBOX+12
          move.l    d3,MBOX
.bf:      bra.s     .bf
          cnop      0,4
body_end:

except:   move.l    #99,MBOX
.e:       bra.s     .e
