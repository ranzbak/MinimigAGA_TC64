# Kickstart differential bench (reference AP68040 vs pipelined)

A real Kickstart ROM on each core's compat wrapper plus a behavioural Amiga,
one retire trace per core, compared order-independently of timing.
Not committed. The ROM is read by path (`$fread`), never copied.

| file | what |
|---|---|
| `kick_sys.sv` | the machine: 2 MB chip RAM, ROM at $F80000 with the OVL overlay, CIA-A/B (ports, timers A/B, TOD, ICR), custom-chip stub, unmapped = $FFFF; fixed wait states; device time on the "access" timebase (default) or the cycle timebase |
| `tb_kick.sv` | wrapper instance (`-DPIPE` selects the pipelined one), retire/exception/write/IO-read trace |
| `build.sh` | `sh build.sh [ref\|pipe\|both]` -> `obj_ref/Vtb_kick`, `obj_pipe/Vtb_kick` (Verilator 5.020, ~40 s each). The pipelined core is a `git archive` snapshot `snap-<rev>/` of `PIPE_REV` (default HEAD). `patched/ap040_mmu.v` is a mechanical Verilator workaround (two array declarations made packed; BLKLOOPINIT) |
| `run.sh` | `sh run.sh <rom> <tag> [+plusargs]`: both cores in parallel, then `compare.py` and `analyze.py` |
| `compare.py` | first divergence (pc, sr, d0-d7/a0-a7 per retired instruction), then a resynchronising walk over every divergent region; exceptions, bus writes (in order and per byte address), IO reads, interrupts taken out of STOP (`I` lines) and the floppy-register stream (CIA-B PRB, CIA-A PRA, DSK* and ADKCON, in bus order; `--floppy-log <file>` writes it out) |
| `analyze.py` | checkpoints: probe instructions (MOVEC/CINV/CPUSH/F-line/STOP/RESET), exceptions, ExecBase, RomTag init entries reached, final hot loop |
| `romdis.py` | capstone 68040 disassembly of the ROM by address |

Interrupts and the floppy (plan M9 subset, 2026-09-22): the stub raises
VERTB every frame, CIA-A/CIA-B timer and TOD flags through their ICR masks,
and BLIT on every BLTSIZE write, encodes Paula's level exactly as
`rtl/minimig/paula_intcontroller.v` does, and shows IPL to the CPU **only
while the core is in the STOP state**, with device time then running one
colour clock per clock.  Both cores therefore stop at the same architectural
point, run device time forward to the same event and take the same interrupt
with the same stacked PC -- the interrupt sequence is a function of the
program, not of either core's timing.  (An interrupt that would arrive on
hardware while the CPU runs is taken at the next STOP instead; exec idles in
STOP whenever no task is ready.)  `+irq=0` keeps the lines idle.

The floppy model covers what Kickstart touches before the first track read:
CIA-B PRB /STEP, DIR, /SIDE, /SEL0-3, /MTR; CIA-A PRA /CHNG, /WPRO, /TK0,
/RDY; DF0 present or not (`+disk=`), DF1-DF3 absent (their drive ID reads as
0), DF0's ID $FFFFFFFF (/RDY low whenever it is selected).  The run ends at
the first DSKLEN write with DMAEN set (trackdisk's first track read), which
is where the board takes over.

Plusargs: `+rom=` (required) `+trace=` `+maxinsn=` (5M) `+maxcycles=` `+stall=`
(200000 clocks without a retirement ends the run: STOP) `+regs=0` `+timebase=1`
(cycle) `+tpa=` (colour clocks per IO access, 16) `+slow=1` (512 KB at $C00000)
`+irq=0` (no interrupts) `+disk=0` (DF0 empty; default 1 = a disk in DF0).

Both wrappers: `AP040_HAS_MMU=0 AP040_HAS_FPU=0 AP040_ENABLE_CACHE=0
AP040_POST_STORES=0 AP040_FILL_CHANNEL=0 AP040_BUS16=1`, ipl from the stub,
ipl_autovector=1, berr=0, clkena_in = bus idle | ready.
