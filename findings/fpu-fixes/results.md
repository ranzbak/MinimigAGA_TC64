# FPU fixes: results (2026-09-26/27)

Plan: [plan.md](plan.md). Source of the findings: `doc/AP040_FPU_COMPARISON_20260926.md`
and our evaluation, [fpu-comparison-evaluation.md](../ap040-pipelined/fpu-comparison-evaluation.md).

## What changed (lib/AP68040-pipelined, branch `fpu-comparison-fixes`)

| Commit | Fix |
|---|---|
| 9dd9d41 | Red tests: `tb/pipe_asm/fpureal_mi`, `fpureal_p2`, `lc_mi_fmt4` |
| 2590de0 | **P1**: memory-indirect FP effective addresses execute. EA-fetch reads the pointer (once, also for stores) before the FPU phase |
| 6da2d88 | **N1**: LC040 format $4 frame stacks the operand's address through a pointer |
| b0f2311 | **P2**: FMOVE.P to Dn gives vector 55, format $3, EA 0. **P2b**: FMOVE.P to An gives the plain F-line |
| fa74901 | Final review I1: FP stores to a PC-relative destination (`(d16,PC)`, `([bd,PC])`) take the F-line instead of storing. The memory-indirect form was opened by P1; `(d16,PC)` was older. Test: `fpureal_p2` cases 6-7 |

D19 needed no RTL change (ruled format $3, 5513147).

## Sim

- `tb/run_pipe_tests.sh` with `AP040_REF`/`AP040_MAIN` set: **232/232**. The compat legs
  (t_integer, t_mmu, IRQ, cache, t_fpu_resume/frames) had not been running before, because the
  script's default `AP040_REF` path does not resolve from this checkout (see Open).
- Mutants, all caught:
  - P1: entry without the pointer wait, a store reading its pointer twice, no pointer issue.
  - P2: the new decode arm removed.
  - P2b: the gate removed.
  - N1: the pre-fix code was the red run.
- Kickstart 3.1.4 legs (`findings/ap040-pipelined/tests/kick`, with `PIPE_REPO` pointed at the
  submodule), both identical to the baseline:

  | Leg | Instructions | Cycles | Trace md5 |
  |---|---|---|---|
  | LC040 | 2,288,738 | 26,935,272 | 226dee9c... |
  | FPU | 2,289,114 | 26,939,749 | 0883f09d... |

- `sim/ddr3_cpu` with FREECORE=1: `--ap040` and `--mmu` each 2 passed, 0 failed. FC-4 stale
  acks 0.
- The reference `t_fpu.s` now runs past test 241 (tests 241-244 include an odd pointed-to word).
  It reaches its last section.

## Build and board

| Image | Content | clk_38 | clk_114 | clk_114→clk_38 | LUTs |
|---|---|---|---|---|---|
| `build/stage_fpu_p1` | P1 only | +0.359 | +0.046 | +1.106 | n/a |
| `build/stage_fpu_fixes` (md5 6398fc53...) | all | +0.603 | +0.409 | +0.738 | 45,884 (72.4 %) |

Both images show the known 16 clk_gen_sdram→clk_114 endpoints (-0.48 to -0.50 ns). Both were
built with IMPL_EFFORT=high, MMU+FPU and FREE_CORE=1.

Board results (Paul):

- `stage_fpu_p1`: boots, SysInfo SPEED 1.00x. `amiga_sw/FPUFixTest`: the P1 cases 7/7 PASS.
  P2/P2b show the old 402C/202C/202C, as expected.
- `stage_fpu_fixes`: boots to Workbench. FPUFixTest **10/10 PASS**.
- `stage_hdmi_rec` (md5 ca937d54..., all FPU fixes + I1 + the HDMI I2C change; clk_38 +0.048, clk_114
  +0.570, clk_114→clk_38 +0.352, the 16 SDRAM endpoints -0.489): FPUFixTest **12/12 PASS**, including the two
  I1 cases (PC-relative FP stores take the F-line, nothing written) (Paul, 2026-09-27).

## Final review

A fresh reviewer read the whole range and found:

- **Critical:** none.
- **Important:** one, I1 above. It is fixed test-first; the suite is 232/232 and the Kickstart
  traces are unchanged.
- **Minor, deferred:**
  - An FP instruction's pointer read goes out while a released FP operation is still running.
    An interrupt then waits for that operation (bounded), and a deferred FP exception would
    re-read the pointer on restart.
  - No tests yet for a pointer read that faults, for FRESTORE/FMOVEM through a pointer, or for
    an interrupt pending while an instruction waits for its pointer. All of these are correct by
    reading.

**The board image `stage_fpu_fixes` predates I1.** A PC-relative FP store is a malformed
encoding that no compiler emits, so the image is fine to keep testing. The next build carries
the fix.

## Open

- **t_fpu IRQ arrival sweep.** Its last section fires a level-2 interrupt while a released FDIV
  runs. There, the compat bench's latency monitor ("qualified level-2 request not taken at the
  next boundary", 16 instruction starts, pc $B7BE) trips. The section was never reached before
  P1, and an A/B on the pre-fix core was inconclusive. Next: cut the soak section into a
  standalone program and run it on 2c904dc and on b0f2311.
- **`tb/run_pipe_tests.sh` default `AP040_REF`** points at `../../MinimigAGA_TC64/lib/AP68040`,
  which only resolves for a sibling clone. From the submodule the compat legs are skipped, and
  so is the final verdict line. Fix it to find `../../AP68040` as well.
- **N1 on hardware** needs an `_lc040` image; not built.
