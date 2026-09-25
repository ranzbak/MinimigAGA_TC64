# 32-bit CPU chip-RAM cycles (AGA style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An aligned longword CPU access to chip RAM (and a longword read of the Kickstart ROM with Turbo kick off) becomes ONE 7 MHz chipset cycle that moves both words in ONE chip slot, as on the A1200/A4000's 32-bit chip bus. DMA timing, the slot schedule and every other bus stay exactly as they are. The point is that Turbo chip RAM can stay off: it breaks the timing of demo graphics.

**Architecture:** Most of the minimig side is already there. `sdram_ctrl` moves two words in one chip slot: a read returns word A in `chipRD` and word A+2 in `chip48[47:32]`, and a write takes `chipWR2` with `chipU2/chipL2`. The m68k bridge, gary and the SRAM bridge already carry `_uds2/_lds2`, `hwr2/lwr2` and `data_in2/data2` for that. That plumbing served the TG68K's "AGA paired word" trick, which Stage E4a removed from `rtl/soc/TG68K.vhd`. Since then the AP68040 splits every longword in `ap040_bus16_adapter` into two word cycles. This plan adds one route to the wrapper's router, next to the RAM, DDR3 and Akiko routes. The route (`x_c32`) takes the whole aligned longword to the existing chipset state machine as one cycle with all four byte strobes. The data comes back as `r_data & r_data2`, and the completion runs through `x_done` the way Akiko's does. The adapter, the core and every submodule stay untouched.

**Tech Stack:** VHDL (rtl/soc/TG68K.vhd), Verilog (minimig, sdram_ctrl), iverilog/vvp (new sim/chip32 bench), Vivado 2023.2 xsim (sim/ddr3_cpu), vasm (68k test code and an Amiga measuring tool), Vivado 2023.2 build and JTAG.

**Spec:** `findings/ap040-pipelined/SESSION-HANDOVER.md`, Backlog item "Chip RAM: longword per chip slot, so turbo can go (Paul, 2026-09-25)". Paul added a requirement on 2026-09-25 while this plan was being written: "Be careful with the Blitter and the Copper, there might be other chips as well that in the original Amiga still used 16 bit busses". The section "What stays 16-bit" below answers it.

---

## What stays 16-bit (and why)

On a real AGA machine the 32-bit path is **CPU <-> chip RAM** (and CPU <-> ROM on the A1200/A4000). It is **not** a 32-bit chipset. This plan widens only that path.

| Master / target | Width on real AGA | In this plan |
|---|---|---|
| CPU -> chip RAM, aligned longword | 32-bit | **one cycle, both words** (new) |
| CPU -> Kickstart ROM read, aligned longword, Turbo kick off | 32-bit | **one cycle, both words** (new) |
| CPU -> chip RAM, byte / word / misaligned longword | 8/16, split | unchanged (adapter) |
| CPU -> custom registers `$DFF000` (Blitter, Copper, Denise/Lisa, Paula, beam counters) | 16-bit registers, a longword = two word cycles | unchanged: not in the `x_c32` decode |
| CPU -> CIAs `$BFxxxx` | 8-bit, E-clock | unchanged |
| CPU -> Gayle / IDE `$DAxxxx`, RTC `$DCxxxx`, Toccata, autoconfig `$E8xxxx` | 16-bit | unchanged |
| CPU -> Akiko `$B8xxxx` | 16-bit | unchanged (own sequencer) |
| CPU -> slow RAM `$C00000` | 16-bit (A500 trapdoor) | unchanged |
| **Blitter DMA** | 16-bit | **unchanged**. Agnus is not touched, and gary forces `ram_hwr2/lwr2` low whenever `dbr` is high |
| **Copper DMA** | 16-bit | unchanged |
| Disk, audio, refresh DMA | 16-bit | unchanged |
| Bitplane / sprite DMA (FMODE 32/64) | 32/64-bit | unchanged. It uses the same `chip48` register, which is why Task 2 tests a DMA slot right after a CPU slot |

