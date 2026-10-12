# Chip RAM and cache-inhibited stores through the store buffer -- results

2026-10-11.  Why: demos written for A1200/A4000 accelerators (The Cure: beam-locked loop, ~5,200-7,000 CPU chip
accesses per frame, mostly stores) stutter with Turbo chip off.  With the MMU on (MMULib) every chip RAM store was
synchronous: the core waited out the whole chipset cycle.  A 68040 puts the write in its write buffer and goes on.

## 1. The old "posting into the SDRAM corrupts" finding

### What was tried (2026-09-29/30, findings/storebuf/results.md)

| image | core | stage 4 window (physical) | board |
|---|---|---|---|
| stage_cu6 | a47b11f | chip RAM, Zorro II, Z3 board 0 (`[31:27]` = $40-$47), Z3 board 1 (`[31:28]`) | Workbench 80000004, damaged icons, bad disk blocks; the same with slow-SD firmware (possibly an already damaged HDF, firmware load unconfirmed) |
| stage_cu7 | cu6, SB_MMU = 0 | -- | clean, xSysInfo 0.88 |
| stage_cu8 | 3f8f3cd | `[31:28]` = 4 only ("DDR3 only") | clean, 1.01 |
| stage_cu9 | 385cc8e (+ copyback S0-S1b, cache-internal) | Zorro II, Z3 board 0, Z3 board 1 | clean, 1.01 |

The conclusion drawn was "chip RAM is what corrupts", and chip RAM stayed out of the window since.

### Why that conclusion does not hold

Stage 4 posts a store only if the MMU's verdict (`m_postok`, ap040_mmu.v) and the window both say yes.  The verdict
in all four images was

    postok_now = c_write && !c_lock && (ttr_hit ? (!ttr_w && !ttr_cm[1]) : (tc_e && atc_hit && !h_cm[1]))

i.e. **cacheable pages only** (CM = 00/01).  On the board the MMU is MMULib's.  Paul's MuScan output (2026-09-30):

| range | MMULib cache mode |
|---|---|
| $00000000-$005FEFFF (chip RAM and the start of Zorro II) | CacheInhibit (CM = 10) |
| $00600000-$009FFFFF (rest of Zorro II) | CacheInhibit Imprecise NonSerial (CM = 11) |
| $40000000-$41FFFFFF (both Zorro III boards) | WriteThrough |

