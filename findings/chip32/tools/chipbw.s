; chipbw.s -- CPU bandwidth to chip RAM and ROM, for findings/chip32/plan.md.
;
; Each test moves 256 KB (a 64 KB buffer, four passes) with interrupts off and
; is timed with CIA-B's TOD counter, which counts HSYNC lines: 15625 a second
; on PAL.  Run it from a Shell with nothing else running; run it twice.
;
;   vasmm68k_mot -m68020 -Fhunkexe -nosym -o chipbw chipbw.s
;
; Read the numbers with the setup next to them: Turbo chip, Turbo kick, and
; whether 68040.library has the MMU on (with the MMU off the core's data cache
; line-fills chip RAM, so even the word READ test moves longwords).

_LVOOpenLibrary  equ -552
_LVOCloseLibrary equ -414
_LVOAllocMem     equ -198
_LVOFreeMem      equ -210
_LVODisable      equ -120
_LVOEnable       equ -126
_LVOCacheClearU  equ -636
_LVOVPrintf      equ -954

MEMF_CHIP   equ $2
MEMF_CLEAR  equ $10000
BUFSIZE     equ 65536
PASSES      equ 4
TOTAL_KB    equ BUFSIZE*PASSES/1024
LINES_PER_S equ 15625

CIAB_TODHI  equ $BFDA00
CIAB_TODMID equ $BFD900
CIAB_TODLO  equ $BFD800

            section code,code
start:      movem.l d2-d7/a2-a6,-(sp)
            move.l  4.w,a6
            lea     dosname(pc),a1
            moveq   #36,d0
            jsr     _LVOOpenLibrary(a6)
            move.l  d0,dosbase
            beq     .exit
            move.l  #BUFSIZE,d0
            move.l  #MEMF_CHIP|MEMF_CLEAR,d1
            jsr     _LVOAllocMem(a6)
            move.l  d0,buf
            beq     .closedos
            lea     tests(pc),a4
.next:      move.l  (a4)+,d0            ; name, 0 ends the table
            beq.s   .done
            move.l  d0,argv
            move.l  (a4)+,a3            ; routine
            move.l  (a4)+,d0            ; region, 0 = the chip buffer
            bne.s   .have
            move.l  buf,d0
.have:      move.l  d0,a2
            bsr     time_it             ; d0 = HSYNC lines
            move.l  d0,argv+4
            move.l  #TOTAL_KB*LINES_PER_S,d1
            tst.l   d0
            beq.s   .zero
            divu.l  d0,d1
            bra.s   .print
.zero:      moveq   #0,d1
.print:     move.l  d1,argv+8
            move.l  dosbase,a6
            lea     fmt(pc),a0
            move.l  a0,d1
            move.l  #argv,d2
            jsr     _LVOVPrintf(a6)
            move.l  4.w,a6
            bra.s   .next
.done:      move.l  buf,a1
            move.l  #BUFSIZE,d0
            jsr     _LVOFreeMem(a6)
.closedos:  move.l  dosbase,a1
            jsr     _LVOCloseLibrary(a6)
.exit:      movem.l (sp)+,d2-d7/a2-a6
            moveq   #0,d0
            rts

; a2 = region, a3 = routine, a6 = ExecBase.  Returns d0 = HSYNC lines.
time_it:    jsr     _LVOCacheClearU(a6)
            jsr     _LVODisable(a6)
            bsr.s   read_tod
            move.l  d0,d6
            moveq   #PASSES-1,d5
.pass:      move.l  a2,a0
            jsr     (a3)
            dbra    d5,.pass
            bsr.s   read_tod
            jsr     _LVOEnable(a6)
            sub.l   d6,d0
            and.l   #$00FFFFFF,d0
            rts

; Reading the high byte latches the counter; reading the low byte releases it.
read_tod:   moveq   #0,d0
            move.b  CIAB_TODHI,d0
            lsl.l   #8,d0
            move.b  CIAB_TODMID,d0
            lsl.l   #8,d0
            move.b  CIAB_TODLO,d0
            rts

; Each routine: a0 = start, covers BUFSIZE bytes, uses d0-d1/a0 only.
rd_l:       move.w  #BUFSIZE/64-1,d1
.lp:        rept    16
            move.l  (a0)+,d0
            endr
            dbra    d1,.lp
            rts
wr_l:       move.w  #BUFSIZE/64-1,d1
            moveq   #0,d0
.lp:        rept    16
            move.l  d0,(a0)+
            endr
            dbra    d1,.lp
            rts
rd_w:       move.w  #BUFSIZE/32-1,d1
.lp:        rept    16
            move.w  (a0)+,d0
            endr
            dbra    d1,.lp
            rts
wr_w:       move.w  #BUFSIZE/32-1,d1
            moveq   #0,d0
.lp:        rept    16
            move.w  d0,(a0)+
            endr
            dbra    d1,.lp
            rts

tests:      dc.l    n_rdl,rd_l,0
            dc.l    n_wrl,wr_l,0
            dc.l    n_rdw,rd_w,0
            dc.l    n_wrw,wr_w,0
            dc.l    n_rom,rd_l,$00F80000
            dc.l    0

dosname:    dc.b    "dos.library",0
fmt:        dc.b    "%-10s %6ld lines %6ld KB/s",10,0
n_rdl:      dc.b    "chip rd.l",0
n_wrl:      dc.b    "chip wr.l",0
n_rdw:      dc.b    "chip rd.w",0
n_wrw:      dc.b    "chip wr.w",0
n_rom:      dc.b    "rom rd.l",0
            even

            section vars,bss
dosbase:    ds.l    1
buf:        ds.l    1
argv:       ds.l    3