**Checked against the A1200 Rev 2 schematic** (`/home/paul/work/amiga/docs/A1200_R2.pdf`, Commodore 365133 rev A; "sheet" is the schematic's own sheet number, the PDF page is one higher):

- Sheet 3, "Bridge/DRAM": Budgie (U20, 391425) is the only link between the CPU bus `D(31:0)` and the chip-RAM bus `DRD(31:0)`. The DRAM is four 512Kx8 parts (U16-U19) with one CAS per byte lane (`CAS_UU/UM/LM/LL`). Budgie takes `SIZE_1/SIZE_0` and `A(1)/A(0)` from the 68EC020, so a CPU access of any size inside one longword is ONE DRAM cycle on its byte lanes. A longword that crosses a longword boundary is two cycles, because the 020's dynamic bus sizing splits it. That is the `x_c32` rule: aligned longwords wide, misaligned ones split.
- Sheet 2: Alice (U2, 8374) has only `DRD(15:0)` and drives `RGA(8:1)`. Every Alice DMA channel (Blitter, Copper, disk, audio, refresh) is therefore 16-bit.
- Sheet 5: Paula (U3) sits on `DRD(15:0)`, 16-bit.
- Sheet 4: Lisa (U4, 4203) takes all 32 data bits. That is the FMODE bitplane/sprite fetch, the only DMA wider than 16 bits, and the one that shares `chip48` here.
- Sheet 10, "ROM": the 32-bit ROM option is U6A on `D(31:16)` and U6B on `D(15:0)`, with 32-bit termination (`_DSACK_1/_DSACK_0`, XU1 "32-BIT Termination for ROM"). There is also a 16-bit single-ROM option, but the wide ROM read matches the 32-bit fit.

Three things this plan must not break, each with a test:
1. **A CPU longword to a 16-bit chip register (e.g. `move.l d0,$DFF080` COP1LC, `move.l $DFF004,d0` VPOSR+VHPOSR) stays two word cycles.** Tested by the ddr3_cpu monitor (Task 3), which allows a wide cycle only in the chip-RAM and ROM windows. The CHIP32PH program does both accesses on purpose.
2. **A Blitter or disk DMA write never writes the CPU's held second word.** `chipWR2` is wired straight from the wrapper's `data_write2` register and keeps the last CPU longword's low word. Only `chipU2/chipL2` (high during DMA) keep it out of SDRAM. Tested in sim/chip32 T6a.
3. **An AGA bitplane/sprite fetch in the next slot does not corrupt the CPU's second word.** `chip48` is shared, and the bridge must latch word 2 before the next chip slot overwrites it. Tested in sim/chip32 T5b (DMA in every other CCK).

## Global Constraints

- Never `git push`. Never write the SPI flash; JTAG (volatile) loads only, and only when Paul is at the board and says so.
- Never stage the five always-dirty files (`fw/ctrl_832/version.h`, `fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`, `fw/ctrl_boot_832/rom_prologue.vhd`, `sim/hostcpu-i2c-bridge/i2c_bridge_tb_behav.wcfg`, `tools/vivado/ila_fastram_check.py`). Always `git add <explicit paths>`. The two generated 832 firmware files DO go into the bitstream, so build in the main checkout, not in a worktree.
- Only the QMTech target (`fpga/openaars`, `project_1`) is built and must keep working. Other tops may break silently.
- Do not modify: `rtl/minimig/agnus*.v`, `rtl/minimig/denise*.v`, `rtl/sdram/sdram_ctrl.v`, `rtl/sdram/cpu_cache_new.v`, any submodule (`lib/AP68040`, `lib/AP68040-pipelined`, `rtl/tg68k`, `EightThirtyTwo`). DMA and video timing stay untouched.
- sim/ddr3_cpu: legs strictly ONE AT A TIME, ALWAYS with `RUNTAG=<word>` (ten reference logs are tracked). Judge the summary line `DDR3 CPU TB: 2 passed, 0 failed`, never the program's own `PASS`. Never edit `run.sh` while a leg is running. Read `memory/sim-ddr3-cpu-bench-traps.md` first.
- vvp (iverilog) runs are single-core and may run in parallel.
- Vivado: `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal ...`, never `-stack`; use `LC_ALL=C LANG=C` if xsim is running at the same time.
- Board work (video, OSD, disks, demos, power cycling) is Paul's. Before blaming the core for a demo, retry with Turbo chip/kick off. No HDMI right after a JTAG load can just need a board power cycle.
- "Not too many changes at once" (Paul): this plan changes the WIDTH only. The release latency of the chipset state machine is deliberately left alone (see Follow-ups).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Longwords to 16-bit chips**: `move.l` to or from `$DFF000-$DFFFFF` (Blitter/Copper pointers, VPOSR), the IDE data register `$DA2000`, and the CIAs must still be two word cycles. Test: CHIP32PH does `move.l` to `$DFF080` and from `$DFF004`, and the Task 3 monitor fails any wide cycle outside the chip/ROM windows.
2. **DMA write or CPU word write after a CPU longword write**: a stale `chipWR2` must never land in word A+2. Test: sim/chip32 T6a (Blitter-style DMA write) and T6b (CPU word write).
3. **Next-slot DMA overwriting `chip48`**: a CPU wide read directly followed by a DMA slot must still return the right word 2. Test: sim/chip32 T5b.
4. **Action Replay / NMI vector**: a longword read of VBR+$7C must stay narrow, because `cart.v` answers it one word at a time by address bit 1 and `chip48` would supply the second word from chip RAM. Test: CHIP32PH reads `$7C`, and the monitor fails a wide cycle at `NMI_addr`.
5. **Misaligned longwords** (A[1] = 1) must stay on the adapter (a real 020 also splits them) and read correctly. Test: CHIP32PH reads `C32BUF+2`, and the monitor fails any wide cycle with A[1:0] /= 0.

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `findings/chip32/plan.md` | this file | |
| `findings/chip32/results.md` | Create (Task 1) | every measured number, sim and board |
| `findings/chip32/tools/chipbw.s` | Create (Task 1) | Amiga CLI tool: chip/ROM bandwidth in KB/s |
| `sim/chip32/chip32_tb.v`, `sim/chip32/run.sh` | Create (Task 2) | the minimig side: bridge + gary + bank mapper + SRAM bridge + real sdram_ctrl + SDRAM model |
| `rtl/soc/TG68K.vhd` | Modify (Task 3) | `chip32` generic, `x_c32` route, one-cycle longword in the chipset state machine |
| `sim/ddr3_cpu/ddr3_cpu_tb.sv`, `sim/ddr3_cpu/run.sh`, `sim/ddr3_cpu/asm/ddr3_cpu_test.asm` | Modify (Task 3) | CHIP32 monitor, `NOCHIP32`, `--c32mutant`, CHIP32PH program phase |
| `rtl/soc/minimig_virtual_top.v`, `rtl/soc/minimig_openaars_top.v`, `tools/vivado/build_ap040.tcl` | Modify (Task 4) | pass `CHIP32` down; `CHIP32=<0/1>` build switch |
| `findings/ap040-pipelined/SESSION-HANDOVER.md` | Modify (Task 6) | backlog item closed with results |

---

### Task 0: Branch

**Files:** none

- [ ] **Step 1: Create the work branch in the main checkout**

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
git status --short | head -20          # expect only the five dirty files + untracked junk
git switch -c chip32
git log --oneline -1                   # base commit; write it into results.md in Task 1
```

---

### Task 1: Measuring tool and simulation baseline

**Files:**
- Create: `findings/chip32/tools/chipbw.s`
- Create: `findings/chip32/results.md`

**Interfaces:**
- Produces: `chipbw` (Amiga executable) printing one line per test, `<name> <lines> lines <KB/s> KB/s`, used again in Task 5. Baseline sim numbers in `results.md` (program phase timestamps of the two `--chipbus` legs), used by Task 3's identity check.

- [ ] **Step 1: Write the tool**

`findings/chip32/tools/chipbw.s`:

```asm
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
```

- [ ] **Step 2: Assemble it**

Run: `cd findings/chip32/tools && vasmm68k_mot -m68020 -Fhunkexe -nosym -o chipbw chipbw.s && ls -l chipbw && head -c 4 chipbw | xxd`
Expected: no errors; the file starts with `0000 03f3` (HUNK_HEADER).

- [ ] **Step 3: Sim baseline, reference core, chip RAM over the chipset bus**

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/sim/ddr3_cpu
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 RUNTAG=c32base ./run.sh --ap040 --chipbus
```
Expected: last line of output `DDR3 CPU TB: 2 passed, 0 failed`, log `xsim_run_pass_ap040_chipbus_c32base.log`. About 10 minutes.

- [ ] **Step 4: Sim baseline, pipelined core (the shipping one), after Step 3 has finished**

```bash
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 RUNTAG=c32base PIPELINED=1 \
    PIPE_DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/lib/AP68040-pipelined \
    ./run.sh --ap040 --chipbus
```
Expected: `DDR3 CPU TB: 2 passed, 0 failed`, log `xsim_run_pass_ap040_chipbus_pipe_c32base.log`. If either baseline FAILS, stop: the `--chipbus` path is broken before any change. Report it to Paul and do not continue.

- [ ] **Step 5: Write `findings/chip32/results.md`**

```markdown
# 32-bit chip cycles -- results

Plan: findings/chip32/plan.md.  Base commit: <git log --oneline -1 from Task 0>.

## Simulation (sim/ddr3_cpu, --chipbus: chip RAM over the 7 MHz chipset bus)

| leg | CHIP32 | wide / narrow chipset cycles | phase 7 at | phase 8 at | $finish at |
|---|---|---|---|---|---|
| reference core, c32base | (none) | n/a | <from log> | <from log> | <from log> |
| pipelined core, c32base | (none) | n/a | <from log> | <from log> | <from log> |

## Board (chipbw, KB/s; PAL)

| image | Turbo chip | Turbo kick | MMU (68040.library) | chip rd.l | chip wr.l | chip rd.w | chip wr.w | rom rd.l |
|---|---|---|---|---|---|---|---|---|
```

Fill the sim rows from `grep -E "^INFO: program phase|\\\$finish called" xsim_run_pass_ap040_chipbus*_c32base.log`.

- [ ] **Step 6: Commit**

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
git add findings/chip32/plan.md findings/chip32/results.md findings/chip32/tools/chipbw.s findings/chip32/tools/chipbw
git commit -m "findings/chip32: plan, chipbw measuring tool, sim baseline

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: sim/chip32 bench: the minimig side moves both words in one slot

This task changes NO RTL. It proves that the path this plan builds on works as the wrapper will drive it: real bridge, gary, bank mapper, SRAM bridge, real `sdram_ctrl` and the SDRAM model, with DMA around the access. If the pass build fails, stop and debug it (superpowers:systematic-debugging) before Task 3. A defect here would corrupt data on the board.

**Files:**
- Create: `sim/chip32/chip32_tb.v`
- Create: `sim/chip32/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the bus contract Task 3 implements. A wide cycle is `as`/`uds`/`lds`/`uds2`/`lds2` all low with `data_write` = word A and `data_write2` = word A+2, launched on `ena7WRreg`. Its read data is `data_read` (word A) and `data_read2` (word A+2), captured on the `ena7RDreg` of state 11.

- [ ] **Step 1: Write the bench**

`sim/chip32/chip32_tb.v`:

```verilog
// sim/chip32/chip32_tb.v -- a 32-bit CPU access to chip RAM through the real
// minimig bus path: minimig_m68k_bridge, gary, minimig_bankmapper,
// minimig_sram_bridge, and the real sdram_ctrl with the vendor SDRAM model.
//
// The question (findings/chip32/plan.md, Task 2): when the wrapper starts ONE
// chipset cycle with uds/lds/uds2/lds2 all low, does the minimig side move BOTH
// words in ONE chip slot -- word 2 of a read from chip48[47:32], word 2 of a
// write through chipWR2/chipU2/chipL2 -- with DMA taking slots around it, and
// without the held word 2 ever leaking into a DMA write or a CPU word write?
//
// Real: everything between the CPU bus pins and the SDRAM pins, wired as
// minimig.v and minimig_virtual_top.v wire it.  Left out, because none of them
// is in the chip-RAM path: Action Replay, Gayle, the CIAs, the custom registers.
// Modelled: the wrapper's chipset state machine (a transcription of the
// S_state process in rtl/soc/TG68K.vhd), the clock enables (a copy of
// rtl/clock/amiga_clk.v's), and Agnus (dbr/dbwe/address/data only).
//
// Usage: ./run.sh   -- pass build and two mutants, run in parallel
`timescale 1ps / 1ps
`define SOC_SIM

module chip32_tb;

// ---------------------------------------------------------------- clocks
// clk_114 and clk_28 come 4:1 off one MMCM, rising edges together.  Integer
// picoseconds so the two never drift; 8816 ps is the board's 113.4375 MHz.
localparam integer HALF114 = 4408;
reg clk114 = 1'b1;
reg clk28  = 1'b1;
always #(HALF114)   clk114 = ~clk114;
always #(4*HALF114) clk28  = ~clk28;

// SDRAM board delays, FAST corner, as sim/sdram_coherency/sdram_coherency_tb.v
localparam integer DLY_CLK_PIN = 6999;
localparam integer T_CO        = 200;
localparam integer T_IN        = 493;
reg pin_clk = 1'b0;
always @(clk114) pin_clk <= #DLY_CLK_PIN clk114;

// ---------------------------------------------------------------- clock enables
// rtl/clock/amiga_clk.v, "generated clocks", minus the PLL-locked reset.
reg [1:0] clk7_cnt   = 2'b10;
reg       clk7_en_r  = 1'b1;
reg       clk7n_en_r = 1'b1;
always @(posedge clk28) begin
  clk7_cnt   <= clk7_cnt + 2'b01;
  clk7_en_r  <= (clk7_cnt == 2'b00);
  clk7n_en_r <= (clk7_cnt == 2'b10);
end
wire clk7_en  = clk7_en_r;
wire clk7n_en = clk7n_en_r;
reg  c3 = 1'b0;  always @(posedge clk28) c3 <= clk7_cnt[1];
reg  c1 = 1'b0;  always @(posedge clk28) c1 <= ~c3;
reg  [3:0] e_cnt = 4'd0;
always @(posedge clk28)
  if (clk7_cnt == 2'b01) e_cnt <= (e_cnt[3] && e_cnt[0]) ? 4'd0 : e_cnt + 4'd1;
wire cck = ~e_cnt[0];
wire [9:0] eclk;
genvar gi;
generate for (gi = 0; gi < 10; gi = gi + 1) begin : g_eclk
  assign eclk[gi] = (e_cnt == gi);
end endgenerate

// ---------------------------------------------------------------- Agnus stand-in
// agnus.v's DMA engines qualify their requests with hpos[0], which is cck, so
// dbr is only ever high in the cck-high half.  dma_pat says which CCKs Agnus
// takes (bit i = the i-th CCK of a 16-CCK cycle); only the test sequence
// writes it.  DMA reads come from dma_adr; with dma_we set they are writes of
// dma_wd, which is how the Blitter and disk DMA write.
reg  [15:0] dma_pat  = 16'h0000;
reg  [3:0]  dma_i    = 4'd0;
reg         dma_busy = 1'b0;
reg         cck_d    = 1'b0;
reg  [20:1] dma_adr  = 20'h40000;        // $080000, a window nothing else uses
reg         dma_we   = 1'b0;
reg  [15:0] dma_wd   = 16'h0000;
always @(posedge clk28) begin
  cck_d <= cck;
  if (cck_d && !cck) begin               // start of the cck-low half
    dma_busy <= dma_pat[dma_i];
    dma_i    <= dma_i + 4'd1;
  end
end
wire        dbr     = cck & dma_busy;
wire        dbwe    = dbr & dma_we;
wire [15:0] dma_bus = dbr ? dma_wd : 16'h0000;   // gary's custom_data_out

// ---------------------------------------------------------------- the wrapper's chipset machine
// The S_state process of rtl/soc/TG68K.vhd, one request at a time from the
// sequence below: the strobes, address and data launched on ena7WRreg,
// dtack sampled on ena7RDreg in state 10, the data captured on ena7RDreg in
// state 11, and the release one ena7RDreg later (chipset_ready = ena7RDreg
// AND clkena_e).  The CPU's own 2-3 clk release delay is left out: the next
// cycle cannot start before the next ena7WRreg either way.
wire        ena7RD, ena7WR;              // sdram_ctrl's registered enables
wire [15:0] cpu_data, cpu_data2;         // the wrapper's data_read / data_read2
wire        dtack_n;
reg  [1:0]  S        = 2'b00;
reg         clkena_e = 1'b0;
reg         waitm    = 1'b1;
reg         as_n = 1'b1, rw = 1'b1, uds_n = 1'b1, lds_n = 1'b1, uds2_n = 1'b1, lds2_n = 1'b1;
reg  [23:0] adr = 24'd0;
reg  [15:0] dw = 16'd0, dw2 = 16'd0;     // data_write / data_write2 (held, as in the VHDL)
reg  [15:0] r_data = 16'd0, r_data2 = 16'd0;
reg         m_go = 1'b0, m_done = 1'b0, m_we = 1'b0, m_wide = 1'b0;
reg  [23:0] m_adr = 24'd0;
reg  [31:0] m_wd  = 32'd0;
always @(posedge clk114) begin
  if (!m_go) m_done <= 1'b0;
  if (ena7WR) begin
    case (S)
      2'b00: if (m_go && !m_done) begin
               as_n   <= 1'b0;
               rw     <= !m_we;
               uds_n  <= 1'b0;
               lds_n  <= 1'b0;
               uds2_n <= !m_wide;
               lds2_n <= !m_wide;
               dw     <= m_wd[31:16];
               if (m_wide) dw2 <= m_wd[15:0];
               adr    <= m_adr;
               S      <= 2'b01;
             end
      2'b01: begin clkena_e <= 1'b0; S <= 2'b10; end
      2'b10: if (!waitm) S <= 2'b11;
      default: ;
    endcase
  end else if (ena7RD) begin
    case (S)
      2'b10: waitm <= dtack_n;
      2'b11: begin
               as_n <= 1'b1; rw <= 1'b1;
               uds_n <= 1'b1; lds_n <= 1'b1; uds2_n <= 1'b1; lds2_n <= 1'b1;
               if (!clkena_e) begin r_data <= cpu_data; r_data2 <= cpu_data2; end
               clkena_e <= 1'b1;
             end
      default: ;
    endcase
  end
  // chipset_ready, last so it wins over state 11 (as in the VHDL)
  if (ena7RD && clkena_e) begin
    S <= 2'b00; clkena_e <= 1'b0; m_done <= 1'b1;
  end
end

// ---------------------------------------------------------------- DUT wiring
wire [23:1] cpu_address_out;
wire [15:0] cpu_data_out, gary_data_out;
wire        cpu_rd, cpu_hwr, cpu_lwr, cpu_hwr2, cpu_lwr2;
wire        dbs, xbs;
wire [23:1] ram_address_out;
wire [15:0] ram_data_in, ram_data_out;
wire        ram_rd, ram_hwr, ram_lwr, ram_hwr2, ram_lwr2;
wire [3:0]  sel_chip;
wire [2:0]  sel_slow;
wire        sel_kick, sel_kickext, sel_kick1mb, sel_cia;
wire [7:0]  bank;
wire        _ram_bhe, _ram_ble, _ram_bhe2, _ram_ble2, _ram_we, _ram_oe;
wire [22:1] ram_address;
wire [15:0] ram_data;
wire [15:0] chipRD;
wire [47:0] chip48;
reg         reset_in = 1'b0;
wire        reset_out;
reg  [3:0]  memcfg = 4'b0011;            // 2 MB chip, no slow RAM
reg         ovl = 1'b0;
reg         hlt = 1'b0;                  // gary's cpu_hlt: the ROM upload path

minimig_m68k_bridge CPU1 (
  .clk(clk28), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .blk(1'b0), .c1(c1), .c3(c3),
  .eclk(eclk), .vpa(sel_cia), .dbr(dbr), .dbs(dbs), .xbs(xbs), .nrdy(1'b0), .bls(),
  .cck(cck), .cpu_speed(1'b0), .memory_config(memcfg), .turbo(),
  ._as(as_n), ._lds(lds_n), ._uds(uds_n), ._lds2(lds2_n), ._uds2(uds2_n), .r_w(rw),
  ._dtack(dtack_n), .rd(cpu_rd), .hwr(cpu_hwr), .lwr(cpu_lwr), .hwr2(cpu_hwr2), .lwr2(cpu_lwr2),
  .address(adr[23:1]), .address_out(cpu_address_out),
  .data(cpu_data), .data2(cpu_data2), .cpudatain(dw), .data_out(cpu_data_out),
  .data_in(gary_data_out),               // minimig.v ORs in CIA/Gayle/cart/RTC/...: all zero here
`ifdef MUT_WORD2
  .data_in2(chip48[31:16]),              // MUTANT: the word after the right one
`else
  .data_in2(chip48[47:32]),              // minimig.v: cpu_data_in2 = chip48[47:32]
`endif
  ._cpu_reset(1'b1), .cpu_halt(1'b0), .host_cs(1'b0), .host_adr(23'd0), .host_we(1'b0),
  .host_bs(2'b00), .host_wdat(16'd0), .host_rdat(), .host_ack()
);

gary GARY1 (
  .clk(clk28), .cpu_address_in(cpu_address_out), .dma_address_in(dma_adr),
  .ram_address_out(ram_address_out), .cpu_data_out(cpu_data_out), .cpu_data_in(gary_data_out),
  .custom_data_out(dma_bus), .custom_data_in(), .ram_data_out(ram_data_out), .ram_data_in(ram_data_in),
  .a1k(1'b0), .cpu_rd(cpu_rd), .cpu_hwr(cpu_hwr), .cpu_lwr(cpu_lwr), .cpu_hwr2(cpu_hwr2), .cpu_lwr2(cpu_lwr2),
  .cpu_hlt(hlt), .ovl(ovl), .dbr(dbr), .dbwe(dbwe), .dbs(dbs), .xbs(xbs),
  .memory_config(memcfg), .ecs(1'b1), .hdc_ena(2'b00),
  .ram_rd(ram_rd), .ram_hwr(ram_hwr), .ram_lwr(ram_lwr), .ram_hwr2(ram_hwr2), .ram_lwr2(ram_lwr2),
  .sel_reg(), .sel_chip(sel_chip), .sel_slow(sel_slow), .sel_kick(sel_kick), .sel_kickext(sel_kickext),
  .sel_kick1mb(sel_kick1mb), .sel_cia(sel_cia), .sel_cia_a(), .sel_cia_b(), .sel_rtc(), .sel_toccata(),
  .sel_ide(), .sel_gayle(), .sel_autoconfig(),
  .autoconfig_done(1'b1), .autoconfig_shutup(5'd0), .autoconfig_configured(5'd0), .toccata_base_addr(8'd0)
);

minimig_bankmapper BMAP1 (
  .chip0(sel_chip[0]), .chip1(sel_chip[1]), .chip2(sel_chip[2]), .chip3(sel_chip[3]),  // ovr = 0: no cart
  .slow0(sel_slow[0]), .slow1(sel_slow[1]), .slow2(sel_slow[2]),
  .kick(sel_kick), .kickext(sel_kickext), .kick1mb(sel_kick1mb), .cart(1'b0),
  .ecs(1'b1), .memory_config(memcfg), .bank(bank)
);

minimig_sram_bridge RAM1 (
  .clk(clk28), .c1(c1), .c3(c3), .bank(bank), .address_in(ram_address_out),
  .data_in(ram_data_in), .data_out(ram_data_out), .rd(ram_rd), .hwr(ram_hwr), .lwr(ram_lwr),
  .hwr2(ram_hwr2), .lwr2(ram_lwr2), ._bhe(_ram_bhe), ._ble(_ram_ble), ._bhe2(_ram_bhe2), ._ble2(_ram_ble2),
  ._we(_ram_we), ._oe(_ram_oe), .address(ram_address), .data(ram_data), .ramdata_in(chipRD)
);

wire [12:0] sdaddr;
wire [3:0]  sd_cs;
wire [1:0]  ba, dqm;
wire        sd_we, sd_ras, sd_cas;
wire [15:0] sdata_fpga;
sdram_ctrl sdc (
  .sysclk(clk114), .clk7_en(clk7_en), .reset_in(reset_in), .cache_rst(reset_in),
  .cache_inhibit(1'b0), .cacheline_clr(1'b0), .cpu_cache_ctrl(4'b0011), .reset_out(reset_out),
  .snoop_stb_out(), .snoop_addr_out(),
  .sdaddr(sdaddr), .sd_cs(sd_cs), .ba(ba), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
  .dqm(dqm), .sdata(sdata_fpga),
  .hostWR(32'd0), .hostAddr(22'd0), .hostce(1'b0), .hostwe(1'b0), .hostbytesel(4'b0000),
  .hostRD(), .hostena(),
  // exactly minimig_virtual_top.v: chipWR2 is the wrapper's data_write2, direct
  .chipAddr({1'b0, ram_address[22:1]}), .chipL(_ram_ble), .chipU(_ram_bhe),
`ifdef MUT_NOWR2
  .chipL2(1'b1), .chipU2(1'b1),          // MUTANT: word 2 of a write never enabled
`else
  .chipL2(_ram_ble2), .chipU2(_ram_bhe2),
`endif
  .chipRW(_ram_we), .chip_dma(_ram_oe), .chipWR(ram_data), .chipWR2(dw2),
  .chipRD(chipRD), .chip48(chip48),
  .rtgAddr(26'd0), .rtgce(1'b0), .rtgfill(), .rtgRd(),
  .audAddr(23'd0), .audce(1'b0), .audfill(), .audRd(),
  .cpu_req(1'b0), .cpu_we(1'b0), .cpu_ir(1'b0), .cpu_wadr(25'd0), .cpu_bs(4'b0000),
  .cpu_wdat(32'd0), .cpu_rdat(), .enaWRreg(), .ena7RDreg(ena7RD), .ena7WRreg(ena7WR),
  .cpu_ack(), .cpu_hit()
);

// board / IOB delay model, as sim/sdram_coherency
wire [12:0] pin_addr;  assign #T_CO pin_addr = sdaddr;
wire [1:0]  pin_ba;    assign #T_CO pin_ba   = ba;
wire        pin_cs;    assign #T_CO pin_cs   = sd_cs[0];
wire        pin_ras;   assign #T_CO pin_ras  = sd_ras;
wire        pin_cas;   assign #T_CO pin_cas  = sd_cas;
wire        pin_we;    assign #T_CO pin_we   = sd_we;
wire [1:0]  pin_dqm;   assign #T_CO pin_dqm  = dqm;
wire        oe = sdc.sdata_oe;
reg         oe_d = 1'b0;      always @(oe)            oe_d     <= #T_CO oe;
reg  [15:0] dq_out_d;         always @(sdc.sdata_out) dq_out_d <= #T_CO sdc.sdata_out;
wire [15:0] dq_pin = oe_d ? dq_out_d : 16'bz;
reg  [15:0] dq_in_d = 16'bz;  always @(dq_pin)        dq_in_d  <= #T_IN dq_pin;
assign sdata_fpga = oe ? 16'bz : dq_in_d;
sdr16mx16 sdram (
  .Dq(dq_pin), .Addr(pin_addr), .Ba(pin_ba), .Clk(pin_clk), .Cke(1'b1),
  .Cs_n(pin_cs), .Ras_n(pin_ras), .Cas_n(pin_cas), .We_n(pin_we),
  .LDQM(pin_dqm[0]), .UDQM(pin_dqm[1])
);

// ---------------------------------------------------------------- slot counter
// CPU chip slots: sdram_ctrl allocates slot 1 to CHIP at ph1; count those the
// CPU owned (dbr low when the controller sampled the chip port).
integer cpu_slots = 0;
reg     dbr_ph1   = 1'b0;
always @(posedge clk114) begin
  if (sdc.sdram_state == 4'd1) dbr_ph1 <= dbr;
  if (sdc.sdram_state == 4'd2 && sdc.slot1_type == 3'd1 && !dbr_ph1) cpu_slots = cpu_slots + 1;
end

// ---------------------------------------------------------------- scoreboard
integer    errors = 0, checks = 0;
integer    slot_hist [0:3];
integer    seed = 32'h0C32_0001;
reg [15:0] shadow [0:1048575];          // chip RAM, word index = byte address [20:1]

task check16;
  input [8*12:1] what;
  input [23:0]   a;
  input [15:0]   got;
  input [15:0]   want;
  begin
    checks = checks + 1;
    if (got !== want) begin
      errors = errors + 1;
      if (errors <= 30)
        $display("FAIL %0s @%06h got %04h want %04h at %t", what, a, got, want, $time);
    end
  end
endtask

// One CPU access.  wide: a longword, wd = {word A, word A+2}; narrow: word A = wd[31:16].
task cpu_acc;
  input        we;
  input        wide;
  input [23:0] a;
  input [31:0] wd;
  integer      n;
  begin
    @(posedge clk114);
    m_we = we; m_wide = wide; m_adr = a; m_wd = wd;
    cpu_slots = 0;
    m_go = 1'b1;
    wait (m_done === 1'b1);
    n = cpu_slots;
    @(posedge clk114);
    m_go = 1'b0;
    wait (m_done === 1'b0);
    slot_hist[n > 3 ? 3 : n] = slot_hist[n > 3 ? 3 : n] + 1;
    checks = checks + 1;
    if (n != 1) begin
      errors = errors + 1;
      if (errors <= 30)
        $display("FAIL slots @%06h %0s %0s: %0d CPU chip slots, want 1 at %t",
                 a, wide ? "wide" : "narrow", we ? "write" : "read", n, $time);
    end
    if (we && a[23:21] == 3'b000) begin
      shadow[a[20:1]] = wd[31:16];
      if (wide) shadow[a[20:1] + 20'd1] = wd[15:0];
    end
  end
endtask

task run_random;
  input [8*12:1] tag;
  input integer  n;
  integer        j;
  reg [23:0]     ra;
  reg [31:0]     rv;
  begin
    for (j = 0; j < n; j = j + 1) begin
      // banks 0 and 2-3; $080000-$0FFFFF is the DMA and T6 area
      ra = ($random(seed) & 1) ? (24'h100000 | ($random(seed) & 24'h0FFFFC))
                               : ($random(seed) & 24'h07FFFC);
      rv = $random(seed);
      cpu_acc(1, 1, ra, rv);
      cpu_acc(0, 1, ra, 32'd0);
      check16(tag, ra, r_data,  shadow[ra[20:1]]);
      check16(tag, ra, r_data2, shadow[ra[20:1] + 20'd1]);
      if (j % 4 == 0) begin                   // and word 2 once through the narrow path
        cpu_acc(0, 0, ra + 24'd2, 32'd0);
        check16(tag, ra + 24'd2, r_data, shadow[ra[20:1] + 20'd1]);
      end
    end
  end
endtask

integer i;
reg [23:0] a;
initial begin
  for (i = 0; i < 4; i = i + 1) slot_hist[i] = 0;
  repeat (40) @(posedge clk114);
  reset_in = 1'b1;
  @(posedge reset_out);
  repeat (64) @(posedge clk114);

  // T1 bench validation: narrow writes, narrow reads, no DMA.  If this fails the
  // bench is wrong, and nothing else it says means anything.
  for (i = 0; i < 64; i = i + 1) cpu_acc(1, 0, 24'h010000 + 2*i, {16'hA000 + i[15:0], 16'h0000});
  for (i = 0; i < 64; i = i + 1) begin
    a = 24'h010000 + 2*i;
    cpu_acc(0, 0, a, 32'd0);
    check16("T1 narrow", a, r_data, shadow[a[20:1]]);
  end

  // T2 wide reads of what narrow writes put there
  for (i = 0; i < 32; i = i + 1) begin
    a = 24'h010000 + 4*i;
    cpu_acc(0, 1, a, 32'd0);
    check16("T2 wide w1", a, r_data,  shadow[a[20:1]]);
    check16("T2 wide w2", a, r_data2, shadow[a[20:1] + 20'd1]);
  end

  // T3 wide writes, read back one word at a time through the narrow path
  for (i = 0; i < 32; i = i + 1) cpu_acc(1, 1, 24'h020000 + 4*i, {16'hB000 + i[15:0], 16'hC000 + i[15:0]});
  for (i = 0; i < 64; i = i + 1) begin
    a = 24'h020000 + 2*i;
    cpu_acc(0, 0, a, 32'd0);
    check16("T3 narrow", a, r_data, shadow[a[20:1]]);
  end

  // T4 random wide write / wide read over the 2 MB, no DMA
  run_random("T4 random", 200);

  // T5 the same with Agnus taking most CCKs
  dma_pat = 16'b1011_0110_1101_1010;
  run_random("T5 dma", 300);
  // T5b DMA in every other CCK: a DMA slot straight after each CPU slot, the
  // way an AGA bitplane/sprite fetch refills chip48 behind the CPU's read
  dma_pat = 16'b0101_0101_0101_0101;
  run_random("T5b nextslot", 200);
  dma_pat = 16'h0000;

  // T6a a DMA write (Blitter, disk) after a CPU longword write must not write
  //     the held data_write2 into word A+2
  cpu_acc(1, 0, 24'h0D0000, {16'h0000, 16'h0000});
  cpu_acc(1, 0, 24'h0D0002, {16'h5A5A, 16'h0000});
  cpu_acc(1, 1, 24'h0C0000, 32'hDEAD_BEEF);          // data_write2 now holds $BEEF
  @(posedge clk28);
  dma_adr = 20'h68000;                               // $0D0000
  dma_wd  = 16'h1234;
  dma_we  = 1'b1;
  dma_pat = 16'hFFFF;
  repeat (32*8) @(posedge clk28);                    // 32 CCKs
  dma_pat = 16'h0000;
  repeat (4*8) @(posedge clk28);
  dma_we  = 1'b0;
  dma_adr = 20'h40000;
  cpu_acc(0, 0, 24'h0D0000, 32'd0); check16("T6a dma", 24'h0D0000, r_data, 16'h1234);
  cpu_acc(0, 0, 24'h0D0002, 32'd0); check16("T6a word2", 24'h0D0002, r_data, 16'h5A5A);

  // T6b a CPU word write after a CPU longword write must not write word A+2
  cpu_acc(1, 0, 24'h0D0012, {16'hA5A5, 16'h0000});
  cpu_acc(1, 1, 24'h0C0010, 32'hCAFE_F00D);          // data_write2 now holds $F00D
  cpu_acc(1, 0, 24'h0D0010, {16'h7777, 16'h0000});
  cpu_acc(0, 1, 24'h0D0010, 32'd0);
  check16("T6b w1", 24'h0D0010, r_data,  16'h7777);
  check16("T6b w2", 24'h0D0010, r_data2, 16'hA5A5);

  // T7 the Kickstart ROM: uploaded as the 832 does it (gary's cpu_hlt), then
  //    read wide at $F80000 and, with the overlay on, at $000000
  hlt = 1'b1;
  for (i = 0; i < 16; i = i + 1) cpu_acc(1, 0, 24'hF80000 + 2*i, {16'hF000 + i[15:0], 16'h0000});
  hlt = 1'b0;
  for (i = 0; i < 8; i = i + 1) begin
    a = 24'hF80000 + 4*i;
    cpu_acc(0, 1, a, 32'd0);
    check16("T7 rom w1", a, r_data,  16'hF000 + 2*i);
    check16("T7 rom w2", a, r_data2, 16'hF001 + 2*i);
  end
  ovl = 1'b1;
  cpu_acc(0, 1, 24'h000000, 32'd0);
  check16("T7 ovl w1", 24'h000000, r_data,  16'hF000);
  check16("T7 ovl w2", 24'h000000, r_data2, 16'hF001);
  cpu_acc(0, 1, 24'h000004, 32'd0);
  check16("T7 ovl w1", 24'h000004, r_data,  16'hF002);
  check16("T7 ovl w2", 24'h000004, r_data2, 16'hF003);
  ovl = 1'b0;

  $display("CHIP32 slots per CPU access: 0:%0d 1:%0d 2:%0d 3+:%0d",
           slot_hist[0], slot_hist[1], slot_hist[2], slot_hist[3]);
  $display("CHIP32 TB: %0d checks, %0d errors", checks, errors);
  if (errors == 0) $display("CHIP32 TB: PASS");
  else             $display("CHIP32 TB: FAIL");
  $finish;
end

initial begin
  #(64'd100_000_000_000);                // 100 ms of sim time
  $display("CHIP32 TB: FAIL timeout (checks %0d, errors %0d)", checks, errors);
  $finish;
end

endmodule
```

- [ ] **Step 2: Write the runner**

`sim/chip32/run.sh`:

```bash
#!/usr/bin/env bash
# sim/chip32 -- a 32-bit CPU access to chip RAM through the real minimig bus
# path and the real sdram_ctrl + SDRAM model (findings/chip32/plan.md, Task 2).
#
#   pass       must print "CHIP32 TB: PASS"
#   mut_word2  word 2 of a read taken from the wrong chip48 word: MUST FAIL
#   mut_nowr2  word 2 of a write never enabled:                 MUST FAIL
#
# The three builds run in parallel (vvp is single-core).  Exit status 0 only
# when the pass build passes and both mutants fail.
set -e
cd "$(dirname "$0")"
mkdir -p build
R=../../rtl
# Order matters for `timescale: the tb (1ps) first, the minimig files inherit
# it, sdram_ctrl.v sets 1ns for itself and what follows it.
SRC="chip32_tb.v \
  $R/minimig/minimig_m68k_bridge.v $R/minimig/gary.v $R/minimig/minimig_bankmapper.v \
  $R/minimig/minimig_sram_bridge.v \
  $R/sdram/sdram_ctrl.v $R/sdram/cpu_enable_cadence.v $R/sdram/cpu_cache_new.v \
  $R/sdram/dpram_inf_256x32.v $R/sdram/dpram_inf_be_1024x32.v $R/sdram/dpram_inf_generic.v \
  ../../lib/models/AS4C16M16SA.v"
for v in pass mut_word2 mut_nowr2; do
  case $v in
    pass)      D="" ;;
    mut_word2) D="-DMUT_WORD2" ;;
    mut_nowr2) D="-DMUT_NOWR2" ;;
  esac
  iverilog -g2012 -gspecify -DSOC_SIM -Dsg7 -DFAST $D -o build/tb_$v -s chip32_tb $SRC
done
for v in pass mut_word2 mut_nowr2; do
  vvp -n build/tb_$v "$@" > build/$v.log 2>&1 &
done
wait
rc=0
grep -h "^CHIP32" build/pass.log
if grep -q "^CHIP32 TB: PASS" build/pass.log; then echo "pass: PASS"; else echo "pass: FAILED"; rc=1; fi
for v in mut_word2 mut_nowr2; do
  if grep -q "^CHIP32 TB: PASS" build/$v.log; then
    echo "$v: MUTANT DID NOT FAIL -- the bench has no teeth"; rc=1
  else
    echo "$v: failed as required ($(grep -c '^FAIL' build/$v.log) FAIL lines)"
  fi
done
exit $rc
```

- [ ] **Step 3: Run it**

Run: `chmod +x sim/chip32/run.sh && sim/chip32/run.sh`
Expected:
```
CHIP32 slots per CPU access: 0:0 1:<N> 2:0 3+:0
CHIP32 TB: <M> checks, 0 errors
CHIP32 TB: PASS
pass: PASS
mut_word2: failed as required (...)
mut_nowr2: failed as required (...)
```
What each outcome means:
- T1 fails: the bench (master transcription, clock enables, pin model) is wrong. Fix the bench, not the RTL.
- `2:` or `3+:` non-zero: an access took more than one chip slot. The plan's premise (one slot per longword) does not hold as the RTL stands. Stop and report the histogram to Paul.
- T2-T7 fail with T1 passing: a real defect in the minimig side. Stop, use superpowers:systematic-debugging, and report before touching `rtl/minimig/*` or `sdram_ctrl.v` (the latter is off-limits without Paul).
- A mutant passes: the check does not see word 2. Fix the bench.

- [ ] **Step 4: Commit**

```bash
git add sim/chip32/chip32_tb.v sim/chip32/run.sh
git commit -m "sim/chip32: a longword CPU access to chip RAM through the real minimig path

Bridge, gary, bank mapper, SRAM bridge and the real sdram_ctrl with the
SDRAM model, driven like the wrapper's chipset state machine.  Proves one
chip slot moves both words, under DMA, with the held second word never
reaching a DMA or word write, and for the ROM with and without overlay.
Two mutants (wrong chip48 word, second-word enables tied off) must fail.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

Add the pass-log summary lines to `results.md` (new section "sim/chip32") and commit that with the bench.

---

### Task 3: The wrapper: one chipset cycle per aligned longword

**Files:**
- Modify: `rtl/soc/TG68K.vhd` (generic list ~l.64-70; signals ~l.213 and ~l.425; router ~l.809-812; `x_done` ~l.1014; turbo switch process ~l.1586-1605; `x_rdata_r` process ~l.1771-1792; chipset state machine ~l.1886-1992)
- Modify: `sim/ddr3_cpu/ddr3_cpu_tb.sv`, `sim/ddr3_cpu/run.sh`, `sim/ddr3_cpu/asm/ddr3_cpu_test.asm`

**Interfaces:**
- Consumes: the bus contract from Task 2.
- Produces: TG68K generic `chip32 : integer := 1` (0 = old behaviour). Task 4 passes it down from the top. The bench define `NOCHIP32` (sets the generic to 0), the run.sh flag `--c32mutant`, and the asm define `CHIP32PH` (set by run.sh for `--chipbus`).

- [ ] **Step 1: Add the generic only (no logic yet)**

In `rtl/soc/TG68K.vhd`, replace:

```vhdl
		z3ram3_size_log2 : integer := 24
	);
```
with:
```vhdl
		z3ram3_size_log2 : integer := 24;
		-- 1: with the AGA chipset, an aligned longword to chip RAM -- or a
		-- longword READ of the Kickstart ROM with Turbo kick off -- is ONE 7 MHz
		-- chipset cycle carrying both words, as on the A1200/A4000's 32-bit chip
		-- bus.  Everything else (custom registers, CIAs, Gayle, slow RAM, bytes,
		-- words, misaligned longwords) stays word/byte cycles, as on those
		-- machines.  0: every longword is two word cycles, as before.
		-- findings/chip32/plan.md.
		chip32           : integer := 1
	);
```

- [ ] **Step 2: Bench: CHIP32 monitor, NOCHIP32, and pass the generic**

In `sim/ddr3_cpu/ddr3_cpu_tb.sv`, replace:

```systemverilog
`ifdef AP040_PIPELINED
TG68K #(.cpu_clk_ratio(`CPU_RATIO), .ap040_pipelined(1)) tg68k (
`else
TG68K #(.cpu_clk_ratio(`CPU_RATIO)) tg68k (
`endif
```
with:
```systemverilog
// NOCHIP32 builds the wrapper with chip32 = 0: every longword two word cycles.
`ifdef NOCHIP32
localparam integer CHIP32_GEN = 0;
`else
localparam integer CHIP32_GEN = 1;
`endif
`ifdef AP040_PIPELINED
TG68K #(.cpu_clk_ratio(`CPU_RATIO), .ap040_pipelined(1), .chip32(CHIP32_GEN)) tg68k (
`else
TG68K #(.cpu_clk_ratio(`CPU_RATIO), .chip32(CHIP32_GEN)) tg68k (
`endif
```

Directly after the `// ---- chipset-side bus ----` block (after the `always @(posedge clk)` that writes `chipmem` through `tg68_uds2`/`tg68_lds2`), add:

```systemverilog
//-----------------------------------------------------------------
// CHIP32 monitor (findings/chip32/plan.md).  Counts every chipset-bus cycle
// the wrapper starts.  A WIDE cycle (uds2/lds2 low) must be an aligned
// longword with all four strobes low, in chip RAM or a ROM read -- never a
// custom register, CIA, Gayle or any other 16-bit chip, and never the NMI
// vector, which the Action Replay overlay answers one word at a time.
//-----------------------------------------------------------------
integer c32_wide = 0, c32_narrow = 0, c32_bad = 0;
reg     c32_as_d = 1'b1;
wire    c32_win  = (tg68_adr[31:21] == 11'd0) ||
                   (tg68_adr[31:24] == 8'h00 && tg68_rw &&
                    (tg68_adr[23:19] == 5'b11111 || tg68_adr[23:19] == 5'b11100));
always @(posedge clk) begin
  c32_as_d <= tg68_as;
  if (tg68_rst && c32_as_d && !tg68_as) begin
    if (!tg68_uds2 || !tg68_lds2) begin
      c32_wide = c32_wide + 1;
      if (tg68_adr[1:0] != 2'b00 || !c32_win ||
          tg68_uds || tg68_lds || tg68_uds2 || tg68_lds2 ||
          tg68_adr[31:2] == tg68k.NMI_addr[31:2]) begin
        c32_bad = c32_bad + 1;
        if (c32_bad <= 10)
          $display("CHIP32 BAD wide cycle at %t: adr=%08x rw=%b uds/lds/uds2/lds2=%b%b%b%b",
                   $time, tg68_adr, tg68_rw, tg68_uds, tg68_lds, tg68_uds2, tg68_lds2);
      end
    end else
      c32_narrow = c32_narrow + 1;
  end
end
```

Immediately before the line `  if (nfail == 0) $display("DDR3 CPU TB: 2 passed, 0 failed");`, add:

```systemverilog
  $display("CHIP32: %0d wide chipset cycles, %0d narrow, %0d bad (chip32=%0d turbochip=%0d)",
           c32_wide, c32_narrow, c32_bad, CHIP32_GEN, turbochipram);
  if (c32_bad != 0) begin
    nfail = nfail + 1;
    $display("DDR3 CPU TB: FAIL  CHIP32: %0d wide cycles outside the rules", c32_bad);
  end
  if (CHIP32_GEN == 0 && c32_wide != 0) begin
    nfail = nfail + 1;
    $display("DDR3 CPU TB: FAIL  CHIP32: chip32 = 0 but %0d wide cycles", c32_wide);
  end
  if (CHIP32_GEN != 0 && !turbochipram && !mmutest && c32_wide < 32) begin
    nfail = nfail + 1;
    $display("DDR3 CPU TB: FAIL  CHIP32: chip RAM over the chipset bus but only %0d wide cycles", c32_wide);
  end
```

- [ ] **Step 3: Bench program: the CHIP32PH phase**

In `sim/ddr3_cpu/asm/ddr3_cpu_test.asm`, add to the failure-code list in the header, after the line for code 14:
```
;  15  CHIP32PH: aligned longword read-back from chip RAM wrong
;  16  CHIP32PH: word read-back of a longword-written location wrong
;  17  CHIP32PH: misaligned (A+2) longword read-back wrong
```

Immediately before the block that starts with
```
;-----------------------------------------------------------------------------
; Done
```
insert:

```asm
;-----------------------------------------------------------------------------
; CHIP32PH (run.sh sets it for --chipbus): longwords to chip RAM over the
; chipset bus.  Aligned ones are one wide chipset cycle each (the bench's
; CHIP32 monitor counts them); the misaligned one, the NMI vector and the two
; custom-register longwords must stay word cycles (the monitor fails a wide
; one).  The values are address-derived, so a swapped or stale word shows.
; No phase marker, so the phase numbering does not shift; not defined,
; nothing is assembled.
;-----------------------------------------------------------------------------
          ifd       CHIP32PH
C32BUF    equ CHIPSCR+$400
          lea       C32BUF,a0
          move.l    #$C32A0000,d0
          moveq     #15,d1
c32_w:    move.l    d0,(a0)+
          add.l     #$00010001,d0
          dbra      d1,c32_w
          dc.w      $F478                ; CPUSHA DC: the reads below go to the bus
          lea       C32BUF,a0
          move.l    #$C32A0000,d4
          moveq     #15,d1
c32_r:    move.l    a0,d2
          move.l    (a0)+,d3
          cmp.l     d4,d3
          bne       f_c32
          add.l     #$00010001,d4
          dbra      d1,c32_r
          move.l    #C32BUF,d2           ; high word of longword 0
          moveq     #0,d3
          move.w    C32BUF,d3
          move.l    #$0000C32A,d4
          cmp.l     d4,d3
          bne       f_c32w
          move.l    #C32BUF+6,d2         ; low word of longword 1
          moveq     #0,d3
          move.w    C32BUF+6,d3
          moveq     #1,d4
          cmp.l     d4,d3
          bne       f_c32w
          move.l    #C32BUF+2,d2         ; straddles longwords 0 and 1
          move.l    C32BUF+2,d3
          move.l    #$0000C32B,d4
          cmp.l     d4,d3
          bne       f_c32m
          move.l    $7C.w,d3             ; NMI vector (VBR = 0): must stay narrow
          move.l    #$00001234,$00DFF080 ; COP1LC: a 16-bit chip, two word cycles
          move.l    $00DFF004,d3         ; VPOSR+VHPOSR: two word cycles
          endif
```

After the `f_cnt2:` handler (`f_cnt2:   moveq     #9,d7` / `bra       report`), add:
```asm
f_c32:    moveq     #15,d7
          bra       report
f_c32w:   moveq     #16,d7
          bra       report
f_c32m:   moveq     #17,d7
          bra       report
```

- [ ] **Step 4: run.sh: CHIP32PH for --chipbus, NOCHIP32, --c32mutant, CHIP32 in the summary grep**

In `sim/ddr3_cpu/run.sh`:

(a) Header leg list: after the `--chipbus` line add
```
#   ./run.sh --c32mutant --chipbus  CHIP32 read data returns word 1 twice; MUST fail
#   NOCHIP32=1 ./run.sh ...         the wrapper's chip32 generic = 0 (longwords as two word cycles)
```
(b) After the line `if [ "$1" = "--gatemutant" ]; then IS_GATEMUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi` add:
```bash
# --c32mutant: the CHIP32 read path answers with its first word twice
# (TG68K.vhd `x_rdata_r <= r_data & r_data2;` -> `r_data & r_data`).  Use it
# with --chipbus; the CHIP32PH phase must then fail with code 15.  Implies --ap040.
IS_C32MUTANT=0
if [ "$1" = "--c32mutant" ]; then IS_C32MUTANT=1; IS_MUTANT=1; shift; set -- --ap040 "$@"; fi
```
(c) In the VARIANT block, after `if [ "$IS_GATEMUTANT" = "1" ]; then VARIANT=gatemutant_ap040; fi` add:
```bash
    if [ "$IS_C32MUTANT" = "1" ];  then VARIANT=c32mutant_ap040;  fi
```
(d) After `if [ "$TURBOCHIP" = "0" ]; then VARIANT="${VARIANT}_chipbus"; fi` add:
```bash
if [ -n "$NOCHIP32" ]; then VARIANT="${VARIANT}_nochip32"; fi
# CHIP32PH: the longword phase of the pattern program, only where chip RAM goes
# over the chipset bus (findings/chip32/plan.md).
C32PH=""
if [ "$TURBOCHIP" = "0" ]; then C32PH="-DCHIP32PH=1"; fi
```
(e) In the non-MMU program build, replace
```bash
        -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN -DCACRVAL="$CACRVAL" \
```
with
```bash
        -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN -DCACRVAL="$CACRVAL" $C32PH \
```
(f) Before the line `elif [ "$IS_ACKMUTANT" = "1" ]; then` add:
```bash
elif [ "$IS_C32MUTANT" = "1" ]; then
    # Generated: the CHIP32 read data's second word replaced by the first.
    TG68K_SRC="$W/TG68K_c32mutant.vhd"
    sed "s|x_rdata_r <= r_data & r_data2;|x_rdata_r <= r_data \& r_data;|" \
        "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC"
    if ! grep -q "x_rdata_r <= r_data & r_data;" "$TG68K_SRC"; then
        echo "--c32mutant: the CHIP32 read-data line moved; fix the sed in run.sh" >&2
        exit 2
    fi
```
(g) In the xelab line, after `${CPU_PHASE:+-d CPU_PHASE=$CPU_PHASE}` add ` ${NOCHIP32:+-d NOCHIP32}`.
(h) Replace `grep -E "^(PASS|FAIL|INFO:|DDR3 CPU TB|       )"` with `grep -E "^(PASS|FAIL|INFO:|DDR3 CPU TB|CHIP32|       )"`.

- [ ] **Step 5: Run the red leg: the monitor must see no wide cycles yet**

```bash
cd sim/ddr3_cpu
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 RUNTAG=c32red ./run.sh --ap040 --chipbus
```
Expected: the program itself passes (the narrow path is correct), and the bench reports
`CHIP32: 0 wide chipset cycles, <n> narrow, 0 bad (chip32=1 turbochip=0)` and
`DDR3 CPU TB: FAIL  CHIP32: chip RAM over the chipset bus but only 0 wide cycles`, so run.sh exits non-zero. If the program fails with code 15-17 here, the CHIP32PH code is wrong: fix the asm first.

- [ ] **Step 6: Implement the route in TG68K.vhd**

(a) Signals. After `SIGNAL r_data      : std_logic_vector(15 downto 0);` add:
```vhdl
	SIGNAL r_data2     : std_logic_vector(15 downto 0);  -- word A+2 of a CHIP32 read
```
After `SIGNAL x_a16      : std_logic;` add:
```vhdl
	-- CHIP32 (findings/chip32/plan.md): an aligned longword to chip RAM, or a
	-- longword read of the ROM, as ONE chipset cycle carrying both words.
	-- chip32_d is the switch, registered where the Turbo switches are, so it
	-- never changes under an access; c32_cyc marks the chipset cycle in
	-- flight as one; c32_done is its completion level, as ak_done is Akiko's.
	SIGNAL c32_en     : std_logic;
	SIGNAL chip32_d   : std_logic := '0';
	SIGNAL x_c32      : std_logic;
	SIGNAL q_c32      : std_logic;
	SIGNAL c32_cyc    : std_logic := '0';
	SIGNAL c32_done   : std_logic := '0';
```

(b) Router. Replace:
```vhdl
	x_akiko <= sel_akiko AND NOT sel_nmi_vector;
	x_a16   <= NOT (x_sdram OR x_ddr OR x_akiko);
```
with:
```vhdl
	x_akiko <= sel_akiko AND NOT sel_nmi_vector;
	-- CHIP32: what the AGA machines' 32-bit chip bus carries in one cycle --
	-- an aligned longword to chip RAM, or an aligned longword read of the ROM
	-- (sel_kick is read-only).  Only what the RAM routes did not already take,
	-- i.e. Turbo chip/kick off.  Never the NMI vector: cart.v answers that one
	-- word at a time by address bit 1, so a wide read would get its second word
	-- from chip RAM.  Custom registers, CIAs, Gayle, slow RAM, bytes, words and
	-- misaligned longwords all stay on the adapter.
	x_c32   <= '1' WHEN chip32_d = '1' AND x_size = "10" AND x_addr(1 DOWNTO 0) = "00"
	                    AND (sel_chip = '1' OR sel_kick = '1')
	                    AND x_sdram = '0' AND x_ddr = '0' AND x_akiko = '0'
	                    AND sel_nmi_vector = '0' ELSE '0';
	x_a16   <= NOT (x_sdram OR x_ddr OR x_akiko OR x_c32);
```
After `q_ddr   <= q_req AND x_ddr;` add:
```vhdl
	q_c32   <= q_req AND x_c32;
	c32_en  <= '1' WHEN chip32 /= 0 ELSE '0';
```

(c) Completion. Replace `x_done <= rs_ack OR rd_ack OR ak_done;` with:
```vhdl
	x_done <= rs_ack OR rd_ack OR ak_done OR c32_done;

	-- CHIP32's completion level: set when the chipset cycle it started is
	-- answered (chipset_ready, the same moment the adapter's word cycle is),
	-- held until the request drops -- which q_req guarantees on the edge the
	-- kernel consumes it, exactly as for ak_done.
	PROCESS(clk, reset)
	BEGIN
		IF reset = '0' THEN
			c32_done <= '0';
		ELSIF rising_edge(clk) THEN
			IF q_c32 = '0' THEN
				c32_done <= '0';
			ELSIF chipset_ready = '1' AND c32_cyc = '1' THEN
				c32_done <= '1';
			END IF;
		END IF;
	END PROCESS;
```

(d) Read data. In the `x_rdata_r` process, replace:
```vhdl
					ELSIF rd_ack = '1' THEN
						x_rdata_r <= rd_rdata;
					ELSE
```
with:
```vhdl
					ELSIF rd_ack = '1' THEN
						x_rdata_r <= rd_rdata;
					ELSIF c32_done = '1' THEN
						x_rdata_r <= r_data & r_data2;
					ELSE
```

(e) The switch. In the Turbo switch process, replace:
```vhdl
				turbochip_d   <= '0';
				turbokick_d   <= '0';
```
with:
```vhdl
				turbochip_d   <= '0';
				turbokick_d   <= '0';
				chip32_d      <= '0';
```
and replace:
```vhdl
				turboslow_d   <= turbochipram OR aga;
```
with:
```vhdl
				turboslow_d   <= turbochipram OR aga;
				chip32_d      <= aga AND c32_en;
```

(f) The chipset state machine (`PROCESS(clk, reset)` with `S_state`):
- In the reset branch, after `clkena_e <= '0';` add `c32_cyc  <= '0';`.
- Replace the release:
```vhdl
			IF (chipset_ready = '1' OR chipset_done = '1') AND clkena = '1' THEN
				S_state <= "00";
			END IF;

			IF S_state = "01" AND clkena_e = '1' THEN
				uds2        <= uds_in;
				lds2        <= lds_in;
				data_write2 <= w_datatg68;
			END IF;
```
with:
```vhdl
			IF (chipset_ready = '1' OR chipset_done = '1') AND clkena = '1' THEN
				S_state <= "00";
				c32_cyc <= '0';
			END IF;

			-- (The TG68K's paired-word latch that sat here -- uds2/lds2 and
			-- data_write2 taken in state "01" while clkena_e was still up -- was
			-- dead since Stage E4a: clkena_e is always '0' in state "01".  It
			-- is removed because data_write2 now carries CHIP32's second word.)
```
- In `WHEN "00" =>` of the `ena7WRreg` branch, replace:
```vhdl
							addr       <= cpuaddr;
							S_state <= "01";
						END IF;
```
with:
```vhdl
							addr       <= cpuaddr;
							S_state <= "01";
						ELSIF q_c32 = '1' AND c32_done = '0' AND cpu_bus_settled = '1' THEN
							-- CHIP32: the whole longword in one cycle.  The
							-- minimig side (bridge, gary, SRAM bridge,
							-- sdram_ctrl) moves word A+2 in the same chip slot:
							-- a write through data_write2 and uds2/lds2, a read
							-- back through data_read2 (chip48).  sim/chip32.
							uds         <= '0';
							lds         <= '0';
							uds2        <= '0';
							lds2        <= '0';
							as          <= '0';
							rw          <= NOT x_we;
							data_write  <= x_wdata(31 DOWNTO 16);
							data_write2 <= x_wdata(15 DOWNTO 0);
							addr        <= x_addr;
							c32_cyc     <= '1';
							S_state     <= "01";
						END IF;
```
- In `WHEN "11" =>` of the `ena7RDreg` branch, replace:
```vhdl
						IF clkena_e = '0' THEN
							r_data <= data_read;
						END IF;
```
with:
```vhdl
						IF clkena_e = '0' THEN
							r_data  <= data_read;
							r_data2 <= data_read2;
						END IF;
```

- [ ] **Step 7: Green legs, ONE AT A TIME, in this order**

```bash
cd sim/ddr3_cpu
L="env LD_LIBRARY_PATH=$HOME/lib/tinfo5"
P="PIPELINED=1 PIPE_DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/lib/AP68040-pipelined"
$L RUNTAG=c32 ./run.sh --ap040 --chipbus                   # 1 reference core
$L RUNTAG=c32 $P ./run.sh --ap040 --chipbus                # 2 pipelined core
$L RUNTAG=c32mut ./run.sh --c32mutant --chipbus            # 3 mutant
$L RUNTAG=c32off NOCHIP32=1 ./run.sh --ap040 --chipbus     # 4 generic off
$L RUNTAG=c32 ./run.sh --ap040                             # 5 Turbo chip on
$L RUNTAG=c32 ./run.sh --mmu --chipbus                     # 6 walker descriptors over the chipset bus
```
Expected:
1. and 2.: `DDR3 CPU TB: 2 passed, 0 failed`; `CHIP32: <w> wide ..., 0 bad` with w >= 32; program phase timestamps EARLIER than the matching c32base leg from Task 1.
3.: `mutant failed as required` (the program reports code 15, or fails earlier on a fetch).
4.: `2 passed, 0 failed`; `CHIP32: 0 wide`. Phases 1-7 BIT-IDENTICAL to the reference-core c32base leg (only phase 8 moves, by the CHIP32PH code): `diff <(grep "program phase [1-7]" xsim_run_pass_ap040_chipbus_c32base.log) <(grep "program phase [1-7]" xsim_run_pass_ap040_chipbus_nochip32_c32off.log)` prints nothing.
5.: `2 passed, 0 failed`. chip32_d switches on the same edge as turbochip_d, so with Turbo chip on nothing is wide (`CHIP32: 0 wide`), not even the reset-vector fetches that happen before the switch.
6.: `2 passed, 0 failed`. If this leg also fails on the base commit (run it there with `RUNTAG=c32base` to find out), record that and drop it. It is not caused by this change.

If 1 or 2 fail with code 15-17, or `bad` > 0: debug (superpowers:systematic-debugging) with `XPLUS=+LBDBG` for the chipset-bus trace. Do not loosen the monitor.

- [ ] **Step 8: Check nothing else in the tree moved**

Run: `git status --short sim/ddr3_cpu | grep -v "^??"`
Expected: only the three files this task edits. If a tracked `xsim_run_*.log` shows as modified, a leg ran without RUNTAG: `git checkout -- <that log>`.

- [ ] **Step 9: Record and commit**

Add the six legs (wide/narrow counts, phase 7/8 and `$finish` times) to `results.md`, including the speed-up of phase 8 over c32base. Then:
```bash
git add rtl/soc/TG68K.vhd sim/ddr3_cpu/ddr3_cpu_tb.sv sim/ddr3_cpu/run.sh sim/ddr3_cpu/asm/ddr3_cpu_test.asm findings/chip32/results.md
git commit -m "TG68K.vhd: an aligned longword to chip RAM is one chipset cycle (AGA 32-bit chip bus)

With the AGA chipset and Turbo chip/kick off, an aligned longword to chip
RAM, or an aligned longword read of the ROM, goes to the chipset state
machine as ONE cycle with uds/lds/uds2/lds2 all low and both words, and
comes back as r_data & r_data2; completion through x_done like Akiko's.
Custom registers (Blitter, Copper, ...), CIAs, Gayle, slow RAM, bytes,
words, misaligned longwords and the NMI vector stay word/byte cycles.
DMA is untouched.  Generic chip32 (default 1); 0 is the old behaviour.

sim/ddr3_cpu: CHIP32 monitor, CHIP32PH program phase for --chipbus,
NOCHIP32, --c32mutant.  findings/chip32/plan.md Task 3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Pass CHIP32 to the top, build the A/B pair

**Files:**
- Modify: `rtl/soc/minimig_virtual_top.v`, `rtl/soc/minimig_openaars_top.v`, `tools/vivado/build_ap040.tcl`

**Interfaces:**
- Consumes: TG68K generic `chip32` (Task 3).
- Produces: top generic `CHIP32` and the build switch `CHIP32=<0|1>` (environment, default 1). Two bitstreams from one commit: `build/stage_chip32_on/` and `build/stage_chip32_off/`.

- [ ] **Step 1: minimig_virtual_top.v**

Replace `    parameter cpu_clk_divide = 30,` with:
```verilog
    parameter cpu_clk_divide = 30,
    // 1: an aligned longword to chip RAM is one chipset cycle, as on the AGA
    // machines' 32-bit chip bus (TG68K.vhd generic chip32; findings/chip32/plan.md)
    parameter chip32 = 1,
```
Replace:
```verilog
    .cpu_clk_ratio(cpu_clk_divide/10)
) tg68k (
```
with:
```verilog
    .cpu_clk_ratio(cpu_clk_divide/10),
    .chip32(chip32)
) tg68k (
```

- [ ] **Step 2: minimig_openaars_top.v**

Replace `  parameter CPU_CLK_DIVIDE = 30,` with:
```verilog
  parameter CPU_CLK_DIVIDE = 30,
  // 32-bit CPU cycles on the chip bus (findings/chip32/plan.md); 0 = two word cycles
  parameter CHIP32 = 1,
```
Replace `  .cpu_clk_divide(CPU_CLK_DIVIDE),` with:
```verilog
  .cpu_clk_divide(CPU_CLK_DIVIDE),
  .chip32(CHIP32),
```

- [ ] **Step 3: build_ap040.tcl**

Before the `set_property generic "HAVEDDR3=1 ...` line add:
```tcl
# CHIP32=0 in the environment builds the wrapper with every longword as two
# word cycles (findings/chip32/plan.md); default 1.
set chip32 [expr {[info exists ::env(CHIP32)] && $::env(CHIP32) ne "" ? $::env(CHIP32) : 1}]
```
and in that `set_property generic` string replace `CPU_CLK_DIVIDE=$cpudiv$pipe_gen` with `CPU_CLK_DIVIDE=$cpudiv CHIP32=$chip32$pipe_gen`.

- [ ] **Step 4: Build ON, then OFF (never two at once: they share project_1)**

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
V="env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal"
CHIP32=1 $V -source tools/vivado/build_ap040.tcl -tclargs build/stage_chip32_on 0
CHIP32=0 $V -source tools/vivado/build_ap040.tcl -tclargs build/stage_chip32_off 0
```
(`0` = no ILA: the shipping configuration, MMU and FPU on, pipelined core from lib/AP68040-pipelined.) Run each in the background and wait for it to finish.
Expected: both print `build_ap040.tcl: re-synthesising (generics or sources changed)` and end with `minimig_openaars_top.bit` in their directory.

- [ ] **Step 5: Timing and size**

Run for both:
```bash
for d in build/stage_chip32_on build/stage_chip32_off; do echo "== $d"; grep -A6 "Design Timing Summary" $d/timing_summary.rpt | tail -3; grep -m1 "Slice LUTs" $d/utilization.rpt; done
```
Expected: the only failing endpoints are the known 16 `clk_gen_sdram -> clk_114` at about -0.498 ns, in both builds. ON is at most ~200 LUTs larger than OFF. Any new failing path in clk_38, clk_114 or between them: stop and report to Paul (do not load).

- [ ] **Step 6: Commit and note the images**

Add both images (commit, md5 of each `.bit`, WNS, LUTs) to `results.md`, then:
```bash
md5sum build/stage_chip32_on/minimig_openaars_top.bit build/stage_chip32_off/minimig_openaars_top.bit
git add rtl/soc/minimig_virtual_top.v rtl/soc/minimig_openaars_top.v tools/vivado/build_ap040.tcl findings/chip32/results.md
git commit -m "openaars: CHIP32 top generic and build switch; A/B images built

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Board A/B (Paul at the board)

**Files:**
- Modify: `findings/chip32/results.md`

**Interfaces:**
- Consumes: `chipbw` (Task 1), the two images (Task 4).

Everything in this task is Paul's to do or to OK. Load an image only when Paul says so:
```bash
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal \
  -source tools/vivado/program.tcl -tclargs build/stage_chip32_off/minimig_openaars_top.bit
```

- [ ] **Step 1: Get chipbw onto the Amiga** (Paul, the way SysInfo got there).

- [ ] **Step 2: OFF image, then ON image, same checklist each** (OSD: Chipset AGA, Turbo chip OFF, Turbo kick OFF; after a JTAG load, power-cycle if there is no HDMI)
  1. Boots to Workbench.
  2. Shell: `chipbw` twice. Record the second run.
  3. OSD Turbo chip ON, reset, `chipbw` once (sanity: both images should agree here, since Turbo bypasses the chipset bus).
  4. Turbo chip OFF again: SysInfo SPEED once, record.
  5. ON image only: cputest `ct040_01_B-01` disk passes.
  6. With Turbo chip OFF: the demos that break with Turbo chip ON (Paul's list; the findings name Way Too Rude and Phenomena's Enigma). On each image, write down how each behaves.

- [ ] **Step 3: Judge**

Pass:
- `chip rd.l` and `chip wr.l` on ON are at least 1.6x OFF. The expected ratio is about 2x: both images do one chipset cycle every 4 ena7 ticks (~564 ns), and ON moves 4 bytes per cycle instead of 2.
- `rom rd.l` (Turbo kick off) also improves.
- Workbench, cputest and the Turbo-ON numbers are unchanged between images.

`chip rd.w` and `wr.w`: record them, with no threshold. With the MMU off, the data cache line-fills chip RAM in longwords, so word reads speed up too. With 68040.library's MMU on they should not.
If the ratio is below 1.6x: do not tune. Record it and hand it to Paul with the Follow-ups below.

- [ ] **Step 4: Record and commit**

```bash
git add findings/chip32/results.md
git commit -m "findings/chip32: board A/B results

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Close the backlog item

**Files:**
- Modify: `findings/ap040-pipelined/SESSION-HANDOVER.md`

- [ ] **Step 1:** In the Backlog item "Chip RAM: longword per chip slot, so turbo can go", add one paragraph at its end. It covers: the status (DONE on branch `chip32` at <commit>, or the stop point), the measured ratio, the demo outcome with Turbo off, the images, and a pointer to `findings/chip32/results.md`. Add `chip32` to the "NOT pushed yet" line.
- [ ] **Step 2: Commit**
```bash
git add findings/ap040-pipelined/SESSION-HANDOVER.md
git commit -m "findings/ap040-pipelined: handover, 32-bit chip cycles

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Follow-ups (not in this plan; each needs Paul's call)

- **Release latency.** The state machine releases the CPU one `ena7RDreg` tick (141 ns) after it has the data (`chipset_ready = ena7RDreg AND clkena_e`), so a CPU chip cycle takes 4 ticks. Releasing on the capture edge would make it 3 ticks. That is a CPU-timing change on top of the width change, so it is measured separately if Task 5 leaves demand for it.
- **Runtime switch** instead of a build generic: an OSD bit, if A/B testing turns out to be needed often.
- **Not planned, on purpose:** a misaligned longword in one slot (a real 020 splits it too), wide slow RAM (16-bit on the machines that had it), and any widening of custom-register or DMA paths (16-bit on real AGA, see "What stays 16-bit").
