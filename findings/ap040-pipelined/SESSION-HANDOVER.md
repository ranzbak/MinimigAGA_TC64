# Session handover — 2026-09-23, evening

For the next Claude session. Written by the coordinating session, not by the
implementation agent. The agent's own state lives in `PLAN.md`'s STATUS block,
which is always more current than this file about milestones; this file carries
what STATUS does not: how the work is organised, what was ruled and by whom, and
the live board failure.

## Read first, in this order

1. `PLAN.md` — STATUS block, READ THIS FIRST, milestones, section 7 (when stuck
   + divergences D1-D23), section 8 (log), section 9 (open questions Q3-Q19).
2. This file.
3. `hw-gate1-checklist.md` and `hw-gate2-checklist.md` — what Paul runs on the board.

## THE LIVE PROBLEM: the core does not boot on hardware

Loaded `build/stage_ap040_pipe_m9se/minimig_openaars_top.bit` over JTAG
(device DONE=1, load fine). Paul's observations:

- OSD menu normal, **no error line** → the ROM loaded and the 832 released the
  CPU. Not the halted-by-design case.
- **Kickstart 3.2.1 = A1200 47.111**, file
  `/home/paul/work/amiga/Update3.2.2/ROMs/A1200.47.111.rom`.
  **Every sim so far used 3.1.4 (`kick.a1200.46.143`).**
- OSD Reset → video signal drops briefly, returns **black**.
- Stable black picture with the OSD drawable on top → video/scandoubler fine,
  chipset idle.
- His own (reference-core) image still boots → board and SD card healthy.

Ruled out already: controller firmware identical between trees (three generated
files, same md5); `TG68K.vhd` wires both cores through 70 ports with zero
differences; the 832 is not holding the CPU.

### UPDATE 2026-09-23 ~19:35 (next session): the hang is located

- 46.143 on the board: same black screen, so the failure is not specific to 47.111. DiagROM 1.3 RUNS on the image
  (68LC040, autoconfig of the Z2/Z3 boards works).
- Experiment 2 done: the real-SDRAM leg PASSES at 230ba47 (`run_pass_ap040_pipe_m9sesnap`).
- ILA image `build/stage_ap040_pipe_m9se_ila` (integration worktree; 230ba47 + ILA,
  MMU=1, depth 1024; failing timing = the known 16 SDRAM endpoints + 3 on the
  DDR3_INIT_DONE ILA probe bit only). `ila_boot_probe.tcl` capture
  `build/probe_m9se_ila/p1_now.csv`: PC frozen at **$FC5710** (the `rts` in
  timer.device right after `move.w #$C000,$DFF09A` = Enable()), zero bus
  cycles, flags 0, no RAM request pending, reset released. The leading hypothesis is a hang on
  interrupt entry when IPL goes up right after INTENA's master bit is set.
  (Third capture "write" fails at depth 1024: trigger position assumes 4096.)
- A bounded implementation agent was spawned to reproduce this in sim, fix it test-first, and
  report. No bitstream was built.
