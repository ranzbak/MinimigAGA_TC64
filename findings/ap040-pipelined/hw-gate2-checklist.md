# Hardware gate 2 (plan M7): the pipelined core with the MMU

> **2026-09-24 update: the image to load is now the M14 image, see `hw-m14-checklist.md`** (`build/stage_ap040_pipe_m14b_fpu` or `_lc040` in the integration worktree).  The FPU-off rule below was overtaken by events: the coordinating session loaded FPU images (fpu_vid2, timing_fpu_ctr) for Paul's tests, Workbench booted and ct040_01 passed on `stage_ap040_pipe_timing_fpu_ctr`.  Both configurations are built for M14 so either can be used; this checklist's steps still apply to either.


> **Every gate and board image stays `AP040_HAS_FPU = 0` (the LC040 configuration) until Paul explicitly asks for an FPU image.**
> The pipelined core now executes a large part of the floating-point instruction
> set with `AP040_HAS_FPU = 1`, and that work is tested only in simulation.  An
> FPU image would make Kickstart's probe report an FPU, after which AmigaOS emits
> floating-point instructions and the first transcendental needs the FPSP that
> only 68040.library installs.  So the images in this checklist are built with the
> FPU OFF, exactly as every image so far, and the first FPU image is a separate,
> deliberate experiment (PLAN.md Q17, ruled by the coordinating session 2026-09-23).


Status 2026-09-23. Prepared by the executing agent. Nothing here has been run on the board.

Since the 2026-09-22 version: the M9 interrupt subset and M8 landed, M10.0 gave
the LC040 its format $4 frame, and the suite is 160 legs green at commit
6ffd224. Nothing in this checklist changed; only which bitstream to load did,
and that is in `hw-gate1-checklist.md` section 2.

## 0. What this gate is now

Gate 2 is the same bitstream as gate 1 (MMU on, FPU off, no CPU ILA): Paul's
Q8 (a) pulled the M9 interrupt subset forward, so Kickstart boots on the
pipelined core and both gates run back to back on one image. Do gate 1
(`hw-gate1-checklist.md`: insert-disk screen, a cputest ADF to its CLI,
cputest runs) first; this checklist is what you do afterwards, with the same
image, to exercise the MMU.

## 1. Evidence in simulation

**Wrapper bench** (`tb/run_pipe_tests.sh`, pipelined 5c95c97). This bench is `tb_ap040_pipe_compat.v`: the lifted MMU, cache and 16-bit adapter. It runs every test in 3 bus phases.

| program | result |
|---|---|
| `t_mmu.s` via `tb/mk_tmmu.py` | pass |
| `t_bitfield_mmu.s` (lib/AP68040) | pass |
| `mmu_asm/t_mmu_pipe.s` (new) | pass |
| `t_movem_restart.s` (apolkosnik main) via `tb/mk_tmovem.py` | pass |

`mk_tmmu.py` makes three changes to `t_mmu.s`:
- the handler completes WB1 (D13/D16);
- the handler skips the EA = FA check when CM is set (D15);
- the interrupt sweeps and STOP are left out (M9).

`mk_tmovem.py` leaves out case 7, which needs interrupts.

**`sim/ddr3_cpu`**, PIPELINED=1, pipelined commit 5c95c97:

| leg | result |
|---|---|
| `--ap040` | pass |
| `--mmu` | pass |
| `--mmumutant` | fails, as required (run at a9ecd20) |
| `--ackmutant` | fails, as required |
| `--chipbus` | pass (run at a9ecd20 and b210f0e) |


With the M9 subset (pipelined 5054375, 0bbab45) the MMU programs run with
their interrupt sweeps in: `t_mmu_m9s` (mk_tmmu.py, the IRQ-vs-MMU sweeps back
in), `t_movem_restart_m9s` (case 7: an interrupt behind a CM restart) and
`texc_m9s` all pass at all three bus phases, and `irq_asm/t_irq_pipe.s` (39
checks) passes.

**Known gaps** (the lifted lib/AP68040 MMU fails them the same way):
- apolkosnik main's `t_atcprobe.s` fails at test 2. It needs negative ATC entries, which that MMU does not have.
- Convergence with apolkosnik main is deferred.

## 2. The bitstream candidate

It is the SAME image as gate 1: `hw-gate1-checklist.md` section 2 has the
build command, the candidate, the timing bar it has to clear and the table of
images that must not be loaded (`m5`, `m7`, `m7b`, `m7c`, `m7e`, `m9s`,
`m9sb`, `m9sc`; and `m7d`, which is timing-clean but predates interrupts, so
Kickstart cannot leave its first `STOP #$2000` on it).

## 2a. Order on the board

Gate 1's three steps first (Kickstart to the insert-disk screen; a cputest ADF
to its CLI; cputest runs), then this gate's steps 1-3 below on the same image.
There is no reload in between.

## 3. Board steps (once Q8 is settled)

1. **Reference first.** Load the reference AP040 bitstream with the MMU. Run Kickstart 3.1, SetPatch and 68040.library, then Enforcer and MuForce, then WHDLoad Trolls AGA with NOEXPCHIP (`findings/compatibility/whdload-notes.md`). This is the baseline.
2. **Pipelined core.** Load the pipelined gate-2 bitstream and repeat step 1. The checks:
   - 68040.library reports the MMU.
   - Enforcer and MuForce report a hit for a deliberate `move.l 0,d0`. The hit report shows a `$7008` frame.
   - The WHDLoad title runs.
3. **If it fails**, record what the screen shows and the CPU ILA capture (depth 1024). A pipelined-only failure is a regression.
