;-----------------------------------------------------------------------------
; freecore_test.asm -- sim/ddr3_cpu program for findings/unfreeze/plan.md.
; Back-to-back accesses whose answers come from different sides of
; rtl/soc/TG68K.vhd: the 16-bit adapter (the undecoded hole, auto-completed
; with $FFFF; chip-RAM words when run with --chipbus) and the router (the
; DDR3 board; chip-RAM longwords).  With a free-running core a stale adapter
; acknowledge, or the read-data mux choosing the adapter's old data, hands
; one access's answer to the next.  Caches OFF, so every access -- the
; instruction fetches too -- crosses m_*.
; Codes: 30 adapter then DDR3 read   31 DDR3 then adapter read
;        32 chip word then DDR3 read 33 DDR3 store, adapter access, DDR3 load
;        99 unexpected exception
;-----------------------------------------------------------------------------
MBOX      equ $00001000
STACKTOP  equ $00007000
DDRBASE   equ $41000000
UNDECODED equ $42000000
CHIPSCR   equ $00008000
          ifnd      NLONGS
NLONGS    equ 64
          endif

          org       $0
          dc.l      STACKTOP
          dc.l      START
          rept      254
          dc.l      EXCEPT
          endr

START:    moveq     #0,d0
          move.l    d0,MBOX
          move.l    d0,MBOX+4
          move.l    d0,MBOX+16
          movec     d0,cacr              ; caches off: everything crosses m_*
          movec     d0,tc

; phase 1: seed DDR3 with $D0000000+off and chip scratch with $C0000000+off
          moveq     #1,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          movea.l   #CHIPSCR,a1
          moveq     #0,d1
          move.w    #NLONGS-1,d6
seed:     move.l    d1,d2
          or.l      #$D0000000,d2
          move.l    d2,(a0)+
          move.l    d1,d2
          or.l      #$C0000000,d2
          move.l    d2,(a1)+
          addq.l    #4,d1
          dbra      d6,seed

; phase 2: adapter answer, then a router answer straight behind it
          moveq     #2,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p2:       move.l    UNDECODED,d3
          move.l    (a0)+,d4
          cmp.l     #$FFFFFFFF,d3
          bne       f30
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f30
          addq.l    #4,d1
          dbra      d6,p2

; phase 3: router answer, then the adapter's
          moveq     #3,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p3:       move.l    (a0)+,d4
          move.l    UNDECODED,d3
          cmp.l     #$FFFFFFFF,d3
          bne       f31
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f31
          addq.l    #4,d1
          dbra      d6,p3

; phase 4: a chip-RAM WORD (the adapter under --chipbus), then DDR3
          moveq     #4,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          movea.l   #CHIPSCR,a1
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p4:       move.w    2(a1),d3             ; low word = off
          move.l    (a0)+,d4
          cmp.w     d1,d3
          bne       f32
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f32
          addq.l    #4,a1
          addq.l    #4,d1
          dbra      d6,p4

; phase 5: DDR3 store (posted), adapter write and read, DDR3 load of it
          moveq     #5,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p5:       move.l    d1,d2
          or.l      #$E0000000,d2
          move.l    d2,(a0)
          move.w    d2,UNDECODED
          move.l    UNDECODED,d3
          move.l    (a0)+,d4
          cmp.l     #$FFFFFFFF,d3
          bne       f33
          cmp.l     d2,d4
          bne       f33
          addq.l    #4,d1
          dbra      d6,p5

          moveq     #1,d7
          move.l    d7,MBOX
done:     bra.s     done

f30:      moveq     #30,d7
          bra.s     report
f31:      moveq     #31,d7
          bra.s     report
f32:      moveq     #32,d7
          bra.s     report
f33:      moveq     #33,d7
report:   move.l    d1,MBOX+4            ; which longword
          move.l    d7,MBOX
halt:     bra.s     halt
EXCEPT:   moveq     #99,d7
          move.l    d7,MBOX
          bra.s     halt