and no transparent-translation range over them (mmu.library keeps such a range as MAPP_TRANSLATED and "disables
unuseful TTx settings itself", mmu.doc).  So every store to chip RAM and to the Zorro II board had
`h_cm[1] = 1` and `m_postok = 0` in every image: the window's chip RAM and Zorro II terms never saw a postable
store.  cu6's window and cu8's differ only in those terms (cu8's `[31:28] = 4` covers both Zorro III boards, a
superset of cu6's board 0 term), and so do cu6's and cu9's.  **cu6, cu8 and cu9 posted exactly the same stores**:
the Zorro III write-through pages.  cu6 could not have posted into chip RAM; the bisect never split anything about
posting.  The simulation side shows the same thing: t_sbchip_pipe at POST_CI = 0 (the old verdict) posts 0 of 64
stores to a CM = 10 and to a CM = 11 page.

Chip RAM posting itself was never absent from the board either.  With translation off -- the boot until MMULib
takes over, and anything started without MMULib -- the stage 1 window has included chip RAM since the store buffer
went in (`stw_ram`, core 07515b4, in every image since; the data cache posts write-through chip stores as well,
POST_STORES).  No corruption was ever tied to that.

So the cu6 corruption was not caused by what was posted.  Two images built from the same logic differed on the
board; that is a build-dependent (placement/routing) effect outside what timing analysis and the simulations check.
Two such effects are visible in the reports and fit "disk data corrupted, icons and loaded code damaged, 80000004"
better than the CPU does:

- **The SPI slave crossings.**  Every HDF sector reaches the Amiga through minimig's SPI slaves
  (rtl/minimig/paula_floppy.v -- the IDE/HDD data path -- and userio_osd_spi.v), whose registers are clocked by
  cfide's `sck`.  sd_card.xdc puts that clock in an asynchronous group with clk_114/dll_28, so those crossings are
  never timed, and the CDC report of every image (cu4, cu6-cu9) lists 213 sck -> dll_28 endpoints, 41 unsafe and
  101 unknown.  paula_floppy.v's transmit path even says "FIXME - crossing clock domains here with no protection".
  How those paths are placed changes with every build.  cu3 (MISPLIT, no stage 4) failed with the same symptoms
  (FAT partition missing, HDF damaged).
- The XC7 = 1 image (2026-10-09) stops at boot with #80000004/#80000005 while every simulation passes -- the third
  image with this signature and no logic explanation.

Neither is proven; a bench cannot reproduce a placement effect.  What is proven is that cu6 did not post into chip
RAM.  **There is no logic fix to make, and no failing test exists for it**: the posting logic of cu6 was the
posting logic of cu8/cu9.

## 2. M68040UM on cache-inhibited writes

- 4.3.2: "If the CM field indicates serialized, then the sequence of read and write accesses to the page is
  guaranteed to match the sequence of the instruction order.  Without serialization, the IU pipeline allows read
  accesses to occur before completion of a write-back for a previous instruction."
- 7.7 (Bus Synchronization): "a memory write access potentially delayed for many clocks while allowing read accesses
  generated by later instructions to complete ... A given sequence of read accesses or write accesses is completed in
  order, and reordering only occurs with writes relative to reads."  And: "When the data memory unit detects an
  attempt to read an operand from a page designated as serialized noncachable, it allows all pending write accesses
  to complete before beginning the external read access.  **The definition of a page as noncachable versus
  serialized noncachable only affects read accesses.**"  "The NOP instruction forces instruction and bus
  synchronization because it freezes instruction execution until all pending bus cycles have completed."
- MMULib's MuFastChip guide (Thomas Richter): it sets chip memory to "IMPRECISE NONSERIALIZED" because
  "NONSERIALIZED ... allows the 68040 to re-order reads and writes ... and can be tolerated by chip memory writes to
  optimize the access speed".

So a write to a CM = 11 page **and** to a CM = 10 page may wait in the write buffer; serialization only makes later
reads wait for it.  This core is stricter than the 68040 for every page: any read that is not a data-cache hit
(and a cache-inhibited read never is) waits until the store buffer is empty, so even a CM = 11 read never overtakes a
pending write.

## 3. What was built

Core branch `post-chip` (lib/AP68040-pipelined), superproject branch combo.

| switch | values | what |
|---|---|---|
| `AP040_POST_CHIP` (TG68K `ap040_post_chip`, build `POST_CHIP`) | 0 / 1 | with translation on, chip RAM ($000000-$1FFFFF physical) joins the stage 4 window (`mem_postok`) |
| `AP040_POST_CI` (TG68K `ap040_post_ci`, build `POST_CI`) | 0 / 1 / 2 | the MMU's verdict (`m_postok`, `cm_post()`) also accepts CM = 11 pages (1) and CM = 10 pages (2) |

Both default 0 in RTL, TG68K.vhd, the tops and build_ap040.tcl; both need STORE_BUF = 1 and SB_MMU = 1 (the board's).
Plain RTL (a parameter and a function), nothing vendor-specific.  With both 0 the core is the old one (the
switch-off suites and the ci0 runs below are clock-identical to before).  The Cure under MMULib needs
`POST_CHIP=1 POST_CI=1` (its DTT0 = $0000C060 is CM = 11 over $00xxxxxx); MuFastChip makes all chip RAM CM = 11
for every program; `POST_CI=2` would post into MMULib's default (CM = 10) chip mapping too.

### The ordering rules, as implemented

Nothing about ordering is new: the post-chip switches only widen which stores take the existing stage 4 path
(findings/storebuf).  For a posted chip store:

- **program order**: the store buffer is a FIFO (4 entries); a synchronous store goes only when it is empty
  (go_sync requires `sb_cnt == 0`); the bus order checker (tb_sb_check.v) compares program and bus byte streams in
  every bus/compat leg.
- **custom registers, CIAs, all I/O**: never in a window (TTR or page CM does not matter), so stores there are
  synchronous and wait for the posted ones; every read that leaves the data cache (all I/O and every
  cache-inhibited read) waits for the FIFO to empty (`go_rd`, `sb_cnt == 0`).  A write to BLTSIZE/COPJMP/DMACON
  therefore reaches the chipset after every earlier chip store.  t_sbchip_pipe case 4 checks this directly: a
  "kick" register write snapshots memory at a posted store's address the moment the bus completes it.
- **a later read of the same address**: a cache-inhibited read waits for the FIFO (above); a cacheable read that
  the data read path could answer checks the FIFO for an overlap (stage 2) or forwards from it (FWD).
- **NOP**: waits until the FIFO is empty and no write is on the port (`sync_busy`); a cache-inhibited write is
  synchronous below the core, so that is "all pending bus cycles have completed" (nop_sync.s, bus legs).
- **exceptions, interrupts, RTE, MOVEC, CINV/CPUSH, PFLUSH, STOP, RESET**: start only once the FIFO is empty
  (`older_busy` includes `sb_busy`; sb_serialize.s).  A MOVEC to TC/URP/SRP/a TTR and PFLUSH empty the postable-page
  table and advance its epoch, so a page made write-protected faults precisely (t_sbchip_pipe case 8).
- **bus error**: chip RAM never raises one (the SoC has no bus error; the only one is the core's 75 ms watchdog).
  A posted store that does fault halts the core visibly (st_fatal, as since stage 1).
- **DMA timing**: unchanged by construction -- the wrapper (TG68K.vhd) and minimig are untouched; each posted
  store is still one chipset cycle, launched by S_state on an ena7WRreg into a slot the bridge grants.  Posting only
  makes the next request arrive sooner (sim/chip32 below).

## 4. Tests

All on core `post-chip` 60db52e / superproject combo (this commit).  The board-switch suites ran on the final RTL; the posting runs of the fuzz and the SoC bench on the same RTL.  RED = before the change (or with the
behaviour taken out), GREEN = after.

### Core (lib/AP68040-pipelined/tb, iverilog)

| what | result |
|---|---|
| t_sbchip_pipe, board switches, `PIPE_POST_CI_REG=1` on a core without POST_CI (the bench claims level 1) | **RED**: fail code 1 (the CM = 11 page's stores were not posted), all three wait profiles |
| t_sbchip_pipe, board switches + POST_CHIP=1, POST_CI = 0 / 1 / 2 | **GREEN**: 12296 / 11788 / 11280 clocks (phase 0); 0 store-order errors (tb_sb_check, 4644 bytes) |
| sb_mutants.sh, post-chip section | 4/4 caught: MOVEC DTTx not emptying the page table (107), CM = 10 posted at level 1 (102), a cache-inhibited read past the FIFO (store-order checker), CM ignored at level 0 (101) |
| full suite, default switches (the committed tree) | ALL TESTS PASSED, 344 |
| full suite, board switches (STORE_BUF FWD RAS PRECISE SB_MMU COPYBACK LDX BTFN DFP_MIS WALLOC) | ALL TESTS PASSED, 347 |
| full suite, board switches + POST_CHIP=1 POST_CI=2 | ALL TESTS PASSED, 347 |
| fuzz.sh `GEN_CI=1`, board switches + POST_CHIP=1 POST_CI=2 vs the reference | seeds 1-60: 60/60 clean (no dump differences, no order errors) |
| fuzz.sh `GEN_CI=1 GEN_IRQ=1` (random level-2 interrupts), same builds | seeds 1001-1040: 40/40 clean |

The compat bench is flat (cache_allow_all), so POST_CHIP's window term is exercised only by the SoC bench below.

### sim/chip32 (real bridge, gary, bank mapper, SRAM bridge, sdram_ctrl, SDRAM model; S_state transcription)

Posting changes only how soon the CPU's next chip request comes (`+lat`): a posted store is issued one clock after
the previous one is acknowledged.  Legs at lat 12 (the bench's default) and lat 0:

| leg | T8 stream | T9 CPU accesses | T9 DMA trace | T10 P2C | steal / b2b |
|---|---|---|---|---|---|
| Standard, lat 12 | 3.00 CCK per access at lat 12/24, 2.00 at 0/6 | 435 | reference (1264 DMA slots) | 480 reads, 0 wrong | 0 / 0 |
| Fast, lat 12 | 2.00 at every lat | 610 | identical | 321, 0 wrong | 0 / 0 |
| Standard, lat 0 | (same T8) | **610** | **identical** | 480, 0 wrong | 0 / 0 |
| Fast, lat 0 | (same T8) | 610 | **identical** | 321, 0 wrong | 0 / 0 |

The DMA slot schedule is bit-identical whatever the CPU does, and a CPU that re-requests at once gets the authentic
AGA rate (2 CCK per access) even in Standard mode: 435 -> 610 accesses in T9.

### sim/ddr3_cpu (real AP68040 + TG68K.vhd + sdram_ctrl + DDR3; its chipset bus always acks, no CCK, no DMA)

`findings/postchip/postchip_ddr3.asm` through run_ddr3_prog.sh: code on the DDR3 board, DTT0 = $0000C060 (chip RAM
CM = 11), DTT1 write-through over $4xxxxxxx, ITT0 cacheable, translation on (TC.E = 1, as MMULib leaves it), 128
iterations per phase, every 4th result read back (CI reads).  Board switches throughout.  ns per iteration:

| loop | Standard, POST off | Standard, POST_CHIP=1 POST_CI=1 | Standard, TC off (stage 1, today) | Fast, POST off | Fast, POST on |
|---|---:|---:|---:|---:|---:|
| `move.l d0,(a0)+` burst | 863 | **720** | 717 | 578 | **433** |
| + 4 ALU | 863 | **722** | 722 | 720 | **439** |
| + 8 ALU | 1008 | **729** | 729 | 865 | **447** |
| + 16 ALU | 1295 | **736** | 737 | 1013 | **563** |
| + 32 ALU | 1727 | **998** | 998 | 1445 | **989** |
| `move.b` + 4 ALU | 870 | **725** | 724 | 725 | **580** |
| load (DDR3) + 3 ALU + `move.l` to chip | 1310 | **1081** | 1083 | 1090 | **809** |

All legs "2 passed, 0 failed" (the program's read-back included).  CHIPBUS cadence: 2091 chipset cycles in every
TC-on leg (posting never adds or drops a chipset cycle); release -> next request 36.6 -> 19.8 clk (Standard), 34.9 ->
21.6 clk (Fast).  Phase 2's perf probe: Standard 4176 -> 3483 clocks, Fast 2800 -> 2096.  With posting on and
translation on the core is exactly as fast as with translation off today (third column).

Turbo chip on (TURBOCHIP=1: chip RAM through sdram_ctrl's CPU port, with the bench's chipset DMA agent writing
chip RAM in SDRAM the whole time), POST off -> on, ns per iteration: burst 293 -> 231, +4 ALU 384 -> 244, +8 494 ->
342, +16 710 -> 552, +32 1142 -> 984, byte 390 -> 232, load + 3 ALU + store 791 -> 552.  Both legs "2 passed, 0
failed", DMA window 1979 / 1648 writes during CPU execution, 0 wrong.

The bench's own legs (`run.sh --ap040 --chipbus`, PIPELINED=1 FREECORE=1, translation off -- ddr3_cpu_test.asm):
the bench defaults (RUNTAG=pc_base) and the board switches + POST_CHIP=1 POST_CI=2 through the new `XDEFS`
(RUNTAG=pc_post) both "2 passed, 0 failed", CHIP32 0 bad, DMA window 1780 / 1530 writes, 0 wrong; phase 1 -> 8
722.5 -> 619.0 us (the switches together, not POST alone: the program runs with translation off).

### sim/sdram_coherency (sdram_ctrl's Turbo chip port; untouched)

`fast sg7 +nobg +rounds=50`: 57 errors, `fast sg7 +rounds=50`: 5 errors -- the reference counts (the two known
Turbo chip defects, unsnooped line buffer and late posted writes, unchanged).

## 5. What it buys

Per chip RAM store, posting removes the wait for the chipset cycle whenever the CPU has other work: the stall
becomes max(compute, chip cycle) instead of compute + chip cycle, and a pure burst still gains because the next
store is issued at once (2 CCK cadence).  Measured above, without display DMA:

| per store | Standard | Fast |
|---|---:|---:|
| pure burst | -143 ns (-17 %) | -145 ns (-25 %) |
| load + 3 ALU + store (The Cure's screen loop shape) | -229 ns (-17 %) | -281 ns (-26 %) |
| 8 ALU between stores | -279 ns (-28 %) | -418 ns (-48 %) |
| 16 ALU between stores | -559 ns (-43 %) | -450 ns (-44 %) |
| byte store + 4 ALU (audio buffer) | -145 ns (-17 %) | -145 ns (-20 %) |

The Cure per frame (17.3 ms budget; ~4,000 longword screen stores, 1,184 audio byte stores, overlay RMWs):

- screen loop as "load + 3 ALU + store": 4,000 x 229-281 ns = 0.9-1.1 ms, audio 1,184 x 145 ns = 0.17 ms:
  **about 1.1-1.3 ms per frame**, 6-8 % of the frame;
- with 8-16 instructions of work per store: 4,000 x 0.28-0.56 us = 1.1-2.2 ms, **up to ~2.4 ms per frame**;
- the ceiling is the chip store time itself (the 4.7-9 ms measured): with display DMA taking slots, each chip cycle
  waits longer and more of it can hide behind computation.
- Read-modify-writes to chip RAM (`or.b d0,(a0)`) gain little: the read is cache-inhibited and waits for the FIFO.
  So does a fast-RAM load that misses the data cache behind posted stores (a 68040 would let it overtake; this
  core does not -- the "load + 3 ALU" row shows it).

## 6. Board test (POST_CHIP=1 POST_CI=1 for the first image; POST_CI=2 is a second step)

1. I/O first, on a fresh copy of the spare HDF: SD FAT partition, programs from the HDF, file copies, icons.
   (Nothing posts into chip RAM there unless something maps it CM = 11 or translation is off: MMULib's default is
   CM = 10.  To exercise it system-wide, run MuFastChip -- that is the real test of chip posting under the OS.)
2. ChipCoh, then the demos that stuttered with Turbo chip off (The Cure with the curemeter copies; scroll-text
   flicker demos), Standard and Fast chip slots, and Turbo chip on (posting must not change it).
3. SerRx at 57600 (serial is I/O: synchronous, ordered behind posted stores).
4. xSysInfo: Dhrystone should not move (it does not store to chip RAM); the chip RAM write rate with POST on.
5. With MuFastChip on: Workbench, disk copies, window dragging (blitter + CPU chip writes).
6. If anything corrupts: rebuild with POST_CI=0 (POST_CHIP=1 alone changes nothing under MMULib) to split the
   verdict from the window, and compare with the same build's TC-off behaviour (no MMULib), which has posted chip
   stores since stage 1.

Risks: the 4-entry postable-page table is shared with the fast RAM pages; a loop storing to five or more pages in
rotation (screen + audio + variables) takes a synchronous store per page change (correct, slower).  A data TTR hit
could post without the table -- not built.  Timing: two extra terms in an existing compare (the window) and in the
MMU's latched verdict; no new paths into the core.
