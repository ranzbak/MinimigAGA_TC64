# FPU fixes from Adam's comparison (P1+N1, P2b, P2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the pipelined core's FPU behaviour in the cases where Adam's review (`doc/AP040_FPU_COMPARISON_20260926.md`) and our evaluation (`findings/ap040-pipelined/fpu-comparison-evaluation.md`) found it wrong:
- **P1:** memory-indirect FP effective addresses execute instead of trapping.
- **N1:** the LC040's format $4 frame stacks the operand address, not the pointer's.
- **P2b:** opclass 011 illegal EAs take the plain F-line.
- **P2:** a packed FMOVE to Dn raises vector 55.

**Architecture:** The core already reads memory-indirect pointers for integer instructions: `need_smi`/`need_dmi`, `next_rd` issuing T_SMI/T_DMI, and the capture into `s_addr`/`d_addr` in `rtl/ap040_ea_fetch.v`. The decoder shuts FP instructions out of it (`d.src.mi == MI_NONE` in six places in `rtl/ap040_decode.v`). The fix:
- lets the decoder pass memory-indirect FP operands;
- has EA-fetch's CL_FPU arm issue the pointer read and enter P_FPU only once the pointer is in;
- makes stores read the pointer once;
- gives the LC040 format $4 path the same wait.

P2b and P2 are two decode-condition fixes in the opclass 011 reject block.

**Tech Stack:** SystemVerilog/Verilog in the submodule `lib/AP68040-pipelined`; iverilog/vvp benches (`tb/run_pipe_tests.sh`, `pipe_asm/*.s` + `.exp`); vasm; the superproject's sim/ddr3_cpu and Vivado build for the gate.

**Spec:** `findings/ap040-pipelined/fpu-comparison-evaluation.md` (verdicts and fix sketches), `doc/AP040_FPU_COMPARISON_20260926.md` (Adam's claims and probe numbers), M68040UM 10.7.2 (FP timing tables list every memory-indirect mode), A.5.1 p. A-6 (format $4 EA = the operand's calculated EA), 9.6.2 (unsupported data type, format $3, vector 55); `findings/ap040-pipelined/PLAN.md` D19, D22, M10.

## Global Constraints

- Work on branch `fpu-comparison-fixes` in `lib/AP68040-pipelined` (off 2c904dc). The superproject gets a pin bump only in Task 5.
- Never `git push` (either repo) unless Paul says so. Never write the SPI flash.
- The LC040 Kickstart leg's architectural trace must stay identical (PLAN.md standing check: 2,288,738 instructions). No FP change may move what an LC040 boot does, except N1's EA field, which Kickstart never takes.
- `tb/run_pipe_tests.sh` must end with every leg `pass`: currently 198 legs, plus the new ones.
- Authority order: M68040UM text, then a source verified on real 040 hardware for the case (WinUAE cpu_level 4 / cputest), then the PRM. Record each decision in PLAN.md 7.1 (D19, D22 rows).
- Timing: the P_START chain is on the M14-tightened path. Check the routed clk_38 slack in Task 5 against `build/stage_unfreeze_on` (+0.905) and `stage_merged_free` (+0.353), and report it.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Every new image gets a **board boot check** before it's called good: `stage_merged_free` failed before the splash screen with clean STA (findings/unfreeze/results.md).

## Review Focus

1. **A pointer read that faults.** It must take format $7 through the existing access-error path, not hang P_FPU. Pinned: Task 2 checks the pointer-read gating reaches the generic `cap_err` path. There is no bus-error region in the FPU_REAL bench, so this is a code-reading check plus the M6 benches; noted as a gap.
2. **A store reading its pointer twice** (`dst = src` for stores, FScc, FSAVE, FMOVEM stores). Pinned: `readonce` lines in Task 1's .exp.
3. **An interrupt arriving while the FP instruction waits for its pointer.** The instruction is still in P_START, where interrupts are taken. Pinned: the IRQ program legs in `run_pipe_tests.sh`, which must stay green.
4. **Released FPU operation (`fp_bg`) plus a memory-indirect FP instruction behind it.** The existing `!fp_bg` wait must still hold. Pinned: fpureal_mi case 2 follows an FDIV.
5. **LC040 build (HAS_FPU=0).** Only the format $4 EA may change. Pinned: Task 3's plain-bench program plus the LC040 Kickstart leg.

