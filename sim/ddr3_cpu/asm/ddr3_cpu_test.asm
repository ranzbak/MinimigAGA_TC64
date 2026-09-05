;-----------------------------------------------------------------------------
; ddr3_cpu_test.asm -- 68k program for sim/ddr3_cpu.
;
; Runs on the real TG68KdotC kernel inside the real rtl/soc/TG68K.vhd wrapper.
; Program, vectors and stack live in the bench's behavioural chip RAM (the
; wrapper's SDRAM-side port); everything it exercises at $40000000 is the real
; ddr3_fastram + ddr3_top + Micron DDR3 model chain.
;
; It writes a status word to a mailbox the bench polls:
;
;   $1000  status : 0 = still running, 1 = PASS, >1 = failure code
;   $1004  address of the first mismatch
;   $1008  expected value
;   $100C  value actually read
;   $1010  phase marker (1..6), so a timeout still says how far it got
;
; Failure codes
;   2  pattern read-back, byte load
;   3  pattern read-back, word load
;   4  pattern read-back, longword load
;   5  misaligned / line-straddling longword read-back
;   6  MemHeader field read-back (not mh_Free)
;   7  MemHeader mh_Free read-back
;   8  counter loop, previous location read back wrong
;   9  counter loop, just-written location read back wrong
;  99  unexpected 68k exception (bus/address error, privilege violation, ...)
;
; Build with asm/build_68k_test.sh (vasmm68k_mot, -m68020 -Fbin).
;
; PATBYTES is the size of the byte/word/long pattern region.  1024 bytes = 64
; cache lines is the default because the whole chain is simulated at gate-ish
; level (Micron model + xc7 PHY ISERDES/OSERDES): every DDR3 write is a real
; 100 MHz round trip, so a 64 kB region would cost roughly an hour of wall
; clock per run.  Raise it here (multiple of 16) if you want more.
;-----------------------------------------------------------------------------

DDRBASE   equ $40000000        ; Zorro-III board 1, on the DDR3 island

PATOFF    equ $00000000        ; byte/word/long pattern region
MISOFF    equ $00001000        ; misaligned / line-straddling longwords
CNTOFF    equ $00002000        ; running-counter loop

; Region sizes.  Overridable from the command line (vasm -DPATBYTES=...) so a
; small, fast debug run needs no edit; run.sh passes the same numbers to the
; bench with +PATBYTES=... etc.
          ifnd      PATBYTES
PATBYTES  equ 1024
          endif
          ifnd      MISLINES
MISLINES  equ 16
          endif
          ifnd      CNTN
CNTN      equ 64
          endif

MBOX      equ $00001000        ; bench-observed mailbox, in the bench chip RAM
STACKTOP  equ $00007000

VBASE     equ $C0DE0000        ; pattern seed: every longword in the region is
                               ; VBASE + (its index), so the value identifies
                               ; the address it belongs to
MBASE     equ $BEEF0000
CBASE     equ $5EED0000

; exec MemHeader, written at the base of the board exactly as exec does
MH_TYPE   equ 10               ; NT_MEMORY
MH_NAME   equ $40000100
MH_ATTR   equ $0005            ; MEMF_PUBLIC|MEMF_FAST
MH_FIRST  equ $40000020
MH_LOWER  equ $40000000
MH_UPPER  equ $41000000
MH_FREE   equ $00FFFFE0

;-----------------------------------------------------------------------------
          org       $0
;-----------------------------------------------------------------------------
          dc.l      STACKTOP             ; vector 0: initial SSP
          dc.l      START                ; vector 1: initial PC
          rept      254
          dc.l      EXCEPT               ; everything else is a bug
          endr

;-----------------------------------------------------------------------------
START:
;-----------------------------------------------------------------------------
          move.l    #3,d0
          movec     d0,cacr              ; enable both caches, as the OS does
          moveq     #0,d0
          move.l    d0,MBOX
          move.l    d0,MBOX+4
          move.l    d0,MBOX+8
          move.l    d0,MBOX+12
          move.l    d0,MBOX+16

;-----------------------------------------------------------------------------
; Phase 1 -- write the pattern with byte, word and longword stores.
;
; Per 16-byte cache line, using four consecutive pattern longwords V0..V3:
;   offset  0.. 3   four byte stores      (V0, big-endian)
;   offset  4.. 7   two  word stores      (V1)
;   offset  8..11   one  longword store   (V2)
;   offset 12..15   one  longword store   (V3)
;-----------------------------------------------------------------------------
          moveq     #1,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE+PATOFF,a0
          move.l    #VBASE,d0
          move.w    #(PATBYTES/16)-1,d6
