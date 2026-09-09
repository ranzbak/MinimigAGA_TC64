;-----------------------------------------------------------------------------
; mmu_walk_test.asm -- stage B bench program for sim/ddr3_cpu.
;
; Proves OUR walker router, not the MMU: lib/AP68040/tb t_mmu already proves
; the MMU itself against the WinUAE oracle.  What is untested until here is the
; path from ap040_mmu's walker port, through rtl/soc/TG68K.vhd, to the two
; memories -- two 16-bit sub-cycles per descriptor, an idle gap between them,
; a level acknowledge, and a bus error instead of a hang for a descriptor that
; is nowhere.
;
; The table is deliberately spread across both ports:
;
;   root table      chip RAM   $8000   (512-byte aligned, URP/SRP point here)
;   pointer tables  chip RAM   $8200 (chip branch), $8400 (Zorro III branch)
;   page table 0    chip RAM   $8600   identity, LA $00000000-$0003FFFF
;   page table C    DDR3       $41010000   the leaves live on the far port
;
; so every walk reads descriptors from chip RAM AND from the DDR3 board, and
; the Used/Modified write-backs are walker WRITES into the DDR3.
;
; Phases, and the failure code each reports in the mailbox:
;
;   1  warm page ($41000000, U and M already set): translated read and write
;      20 read wrong   21 write/read-back wrong
;   2  cold page ($41001000, U and M clear): the read forces a U write-back and
;      the write forces an M one, both through the walker
;      22 data wrong   23 the descriptor did not come back with U and M set
;   3  invalid page ($41002000, PDT = 00): must take an access fault
;      24 no fault
;   4  a table branch that decodes as nothing ($50000000 -> a pointer table at
;      $70000000): the router must raise walker_berr, so this is a fault and
;      not a hang
;      25 no fault
;   5  translation off again, the data written under translation is still there
;      26 data wrong after disabling the MMU
;   99 an exception at a point where none was expected
;
; A hang instead of a fault shows up as the bench's timeout, and a walk that
; never acknowledges shows up as no phase progress -- both are FAILs there.
;
; Build with asm/build_68k_test.sh --mmu (vasmm68k_mot -m68040 -Fbin).
;-----------------------------------------------------------------------------

DDRBASE   equ $41000000        ; Zorro-III board 3, on the DDR3 island

MBOX      equ $00001000        ; bench-observed mailbox
FLTFLAG   equ $00001020        ; set by the access-fault handler
SAVESP    equ $00001024        ; stack pointer to restore when it fires
RESUME    equ $00001028        ; where to continue after it fires
STACKTOP  equ $00007000

ROOT      equ $00008000        ; 128 longwords, index LA[31:25]
PTRA      equ $00008200        ; 128 longwords, index LA[24:18]  (LA[31:25]=0)
PTRB      equ $00008400        ;                                 (LA[31:25]=32)
PAGE0     equ $00008600        ;  64 longwords, index LA[17:12]  (chip RAM)
PAGEC     equ DDRBASE+$10000   ;  64 longwords, in the DDR3 -- the far leaves
BADPTR    equ $70000000        ; 32-bit space that decodes as nothing

; descriptor bits, 68040 format
UDT_RES   equ $02              ; table descriptor, resident
D_U       equ $08              ; Used
D_M       equ $10              ; Modified
PDT_RES   equ $01              ; page descriptor, resident

WARM      equ PDT_RES|D_U|D_M  ; a page the walker never has to write back to
COLD      equ PDT_RES          ; U and M clear: both write-backs will happen

V_WARM    equ $C0DE0001
V_COLD    equ $C0DE0002
W_WARM    equ $A5A50001
W_COLD    equ $A5A50002

;-----------------------------------------------------------------------------
          org       $0
;-----------------------------------------------------------------------------
          dc.l      STACKTOP             ; vector 0: initial SSP
          dc.l      START                ; vector 1: initial PC
          dc.l      ACCFLT               ; vector 2: access fault -- expected
          dc.l      ACCFLT               ; vector 3: address error
          rept      252
          dc.l      EXCEPT
          endr

