; DDR3First -- make AllocMem prefer the DDR3 fast RAM board
;
; The DDR3 Zorro III board has its own memory sequencer and does not compete
; with the chipset for the SDRAM, so the CPU runs faster from it (SysInfo:
; 0.83x an A4000/040 with all boards, 0.88x with the DDR3 board alone).
; AllocMem hands out memory from the highest-priority MemHeader first, so
; this raises the DDR3 board's MemHeader above the SDRAM boards' and leaves
; every board configured (RTG needs the Zorro II board).
;
; The board is found through expansion.library by the IDs in
; rtl/minimig/minimig_autoconfig_rom.v: manufacturer $1399, product $11,
; serial 3. (The extra board on 64 MB platforms has the same IDs, serial 4.)
;
; Usage: put "DDR3First" near the top of S:Startup-Sequence, after SetPatch.
; Silent. Return code 0 when done, 5 (WARN) when there is no DDR3 board,
; so the Startup-Sequence carries on either way.
;
; Self-contained: offsets and LVOs are written out, no NDK needed.
; Build: see Makefile.

MANUF           equ     $1399
PROD            equ     $11
SERIAL          equ     3
PRI             equ     10              ; above expansion's fast RAM (0), chip is -10

; exec.library
_LVOForbid      equ     -132
_LVOPermit      equ     -138
_LVORemove      equ     -252
_LVOEnqueue     equ     -270
_LVOCloseLibrary equ    -414
_LVOOpenLibrary equ     -552
eb_MemList      equ     322             ; ExecBase->MemList (struct List)
; expansion.library
_LVOFindConfigDev equ   -72
cd_SerialNumber equ     22              ; cd_Rom (16) + er_SerialNumber (6)
cd_BoardAddr    equ     32
cd_BoardSize    equ     36
; struct MemHeader
ln_Pri          equ     9
mh_Lower        equ     20

RETURN_OK       equ     0
RETURN_WARN     equ     5

        section code,code

start:
        movem.l d2-d7/a2-a6,-(sp)
        moveq   #RETURN_WARN,d6         ; result until the board is moved
        move.l  4.w,a6
        lea     expname(pc),a1
        moveq   #33,d0                  ; FindConfigDev: V33
        jsr     _LVOOpenLibrary(a6)
        tst.l   d0
        beq.b   .exit
        move.l  d0,a5                   ; ExpansionBase

        ; find the DDR3 board: walk every $1399/$11 board, match the serial
        sub.l   a4,a4                   ; board base, 0 = not found
        suba.l  a0,a0                   ; start of the board list
.find:
        move.l  a5,a6
        move.l  #MANUF,d0
        moveq   #PROD,d1
        jsr     _LVOFindConfigDev(a6)
        tst.l   d0
        beq.b   .found_all
        move.l  d0,a0                   ; continue from this one if no match
        cmp.l   #SERIAL,cd_SerialNumber(a0)
        bne.b   .find
        move.l  cd_BoardAddr(a0),a4
        move.l  cd_BoardSize(a0),d7
.found_all:
        move.l  a5,a1
        move.l  4.w,a6
        jsr     _LVOCloseLibrary(a6)
        move.l  a4,d0
        beq.b   .exit                   ; no DDR3 board

        ; the MemHeader whose memory lies on the board: re-enqueue it
        move.l  a4,d5
        add.l   d7,d5                   ; board end (exclusive)
        jsr     _LVOForbid(a6)
        lea     eb_MemList(a6),a2
        move.l  (a2),a3                 ; lh_Head
.walk:
        tst.l   (a3)                    ; ln_Succ = 0: the list's tail node
        beq.b   .done
        move.l  mh_Lower(a3),d0
        cmp.l   a4,d0
        blo.b   .next
        cmp.l   d5,d0
        bhs.b   .next
        move.l  a3,a1
        jsr     _LVORemove(a6)
        move.b  #PRI,ln_Pri(a3)
        move.l  a2,a0
        move.l  a3,a1
        jsr     _LVOEnqueue(a6)         ; sorted by priority
        moveq   #RETURN_OK,d6
        bra.b   .done
.next:
        move.l  (a3),a3
        bra.b   .walk
.done:
        jsr     _LVOPermit(a6)
.exit:
        move.l  d6,d0
        movem.l (sp)+,d2-d7/a2-a6
        rts

expname:
        dc.b    "expansion.library",0
        even
