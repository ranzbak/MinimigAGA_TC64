# Board check for M14 (split instruction and data read paths) -- PENDING BOARD

Prepared 2026-09-24 by the executing agent.  Nothing here has been run on the
board.  Paul deferred all board work until the plan is done; this is the list
for when he picks it up.  Load over JTAG only (volatile); never flash.

## The images

| image (integration worktree `../MinimigAGA_TC64-pipelined/build/`) | sources | configuration |
|---|---|---|
| `stage_ap040_pipe_m14b_fpu/minimig_openaars_top.bit` (md5 d8dbb7eb01d58aa43a898ccef2d7d86f) | AP68040-pipelined `minimig-pipelined` 629eab9 (the M14 merge; tree = 4fbc558) | MMU=1, FPU=1, no ILA, IMPL_EFFORT=high |
| `stage_ap040_pipe_m14b_lc040/minimig_openaars_top.bit` (md5 e70e194568f19375f980c26963ac6cb9) | the same | MMU=1, FPU=0 (the LC040 configuration), no ILA |

Both meet timing apart from the 16 known SDRAM input endpoints (clk_gen_sdram ->
clk_114, -0.487 / -0.474, present in every build since fix-12): FPU image 44,231
LUTs, 71.5 BRAM tiles; LC040 image 33,212 LUTs, 71.5 BRAM tiles.  Details in
PLAN.md (M14 log rows, Q22).  The
previous board image, `stage_ap040_pipe_timing_fpu_ctr` (pipe-timing 245fe84,
no M14), is the A/B reference: keep it next to these.

Both images carry the integration worktree's uncommitted video fix
(`rtl/openaars/adv7511/adv_ddr.v`, v3 centre alignment) exactly as the
previous image did.  No HDMI straight after a JTAG load is not a verdict:
power-cycle the board and retry the same .bit (vivado-lab-gotchas).

## What changed for the board

- Instruction fetches that hit the 040's I-cache are answered in one CPU clock
  without the shared memory port, also with the MMU translating (a copy of the
  instruction ATC).  Data reads that hit the D-cache likewise (a copy of the
  data ATC).  Misses, stores, I/O, chip-RAM fetches and anything cache-
  inhibited take the old path unchanged.
- Two core bugs this exposed are fixed (both latent before, both invisible on
  the old image's timing): an early operand read down a wrongly guessed branch
  path is no longer issued (it could clear a CIA ICR), and a late answer to one
  is never handed to the next instruction.

## Checks, in order (each: pass / fail + what was seen)

1. **Boot.**  Kickstart 3.1.4 (46.143) to Workbench from the usual disk.  Then
   the same with 47.111.  A hang: note where (OSD, black, insert-disk hand,
   Workbench partly drawn).
2. **SysInfo SPEED**, three runs, with the caches as they come up.  Record the
   A4000/040 ratio each time.  The simulation predicts, for SysInfo's own loop
   (PLAN M11.2 / M14; sim/ddr3_cpu with the loop in DDR3 fast RAM measures
   2,263 CPU clocks a pass, from 4,672): about **0.92x with the MMU off** and
   about **0.89x with 68040.library/MuForce translating**, against 0.33x on the
   previous image and 0.50x for the TG68K.  Also note: is 68040.library loaded, is MuForce or
   Enforcer running (that decides MMU on/off, and M11.2 left it as the open
   question behind the 0.33x).
3. **SysInfo with the data cache off** (its DCACHE gadget), then back on.  The
   number must drop a little and come back; a crash or garbage here points at
   the data read path's DE rule.
4. **cputest ct040_01_B-01** (passed on the previous image), then whichever
   further disks are to hand (M0.3's list).
5. **Self-modifying code / cache flushing**: a demo or game that patches its
   own code (plan 6.3's list), with turbo chip and turbo kick OFF first, then
   on.  A difference from the previous image here is an instruction-path
   coherency bug -- report the title and the symptom.
6. **Chip-RAM DMA coherency**: Way Too Rude (the D3 corruption test) with both
   turbos on -- the data read path now answers cached chip-RAM reads itself and
   relies on the snoop copy; any corruption is a data-path snoop bug.
7. **Frontier Elite II** for ten minutes (the 2^31-word freeze fix is in both
   images; the ~5-minute freeze was seen only on images without it).
8. **FPU image only**: AIBB Beachball (drew nothing before -- note whether
   68040.library is installed; without its FPSP the transcendental opcodes
   trap), and SysInfo's FPU MFLOPS figure.

## If something fails

Note the image, the step, the Kickstart, turbo settings, and whether
68040.library/MuForce were loaded.  The simulation reproductions to reach for:
tests/kick (the Kickstart bench; `KICK_ALLOW=1 sh build.sh pipeboard` runs the
ROM with every access cacheable, which is how both core bugs above were found),
tb/cache_asm/t_icache_pipe.s, t_dcache_pipe.s, t_specread_pipe.s,
t_earlydrop_pipe.s, and sim/ddr3_cpu via tests/perf/run_ddr3_perf.sh.

## Addition 2026-09-24: the FPSP (plan M10.10) -- needs a NEW FPU image

`stage_ap040_pipe_m14b_fpu` predates M10.10.  On it, 68040.library's FPSP
handles every UNIMPLEMENTED instruction correctly (FSIN, FETOX, FINT, FMOD,
FMOVECR ... -- the vector-11 path was already right in sim) but the first
UNSUPPORTED DATA TYPE -- a packed-decimal operand or a denormal -- ends in a
format error (vector 14), because that core could not FRESTORE the $4160 frame
the FPSP builds on its way out.  Build an FPU image from AP68040-pipelined
`minimig-pipelined` **9efe490** (AP040_PIPE_MMU=1 AP040_PIPE_FPU=1, as
m14b_fpu) before judging any of this; the LC040 image is unaffected (its trace
is bit-identical).

1. Install MMULib's `68040.library` (40.2) with `mmu.library` in LIBS: and
   reboot.  It must load (SysInfo/ShowConfig: 68040 with FPU; AttnFlags gains
   68881|68882 -- the library sets them when its FPSP is in).
2. AIBB **Beachball** in FPU mode: it must now draw.  If it still draws
   nothing with the new image, note whether step 1 held (no FPSP = every
   transcendental traps).
3. A packed/denormal smoke test: any program that prints floats through
   `printf("%e")`-style packed conversion (e.g. a small vbcc test printing
   `1.25e2` and `4e-320`) -- the output must be the value, not a crash or a
   software failure requester.
4. SysInfo's FPU MFLOPS figure, next to the m14b_fpu one.
If a Guru shows up: note the alert number (the FPSP calls Alert with $BF000002
on a frame it cannot parse) and the program.  The simulation reproduction is
tb/fpsp_asm/fpsp_lib.s (tb/mk_fpsp.py adds cases).