---

## Files

| File | Change | Task |
|---|---|---|
| `tb/pipe_asm/fpureal_mi.s`, `.exp` | new: memory-indirect FP on the FPU_REAL bench | 1 |
| `tb/pipe_asm/fpureal_p2.s`, `.exp` | new: packed store to Dn/An | 1 |
| `tb/pipe_asm/lc_mi_fmt4.s`, `.exp` | new: LC040 format $4 EA through a pointer | 1 |
| `rtl/ap040_decode.v` | the six `mi == MI_NONE` terms (P1); the opclass 011 arm (P2); the `fp_op_hw` split (P2b) | 2, 4 |
| `rtl/ap040_ea_fetch.v` | `need_smi`/`need_dmi` for CL_FPU; CL_FPU and CL_EXC-fmt4 arms issue the pointer read; P_FPU entry gate | 2, 3 |
| `rtl/compat/ap040_fpu.v` | only if P2's red test shows the unit writes Dn instead of trapping | 4 |
| superproject: `lib/AP68040-pipelined` pin, `findings/ap040-pipelined/PLAN.md` (D19/D22/M10 STATUS) | pin bump, records | 5 |

Shell: `cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/lib/AP68040-pipelined`. One program on its own: `sh tb/run_pipe_tests.sh 2>&1 | grep -E 'fpureal_mi|fpureal_p2|lc_mi_fmt4'` (the suite takes about 3 minutes, and vvp legs run in parallel inside it).

---

### Task 1: Red tests, all three programs failing for the reason the evaluation predicts

**Files:** Create `tb/pipe_asm/fpureal_mi.s/.exp`, `tb/pipe_asm/fpureal_p2.s/.exp`, `tb/pipe_asm/lc_mi_fmt4.s/.exp`.

**Interfaces:**
- Consumes: `vectors.inc` (the `v_*` equates, `unexp`); the bench directives `halt <pc>`, `m32 <addr> <value>`, `readonce <addr>`.
- Produces: the three programs, run automatically. `fpureal*.s` with a `.exp` runs in the fpr and fprbus0-2 legs. The plain pipe_asm programs run where `run_pipe_tests.sh` runs the other plain `pipe_asm` programs (check the loop; if plain programs need listing, add `lc_mi_fmt4` there).

- [ ] **Step 1: `fpureal_mi.s`** (supervisor, FPU_REAL). Scaffold as `fpureal_sv.s`: `v_*` equates, `include "vectors.inc"`, `org $400`, `start:`, the handlers, `halt: bra.s halt`. Body:

```asm
v_flin	equ	unexp		; any F-line = failure (the gap P1 closes)
v_fpun	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"
	org	$400
start:
	lea	$3000,a0
	moveq	#1,d1
	fmove.l	#10,fp5
	fdiv.w	([$3100.w]),fp5		; 1: 10 / 5 -> fp5 = 2
	fadd.x	([0,a0,d1.l*4],8),fp5	; 2: pointer at $3004 -> $3600, +8: 3.0 -> fp5 = 5
	fmove.l	fp5,([$3104.w])		; 3: store through a pointer: $3300 = 5
	fsne	([$3108.w])		; 4: 5 <> 0: $3400's byte = $FF
	fmove.l	fpcr,([$310c.w])	; 5: control register store: $3500 = FPCR = 0
	fsave	([$3110.w])		; 6: $3700 = $41000000 (IDLE: the unit was used)
halt:	bra.s	halt
unexp:	bra.s	unexp

	org	$3004
	dc.l	$3600
	org	$3100
	dc.l	$3200, $3300, $3400, $3500, $3700
	org	$3200
	dc.w	5
	org	$3300
	dc.l	$DEADBEEF
	org	$3400
	dc.l	$00112233
	org	$3500
	dc.l	$DEADBEEF
	org	$3608
	dc.l	$40000000, $C0000000, $00000000	; 3.0 extended
	org	$3700
	dc.l	$DEADBEEF
```
If vasm rejects a memory-indirect FP form, write that instruction as `dc.w` (vasm listing of the integer twin, M68040UM encoding) and say so in a comment.

