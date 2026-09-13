;-----------------------------------------------------------------------------
; ddr3_cpu_test.asm -- 68k program for sim/ddr3_cpu.
;
; Runs on the real TG68KdotC kernel inside the real rtl/soc/TG68K.vhd wrapper.
; Program, vectors and stack live in the bench's behavioural chip RAM (the
; wrapper's SDRAM-side port); everything it exercises at $41000000 is the real
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
;  10  MOVEM.L through displacement addressing, chip RAM
;  11  ADDQ.L #4,(a0) longword read-modify-write, chip RAM
;  12  Exec List relocation left a pointer wrong
;  13  Exec List relocation left the list empty -- the AllocMem symptom
;  14  a cacheable read of an undecoded hole inside the Zorro III window did
;      not read back $FFFFFFFF
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

DDRBASE   equ $41000000        ; Zorro-III board 3, on the DDR3 island.
                               ; Board 1 ($40000000) is SDRAM-backed now; the
                               ; DDR3 is an extra board whose base the OS
                               ; assigns and the hardware latches.  Must match
                               ; z3ram3_base in the bench.

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
; Which CACR the program writes.  The default is the 68020 encoding this
; program has always used -- bit 0 enables the instruction cache -- because
; the TG68KdotC kernel is a 68020 and drives CACR_out straight from it.
;
; The AP68040 is not: ap040_core.v:3352 masks MOVEC to CACR with $80008000,
; so bits 31 (DE) and 15 (IE) are the only ones that mean anything and a
; value of 3 leaves BOTH internal caches OFF.  That is how this bench had
; always run the AP68040 -- with no data or instruction cache, hence no cache
; line fills at all, which the fill counters in ddr3_cpu_tb.sv now report.
; run.sh --ap040 passes -DCACRVAL=$80008003, which turns both on for the 040
; and leaves the TG68K leg bit-identical.
          ifnd      CACRVAL
CACRVAL   equ 3
          endif

; A longword-aligned address inside the AP68040's cacheable Zorro III window
; (cache_z3_base1 = $4, so all of $4xxxxxxx) that NO board in this bench
; decodes: board 3 is 16 MB at $41000000 and boards 1 and 2 are disabled
; (ddr3_cpu_tb.sv, ziiiram_active/ziiiram2_active = 0).  Reads $FFFF a word.
UNDECODED equ $42000000

MBOX      equ $00001000        ; bench-observed mailbox, in the bench chip RAM
STACKTOP  equ $00007000

VBASE     equ $C0DE0000        ; pattern seed: every longword in the region is
                               ; VBASE + (its index), so the value identifies
                               ; the address it belongs to
MBASE     equ $BEEF0000
CBASE     equ $5EED0000

; exec MemHeader, written at the base of the board exactly as exec does
MH_TYPE   equ 10               ; NT_MEMORY
MH_NAME   equ $41000100
MH_ATTR   equ $0005            ; MEMF_PUBLIC|MEMF_FAST
MH_FIRST  equ $41000020
MH_LOWER  equ $41000000
MH_UPPER  equ $42000000
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
          move.l    #CACRVAL,d0
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
; Phase 7 -- the Exec idioms the AP68040 hardware failure implicates.
;
; Kickstart 46.143 relocates SysBase->MemList from the old ExecBase to the new
; one at $F80650-$F8067A, in between the AllocMem that succeeds ($F805E4) and
; the AllocMem that fails forever ($F80690).  AllocMem walks that list with
; "movea.l (a0),a0 / tst.l (a0) / beq fail", so a relocation that leaves the
; list empty makes every later AllocMem return 0 for every size and every
; memory type -- exactly what the board does.
;
; The idiom is longword pointer traffic over a 16-bit bus, which is the one
; thing the AP040 does differently from the TG68K here (longword_pair off, so
; every longword is two separate word cycles):
;
;   * MOVEM.L to and from displacement addressing, as at $F80626/$F8063E
;   * ADDQ.L #4,(a0) -- a longword read-modify-write, two reads, two writes
;   * the six-instruction List relocation itself
;
; This runs in chip RAM, so under --chipbus it goes out over the 7 MHz chipset
; bus -- the path the failing board uses with Turbo off.
;-----------------------------------------------------------------------------
CHIPSCR   equ $00008000        ; scratch in the bench's chip RAM, clear of the
                               ; program (< $800) and the mailbox ($1000)
