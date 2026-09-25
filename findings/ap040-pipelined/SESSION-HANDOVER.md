# Session handover — last updated 2026-09-25 (end of the 09-24/25 session)

For the next Claude session. Written by the coordinating session, not by the
implementation agent. The agent's own state lives in `PLAN.md`'s STATUS block,
which is always more current than this file about milestones; this file carries
what STATUS does not: how the work is organised, what was ruled and by whom, and
the live board failure.

## START HERE — state at the end of the 2026-09-24/25 session (supersedes the older sections below)

The core boots and runs (Workbench, cputest 2 h clean, Frontier all night, SysInfo 0.83x
A4000/040-25 with all boards, 0.88x with "DDR3 only"). The "live problem" sections further down are
history. Everything open is in **Backlog** below; the items of this session are at its end.

- **Layout (since session end 2026-09-25): the MAIN checkout `MinimigAGA_TC64` is on
  `5.0-040-pipelined`**, HEAD 7edc896, all four submodules at their pins (incl. the new
  lib/AP68040-pipelined @ 9efe490). The firmware builds right there (`make` in fw/ctrl_832; the
  built 832 toolchain is in EightThirtyTwo/). The old integration worktree
  `../MinimigAGA_TC64-pipelined` is DETACHED at 7edc896 and kept only for its `build/` directory
  (every bitstream named below lives there). Build new bitstreams from the main checkout, or
  `git -C ../MinimigAGA_TC64-pipelined switch --detach <commit>` for an isolated build.
- **NOT pushed yet (9 commits on 5.0-040-pipelined; the last is this handover commit):** 6858351 (RTG sync), c847d98 (README),
  829167b (submodules), ba33a57 + 70724bc (docs), 10a11c3 (m68020 always true), 3862d0e (OSD
  memory-reset prompt), 7edc896 (OSD HDMI clock-delay page). Push only when Paul says so, then a
  real `git clone --recursive` test from GitHub.
- **HDMI clock delay: DONE (7edc896).** OSD Settings -> "HDMI" page steps ADV7511 0xBA from -1.2
  to +1.6 ns, live, with a read-back of the chip's value; saved in the config file's former padding
  byte (file stays 212 bytes). Paul stepped it on the board: **-1.2 ns (0x00) is the ONLY
  glitch-free value** -> new default. Binary: fw-fixes/832OSDAD_HDMISLIDER3.bin. Follow-up: clean
  only at the END of the range means the eye centre lies beyond it; move the data ~1 ns on the RTL
  side (adv_ddr.v launch edge/phase) so the centre lands mid-range. Also: the RTL's own I2C master
  (i2c_sender.vhd, same bus, no arbitration) re-sends its whole table on every dv_int edge -- now
  that the firmware owns hot-plug, consider removing that re-send.
- **On the board (JTAG):** `build/stage_ap040_pipe_m14f_fpu_ila` (full core, FPU, ILA, Zorro
  III/Toccata autoconfig fix). Its RTL = 5.0-040-pipelined minus the firmware-only commits.
- **A/B images for the intermittent SysInfo slow run** (Backlog "OPEN, intermittent"):
  `build/stage_ap040_rtlfix` (reference core), `build/stage_ap040_pipe_exp_ciarev` (branch
  exp/cia-revert bf21509, CIA timers before 15d132a/6e6ec15; timing normal: only the known 16
  clk_gen_sdram→clk_114 at -0.498 and the 3 ILA DDR3_INIT_DONE at -3.953). ILA scripts:
  `ila-scripts/ila_hang.tcl` (now x3, busy, CIA ICR traps), `ila-scripts/ila_cia.tcl`.
- **Programming:** `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado
  -mode batch -nolog -nojournal -source tools/vivado/program.tcl -tclargs <dir>/minimig_openaars_top.bit`
  (bitstream dirs under ../MinimigAGA_TC64-pipelined/build/).