;-----------------------------------------------------------------------------
START:
;-----------------------------------------------------------------------------
          moveq     #0,d0
          move.l    d0,MBOX
          move.l    d0,MBOX+4
          move.l    d0,MBOX+8
          move.l    d0,MBOX+12
          move.l    d0,MBOX+16
          move.l    d0,FLTFLAG

          ; Transparent translation off: a TTR hit would answer the access
          ; without a walk and the whole test would pass without proving
          ; anything.
          movec     d0,itt0
          movec     d0,itt1
          movec     d0,dtt0
          movec     d0,dtt1
          movec     d0,tc

          ; Internal caches on, as they are on hardware whenever the MMU is.
          ; The value comes from run.sh (-DCACRVAL); ap040_core.v:3352 masks
          ; MOVEC to CACR with $80008000, so this sets DE and IE and nothing
          ; else.  Without it this program ran with no caches at all and so
          ; never took a cache line fill -- which left the line-fill channel,
          ; and every cached access made through a TRANSLATED address,
          ; completely untested.  A stale descriptor read back from the data
          ; cache after the walker has written U/M is exactly what the compat
          ; top's walker-write snoop exists to prevent, and phases 22-23 are
          ; where it would show.
          ifnd      CACRVAL
CACRVAL   equ 0
          endif
          move.l    #CACRVAL,d1
          movec     d1,cacr

;-----------------------------------------------------------------------------
; Build the tables, with translation still off.
;-----------------------------------------------------------------------------
          moveq     #1,d7
          move.l    d7,MBOX+16

          ; zero the chip-RAM tables ($8000..$86FF)
          movea.l   #ROOT,a0
          move.w    #(PAGE0+256-ROOT)/4-1,d6
zt:       clr.l     (a0)+
          dbra      d6,zt

          ; zero the DDR3 page table
          movea.l   #PAGEC,a0
          moveq     #63,d6
zc:       clr.l     (a0)+
          dbra      d6,zc

          ; root[0]  -> PTRA   (LA $00000000-$01FFFFFF, the chip RAM)
          move.l    #PTRA|D_U|UDT_RES,ROOT
          ; root[32] -> PTRB   (LA $40000000-$41FFFFFF, the Zorro III boards)
          move.l    #PTRB|D_U|UDT_RES,ROOT+32*4
          ; root[40] -> a pointer table in undecoded space (phase 4)
          move.l    #BADPTR|D_U|UDT_RES,ROOT+40*4

          ; PTRA[0]  -> PAGE0  (LA $00000000-$0003FFFF)
          move.l    #PAGE0|D_U|UDT_RES,PTRA
          ; PTRB[64] -> PAGEC  (LA $41000000-$4103FFFF)
          move.l    #PAGEC|D_U|UDT_RES,PTRB+64*4

          ; PAGE0: identity, warm, 64 pages of 4 kB = the whole 256 kB the
          ; bench's chip RAM can answer for.  Code, stack, mailbox and the
          ; tables themselves are all in here.
          movea.l   #PAGE0,a0
          move.l    #WARM,d0
          moveq     #63,d6
p0:       move.l    d0,(a0)+
          add.l     #$1000,d0
          dbra      d6,p0

          ; PAGEC: identity for the DDR3 board, but not uniformly.
          ;   page 0  warm
          ;   page 1  cold  -- U and M clear, so the walker must write it back
          ;   page 2  invalid
          ;   page 3  warm
          ;   page 16 warm  -- the page table itself, so the test can read the
          ;                    descriptors back with translation ON
          move.l    #DDRBASE+$0000|WARM,PAGEC
          move.l    #DDRBASE+$1000|COLD,PAGEC+4
          move.l    #0,PAGEC+8
          move.l    #DDRBASE+$3000|WARM,PAGEC+12
          move.l    #DDRBASE+$10000|WARM,PAGEC+16*4

          ; the data the translated accesses will find
          move.l    #V_WARM,DDRBASE+$0000
          move.l    #V_COLD,DDRBASE+$1000

;-----------------------------------------------------------------------------
; Translation on.
;-----------------------------------------------------------------------------
          moveq     #2,d7
          move.l    d7,MBOX+16

          move.l    #ROOT,d0
          movec     d0,urp
          movec     d0,srp
          pflusha
          move.l    #$8000,d0            ; E = 1, P = 0 (4 kB pages)
          movec     d0,tc
          nop

