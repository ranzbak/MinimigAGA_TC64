# cputest on the board

## run1: stage_cu9, 2026-10-01, cputest040_log.hdf (all groups but FBASIC)

Image build/stage_cu9 (the flashed stable baseline: STORE_BUF FWD RAS PRECISE
SB_MMU, no copyback, no BTB). Booted from `adf/cputest040_log.hdf`, bare
shell, no MMULib. Log: `run1_cu9.log`. 846 instructions, no crash, about 2 h.

| group | ok | fail |
|---|---|---|
| basic | 154 | 27 |
| fpack | 0 | 14 |
| fint | 2 | 4 |
| fillg | 9 | 378 |
| ae | 11 | 1 |
| oddstk | 4 | 0 |
| oddirq | 0 | 4 |
| oddexc | 9 | 7 |
| irq | 29 | 0 |
| extdst | 6 | 0 |
| extsrc | 6 | 0 |
| default | 181 | 0 |

cputest stops an instruction at its first failure, so each line names one
cause only:

* **392: FPIAR not updated.** Every FPU instruction leaves FPIAR alone; the
  040 loads it with the instruction's address. This hides the FPU results
  themselves: rerun with `-nofpiar` (`adf/cputest040_fpu.hdf`).
* **40: no trace on change of flow (SR T0).** "Expected trace exception but got
  none" with T0=1: ANDSR/EORSR/ORSR/MV2SR, Bcc, BSR, JMP, JSR, DBcc, RTS/RTD/
  RTR/RTE, NOP, CAS/CAS2, MOVES, MVR2USP, FBcc, FDBcc; and in oddirq/oddexc
  EXT, SWAP, CHK, DIVS/DIVU(L), TRAPV with T0 set. fint/FMOVEM.X (an
  unexpected trace after `fmove.l d0,<no reg>` with T0=1) and ae/RTE (SR $2001
  instead of $0001 after RTE from a T0=1 state) are the same area.
* **1 real decode bug: FScc to (An)+.** `fsf (a6)+` advances A6 by 2 instead of
  1 and does not write the byte.

Everything else, including the whole integer BASIC set apart from the T0
cases (DIVU/DIVS, shifts, MUL, BCD, bitfields, MOVEM, ...), Default, IRQ and
the odd-stack/odd-exception groups, passes on the board.

The Verilator replay of BASIC (core 6b1d7ba) passes 670/670 slices but skips
75% of the rounds as unsupported; the board run covers those.

### Fixes (core branch `cputest-fixes`, 2026-10-01)

Each with a pipe_asm test that failed first in simulation, the way the board
did:

| # | finding | cause | fix | test |
|---|---|---|---|---|
| 1 | T0 trace missing (40) | a T0-only trace yielded to the NEXT instruction's exception (`tr_yield`, copied from the reference's `flow_t0_pend`); every cputest ends in an ILLEGAL | removed: T0, like T1, is taken at the boundary | `trace_t0_ill.s`; `trace_t0.s` case 7 now expects the trace |
| 2 | FScc to (An)+/-(An) | decode left the EA in src AND dst, so EA-calc stepped the register twice and the byte landed one step off | src cleared for FScc | `fpureal_fscc_ea.s` |
| 3 | FPIAR not loaded (392) | an opclass 010 instruction whose EA the 040 rejects (An, extended in Dn, ...) takes the F-line without engaging the unit, so nothing loaded FPIAR | new `id_t.fpiar_x`; EA-fetch writes FPIAR with the PC when that entry commits | `fpureal_fpiar.s` |
| 4 | trace after `fmove.l fpiar,d0` (fint/FMOVEM.X) | control-register moves to Dn/An were T0 sync points | only the move to MEMORY is (WinUAE) | `fpureal_t0_fcr.s` |
| 5 | ae/RTE: RTE (format $2 frame, restored SR $0001, odd PC $4ABA27) from SR $6000; we stack SR $2001, cputest expects $0001 (the frame is otherwise accepted: PC = the RTE, $200C, address $4ABA26) | **not a hardware oracle**: the generator (cputest.cpp, d2838c08 and still at WinUAE HEAD) records the 040 case's secondary SR in `test_exception_3_sr` and never uses it, so it stacks the restored SR. WinUAE's EMULATOR models a "weird 68040 bug" and stacks the SR from BEFORE the RTE ($6000 here, newcpu.cpp exception3_read_prefetch_68040bug, 2020); the M68040UM 1998 addendum (PLAN.md D26) gives restored SR with S set ($2001), which the core does | **unchanged**; Paul: follow real hardware -- which needs a run on a real 68040 to decide between $6000 and $2001 | – |

Next board run: `adf/cputest040_run2.hdf` (all groups but FBASIC, FPIAR
checked again, SerTest first) on the image with these fixes.

## run2 (stage_cf1, 435 failures of run1) and run3 (stage_cf2)

run2: 394/435 pass, every fix above confirmed on the board. Left over:

* **packed source in Dn (28)**, e.g. `fint.p d0,fp1`: fixed (core 504b663,
  `fpureal_dnpacked.s`). WinUAE's get_fp_value rejects Dn with .P as the plain
  F-line before it asks about the opmode.
* **empty FMOVEM.X list (1)**: fixed (core fea708a, `fpureal_fmovem_empty.s`),
  confirmed by run3.
* **trace + odd exception vectors (11, oddirq/oddexc)**: generator
  simplification, not a core bug. In this mode the runner points EVERY vector
  from 4 up at $123, the trace vector 9 included (main.c). The generator
  records a trace that meets the next instruction's exception as a stacked
  trace frame (`trace_store_pc`, "Trace stacked with other exception is
  handled later") and runs the ILLEGAL, whose odd vector 4 then gives the
  address error with PC field $10. It never applies the odd vector to the
  trace itself. A 68040 takes the trace first; its vector 9 is odd, so the
  address error belongs to the trace -- PC field $24, the vector offset, which
  is the generator's own convention (`regs.pc = original_exception * 4`) --
  and the ILLEGAL never runs. The core does exactly that.
* **ae/RTE (1)**: open, see the table above.

run3 used an FPU corpus generated with FPU_UNIMP=1 by mistake (WinUAE's
`fpu_no_unimplemented = true` IS the real 040 that traps to the FPSP; the
option turns that off), so its 184 FPU "frame mismatches" do not count.
Logs: `run2_cf1_fail1.log`, `run3_cf2_fail2.log`.

## run4 (stage_cf3, core 504b663): the 41 left after run2

29/41 pass: every packed-source case (28) and FMOVEM.X now pass on the
board. Left: the 11 trace + odd-vector cases (generator simplification,
pinned by `trace_oddvec.s`, core bd77429) and ae/RTE (open). Of run1's 435
failures, 423 are fixed or shown to be generator artefacts. Log:
`run4_cf3_fail3.log`.