- **New backlog items this session:** OSD open at boot; only ~10 MB fast RAM shown with "DDR3
  only"; RTG broken with "DDR3 only" (fetcher reads SDRAM only); longword per chip slot so turbo can
  go (demos break with turbo); SysInfo intermittent slow run.

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

- **Investigate apolkosnik's optimized pipelined 040 core (Paul, 2026-09-25)**:
  https://github.com/apolkosnik/Minimig-AGA_MiSTer/tree/ap040-pipelined. We may want to borrow some of its
  optimizations. First step: diff its core and wrapper against lib/AP68040-pipelined (9efe490) and our
  rtl/soc/TG68K.vhd, list each optimization (what, where, measured gain if the branch states one), and rate each for
  fit with our M14 split caches, the FPU, the 1:3 clk_38 island and the timing budget. Then give Paul the shortlist.
  Adopt nothing unilaterally: memory `ap040-reference-integration` records that convergence with apolkosnik's branches
  was DEFERRED, and our submodule is a hand overlay 1300+ lines away from upstream main.

- **OPEN (Paul, 2026-09-25): the OSD is open at boot, also right after loading a new bitstream** (so not only after
  an Amiga reset). It was already reported 2026-09-24 and NOT resolved: the input-diagnostic agent ruled out
  RTL/firmware tree mismatch and found no RTL cause (the only KEY_MENU queued at configuration is the first queue
  event, which the firmware drops in MENU_NONE1). Its diagnostic firmware (fw-fixes/832OSDAD_BAA0_INDIAG.bin) shows
  in Chipset line 7 WHY the OSD first opened (`k<code>@<pass>` key event, `b..` board button, `e<mask>` error) —
  never read out on the board yet. Also check whether it opens because of a boot error (the firmware opens the OSD
  on errors, e.g. no ROM/SD/config issues) or because of joystick-2 KEY_MENU from the MCP23S17 expander.