wr_line:
          move.l    d0,d1
          rol.l     #8,d1
          move.b    d1,(a0)+
          rol.l     #8,d1
          move.b    d1,(a0)+
          rol.l     #8,d1
          move.b    d1,(a0)+
          rol.l     #8,d1
          move.b    d1,(a0)+
          addq.l    #1,d0

          move.l    d0,d1
          swap      d1
          move.w    d1,(a0)+
          move.w    d0,(a0)+
          addq.l    #1,d0

          move.l    d0,(a0)+
          addq.l    #1,d0
          move.l    d0,(a0)+
          addq.l    #1,d0
          dbra      d6,wr_line

;-----------------------------------------------------------------------------
; Phase 2 -- read it back with byte, word and longword loads.
;
; cpu_cache_new has no write allocate and tags are not updated on writes, so
; every one of these loads is a real DDR3 line fill, not a cache hit.
;-----------------------------------------------------------------------------
          moveq     #2,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE+PATOFF,a0
          move.l    #VBASE,d0
          move.w    #(PATBYTES/16)-1,d6
rd_line:
          move.l    d0,d1
          moveq     #3,d5
rd_byte:
          rol.l     #8,d1
          move.l    a0,d2
          moveq     #0,d3
          move.b    (a0)+,d3
          moveq     #0,d4
          move.b    d1,d4
          cmp.l     d4,d3
          bne       f_byte
          dbra      d5,rd_byte
          addq.l    #1,d0

          move.l    d0,d1
          swap      d1
          move.l    a0,d2
          moveq     #0,d3
          move.w    (a0)+,d3
          moveq     #0,d4
          move.w    d1,d4
          cmp.l     d4,d3
          bne       f_word
          move.l    a0,d2
          moveq     #0,d3
          move.w    (a0)+,d3
          moveq     #0,d4
          move.w    d0,d4
          cmp.l     d4,d3
          bne       f_word
          addq.l    #1,d0

          move.l    a0,d2
          move.l    (a0)+,d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_long
          addq.l    #1,d0
          move.l    a0,d2
          move.l    (a0)+,d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_long
          addq.l    #1,d0
          dbra      d6,rd_line

;-----------------------------------------------------------------------------
; Phase 3 -- longwords that are NOT longword aligned.
;
; Offsets 2, 6, 10 and 14 in each 16-byte line are all 2 mod 4; the one at 14
; also straddles into the next cache line, which is the case ddr3_fastram's
; longword_en explicitly excludes from its single-request path (it has to
; become two accesses).
;-----------------------------------------------------------------------------
          moveq     #3,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE+MISOFF,a0
          move.l    #MBASE,d0
          move.w    #MISLINES-1,d6
mw_line:
          move.l    d0,2(a0)
          addq.l    #1,d0
          move.l    d0,6(a0)
          addq.l    #1,d0
          move.l    d0,10(a0)
          addq.l    #1,d0
          move.l    d0,14(a0)
          addq.l    #1,d0
          lea       16(a0),a0
          dbra      d6,mw_line

          movea.l   #DDRBASE+MISOFF,a0
          move.l    #MBASE,d0
          move.w    #MISLINES-1,d6
mr_line:
          move.l    a0,d2
          addq.l    #2,d2
          move.l    2(a0),d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_mis
          addq.l    #1,d0

          move.l    a0,d2
          addq.l    #6,d2
          move.l    6(a0),d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_mis
          addq.l    #1,d0

          move.l    a0,d2
          add.l     #10,d2
          move.l    10(a0),d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_mis
          addq.l    #1,d0

          move.l    a0,d2
          add.l     #14,d2
          move.l    14(a0),d3
          move.l    d0,d4
          cmp.l     d4,d3
          bne       f_mis
          addq.l    #1,d0

          lea       16(a0),a0
          dbra      d6,mr_line

