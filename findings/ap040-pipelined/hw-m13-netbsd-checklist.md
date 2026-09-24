# M13 -- NetBSD/amiga on the pipelined 68040: board checklist (PENDING BOARD)

Prepared 2026-09-24 by the executing agent; nothing here has been run.  M13's
entry (PLAN.md) is M12's Kickstart and MMU-tools lines passing, so this list
follows hw-m14-checklist.md and hw-gate2-checklist.md, on the same image
(`build/stage_ap040_pipe_m14b_fpu`, or `_lc040` for an FPU-less kernel test).
Paul deferred all board work until the plan is done.

## What simulation has covered for NetBSD's paths

- Access faults with the manual's write-back model (D13, D15, D16): a
  faulted store's WB1 is valid and the handler completes it, as NetBSD's
  `trap.c` `writeback()` does; MOVEM faults set CM and restart from the
  calculated EA.  (t_mmu.s through mk_tmmu.py, t_mmu_pipe.s,
  t_movem_restart.s.)
- The MMU walker, ATC, PTEST/PFLUSH and TTRs (M7; t_mmu*), and since M14 the
  read paths' ATC copies following PFLUSH (t_icache_pipe.s 10,
  t_dcache_pipe.s 8).
- The format $7 fetch-fault address is Q19's open point ($E58 here against
  the reference's $E5A): a NetBSD page fault on an instruction fetch reads
  FA -- if the kernel loops on one fetch fault, look there first.
- Interrupts, STOP, the M bit and trace (M9, M9.T); D23 (trace before
  interrupt at the same boundary) differs from WinUAE and the reference core:
  first suspect if single-stepping (ddb `s`) misbehaves.

## Stages (pass / fail, with the kernel version and image)

1. **loadbsd** (from AmigaDOS) loads the kernel and jumps to it: the screen
   changes to the kernel's console.
2. **The MMU comes on**: `pmap_bootstrap` completes -- the kernel prints its
   memory configuration past the copyright banner.
3. **Single user**: the root filesystem prompt (`Enter pathname of shell`).
4. **Multi user**: the login prompt.

## On a failure

A serial console capture (the kernel's messages) and the last PC; for a hang
before the console, an ILA capture needs an ILA image (the FPU image has no
room for one: Q9/Q22), so use the LC040 image with CPU040_DEBUG_ILA.  Every
failure is reproduced in simulation before it is fixed (PLAN 7.6): the
trace-harness programs under tb/, or a NetBSD-shaped fault sequence in
tb/mmu_asm/.