- **Toccata independent of FAST=Maximum (Paul, 2026-09-25).** In minimig_autoconfig.v the Toccata (ac 3'b101) is only
  reached through the Zorro III part of the chain, and the chain only enters that part when fastram_config is 11
  ("Maximum"). Add a path from the Zorro II board (3'b000) to the Toccata when Zorro III is not offered, and keep
  sim/autoconfig's table in step (it has the rows for this).
- **Is the m68020 input still worth keeping? (Paul, 2026-09-25)** Since 10a11c3, an AP68040 build ties it true
  (`cpu_config[1] | CORE_CAPS[0]`). With only the 68040 left, consider removing the input and the CPU-field
  dependency altogether. Check first whether anything else still reads cpu_config[1] (turbo chip/kick use
  cpu_config[2]/[3]), what the OSD and firmware do with config.cpu on a fixed 040, and whether the reference core
  (AP040_PIPE_DIR=none) or any TG68K build still needs it. This ties in with the TG68K-removal item.

- **Remove the TG68K name from the source tree (Paul, 2026-09-25): the TG68K core is no longer used.** Scope to
  map first: the rtl/tg68k submodule (TobiFlex/TG68K.C), the wrapper rtl/soc/TG68K.vhd (it now wraps the AP68040
  cores: entity/file name, the generics, the g_tg68k generate), the tg68_* signal names in minimig_virtual_top.v /
  minimig_openaars_top.v / minimig.v, the ILA probe names (probe files / .ltx and tools/vivado/*.tcl filter on
  *tg68_adr*, *tg68_dat_in*, ...), build_ap040.tcl / project file lists, sim benches, and docs. Do it as a
  mechanical rename in its own commit(s), with one full build + board boot to prove no behaviour change. Update
  the ILA scripts' probe filters in the same change or they silently match nothing.
- **Submodules (done 2026-09-25, 829167b, NOT pushed yet):** HTTPS URLs; lib/AP68040 now comes from
  ranzbak/AP68040-pipelined branch `ap68040-reference` (530fc72; e2-fixes had never been pushed, so `clone
  --recursive` failed with "not our ref"). A fresh recursive clone over HTTPS was verified: all four submodules land
  on their pinned commits.

- **OPEN (Paul, 2026-09-25): HDMI does not come back after the display has been off for a while.** The CPU keeps
  running (disk LED active), and Shift+'.' (the firmware's manual ADV7511 re-init) does not restore the picture.
  Relevant history in fw/ctrl_832: a8f5174 "HDMI comes back by itself when the monitor is switched on again", e4d8fce
  (a failed status read records the sink as gone), 37425ca (bounded I2C write wait, so Shift+'.' cannot freeze the
  OSD), and the HPD/status history in the OSD Chipset line 0. Questions: does F12 still open the OSD (i.e. is the
  832 main loop alive)? Only after a *long* off period? It's the same symptom family as the 2026-09-23 HPD work.
  Best diagnostic: the 832 serial log (CP210x) across the off/on, which shows the HPD transitions, the status reads
  and whether the re-init runs and what the I2C writes return. Suspects: the ADV7511 entering power-down / losing
  its register state after a long HPD-low, and the firmware's re-init not restoring the power-up sequence (0x41
  power-down bit, 0xD6 HPD override) or the I2C master stuck (a bounded wait gives up silently).

- **The stuck right mouse button and the "missing built-in commands" boot error are RESOLVED as not-a-core-bug
  (2026-09-25).** Both vanished together after pulling the board power; Paul has seen the button issue on the 020 core
  too. The cause is peripherals keeping their state across JTAG loads, not the pipelined CPU. The firmware already
  forces a cold start (ClearVectorTable). Hardening candidates:
  (a) PS/2 mouse: after every FPGA start send FF (reset) and wait out the self-test (19a39f1 fixes the init
  timeout); on hot-plug also clear the RTL's intellimouse flag, so the 3/4-byte framing can't disagree with the mouse.
  (b) SD: at firmware start send CMD12 (stop transmission) before CMD0, so a transfer interrupted by a JTAG
  load is closed.
- **HDMI clock delay from the core, not the firmware table:** the core reports its ADV7511 0xBA value in the
  OSD version reply (capability bit + byte), and the firmware writes it, falling back to 0x00 on older images.
  Then the delay travels with the adv_ddr.v timing it belongs to.

- **PCB reset button does not clear a fatal OSD error** (e.g. booted without an SD card): the board resets but
  the error stays, and only a power cycle or JTAG reload clears it. Likely the button resets the Minimig side but not
  the 832, or the firmware's error path does not re-probe. 21729c5 ("A failed boot recovers instead of latching")
  does not cover this case. Reported by Paul 2026-09-24.
- **Flash image predates the 19-Sep OSD fixes** (72f15a7 68040 OSD, 833ddc3, 5f0d1da, keyq). After a power cycle
  it shows the 68000/010/020 menu. Refresh the flash once the 040 branch is stable (Paul flashes).

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
  **Measured 2026-09-25 (m14f_fpu_ila): all boards 0.83x, DDR3 only 0.88x an A4000/040 25 MHz**
  (+6%). Worth doing -- but "DDR3 only" also breaks RTG (below), so the tool/priority route that
  keeps the SDRAM boards configured is the one to take.
- **Only ~10 MB fast memory in Workbench with "DDR3 only" (Paul, 2026-09-25).** The DDR3 board
  is the third Zorro III board, fixed at 16 MB in the autoconfig ROM (minimig_autoconfig.v: with
  ddr3_only the chain starts at acdevice 3'b011; the size-nibble rewrite is skipped for DDR3).
  First establish whether this is a real shortfall: the Workbench title bar shows FREE memory, so
  compare `Avail` (Total column) and `ShowConfig` (board size) in a fresh shell right after boot.
  If Total is below 16 MB: check the size ExpansionRom advertises for board 3 and what
  expansion.library actually AddMem'd (ShowConfig / SysInfo boards). If Total is 16 MB: ~6 MB in
  use is RAM-disk, fonts, SetPatch, 68040.library etc. landing in fast RAM, i.e. not a bug.
- **RTG does not work with "DDR3 only" (Paul, 2026-09-25).** Likely cause, from the RTL: the RTG
  video fetcher reads the SDRAM only. akiko.vhd latches the framebuffer base (rtg_addr[25:4]) that
  the Picasso96 driver writes, minimig_virtual_top.v mangles it and hands it to the SDRAM
  controller (`.rtgAddr(rtg_addr_mangled)`); there is no path to the DDR3. With "DDR3 only" the
  only fast RAM is the DDR3 board, so the driver's framebuffer lands in DDR3 and the fetcher shows
  whatever SDRAM holds at the same low 26 address bits. Confirm: RTG screen black/garbage while
  the CPU runs, and the driver's framebuffer address (SysInfo/Scout) in the board-3 window.
  Fix options: (a) keep a small SDRAM Zorro board/region configured for the RTG framebuffer even
  in "DDR3 only" (or allocate the framebuffer from a fixed SDRAM window in the driver); (b) grey
  out RTG in the OSD when "DDR3 only" is selected; (c) an RTG fetch path from the DDR3 (big: the
  fetcher needs guaranteed bandwidth, and the DDR3 arbiter already serves the CPU).
- **Chip RAM: longword per chip slot, so turbo can go (Paul, 2026-09-25).** Why: turbo chip RAM
  breaks timing in demo graphics, and without it the CPU gets one 16-bit word per free 280 ns slot
  -- half of what a real A1200/A4000 gets (32-bit chip bus, same slot rate). Goal: a 32-bit CPU
  access completes in ONE chip slot (two-word SDRAM burst), with DMA/video timing untouched. That
  is exactly AGA behaviour, unlike a "14 MHz" two-arbitrary-words-per-slot scheme, which no real
  machine had. The SDRAM side already has wide chip paths (AGA FMODE 32/64-bit display fetches);
  what is 16-bit is the CPU side (TG68K.vhd wrapper -> minimig chip bus: the ILA shows only
  uds/lds word transfers). Step 1, MEASURE FIRST: chip RAM read/write MB/s in turbo and 7 MHz
  (a bustest-style tool, or SysInfo), plus an ILA count of wait clocks per chip access -- the
  SysInfo loop above ran ~0.8 us per word, far slower than one word per 280 ns slot, so the width
  may not be the current bottleneck. Step 2: the longword-per-slot path. Step 3: re-test the
  demos that break with turbo, with turbo off.
- **OPEN, intermittent: SysInfo SPEED sometimes takes minutes (MHz / MFLOPS phase).** 2026-09-24
  (all boards): CPU found in STOP with no interrupt for ~2 min, then continued. 2026-09-25 on
  m14f_fpu_ila: one run with all boards finished normally; one MFLOPS phase was slow; with "DDR3
  only" the whole test runs in 55 s. ILA (findings/ap040-pipelined/ila-scripts/ila_hang.tcl, now/busy/CIA-ICR traps): during
  the slow phase the CPU is NOT stopped -- it loops at $40224D2E..46 sweeping chip RAM word by
  word (~0.8 us/word, all zeros), VERTB and CIA-A (ICR reads at $FC34B2, timer.device reading
  CIA-A timer B) are serviced, no CIA-B ICR read in 50 s; code at $F946E0 and $40177C86 arms the
  CIA-B TOD alarm (CRB=0, TOD=0, CRB=$80). The CIA commits 15d132a/6e6ec15 only touch timers A/B
  (E-clock reload, CNT/INMODE decode), not TOD/alarm. A/B images ready: build/stage_ap040_rtlfix
  (reference core, same CIA), build/stage_ap040_pipe_exp_ciarev (branch exp/cia-revert bf21509,
  CIA as before 15d132a; timing normal). Next: time SysInfo 2-3x on each; suspect SDRAM/chip-bus
  contention (all-boards config) as much as the CIA.
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
