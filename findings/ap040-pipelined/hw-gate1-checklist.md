# Hardware gate 1 (plan M5, with the M9 interrupt subset) and the M0.3 cputest baseline

> **2026-09-24 update: the image to load is now the M14 image, see `hw-m14-checklist.md`** (`build/stage_ap040_pipe_m14b_fpu` or `_lc040` in the integration worktree).  The FPU-off rule below was overtaken by events: the coordinating session loaded FPU images (fpu_vid2, timing_fpu_ctr) for Paul's tests, Workbench booted and ct040_01 passed on `stage_ap040_pipe_timing_fpu_ctr`.  Both configurations are built for M14 so either can be used; this checklist's steps still apply to either.


> **Every gate and board image stays `AP040_HAS_FPU = 0` (the LC040 configuration) until Paul explicitly asks for an FPU image.**
> The pipelined core now executes a large part of the floating-point instruction
> set with `AP040_HAS_FPU = 1`, and that work is tested only in simulation.  An
> FPU image would make Kickstart's probe report an FPU, after which AmigaOS emits
> floating-point instructions and the first transcendental needs the FPSP that
> only 68040.library installs.  So the images in this checklist are built with the
> FPU OFF, exactly as every image so far, and the first FPU image is a separate,
> deliberate experiment (PLAN.md Q17, ruled by the coordinating session 2026-09-23).


Status 2026-09-23, after the M9 subset (interrupts, STOP, RESET) and the
timing work that followed it. Prepared by the executing agent; nothing here
has been run on the board.

Gate 2 (the same image, MMU on) is `hw-gate2-checklist.md`; the two gates now
run back to back on **one** bitstream, as Paul's Q8 (a) asked.

## 0. What Paul runs, in order

**If you only have ten minutes:** load the image section 2 names, leave DF0
empty, and see whether the insert-disk hand appears (section 3). That alone
settles gate 1's first line and tells me the core runs real Kickstart on real
hardware, which nothing in simulation can. Everything after it can wait.


1. **Kickstart reaches the insert-disk screen** (no disk in DF0).
2. **Insert a cputest ADF, boot to its CLI** (the disk's startup-sequence
   runs the tests by itself).
3. **cputest runs** and its output is compared with the reference core's.

Sections 3-5 say what to expect at each step and what to note when it fails.

## 1. Kickstart in simulation (done before the bitstream: the evidence)

Bench: `findings/ap040-pipelined/tests/kick/` (Verilator, one build per core;
`build.sh`, `run.sh <rom> <tag> [+plusargs]`, then `compare.py` / `analyze.py`).
The machine is 2 MB chip RAM, ROM at $F80000 with the reset overlay, CIAs with
timers/TOD/ICR, a custom-chip stub, Paula's interrupt encoder, and a floppy
model (CIA-B PRB select/motor/step/dir/side, CIA-A PRA /CHNG /WPRO /TK0 /RDY,
DF0 present or not, DF1-3 absent). Unmapped reads return $FFFF.