`.exp`, with the halt address taken from `vasmm68k_mot -m68040 -Fbin -L /tmp/mi.lst` (label `halt`):
```text
# findings/fpu-fixes/plan.md: memory-indirect FP effective addresses (P1)
halt <halt>
m32 00003300 00000005
m32 00003400 ff112233
m32 00003500 00000000
m32 00003700 41000000
readonce 00003100
readonce 00003104
readonce 00003108
readonce 0000310c
readonce 00003110
```

- [ ] **Step 2: `fpureal_p2.s`** (P2 and P2b). The same scaffold, with its own handlers that record the frame word and the address field:
```asm
v_fpun	equ	h_fpun
v_flin	equ	h_flin
	...
start:	clr.l	$7000
	clr.l	$7004
	moveq	#0,d1
	fmove.l	#1,fp0
	lea	$7010,a5		; where the recorded words go
	dc.w	$F200,$6C00		; 1: FMOVE.P FP0,D0{#0}  -> vector 55, $30DC, EA 0
	dc.w	$F200,$7C10		; 2: FMOVE.P FP0,D0{D1}  -> vector 55, $30DC, EA 0
	dc.w	$F208,$7C10		; 3: FMOVE.P FP0,A0{D1}  -> F-line, $002C
	dc.w	$F208,$6C05		; 4: FMOVE.P FP0,A0{#5}  -> F-line, $002C
halt:	bra.s	halt
h_fpun:	move.w	6(sp),(a5)+		; format/vector word
	move.l	8(sp),(a5)+		; format $3 address field
	clr.l	-(sp)			; leave the unit as FRESTORE of NULL does
	frestore (sp)+
	rte				; format $3: the PC is already the next instruction
h_flin:	move.w	6(sp),(a5)+
	clr.l	(a5)+
	addq.l	#4,2(sp)		; format $0: the PC is the F-line's own; skip its two words
	rte
unexp:	bra.s	unexp
```
`.exp`: `halt <halt>`, then `m32 00007010 30DC0000`, `m32 00007014 00000000` (case 1: the word and the address field span the longwords as written; recompute from the `(a5)+` layout and write the four cases' words exactly).

- [ ] **Step 3: `lc_mi_fmt4.s`** (plain prog bench, HAS_FPU=0: N1). Handler `v_flin equ h_flin` records `6(sp)` (the frame word, expect `$402C`) and `8(sp)` (the EA field), then `addq.l #6,2(sp)` or `#8` to skip the instruction (words: F-line + ext + bd.w, and the `,4` form adds one od word; count them from the listing), then `rte`. Cases:
  - `fdiv.w ([$3100.w]),fp5` → EA `$3200`
  - `fdiv.w ([$3104.w],4),fp5` → EA `$3204`
  - `fdiv.w $3200,fp5` → EA `$3200` (control)

  Pointers: `$3100` and `$3104`, both holding `$3200`. `.exp`: `halt`, the three frame words `$402C`, the three EAs, `readonce 00003100`, `readonce 00003104`.

- [ ] **Step 4: Run and read the red results**

Run: `sh tb/run_pipe_tests.sh 2>&1 | grep -E 'fpureal_mi|fpureal_p2|lc_mi_fmt4'`
Expected (the evaluation's probe numbers):
- `fpureal_mi` FAILs in all four fpr legs at case 1 (F-line through `unexp`, so no `halt`).
- `fpureal_p2` FAILs: cases 1-2 give `$402C`/`$002C` instead of `$30DC`, and cases 3-4 give `$202C` instead of `$002C`.
- `lc_mi_fmt4` FAILs on the two memory-indirect EAs (`$3100`/`$3104`, not `$3200`/`$3204`); the control case passes.

If any program fails for another reason (assembly, wrong halt address, a wrong frame-offset assumption), fix the program first. A red test must fail on the defect.

- [ ] **Step 5: Commit** (in the submodule): `git add tb/pipe_asm/fpureal_mi.* tb/pipe_asm/fpureal_p2.* tb/pipe_asm/lc_mi_fmt4.* && git commit` with a message naming the three red programs and their failure signatures.

---

### Task 2: P1: memory-indirect FP operands execute

**Files:** Modify `rtl/ap040_decode.v` (lines 1251, 1275, 1318, 1330, 1359, 1437) and `rtl/ap040_ea_fetch.v` (`need_smi`/`need_dmi` about line 465, the `fp_mem_dst` definition about line 1670, the P_START step function's CL_FPU arm about line 1023, the P_FPU entry about line 2346).

- [ ] **Step 1: Decode.** On each of the six lines, delete the term `&& d.src.mi == MI_NONE`; line 1437 keeps `d.src.kind == EK_MEM`. Update the comment at 1301-1306 and at 1370-1372 (the memory-indirect gap is closed). `grep -n 'MI_NONE' rtl/ap040_decode.v` must show no FP site left.

- [ ] **Step 2: One pointer read per FP instruction.** Move the `fp_mem_dst` wire (and whatever it needs, e.g. `fp_gen`) above `need_smi`. Then:
```verilog
// (FPU fixes P1) an FP instruction reads its memory-indirect pointer ONCE:
// the destination's for an opclass-011 store (fp_addr takes d_addr_c), the
// source's for everything else (fp_addr takes s_addr_c) -- stores, FScc,
// FSAVE and FMOVEM stores carry dst = src, which would read it twice.
wire fp_mi_dst = (i.cls == CL_FPU) && fp_mem_dst;
wire need_smi = (i.src.kind == EK_MEM) && (i.src.mi != MI_NONE) && !cm_use && !fp_mi_dst;
wire need_dmi = (i.dst.kind == EK_MEM) && (i.dst.mi != MI_NONE) && !cm_use &&
                !(i.cls == CL_FPU && !fp_mem_dst);
```

- [ ] **Step 3: The CL_FPU arm issues the pointer read** (in the step function; if `need_smi`, `dn_smi`, `cap`, `can_rd` or `rd_pend` are not in its scope, pass them in as the existing arguments are):
```verilog
			end else if (has_fpu && i.cls == CL_FPU) begin
				// the FPU request runs in P_FPU (M10.1(c)).  (FPU fixes P1) a
				// memory-indirect operand's pointer is read here first; P_FPU
				// starts once it is in (the gate at the P_FPU entry).
				if (nx.v && (nx.t == T_SMI || nx.t == T_DMI) && !cap && can_rd && !rd_pend) begin
					s.issue = 1'b1; s.it = nx.t; s.ia = nx.a; s.isz = nx.sz;
				end
```

- [ ] **Step 4: The P_FPU entry waits for it.** Replace `if (!fp_bg && !fp_pcap) begin` with:
```verilog
							if (!fp_bg && !fp_pcap &&
							    (!need_smi || dn_smi) && (!need_dmi || dn_dmi) &&
							    !(rd_pend && !rd_ack)) begin
```
(`fp_addr <= fp_mem_dst ? d_addr_c : s_addr_c` then carries the final EA.)

- [ ] **Step 5: Run.** `fpureal_mi` passes in all four fpr legs. `fpureal_p2` and `lc_mi_fmt4` still fail (not yet fixed). Every other leg passes. Then run the t_fpu program past test 241 (the leg in `run_pipe_tests.sh` that runs `tb/asm/t_fpu*`, or `tb/mk_tfpu.py`): it must get past §47 (test 241). Record the new stopping point, or "all" if it completes.

- [ ] **Step 6: Mutants (each must fail a named test; restore after each).**
  - P_FPU entry without the `dn_smi` term: `fpureal_mi` case 1 wrong or hung.
  - `need_smi` without `!fp_mi_dst`: the `readonce 00003104` line fails.
  - The CL_FPU arm's issue removed: hangs, caught by the `--cycles` bound.

- [ ] **Step 7: Commit** (submodule) with the before/after of `fpureal_mi` and the t_fpu stopping point.

---

### Task 3: N1: the LC040 format $4 frame stacks the operand's address

**Files:** Modify `rtl/ap040_ea_fetch.v`, the step function's CL_EXC arm (about line 1009).

- [ ] **Step 1: Wait for the pointer on a format $4 exception**
```verilog
			end else if (i.cls == CL_EXC) begin
				// (FPU fixes N1) a format $4 frame stacks the operand's
				// CALCULATED address (M68040UM A.5.1, p. A-6); through a memory-
				// indirect mode that needs the pointer read first.
				if (i.exc_fmt == 4'd4 && need_smi && !dn_smi) begin
					if (nx.v && nx.t == T_SMI && !cap && can_rd && !rd_pend) begin
						s.issue = 1'b1; s.it = nx.t; s.ia = nx.a; s.isz = nx.sz;
					end
				end else begin
					s.exc_go = 1'b1; s.ev = i.exc_vec; s.ef = i.exc_fmt;
					s.epc = i.exc_next ? i.next_pc : i.pc;
					s.eaddr = (i.exc_fmt == 4'd4) ? ((i.src.kind == EK_MEM) ? s_addr_c : 32'd0)
					                              : i.exc_addr;
				end
```
(Keep the existing comment lines; replace only the body. On the LC040 build, `need_dmi` for a store is suppressed only for CL_FPU. A CL_EXC store has dst = src, so waiting on `need_smi` alone reads the pointer once, and `next_rd` would offer T_DMI next, which this arm does not issue.)

- [ ] **Step 2: Run.** `lc_mi_fmt4` passes, including its `readonce` lines. The LC040 Kickstart leg: architectural trace identical (instruction count 2,288,738; the md5 recorded in PLAN.md STATUS). Everything else as after Task 2.

- [ ] **Step 3: Mutant.** Drop the wait (always `exc_go`): `lc_mi_fmt4` fails with EA `$3100`. Restore.

- [ ] **Step 4: Commit.**

---

### Task 4: P2b and P2: packed stores to An and Dn

**Files:** Modify `rtl/ap040_decode.v` (the opclass 011 reject block, about lines 1386-1402); `rtl/compat/ap040_fpu.v` only if Step 3 says so.

- [ ] **Step 1: P2b.** The format split applies to opclass 010 only:
```verilog
						if (x1[15:13] != 3'b010 || fp_op_hw(x1[6:0])) begin
							d.exc_fmt = 4'd0; d.exc_next = 1'b0;
```
Run: `fpureal_p2` cases 3-4 now give `$002C`. Cases 1-2 still fail.

- [ ] **Step 2: P2.** Before the reject block, send a packed store to Dn to the unit as an FP instruction:
```verilog
					// (FPU fixes P2, D22) FMOVE.P to Dn -- static (011) or dynamic
					// (111) k-factor -- is the unsupported DATA TYPE on a 68040:
					// vector 55, format $3, EA 0 (WinUAE fpp.cpp put_fp_value /
					// fp_unimp_datatype; the PRM calls Dn illegal, rule 2 wins)
					else if (x1[15:13] == 3'b011 && d.src.kind == EK_DREG && !fp_ireg &&
					         (x1[12:10] == 3'b011 || x1[12:10] == 3'b111)) begin
						d.cls = CL_FPU;
					end
```
Then drop the now-dead `x1[12:10] != 3'b011` term from the reject list, and the comment "(packed into a data register is the DATATYPE fault... keeps format $4 for now)". Keep whatever the other CL_FPU arms of the same opclass set (`reg_c` for the dynamic k-factor register, sizes); copy them from the memory-destination packed store's decode.

- [ ] **Step 3: Run `fpureal_p2`.** Expected: all four cases pass. If cases 1-2 now write D0 instead of trapping, the unit's packed-store unsupported-type check is keyed on a memory destination. Make it key on the format alone in `rtl/compat/ap040_fpu.v`'s opclass 011 path (find where the packed store to memory raises vector 55 via the $4160 BUSY frame, a8a50ce) and rerun. Also check that FSAVE right after the trap yields the $4160 BUSY frame with ETEMP = the source: add a case to `fpureal_p2` that does `fsave (a4)` in the handler before the `frestore`, and `m32` the frame's first longword `$41600000`.

- [ ] **Step 4: Full suite** (every leg pass, the LC040 Kickstart trace identical) and the t_fpu leg. **Mutants:** P2's arm removed → cases 1-2 fail; P2b's `x1[15:13] != 3'b010` removed → cases 3-4 fail.

- [ ] **Step 5: Commit** (submodule).

---

### Task 5: Integration, records, image

**Files:** Superproject: the `lib/AP68040-pipelined` pin, `findings/ap040-pipelined/PLAN.md` (STATUS M10 line, D19 ruling, D22 row), `findings/fpu-fixes/results.md` (new).

- [ ] **Step 1: SoC smoke.** In the superproject, `sim/ddr3_cpu` with the submodule at the new tip: `FREECORE=1 RUNTAG=fpu1 ./run.sh --ap040` and `FREECORE=1 RUNTAG=fpu2 ./run.sh --mmu`, one at a time, with `PIPELINED=1 PIPE_DIR=$ROOT/lib/AP68040-pipelined`. Expected: `2 passed, 0 failed`, and FC monitors quiet.

- [ ] **Step 2: Records.**
  - PLAN.md STATUS: M10's open items lose the memory-indirect EA.
  - D22: the packed-to-Dn case done.
  - D19: already recorded (Paul, 2026-09-26): format $3, following hardware (cputest v24) and WinUAE over UM 9.6.2's format $0. No RTL change.

- [ ] **Step 3: Build** (default FREE_CORE=1, MMU+FPU, no ILA): `AP040_PIPE_MMU=1 AP040_PIPE_FPU=1 $V -source tools/vivado/build_ap040.tcl -tclargs build/stage_fpu_fixes 0`. Record clk_38 / clk_114→clk_38 slack and LUTs in results.md. More than 16 failing endpoints: stop and report.

- [ ] **Step 4: Board (Paul):** a cold boot to Workbench **with the splash screen** (the boot check), SysInfo SPEED (1.00x expected, unchanged), and the FPU programs he uses (FPU mode: 68040.library/FPSP).

- [ ] **Step 5: Commit** the pin bump, PLAN.md and results.md on a superproject branch `fpu-fixes`; merge when Paul has boot-checked the image.

---

## Follow-ups (not in this plan)

- A bus-error-on-pointer test for FP instructions (needs a berr region in the FPU_REAL bench).
- A1/A2 (Adam's FP register file in memory, one shared normalizer): LUT savers, only if Q22 needs them. Measure routed.
- Offer D24 (our denormal ETEMP layout) upstream to Adam.
- The OSD HDMI slider: re-init the ADV7511 after each step so the delay takes effect live (Paul's report 2026-09-26).
