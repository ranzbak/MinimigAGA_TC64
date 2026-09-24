# cputest corpus replay for the pipelined AP68040 core (plan M0.4)

Replays WinUAE cputest slices from `../data040/` (DATA_VERSION 24) on
`ap040_pipe_core` from `~/work/fpga/Xilinx/artix7/AP68040-pipelined`
(`minimig-pipelined`), and checks what apolkosnik's reference-core driver
`tb_dat_replay.v` checks.

    run_replay.py              runner: per slice, replay_gen.py -> APR2 job -> bench; one line per slice + TOTAL
    tb_dat_replay_pipe.v       the bench (reads APR2 records, drives and checks the core)
    ap040_pipe_l1_replay.v     module ap040_pipe_l1 backed by the corpus memory regions,
                               compiled INSTEAD of rtl/ap040_pipe_l1.v

## Use

    ./run_replay.py --work /some/dir --preset m2                  # the M0.4 list (Basic, 63 instructions)
    ./run_replay.py --work /some/dir --preset m2extra             # the rest of what M2 implements
    ./run_replay.py --work /some/dir --instruction 'MOVE.*' --slice 0003
    ./run_replay.py --work /some/dir --instruction MOVE.L --slice 0001 --plusarg +dump=10 --plusarg +report=50
    ./run_replay.py --work /some/dir --instruction MOVE.L --slice 0001 --plusarg +mutate_reg=3   # must FAIL
    ./run_replay.py --work /some/dir ... --rtl /path/to/extracted/rtl   # a scratch/mutant copy of the core
    ./run_replay.py --work /some/dir ... --sim iverilog                 # same results, ~30x slower

`--work` is required; jobs, logs (`<work>/logs/<group>--<insn>--<slice>.log`),
unpacked corpus and builds go there. Without `--rtl` the runner snapshots the
committed tree (`git archive HEAD rtl`, read-only) into `<work>/snap-<hash>/`,
so an agent editing the working tree does not affect the run. A new commit
gives a new snapshot automatically.

`replay_gen.py` and `dat_parser.py` are imported from
`~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer/tests/ap040/diff/` (not
copied, not modified; bytecode writing is disabled).

Simulator: Verilator 5.020 (default) runs the core about 30x faster than
Icarus (the core alone does ~1,800 clocks/s under Icarus: a Basic slice takes
2 minutes instead of 4 s). Both were run on MOVE.L/0001 and gave identical
results (8,270 rounds, 0 failing, same 910 extra-write rounds before the
filter below was added).

## What one round does