ROM (Paul's choice, read by path, never copied):
`/home/paul/work/amiga/Update3.1/ROMs/unsplit_unswapped/kick.a1200.46.143`
(Kickstart 3.1.4 A1200, exec 46.45).

Interrupts are made deterministic: the stub shows IPL to the CPU only while
the core is stopped, and then runs device time forward. Both cores therefore
stop at the same architectural point and take the same interrupt with the
same stacked PC, so the comparison is timing-independent.

### RESULTS (filled in by the run of 2026-09-22)

Two variants were run on ROM 3.1.4 (tag `d1` and `n1` in `tests/kick/runs/`):

**A disk in DF0** (`run.sh <rom> d1 +disk=1 +maxinsn=8000000`) -- both cores
reach **the first DSKLEN write with DMAEN set**, trackdisk's first track read,
which is where this bench stops:

| | reference | pipelined |
|---|---|---|
| instructions to that point | 2,289,114 | 2,288,738 |
| clocks | 33,496,750 | 26,724,115 (0.80x, the pipelined core is faster) |
| IO accesses / colour clocks / frames | 14,004 / 1,413,738 / 19 | identical |
| interrupts taken (out of STOP) | 45: level 2 x27, level 3 x18 | **identical, same order** |
| chipset reads (every CIA/custom read, in order and value) | 9,864 | **identical** |
| floppy-register accesses (CIA-B PRB, CIA-A PRA, DSK*, ADKCON) | 808 | **identical, in bus order** |
| DF0 state at the stop | cyl 0, motor on, /CHNG released | identical |
| INTENA / INTREQ / DMACON | 602E / 0040 / 02D0 | identical |

The floppy sequence in the trace is the real one: the drive-ID shift (/SEL0
toggled with the motor off, PRA read back), `DSKLEN=$4000` to disarm disk DMA,
the motor on, the step pulses in, /TK0 and /CHNG read after each step, then the
track read that ends the run.

**Instruction-level divergence**: one, and it is the known reference-core bug
D12.  (Re-run 2026-09-23 at core commit 458694e, with M10.0 in: identical in
every respect except that the pipelined core's vector 11 now carries the
MC68LC040's **format $4** frame with the next instruction's PC, which is what
the manual asks for -- see PLAN.md M10.0 and D18.)
At #437,293 the ROM probes for an FPU with `fsave -(a7)`; the reference
core (`AP040_HAS_FPU=0`) executes it and writes a NULL frame, so Kickstart sets
AttnFlags = $004F ("FPU present", wrong), while the pipelined core takes vector
11 and Kickstart sets $000F (right). **Every later divergence in the run starts
at a read of AttnFlags** (`move.w $128(a6),d0` at $F80756 / $FC090C, `tst.w
$128(a6)` at $F827B2): the two cores then run the FPU and the non-FPU arm of
the same routine, differ in what they push on the supervisor stack while they
are in it (the 1,168 differing write blocks are all in $1FFFAA..$1FFFC6 and in
the FSAVE frame at $3E8), and reconverge. Both cores end with the same A7
($11358), the same chipset state and the same stop point.

**No disk in DF0** (`run.sh <rom> n1 +disk=0 +maxinsn=4000000`): both cores run to
the 4,000,000-instruction budget in the insert-disk wait: 33 interrupts each
(level 2 x20, level 3 x13, same order), the chipset reads identical over the
common prefix (28,093 of them), the floppy-register stream identical (588
accesses: the drive-ID probe, then trackdisk stepping and polling /CHNG, which
stays low because the drive is empty), 30 frames on both, the same 177 hot PCs
in the last 20,000 instructions, and no DSKLEN-with-DMAEN write on either core
(nothing to read). Clocks: 56,460,158 reference vs 45,371,997 pipelined.



## 2. The bitstream candidate

- Worktree `../MinimigAGA_TC64-pipelined`, branch `pipelined-integration`.
- Build (MMU on, FPU off, **no CPU ILA**):
  `AP040_PIPE_DIR=../AP68040-pipelined-snap AP040_PIPE_MMU=1 vivado -mode batch -source tools/vivado/build_ap040.tcl -tclargs build/<stage> 0 $PWD 1 30 1024`
  Add `IMPL_EFFORT=high` to that environment for a higher-effort run (place
  ExtraTimingOpt, phys_opt/route/post-route AggressiveExplore; worktree commit
  cb135fb). `../AP68040-pipelined-snap` is a detached worktree of the core
  repo: `git -C ../AP68040-pipelined-snap checkout <sha>` picks the sources.
  Both gate images below are built from **230ba47**.
- **LOAD THIS: `build/stage_ap040_pipe_m9se/minimig_openaars_top.bit`**
  (built 2026-09-23 02:03 from core commit 230ba47 with `IMPL_EFFORT=high`;
  md5 `85938c2a83e0b9828175c88f13378dce`, 3,825,905 bytes -- worth checking,
  because several other builds have come and gone in that tree since).
  It is **clean by the bar below**: WNS -0.474, TNS -5.558, **16 failing
  endpoints and all 16 are the SDRAM path every reference build has**.
  Everything else meets: clk_38 intra +0.129 ns, clk_114 -> clk_38 exactly
  0.000 with nothing failing, clk_114 intra +0.610, clk_148 +0.366.
  31,298 LUTs (49.4 % of the part), 59.5 RAMB36 tiles.
  Nothing else in the table below may be loaded.

### Do NOT load any of these

Every one of them misses timing on CPU paths. The number is the whole design's
WNS / number of failing endpoints.

| build folder | WNS | failing endpoints | why |
|---|---|---|---|
| `stage_ap040_pipe_m5` | -1.212 | 537 | M5 sources, before any timing work |
| `stage_ap040_pipe_m7` | -0.857 | 284 | ack -> WB store hold -> EX redirect -> IF |
| `stage_ap040_pipe_m7b` | -0.641 | 345 | same family, partly cut |
| `stage_ap040_pipe_m7c` | -1.465 | 512 | worse variant |
| `stage_ap040_pipe_m7e` | -0.729 | 318 | the ILA-ON build of the M7 sources (PLAN.md Q9) |
| `stage_ap040_pipe_m9s` | -0.483 | 196 | M9 subset: 180 new CPU endpoints (the interrupt headed EA-fetch's priority chain) |
| `stage_ap040_pipe_m9sb` | -1.307 | 626 | the first attempt at fixing that, much worse |
| `stage_ap040_pipe_m9sc` | -0.452 | 22 | close: 16 SDRAM + 6 new CPU endpoints at -0.075 / -0.052 / -0.014 ns. The best image built so far, but not clean |
| `stage_ap040_pipe_m9sc` (superseded by m9se) | -0.452 | 22 | the same sources at the default effort: the 16 plus 6 new CPU endpoints. m9se is the one to load |
| `stage_ap040_pipe_m9sd` | -0.495 | 182 | the attempt to fix m9sc's worst path (IF's fetch PC) made it far worse: 165 endpoints on clk_114 -> clk_38 and 40 inside clk_38 |

`stage_ap040_pipe_m7d` (-0.479, 16 endpoints) is timing-clean but is the
PRE-M9 build: it has no interrupts, so Kickstart cannot get past its first
`STOP #$2000`. Do not use it for these gates either.

### The bar, and the verdict

The only timing exception any candidate is allowed is the long-standing
`clk_gen_sdram -> clk_114` SDRAM output path: exactly **16 failing endpoints
at about -0.45..-0.60 ns**, which every reference build shows too
(`stage_ap040_e2t4b` -0.552, `stage_ap040_e2t4d` -0.479,
`stage_ap040_e2t5b` -0.479, `stage_ap040_e4a` -0.600 -- each with those 16 and
nothing else). Anything beyond those 16 is a CPU path and the image is
rejected.

`report_timing_summary` prints only the worst path per clock group, so a
verdict on more than four failing endpoints is written from
`tests/synth/failing_paths.tcl`, which opens the routed checkpoint and lists
every failing path. The routed checkpoint lives at
`project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp` and the NEXT
build overwrites it -- copy it next to the build's reports if the listing may
be wanted later.

No CPU ILA in the candidate: a failure is diagnosed with the reference core's
ILA build (PLAN.md Q9).

## 3. Step 1 -- Kickstart to the insert-disk screen

Settings: Kickstart 3.1 (or 3.1.4), 4 MB or more fast RAM, CPU 68040, IDE off,
turbo chip RAM and turbo Kickstart **off** (standing rule), DF0 empty.

What you should see:

1. A black screen for a few seconds while the ROM checksums itself and sizes
   memory, then the grey/blue early screen.
2. The insert-disk (hand holding a floppy) animation, with the screen
   flipping between the two hand frames about once a second.
3. The floppy motor clicks once at the start (the drive-ID probe and the seek
   to track 0) and then stays quiet.

Wait **five minutes** before calling it dead (bench-traps note: the reference
core needs ~110 s to Workbench on this board).

If it fails, note:
- the screen colour when it stops (black = never got out of the ROM's early
  init; red = a Guru before the display is up; grey = it reached the display
  but hung; green/yellow = memory or ROM checksum);
- whether the power LED flashes (the Amiga's Alert blink code) and how often;
- any Guru / Alert number on screen (`8000 000x` = a CPU exception, the second
  longword is the PC);
- whether the drive clicks at all (no click = the CIA-B PRB writes never
  arrive; continuous clicking = trackdisk keeps re-stepping, which means
  /TK0 or /CHNG is read wrong).

## 4. Step 2 -- boot a cputest ADF to its CLI

Disks: `findings/ap040-pipelined/tests/cputest/adf/ct040_*.adf` (53 bootable
FFS disks, `build_adfs.py` makes them). Start with `ct040_35_OS-01.adf`
(ODD_STK, the shortest).

1. Insert the ADF in DF0 through the OSD and reset.
2. The insert-disk screen goes away, the drive reads for a few seconds, and
   the CLI window opens with `=== cputest disk OS-01 (35/53) ...`.

If it fails, note: the screen at the moment it stops, the Guru/Alert number,
and whether the drive kept reading (a read that never ends is a DMA or
interrupt problem, not a CPU one). "Not a DOS disk" means the boot block read
wrong data -- record it, it is a real regression.

## 5. Step 3 -- cputest runs

Each disk's `s/startup-sequence` runs `:cputest <group>/all -continue -68040`.

- A pass ends each instruction with `All tests complete (total N).`:

  ```
  BSR.B (oddstk):
  BSR.B/0000.dat (oddstk). 0...
  3360 (2/2/0) S=0 E03=3360/0/0
  All tests complete (total 3360).
  ```

- A failure prints a disassembly, a reason line, the registers before and
  after, then the count line, and no "All tests complete". Reason lines:
  `Dn: expected X but got Y`, `SR: expected a -> b but got c`,
  `Exception N stack frame mismatch:`, `Memory long write: ...`,
  `Got unexpected exception N`.
- Fatal: `Couldn't allocate tmem area` (no fast RAM), `Invalid test data file`
  (wrong DATA_VERSION), `Mismatched CPU model`.

Order: the **reference** core first (the M0.3 baseline), then the pipelined
image on the same disks. **Baseline so far (Paul, 2026-09-22): `ct040_01`
(B-01) passes completely on the current non-pipelined reference core. 52 disks
to go.** So the useful order now is: run a disk on the pipelined image only
after the reference core has been through it, and start with `ct040_01`, the
one disk whose reference result is already known. An instruction that passes on the
reference core and fails on the pipelined one is a regression: note the disk,
the instruction and the reason line.

Disk contents:

| disks | contents |
|---|---|
| ct040_01 .. 30 | Basic: 155 of its 181 instructions |
| ct040_31 .. 34 | AE |
| ct040_35 | ODD_STK |
| ct040_36 | ODD_IRQ |
| ct040_37 .. 39 | ODD_EXC |
| ct040_40 .. 41 | IRQ |
| ct040_42 .. 47 | EXTDST |
| ct040_48 .. 53 | EXTSRC |

The 26 largest Basic instructions and the Default group are on
`cputest040_all.hdf` only (IDE master): MOVE.B/W/L, ADD/SUB/AND/OR/EOR .B/W/L,
Bcc.B/W/L, DBcc.W, Scc.B, BCHG.B, STOP, TRAPcc.

Expectations for the pipelined core, after the M9 subset:
- the STOP and RESET instructions now exist, so the Basic STOP/RESET groups
  (the ones that failed in the M3/M4 sim replay) should pass;
- the IRQ and ODD_IRQ groups exercise interrupt timing the sim replay cannot
  run at all -- they are the first real test of the interrupt subset;
- trace (T0/T1) and the M-bit throwaway frame are still M9 proper: any slice
  that needs them fails on the pipelined core and that is expected. Record it
  rather than treating it as a regression.

To repeat one instruction alone: `:cputest <group>/<insn> -68040`.