- **FIXED, 21:40: WORKBENCH BOOTS ON THE BOARD.** Root cause: `rtl/ap040_ea_fetch.v`
  `rd_req` was gated on `irq_take` in every phase, but the interrupt is only taken
  at P_START/P_STOP. So an instruction past P_START (the MOVEM restore after
  timer.device's Enable()+RTS) that still needed a read wedged forever. Fix
  **3af610f** on minimig-pipelined (`irq_blk = irq_take && ph==P_START`), test
  `tb/irq_asm/t_irqwedge_pipe.s` (205/205 legs green, the LC040 Kickstart leg is bit-identical).
  Image `build/stage_ap040_pipe_irqfix` (integration worktree; 3af610f,
  MMU=1, FPU=0, ILA on, high effort). Timing: clk_114 intra -0.059 on 9
  endpoints in the DDR3 fast-RAM cache (itram -> cpu_cacheline_hi CE), which is probably ILA
  congestion. Suspect it first if fast RAM misbehaves. The cross-clock failures are the ILA probe bit plus the known 16
  SDRAM endpoints. Paul: chip + fast RAM detected, Workbench up with 46.143.
  Next: an ILA-free gate image, then run hw-gate1-checklist.md.
- **VIDEO (not CPU), ~22:40:** the pipelined images corrupt colours (blue -> black, red -> white, OSD
  included) and then drop HDMI after 1-2 min; the reference build stage_ap040_rtlfix does not.
  Cause: Place 30-73 CRITICAL WARNINGs in BOTH trees. adv_ddr's clk_pixel_out/de_out/hsync_out
  never packed into IOBs (internal loads / merged regs), so the forwarded clock-to-data skew at
  the ADV7511 depends on placement. Fix in the integration worktree (UNCOMMITTED,
  rtl/openaars/adv7511/adv_ddr.v): pad-only DONT_TOUCH output regs + internal copies. iverilog
  shows it cycle-exact vs HEAD. Test build `build/stage_ap040_pipe_fpu_vid` (3af610f, MMU=1 FPU=1,
  NO ILA). Paul's checkout needs the same fix, since every image is affected; that's his call.
- **Video fix v2 (2026-09-24 ~01:00), loaded on the board for Paul's morning test:** pad registers
  are now pure one-clock copies of internal registers (a register that held its value needed feedback
  through fabric, which blocked packing). iverilog: identical to the original delayed one clk_148, over
  100k checks. `build/stage_ap040_pipe_fpu_vid2` (3af610f, MMU=1 FPU=1, no ILA, md5 1d85b986...):
  every ADV7511 pin register sits in OLOGIC (hsync via the synthesis replica `hsync_out_reg_rep`;
  the original stays in fabric because pal_to_ddr.sv:275 feeds o_hsync back into my60hzupsample, so
  the 60 Hz upsampler now sees hsync one clk_148 later). Timing: clk_38 +0.075, clk_114 +0.051,
  clk_148 +0.636, plus the known 16 SDRAM endpoints. Patch for Paul's checkout (not applied):
  `findings/ap040-pipelined/adv_ddr-iob-fix.patch` (`git apply --check` passes).
- Overnight: ILA image `build/stage_ap040_pipe_vid_ila` (video fix, MMU=1, FPU=0) for the Frontier
  capture; ila_boot_probe.tcl write capture fixed for 1024-deep ILAs (integration worktree,
  uncommitted); timing agent on worktree `AP68040-pipelined-timing`, branch `pipe-timing` (OOC only,
  its whole-design routed check is still to do).
- **Timing agent done (branch `pipe-timing`, worktree AP68040-pipelined-timing, 7 commits on
  3af610f, NOT merged).** It found **a real freeze bug, cc65d93**: IF compared a 32-bit issued-word
  count against PROG_WORDS (32'h7FFF_FFFF in the wrapper), so after 2^31-1 words the core stops
  for good (~6 min of non-STOP running). That is the prime suspect for the Frontier freeze
  (unproven on hardware). Every image so far has it. There are 5 pure-timing commits; OOC reg->reg
  improved -0.290 -> +0.451 ns at 26.446 ns. Suite 206/206, Kickstart legs bit-identical at every
  commit. See TIMING-LOG.md there. Routed whole-design judge build: `build/stage_ap040_pipe_timing_fpu`
  (MMU=1 FPU=1, no ILA, video fix); compare with fpu_vid2 (clk_38 +0.075).
  **Result, routed: clk_38 +2.020 ns (was +0.075), clk_114 +0.014, clk_148 +0.479, 43,196 LUTs
  (-196); video pins packed as before. LOADED on the board ~05:30 (md5 8933acfe...)**, replacing
  fpu_vid2, so the morning test covers the video fix, the freeze fix, and full MMU+FPU together.
  pipe-timing is still unmerged into minimig-pipelined: Paul's call after the board test.
- **2026-09-24 morning.** The v2 video fix (edge-aligned IOB outputs) got the colours right but still
  dropped HDMI after a few minutes. With 0xBA=0x00 (-1.2 ns, the minimum) the ADV7511 samples 1.2 ns before each
  transition against 1.0 ns hold, so the margin is ~0.2 ns. v3 "centre alignment": data/sync/DE leave half a
  clk_148 after the pixel clock (sample ~2.2 ns into each 6.7 ns word). iverilog: exactly v2
  shifted half a cycle, 0/100k mismatches. Image `build/stage_ap040_pipe_timing_fpu_ctr` (pipe-timing
  245fe84, MMU=1 FPU=1, no ILA): clk_38 +0.451 (placement variance; +2.020 in the previous run),
  clk_114 +0.254, clk_148 +0.378. LOADED. Paul: display still on, and **cputest ct040_01_B-01 PASSES on
  the pipelined core** (the first cputest disk on hardware). The patch in findings/ was refreshed to v3.
  NOTE: no HDMI right after a JTAG load can just need a board power cycle (see memory vivado-lab-gotchas).
- **CPU, open, parked until video is stable:** Frontier Elite II freezes after ~5 min on
  stage_ap040_pipe_irqfix. Standing rule first: retry with turbo chip/kick off. Then an ILA capture.

### The experiments in flight when the session ended

1. **Run Paul's own 47.111 ROM through the Kickstart differential bench**, both
   cores. Highest-value experiment: the exact binary that fails, with a full
   trace. Watch for: 47.111's newer exec probing, and that 3.2 ships an
   **extended ROM** the bench models as absent — establish what the SoC maps
   before reading anything into a fetch outside `$F80000-$FFFFFF`.
2. **`sim/ddr3_cpu` REALSDRAM leg at the image's own sources (230ba47) vs the
   tip.** The gate image was built from M9-subset-era sources, before the FPU
   and all of today's work. That leg (real `sdram_ctrl`, vendor SDRAM model,
   real `TG68K.vhd`) passes at the tip and had apparently never been run against
   230ba47. If it fails there, a rebuild from the tip is the fix.
3. **ILA on the CPU bus** if 1 and 2 leave no hypothesis. First question:
   does the core fetch the reset vector, fetch a few instructions and stop, or
   fetch nothing?
4. Asked of Paul, not blocking: try **3.1.4 on the board** — splits
   ROM-specific from board-specific in one test.

## 2026-09-24 afternoon: M14 boots on hardware (screen-free, ILA)

- `build/stage_ap040_pipe_m14b_lc040_ila` (minimig-pipelined 629eab9, MMU=1 FPU=0, CPU ILA only):
  `FASTRAM_ILA=0` (new env switch in build_ap040.tcl, uncommitted), because M14's block-RAM copies plus both ILAs
  = 279/270 RAMB18. Timing: clk_38 +0.445, clk_114 +0.273, clk_148 +0.446, plus the known 16 SDRAM endpoints and 3 on
  the ILA probe bit.
- Probe at 90 s: the IDE PIO sector-read loop in ROM (`$FB7FA4..`, reading `$DA2000`). At ~6.5 min: **idle
  in `STOP #$2000` at $F815CE** (the reference signature; ours reports the STOP's own address, the
  reference reports $F815D2), woken by the ROM interrupt server chain ($F8190E), and disk-loaded code in fast
  RAM ($4019CBFE) programming the beam registers. So it **booted to Workbench**. Hourly liveness probes are in
  build/probe_m14/l1..l6.
- Paul is away from the screen, so SysInfo/cputest/Frontier/Beachball are still pending (hw-m14-checklist.md).
  NetBSD (M13) was DROPPED FOR NOW by Paul: focus AmigaOS. An agent is doing the FPSP (68040.library) sim check,
  cputest interrupt rounds, and the $4160 frame.

- **~17:45: FPSP work merged (minimig-pipelined 9efe490, pushed to ranzbak main).** Suite 220/220; the real
  68040.library 40.2 FPSP runs 278 checks on the bench; $4160 BUSY frame + 4 more FPU fixes (D24/D25); cputest
  IRQ/ODD_IRQ/ODD_EXC rounds now run with 0 failures. Liveness l1..l6 (16:09-17:01): idle STOP, IRQ-woken, no freeze.
  **Board FPU image for the new checklist section: `build/stage_ap040_pipe_m14c_fpu`** (9efe490, MMU=1 FPU=1, no ILA,
  md5 efbc4ba8...): clk_38 +0.639, clk_114 +0.333, clk_148 +0.424, 45,391 LUTs (Q22 budget question), the known
  16 SDRAM endpoints only. NOT loaded (the ILA image stays on until Paul is at the screen). m14b_fpu is superseded
  (format error on packed/denormal).

- **ADV7511 clock delay sweep (evening, firmware only).** The artifacts along colour edges came from the sampling point.
  Firmware variants are in findings/ap040-pipelined/fw-ba-sweep/. Results: BA00 (-1.2 ns) artifacts, BA60 (0 ns) slightly
  fewer, **BAA0 (+0.8 ns): stable, now on the SD card**. The SD card's original firmware is kept as 832OSDAD.OLD on the card
  and as fw-ba-sweep/832OSDAD_SDCARD_BACKUP.bin. TODO: set `0xBA, 0xA0` in fw/ctrl_832/adv7511.c together with applying
  the adv_ddr.v patch to the main tree (the flash image still has the old placement-dependent video timing).
- **OPEN: mouse buttons fail "most of the time" with the OSD closed** (they work with the OSD open). Reported after the
  firmware swap. The cause is not split yet: firmware (rebuilt from the current checkout sources) vs m14c_fpu (M14 read paths;
  a suspect is a cached/stale read of CIA-A $BFE001 or POTGOR $DFF016). Test: the flash image with the BAA0 firmware.

## Backlog (after the plan is finished; Paul, 2026-09-24: "not too many changes at once")

- **Fix `rtl/ap040_pipe.qip`** in AP68040-pipelined: it only lists the early-milestone stages. It needs
  ap040_pipe_pkg.sv, ap040_pipe_bcu/l1/muldiv, and rtl/compat/*. The README (df947fe, pushed to
  ranzbak/AP68040-pipelined main) says it is out of date; update the README line once it's fixed.

- **Q12 (early acknowledge from the wrapper, TG68K.vhd / ap040_ram_seq.vhd).** Deferred by Paul until the
  plan completes. Q23 was ruled "keep STDONE_REG=1" (4fbc558: +2.7 % SysInfo MMU off, +0.7 % MMU on /
  Kickstart). Q12 is the way to win that clock back.

- **DDR3 fast RAM first.** Make AllocMem prefer the DDR3 Zorro III board (board 3, its own
  sequencer, fully decoupled from chipset/SDRAM contention) over the SDRAM-backed boards.
  Recommended: a small boot-time tool (Forbid; Remove the DDR3 MemHeader; raise ln_Pri;
  Enqueue; Permit) run from S:Startup-Sequence. Alternative: reorder the autoconfig chain so the
  DDR3 board configures first (RTL; first check what priority expansion.library gives each board).
  Measure first: SysInfo SPEED with OSD "Boards: DDR3 only" vs "all".
- Deferred board checks: display stability 10+ min on the v3 (centre-aligned) video image, Frontier
  Elite II past 6 min (cc65d93), AIBB Beachball in FPU mode (install 68040.library/FPSP first).

## How the work is organised

- **Implementation agent** (Opus, background) does all RTL, tests, sims and
  builds. The coordinating session rules on questions, sets order, and relays
  to Paul. **Restarting the session kills the running agent** — the next
  session must spawn a fresh one; `PLAN.md` plus this file is what it needs to
  read, and the agent prompts used here were: read PLAN.md fully, resume from
  STATUS, tests first with named mutants, close milestones only on their exit
  checks.
- Work branch `minimig-pipelined` in
  `/home/paul/work/fpga/Xilinx/artix7/AP68040-pipelined`, tip **e6127bf**, clean,
  **never pushed** (push disabled, keep it so).
- Integration worktree `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-pipelined`,
  branch `pipelined-integration`, tip **b965373**.
- Snapshot worktree `../AP68040-pipelined-snap` parked at **230ba47** = the gate
  image's sources. Leave it there so the image can be reproduced.
- Reference clone `/home/paul/work/fpga/Xilinx/artix7/AP68040-reference` (read-only);
  the *shipping* reference is `lib/AP68040` in Paul's checkout.
- **Paul's checkout is never touched** except files under
  `findings/ap040-pipelined/` (uncommitted; Paul commits them). The five
  always-dirty files are never staged.

## State of the work (sim side essentially complete)

M0-M8 done; M9 done including trace/M-bit; M10 (FPU) done bar deliberate gaps;
M11 measured. 204 bench legs green. cputest Basic 670/670 (5.2M rounds) plus six
more groups (439,688 rounds, zero failing). Throughput **0.799x / 0.804x** the
reference on two unrelated workloads = ~1.25x faster at the same clock.
Routed, FPU off: 32,113 LUTs, only the known SDRAM endpoints fail.
Routed, FPU on: 42,912 LUTs (67.7%), also clean, but only ~1,088 LUTs spare —
**an FPU image and an ILA cannot coexist**.

Standing check after every FP commit: the LC040 Kickstart leg is bit-identical
(2,288,738 instructions / 26,758,312 cycles) — nothing in the FPU work can move
what Paul loads.

## Rulings made by the coordinating session (Paul may overrule)

- **Q13/Q15/Q18** — the stop rule is tested against the **routed** build at
  `IMPL_EFFORT=high`; the out-of-context number is advisory. Two consecutive
  failures on the same endpoint family is the real signal, not one.
- **Q17** — build FSAVE/FRESTORE, but **every image stays `AP040_HAS_FPU=0`**
  until Paul explicitly asks for an FPU image. Measured since: with the FPU
  visible, 46.143 boots with zero unimplemented traps, so the FPSP is not a boot
  problem.
- **D23** (the agent's, on the manual's authority) — trace before interrupt at
  the same boundary, which **differs from both the reference core and WinUAE**.
  First thing to check if single-stepping or NetBSD's trap path misbehaves.

## Open for Paul

- **Q12** — may the wrapper acknowledge one `clk_114` cycle early? Touches
  `TG68K.vhd`/`ap040_ram_seq.vhd`, shared with the reference core.
- **Q14** — confirm `REDIR_REG=1` (0.13% more cycles, 388 LUTs, removes all CPU
  timing pressure). Currently on.
- **Q19** — format $7 fault address for a fetch bus error: aligned `$E58` here
  vs the reference's `$E5A`. His cputest AE/ODD_STK disks may answer it.
- **M14 split caches** — measured as justified on throughput (IF denied the
  shared port 19% of cycles) but unaffordable with an FPU. A consequence of
  which image he wants.
- **M0.3** — all 53 cputest ADFs are on his SD card; `ct040_01` passes on the
  reference core. 52 disks to go.

## Standing rules (do not relax)

Never `git push`. Never write the SPI flash — volatile JTAG loads only.
Video, OSD, ADFs, keyboard and power cycling are Paul's. RTG is judged only
after an Amiga **power cycle**. Sim legs strictly one at a time, always with
`RUNTAG`. Read `memory/sim-ddr3-cpu-bench-traps.md` before trusting
`sim/ddr3_cpu`, and `memory/vivado-lab-gotchas.md` before any lab run (note:
the libtinfo shim at `/home/paul/lib/tinfo5` points at `libtinfo.so.6` and works
anyway). Before blaming the core for a demo or game failure, retry with turbo
chip/kick off. Authority when sources disagree: M68040UM text, then a source
verified on real 040 hardware for that case, then the PRM, then other online
sources — look things up before asking Paul, and record every decision in the
divergences table.

## Cost

This session ran to roughly $6,400, mostly the implementation agents. Worth
saying plainly to Paul before another long unattended run.