1. Apply the record's setup patches and branch-target toggles to the model memory.
2. Reset. The boot overlay answers the reset reads: ISP = the record's ISP,
   PC = a stub at `$7F00_0000` (12 NOPs, then `JMP (xxx).L` to the round's PC).
3. When the first stub NOP retires, poke D0-D7, A0-A6, USP, ISP, MSP, SR, VBR
   (`$7F00_0400`, a synthetic table), SFC, DFC and CACR. The bench checks that
   no stage holds a non-stub instruction at that moment. As the native runner
   does, a supervisor-mode round first gets the 32-byte A7 image copied to ISP.
4. Run until the final micro-op of an exception entry is in WB
   (`exe_valid && exe_o.exc`), and sample the registers and SR on that clock's
   falling edge. The entry's frame stores are in memory by then, but its
   SP/SR write has not happened yet. This is the reference bench's S_EXC0
   snapshot. A normally completing test ends at the ILLEGAL the generator puts
   after it (vector 4).
5. Compare, the same way `tb_dat_replay.v` does:
   - vector (taken from the frame's format word)
   - D0-D7, A0-A6
   - A7, compared as USP, as the reference does
   - SR under the corpus mask
   - the frame bytes under their masks. In v24 even the normal vector-4 end
     carries a real frame oracle with the stacked PC.
   - every CT_MEMWRITE value

   Then restore those locations and apply the post/cleanup patches.

Extra check that the reference bench does not make: a port-W byte that
changes memory outside the CT_MEMWRITE list and outside the frame is an
"extra write". It is reported as a count, and becomes a mismatch with
`+strictwrites`. A byte rewritten with its own value does not count, because
the generator only records memory that changed.

Rounds that are **skipped**, and counted as unsupported rather than failed,
because the core has no such feature yet:
- trace: T1/T0 set in the input SR or in the masked expected SR, a trace
  record, or vector 9. This is about 3/4 of every slice, because the
  generator runs each test under S/T0/T1/M variants.
- bus error (vector 2)
- maintenance/"ignore exception" records. These are not run by the reference
  bench either.

**Interrupt and odd-vector rounds RUN since 2026-09-24** (they had been
skipped since M0.4 "because the core has no such feature yet", which stopped
being true with the M9 subset; the black-screen interrupt wedge of 2026-09-23
slipped through exactly this gap).  The core is built with `IRQ=1`, and a
round's level goes onto `ipl` when the stub's JMP is in EA-fetch, with the
two-sample synchronizer preloaded: the native runner writes INTREQ several
instructions before the tested one, so the level is settled by the time the
tested instruction's early operand read could go out (a JMP resolves in ID,
so the tested instruction can issue its early read one clock after the JMP
is in EA-fetch; asserting the pins any later let D17 legitimately defer the
interrupt past a memory-operand instruction -- 167 MOVE-to-CCR rounds).  An
odd-vector job points every synthetic vector from 4 up at its odd address, as
lib/AP68040's tb_dat_replay.v does.  In an interrupt or odd-vector round, an
exception entry whose vector is not the recorded one is passed over and the
round is captured at the recorded one (a privileged SR move in user mode
takes vector 8 and the pending interrupt at the handler's first boundary; an
interrupt's handler fetch at an odd vector takes the address error); a wrong
vector then shows as a timeout.  The passed-over frames count as extra writes.
Result at 629eab9/df947fe: IRQ 117/117 slices, 293,881 rounds, 0 failing
(was 18,352 run, 275,529 skipped); ODD_IRQ 8/8, 256 rounds, 0 failing (was
0 run); ODD_EXC 33/33, 163,980 rounds, 0 failing (was skipped).  Teeth: the
interrupt stacked PC mutated to the next instruction fails all 55 slices of
NOP/MV2SR/STOP (1,623 of 1,727 rounds); the pins asserted one clock late (the first version of this
change) failed 2,299/2,452 ANDSR.W rounds; `+mutate_reg=3` fails every
ODD_IRQ/ODD_EXC round.  Not observable here by construction: the new mask on
interrupt entry (the capture is the state BEFORE the entry's SR write) and a
level equal to the mask (the corpus has no such round) -- t_irq_pipe holds
both.

FPU state is not checked (the integer corpus has fpu_model 0).

Plusargs: `+limit=N +start=N +report=N` (mismatch lines), `+dump=N` (full
register dump of the first N failing rounds), `+trace_round=N` (per-clock
stage trace of record N), `+mutate_reg=K`, `+strictwrites`.

## Results (2026-09-22)

HEAD 997bb34 (M2), `--preset m2`: **360/360 slices pass**. That is 3,215,226
rounds run, 0 failing, 9,645,678 skipped as unsupported (trace), and 0 rounds
with extra writes. It took 39 min.

HEAD 2cf65d3 (after M3's d420808), `--preset m2all` plus shifts/rotates, bit
ops, MUL/DIV, BCD, PACK/UNPK, TAS, CAS, CHK/CHK2, TRAPcc/TRAPV:
**596/599 pass**. 4,843,130 rounds run, 16,400 failing. It took 69 min.
The three failures are all MOVEC2 (0001-0003), MOVEC Rc,Rn (`4e7a`) only:
- User mode, any selector the core does not accept (003-7FF): the core gives
  vector 4 (illegal), the corpus expects vector 8 (privilege violation).
  MOVEC is privileged, so the privilege check has to come before the
  selector check. This is a core bug. The reference core passes the same
  records (j198/j199, j264; its tb_dat_replay.v run on the same APR2 job,
  first 300 records, gives 291 rounds and 0 mismatches).
- Supervisor mode, TC/ITT0/ITT1/DTT0/DTT1 (003-007): the core raises
  illegal. The corpus expects the register value (0) and the following
  MOVE.L #0,D0 to execute. These are MMU registers, not implemented yet.

The check that the bench can fail, on HEAD 997bb34:
- `+mutate_reg=3`: every round fails
- an ALU mutant in a scratch copy, where MOVE/TST's N flag is inverted
  (`ap040_pipe_alu.v:149`, `~res_msb(am)`): MOVE.L/0001 fails 8270/8270
  rounds and TST.B/0001 fails 2440/2440. Both show SR and frame-SR
  mismatches.
- a store mutant, where `ap040_execute.v:129` sends `st_data = alu_result ^ 1`:
  MOVE.B/0002 fails 2058 rounds with "memory write" mismatches, and 47 rounds
  have extra writes.

Note on the reference tooling: `run_cputest.py`'s RTL list lacks
`rtl/ap040/ap040_bus_timeout.v` (the reference compat module needs it), so it
does not compile at Minimig-AGA_MiSTer 2b1f7a14. The cross-check above
compiled `tb_dat_replay.v` by hand with that file added.