;-----------------------------------------------------------------------------
; Phase 4 -- the exec MemHeader at the base of the board, then read it back.
;
; This is the structure whose contents were garbage on hardware, which is why
; the OS discarded the board and `avail` only ever showed the 2 MB Zorro-II
; one.  ln_Name sits at offset 10, so it is also a misaligned longword store.
;-----------------------------------------------------------------------------
          moveq     #4,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d0
          move.l    d0,(a0)              ; ln_Succ
          move.l    d0,4(a0)             ; ln_Pred
          move.b    #MH_TYPE,8(a0)       ; ln_Type
          move.b    #0,9(a0)             ; ln_Pri
          move.l    #MH_NAME,10(a0)      ; ln_Name
          move.w    #MH_ATTR,14(a0)      ; mh_Attributes
          move.l    #MH_FIRST,16(a0)     ; mh_First
          move.l    #MH_LOWER,20(a0)     ; mh_Lower
          move.l    #MH_UPPER,24(a0)     ; mh_Upper
          move.l    #MH_FREE,28(a0)      ; mh_Free

          move.l    a0,d2
          move.l    (a0),d3              ; ln_Succ
          moveq     #0,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          addq.l    #4,d2
          move.l    4(a0),d3             ; ln_Pred
          moveq     #0,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #8,d2
          moveq     #0,d3
          move.b    8(a0),d3             ; ln_Type
          moveq     #MH_TYPE,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #10,d2
          move.l    10(a0),d3            ; ln_Name
          move.l    #MH_NAME,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #14,d2
          moveq     #0,d3
          move.w    14(a0),d3            ; mh_Attributes
          move.l    #MH_ATTR,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #16,d2
          move.l    16(a0),d3            ; mh_First
          move.l    #MH_FIRST,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #20,d2
          move.l    20(a0),d3            ; mh_Lower
          move.l    #MH_LOWER,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #24,d2
          move.l    24(a0),d3            ; mh_Upper
          move.l    #MH_UPPER,d4
          cmp.l     d4,d3
          bne       f_mh
          move.l    a0,d2
          add.l     #28,d2
          move.l    28(a0),d3            ; mh_Free -- its own failure code
          move.l    #MH_FREE,d4
          cmp.l     d4,d3
          bne       f_free

;-----------------------------------------------------------------------------
; Phase 5 -- running counter at successive addresses, back-to-back write/read.
;
; Each iteration stores the next counter and immediately reads back BOTH the
; previous location and the one just written.  Because writes never allocate
; and always mark the one-line write buffer dirty, both of those reads are
; real DDR3 reads issued right behind the write.
;-----------------------------------------------------------------------------
          moveq     #5,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE+CNTOFF,a0
          move.l    #CBASE+1,d0
          move.l    d0,(a0)
          move.w    #CNTN-2,d6
cn_loop:
          movea.l   a0,a1
          move.l    d0,d5
          lea       4(a0),a0
          addq.l    #1,d0
          move.l    d0,(a0)              ; store the new counter
          move.l    (a1),d3              ; read the PREVIOUS one back
          move.l    d5,d4
          move.l    a1,d2
          cmp.l     d4,d3
          bne       f_cnt
          move.l    (a0),d3              ; read back the one just written
          move.l    d0,d4
          move.l    a0,d2
          cmp.l     d4,d3
          bne       f_cnt2
          dbra      d6,cn_loop

;-----------------------------------------------------------------------------
; Done
;-----------------------------------------------------------------------------
          moveq     #6,d7
          move.l    d7,MBOX+16
          moveq     #0,d2
          moveq     #0,d3
          moveq     #0,d4
          moveq     #1,d7
          move.l    d7,MBOX              ; PASS
done:     bra       done

;-----------------------------------------------------------------------------
f_byte:   moveq     #2,d7
          bra       report
f_word:   moveq     #3,d7
          bra       report
f_long:   moveq     #4,d7
          bra       report
f_mis:    moveq     #5,d7
          bra       report
f_mh:     moveq     #6,d7
          bra       report
f_free:   moveq     #7,d7
          bra       report
f_cnt:    moveq     #8,d7
          bra       report
f_cnt2:   moveq     #9,d7
          bra       report

EXCEPT:   move.l    #$EEEEEEEE,d2
          move.l    d2,d3
          move.l    d2,d4
          moveq     #99,d7
          bra       report

; d2 = address, d4 = expected, d3 = got, d7 = code.  The code goes out LAST so
; the bench never sees a half-written mailbox.
report:   move.l    d2,MBOX+4
          move.l    d4,MBOX+8
          move.l    d3,MBOX+12
          move.l    d7,MBOX
rhalt:    bra       rhalt

          end       START