;-----------------------------------------------------------------------------
; Phase 1 -- a warm page.  One walk, four descriptor reads, no write-back.
;-----------------------------------------------------------------------------
          moveq     #3,d7
          move.l    d7,MBOX+16

          move.l    #DDRBASE,d2
          move.l    #V_WARM,d4
          move.l    DDRBASE,d3
          cmp.l     d4,d3
          bne       f_warm_rd

          move.l    #W_WARM,d4
          move.l    d4,DDRBASE
          move.l    DDRBASE,d3
          cmp.l     d4,d3
          bne       f_warm_wr

;-----------------------------------------------------------------------------
; Phase 2 -- a cold page.  The read walks and writes U back; the write walks
; again (the ATC entry has no M) and writes M back.  Both write-backs are
; walker writes into the DDR3.
;-----------------------------------------------------------------------------
          moveq     #4,d7
          move.l    d7,MBOX+16

          move.l    #DDRBASE+$1000,d2
          move.l    #V_COLD,d4
          move.l    DDRBASE+$1000,d3
          cmp.l     d4,d3
          bne       f_cold

          move.l    #W_COLD,d4
          move.l    d4,DDRBASE+$1000
          move.l    DDRBASE+$1000,d3
          cmp.l     d4,d3
          bne       f_cold

          ; and the descriptor itself must have come back with U and M set --
          ; read through the mapping of the page table's own page, so this is
          ; also a translated access to the DDR3.
          move.l    #PAGEC+4,d2
          move.l    #DDRBASE+$1000|WARM,d4
          move.l    PAGEC+4,d3
          cmp.l     d4,d3
          bne       f_desc

;-----------------------------------------------------------------------------
; Phase 3 -- an invalid page descriptor must fault, not hang.
;-----------------------------------------------------------------------------
          moveq     #5,d7
          move.l    d7,MBOX+16

          move.l    #0,FLTFLAG
          move.l    sp,SAVESP
          move.l    #p3_back,RESUME
          move.l    DDRBASE+$2000,d3     ; PDT = 00
p3_back:
          tst.l     FLTFLAG
          beq       f_noflt_inv

;-----------------------------------------------------------------------------
; Phase 4 -- a table branch that decodes as nothing.  The pointer table lives
; at $70000000, which no memory answers for; the router must turn that into
; walker_berr and the MMU into an access fault.  Before stage B this hung.
;-----------------------------------------------------------------------------
          moveq     #6,d7
          move.l    d7,MBOX+16

          move.l    #0,FLTFLAG
          move.l    sp,SAVESP
          move.l    #p4_back,RESUME
          move.l    $50000000,d3
p4_back:
          tst.l     FLTFLAG
          beq       f_noflt_berr

;-----------------------------------------------------------------------------
; Phase 5 -- translation off, the data is still where it was written.
;-----------------------------------------------------------------------------
          moveq     #7,d7
          move.l    d7,MBOX+16

          moveq     #0,d0
          movec     d0,tc
          nop
          pflusha

          move.l    #DDRBASE+$1000,d2
          move.l    #W_COLD,d4
          move.l    DDRBASE+$1000,d3
          cmp.l     d4,d3
          bne       f_after

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
f_warm_rd: moveq    #20,d7
          bra       report
f_warm_wr: moveq    #21,d7
          bra       report
f_cold:   moveq     #22,d7
          bra       report
f_desc:   moveq     #23,d7
          bra       report
f_noflt_inv:
          move.l    #DDRBASE+$2000,d2
          moveq     #24,d7
          bra       report
f_noflt_berr:
          move.l    #$50000000,d2
          moveq     #25,d7
          bra       report
f_after:  moveq     #26,d7
          bra       report

; The access-fault handler.  A 68040 access-error frame cannot simply be
; RTE'd -- that retries the faulting access, which would fault again -- so the
; handler abandons the frame: it restores the stack pointer the test saved
; before the access and jumps to the label the test nominated.  Everything it
; touches is in identity-mapped chip RAM.
ACCFLT:   move.l    #1,FLTFLAG
          movea.l   SAVESP,sp
          movea.l   RESUME,a0
          jmp       (a0)

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