LOLD      equ CHIPSCR+$40      ; the "old" List header
LNODE     equ CHIPSCR+$80      ; its one node
LNEW      equ CHIPSCR+$C0      ; the "new" List header
P2CPROBE  equ CHIPSCR+$10      ; P7LOOPS pass counter, read back by the chipset
P2CBLK    equ CHIPSCR+$100     ; P2CBLOCK longword block, read back by the chipset

          moveq     #7,d7
          move.l    d7,MBOX+16

; P7LOOPS: repeat the whole of phase 7, for the sim/ddr3_cpu DMA_OVERLAP leg,
; where the chipset writes into the unused slots of these same cache lines.  Once
; through is a few dozen accesses and ~37 us -- far too short a window to catch
; a coherency race.  Every pass re-initialises its own data, so it loops
; cleanly.  d6 is free here: only phases 1-6 use it.  Not defined, nothing is
; assembled and the program is byte-identical to before.
          ifd       P7LOOPS
          move.w    #P7LOOPS-1,d6
p7_top:
          endif

; ---- MOVEM.L store and load, displacement addressing ----------------------
          movea.l   #CHIPSCR,a0
          move.l    #$11111111,d0
          move.l    #$22222222,d1
          move.l    #$33333333,d2
          move.l    #$44444444,d3
          movem.l   d0-d3,$20(a0)
          moveq     #0,d0
          moveq     #0,d1
          moveq     #0,d2
          moveq     #0,d3
          movem.l   $20(a0),d0-d3
          cmpi.l    #$11111111,d0
          bne       f_mvm0
          cmpi.l    #$22222222,d1
          bne       f_mvm1
          cmpi.l    #$33333333,d2
          bne       f_mvm2
          cmpi.l    #$44444444,d3
          bne       f_mvm3

; ---- ADDQ.L #4,(a0): longword read-modify-write ---------------------------
          movea.l   #CHIPSCR,a0
          move.l    #$12345678,(a0)
          addq.l    #4,(a0)
          move.l    (a0),d3
          move.l    #$1234567C,d4
          move.l    a0,d2
          cmp.l     d4,d3
          bne       f_rmw

; ---- the List relocation, instruction for instruction ---------------------
; A one-node Amiga List: lh_Head = node, lh_Tail = 0, lh_TailPred = node;
; node ln_Succ = &lh_Tail, ln_Pred = &lh_Head.
          movea.l   #LOLD,a2
          movea.l   #LNODE,a1
          movea.l   #LNEW,a3
          move.l    a1,(a2)              ; old lh_Head    = node
          clr.l     4(a2)                ; old lh_Tail    = 0
          move.l    a1,8(a2)             ; old lh_TailPred= node
          move.l    #LOLD+4,(a1)         ; node ln_Succ   = &old lh_Tail
          move.l    a2,4(a1)             ; node ln_Pred   = &old lh_Head
          moveq     #0,d0                ; scrub the destination first, so a
          move.l    d0,(a3)              ; relocation that writes nothing at
          move.l    d0,4(a3)             ; all is caught rather than passing
          move.l    d0,8(a3)             ; on whatever was already there

          movea.l   (a2),a0              ; --- $F80666, verbatim
          move.l    a0,(a3)
          move.l    a3,4(a0)
          movea.l   8(a2),a0
          move.l    a0,8(a3)
          move.l    a3,(a0)
          addq.l    #4,(a0)              ; --- $F80678

          move.l    #LNEW,d2             ; new lh_Head must be the node
          move.l    #LNODE,d4
          move.l    LNEW,d3
          cmp.l     d4,d3
          bne       f_list
          move.l    #LNEW+8,d2           ; new lh_TailPred must be the node
          move.l    #LNODE,d4
          move.l    LNEW+8,d3
          cmp.l     d4,d3
          bne       f_list
          move.l    #LNODE+4,d2          ; node ln_Pred must be the new header
          move.l    #LNEW,d4
          move.l    LNODE+4,d3
          cmp.l     d4,d3
          bne       f_list
          move.l    #LNODE,d2            ; node ln_Succ must be new header + 4
          move.l    #LNEW+4,d4
          move.l    LNODE,d3
          cmp.l     d4,d3
          bne       f_list

; ---- and now walk it the way AllocMem does --------------------------------
; movea.l (a0),a0 / tst.l (a0) / beq -> "no memory".  A zero here is the
; hardware symptom exactly.
          movea.l   #LNEW,a0
          movea.l   (a0),a0
          move.l    (a0),d3
          move.l    a0,d2
          move.l    #LNEW+4,d4
          tst.l     d3
          beq       f_walk
          ifd       P7LOOPS
; P2C probe: the pass counter, written into a chip-RAM line nothing else uses.
; The bench's chipset agent reads it back through the real sdram_ctrl and must
; see what the CPU wrote -- the direction of the hardware's uncleared pixels,
; which no DMA agent had checked with the real CPU and controller together.
          move.l    d6,P2CPROBE
; P2CBLOCK: the chunky-to-planar shape -- a whole block of longwords written in
; a tight (an)+ burst every pass, values changing each pass, for the chipset to
; read back.  d5 is free here (only phases 1-6 use it); d0 is reloaded at the
; top of every pass; a4 is used nowhere else in this program.
          ifd       P2CBLOCK
          lea       P2CBLK,a4
          move.w    #P2CBLOCK-1,d5
          move.l    d6,d0
p2cb_top: move.l    d0,(a4)+
          addq.l    #1,d0
          dbra      d5,p2cb_top
          endif
          dbra      d6,p7_top
          endif

;-----------------------------------------------------------------------------
; A CACHEABLE read of a hole inside the Zorro III window.
;
; The AP68040's cacheable Zorro windows are much wider than the boards inside
; them: cache_z3_base0 is addr(31:27), a 128 MB window, and cache_z3_base1 is
; addr(31:28), a 256 MB one (ap040_tg68k_compat.v:397-401).  UNDECODED is
; inside cache_z3_base1's window here -- the DDR3 board's base is $41 and the
; window is all of $4xxxxxxx -- but no board decodes it, so sel_undecoded
; auto-completes it with $FFFF, which is the SoC's stated policy for every
; address that decodes to nothing (TG68K.vhd, "The SoC never raises a bus
; error").  With the caches on it is also a cache MISS in a cacheable window,
; so it is a line fill, and the line-fill router has to answer it the same
; way: a line of all ones, acknowledged, no fault.
;
; No phase marker on purpose, so that the phase numbering the bench and the
; plan's tables use does not shift.  It sits just before the phase-8 marker,
; which is therefore the one timestamp it moves: measured +1.128 us on
; run.sh --ap040 (2026-09-09), phases 1-7 bit-identical.
;-----------------------------------------------------------------------------
          move.l    UNDECODED,d3
          move.l    #$FFFFFFFF,d4
          cmp.l     d4,d3
          bne       f_und

;-----------------------------------------------------------------------------
; Done
;-----------------------------------------------------------------------------
          moveq     #8,d7
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

; Phase 7.  The MOVEM.L handlers move the offending register into d3 last,
; because d3 is itself one of the four being checked.
f_mvm0:   move.l    d0,d3
          move.l    #$11111111,d4
          bra       f_mvm
f_mvm1:   move.l    d1,d3
          move.l    #$22222222,d4
          bra       f_mvm
f_mvm2:   move.l    d2,d3
          move.l    #$33333333,d4
          bra       f_mvm
f_mvm3:   move.l    #$44444444,d4
f_mvm:    move.l    #CHIPSCR+$20,d2
          moveq     #10,d7
          bra       report
f_rmw:    moveq     #11,d7
          bra       report
f_list:   moveq     #12,d7
          bra       report
f_walk:   moveq     #13,d7
          bra       report
f_und:    move.l    #UNDECODED,d2
          moveq     #14,d7
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
