# OSD host CPU -> VexRiscv: executable plan, stage 5 (Phase 5 -- build integration, build B, the A/B card, the board-test protocol)

Status: **planned 2026-10-19**, executing on branch `p5-build` (worktree `MinimigAGA_TC64-p5build`, off `osd-riscv` 5462a0f). Corrected the same day by Paul: RISC-V only on this branch, A = `stage_spicdc_49b1868` (see Decisions). Stops at the first step that needs Paul at the board (Task 6). **Status 2026-10-20:** Tasks 1, 2, 3, 5 done and reviewed, Task 4 skipped (gate met), Task 6 protocol written (`findings/osd-riscv/ab-board-test.md`), final whole-branch review done (fixes applied), backup pushed to origin/p5-build; card `RV32OSDA.BIN` = osd-riscv `6ea1b76` floppy-write fix (sha256 `17bf2563`, replaces Task 5's C1 image `0162e53f`; ledger R11). STOP: waiting for Paul at the board.

> For agentic workers: execute task by task with superpowers:subagent-driven-development
> (SDD tooling extracts tasks by their `### Task N` heading). Each task ends at its pass
> gate; one commit per task, only its files, on branch `p5-build` in the `p5-build` worktree
> (`$P5`); the implementer commits there (Phase 4 does not share this worktree).

**Goal.** One bitstream **B** = the board top with the VexRiscv host CPU (`cpu_riscv = 1`,
`rv_debug = 0`) built from **one** `p5-build` commit (**C1**), implemented, timed and recorded
against the board-verified 832 reference **A** = `build/stage_spicdc_49b1868` (main checkout,
md5 28b07e8c, built from `5.0-040-pipelined` 49b1868; not rebuilt here); an SD-card addition
(`RV32OSDA.BIN` built from C1 and pre-converted `MINMGAR*.CFG`) that Paul copies onto his card
**copy** next to the files already there (his `832OSDAD.BIN` stays, A reads it); and a
board-test protocol for Paul (A as reference/fallback, then B). Phase 5.4 (debug bridge) and the
merge into `5.0-040-pipelined` are out of scope.

Parent plan: `doc/osd-riscv-plan.md` (section 8 Phase 5, 5.1-5.3; 3.6; 3.8; 6.4; 7.4; 9;
decisions 12.4, 12.6, 12.10, 12.13). Stage before this one: `doc/osd-riscv-exec-4.md`
("What Phase 5 consumes", items 2, 3, 5). Spec for this stage: the planner brief
`$RV/.superpowers/sdd/osd-riscv-exec-5-planner-brief.md` (untracked), Paul's decisions of
2026-10-19 (recorded in the Phase 4 ledger lines 153-155, 196 and below) and Paul's correction of
2026-10-19 ~17:30 (Decisions below), which overrides the planner draft where they differ.

**Architecture summary.** Phase 1 left the CPU choice as bridge generics (`cpu_riscv`,
`rv_debug`) with both CPUs bound through component declarations, but the board top still
instantiates the bridge as `EightThirtyTwo_Bridge #( debug ? 1'b1 : 1'b0)` -- nothing above the
bridge can select the RISC-V. Task 1 threads two parameters through the board path
(`minimig_openaars_top.HOSTCPU_RISCV = 1`, `HOSTCPU_RVDEBUG = 0` -> `minimig_virtual_top.hostcpu_riscv/
hostcpu_rvdebug` (defaults **0**, so every other top that instantiates `minimig_virtual_top` --
Chameleon, DE10-Lite, DE0-Nano, virtual -- keeps its 832) -> bridge `cpu_riscv/rv_debug`), so the
QMTech board top **defaults to the RISC-V** (decision 12.10: one CPU per bitstream; the 832 lives
on its own branch). The board build script `build_ap040.tcl` always builds the RISC-V: a sourced
`tools/vivado/hostcpu.tcl` adds the RV file group to `project_1` (`rv_hostcpu.v`, `VexOsd.v`,
`OSDBoot_rv_ROM.vhd`), disables the 832 file group (the EightThirtyTwo RTL, `OSDBoot_832_ROM.vhd`,
`debug_bridge_jtag` and its helpers) for the run and restores the project afterwards like the
script's other switches. There is **no** `HOSTCPU=832` build target and no new 832 build path; the
832 sources stay in the tree as the simulation reference (Phase 4's L3 differential instantiates
the bridge directly) and are removed in Phase 9. C1 descends from 5462a0f (Phase 4 Task 12, the
handshake RTL + `SPI_reply` poll) and differs from it in `rtl/ fw/ fpga/ tools/vivado/` only by
Task 1's files. B is built in one fresh detached worktree of C1 (its own `project_1` copy, IPs
still read from the main checkout's `ip/`), outputs to the `osd-riscv` worktree's git-ignored
`build/` (`$RV/build/`: the long-lived worktree, so Paul finds B and the card set there after
`p5-build` is merged and its worktree removed; build outputs are untracked). Task 3 records fit and
timing of B against A; Task 4 is the 5.2 recovery ladder, run only if B misses a gate; Task 5
prepares the card files; Task 6 writes the board protocol and stops.

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Earlier constraints | Everything in `doc/osd-riscv-exec-4.md` "Global Constraints" still binds unless a row below changes it (branch **`p5-build`** in worktree `$P5`, one commit per task with only its files, never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`, `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` as the last line of every commit message, README rule, no `git push` except the controller's backup of `p5-build`). |
| Parallel Phase 4 | Phase 4 (Tasks 13-23) keeps committing `sim/**`, `findings/osd-riscv/phase4.md`, `doc/osd-riscv-exec-4.md` on `osd-riscv` in the `osd-riscv` worktree `$RV` under its own orchestrator. Phase 5 commits only on `p5-build` in `$P5` (off 5462a0f; merged into `osd-riscv` later by the controller) and never runs git commands that change `$RV`, its branch or the Phase 4 lane worktrees (`-p4disk`, `-p4akiko`); it never touches Phase 4's files. Writing untracked outputs under `$RV/build/` is allowed. Phase 5's build waits only for Phase 4 Tasks 11 and 12 (done: 5462a0f), not for 13-23. While a Vivado build runs, Phase 4 runs at most **2** Verilator jobs at once (Paul 2026-10-19 ~17:40: the build is the priority; normal Vivado thread settings, no artificial limit); the controller writes `VIVADO BUILDS STARTED/FINISHED` lines into the Phase 4 ledger. |
| Branch / merge | **No merge into `5.0-040-pipelined`**, no cherry-pick, no push of anything but `p5-build` (backup, only after its reviews passed). `p5-build` merges into `osd-riscv` later via the controller. Merge only after the board A/B and Paul's go (overrides plan 5.3's "Merge" line). |
| RTL review gate | Waived by Paul 2026-10-19 08:45: the handshake (Phase 4 Tasks 9-10) passed its unit benches, so the bitstream is built now; Paul reviews the RTL after hardware verification. |
| RISC-V only (Paul 2026-10-19 ~17:30) | This branch builds **only B**. No 832 bitstream is built from it; A is the existing `build/stage_spicdc_49b1868`. The board top and `build_ap040.tcl` default to the RISC-V; no `HOSTCPU` switch, no 832 build target. The 832 sources (`EightThirtyTwo` submodule, `rtl/host/832_bridge.vhd`'s 832 branch, `fw/ctrl_832`, `fw/ctrl_boot_832`) stay as simulation reference (removal = Phase 9). |
| B's generics | Those of the reference except the CPU: `POST_CHIP=1 POST_CI=1`, `<ila>` argument `0`, every other `build_ap040.tcl` default. The reference's `.last_generics`: `HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=0 CPU040_DEBUG_ILA=0 AP040_POST_STORES=1 CPU_CLK_DIVIDE=30 CHIP32=1 AP040_PIPELINED=1 AP040_HAS_MMU=1 AP040_HAS_FPU=1 AP040_FREE_CORE=1 AP040_STORE_BUF=1 AP040_FWD=1 AP040_RAS=1 AP040_PRECISE=1 AP040_MISPLIT=0 AP040_SB_MMU=1 AP040_COPYBACK=1 AP040_BTB=0 AP040_LDX=1 AP040_BTFN=1 AP040_DFP_MIS=1 AP040_WALLOC=1 AP040_XC7=0 AP040_POST_CHIP=1 AP040_POST_CI=1 AP040_CWF=0`. B's `.last_generics` must equal that string (the CPU comes from the top's parameter default, not a generic; if Task 1 adds `HOSTCPU_RISCV=1` to the generic line for the record, B's string = the reference + that one token, and the task says so). |
| One CPU per bitstream (12.10) | B contains no EightThirtyTwo, no `OSDBoot_832_ROM`, no `debug_bridge_jtag` (file group disabled **and** no such cell in the routed netlist). `rv_bscane2.v`, `VexOsd_DMT.v`, `VexOsd_DMJ.v` are never added (production `rv_debug=0`). |
| A = reference = fallback | `build/stage_spicdc_49b1868` (main checkout, md5 28b07e8c, 832, from `5.0-040-pipelined`) is A, the timing reference and the board fallback, with the files already on Paul's card (its `832OSDAD.BIN`, `MINMGAA*.CFG`). |
| Vivado | 2023.2 only: `/opt/Xilinx/Vivado/2023.2/bin/vivado` called directly with `LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C` in the command's own `env` (never exported shell-wide; the shim directory holds only `libtinfo.so.5`), **never `-stack`**, `-mode batch -nojournal -log <file>`. `project_1.xpr` is opened only by the committed `tools/vivado/build_ap040.tcl` in batch mode, never by hand, never in the GUI; no `upgrade_ip`, no `report_ip_status -upgrade`, no IP regeneration. Before and after every build: `md5sum <main>/ip/ddr3/*.xcix > <out>/ip_md5_{before,after}.txt` and the two must be equal (the IPs live in the main checkout and escape worktrees: memory "vivado-lab-gotchas"). Incremental synthesis and incremental implementation stay off (the script forces it). A timing-only experiment may use `STOP_AFTER_ROUTE=1`. |
| Where the build runs | One detached worktree of C1, a sibling of the main checkout: `<base>/MinimigAGA_TC64-p5b` (`$WB`), `<base>` = `/home/paul/work/fpga/Xilinx/artix7`. Not the main checkout (Paul's uncommitted files), not the `osd-riscv` worktree (Phase 4 commits there, and it has no `project_1` and no submodules), not the `p5-build` worktree `$P5` (later Phase 5 commits land there while the build runs), not `MinimigAGA_TC64-v2023` (keeps the reference's runs). Justification and recipe: Task 2. Outputs (bit, reports, logs) go to `$RV/build/stage_p5b_<C1>`; nothing is written into the main checkout. |
| Paths | `$MAIN` = `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64` (read-only for every task), `$RV` = `.../MinimigAGA_TC64-riscv` (outputs only), `$P5` = `.../MinimigAGA_TC64-p5build` (branch `p5-build`, all Phase 5 commits), `$WB` = the build worktree, `$C1` = the 7-char hash of Task 1's commit. Shell is zsh: no unquoted multi-word variables, write `vivado` calls out in full or as a function (memory "vivado-lab-gotchas", zsh no-word-split). |
| SD card | **Never write to `/media/paul/AARSDISK55`** (Paul's live card). Reading it is allowed (copy files off). Paul copies the prepared files onto his card **copy** himself, next to the files already there (nothing on the card is replaced). |
| Vendor-neutral | `minimig_virtual_top`'s new parameters default to 0 (the 832: every other top and the Quartus projects unchanged); only `minimig_openaars_top` (the QMTech board, the only board built: memory "target-board-qmtech") selects the RISC-V. `host.qip` lists the RV sources (never `rv_bscane2.v`); no vendor primitive added. A recovery switch (Task 4) is a parameter defaulting to off. |
| Timing reference | `build/stage_spicdc_49b1868/timing_summary.rpt` (main checkout): clk_114 intra-clock WNS **+0.101 ns**, WHS +0.056; spi_sck +19.166; the only failing paths are the known inter-clock `clk_gen_sdram -> clk_114` set (-0.525 ns, 16 endpoints, memory "osd-riscv" 10-17). Utilisation 53,409 LUT (84.24 %), 15,460 slices (97.54 %), 26,066 FF. |
| Gate numbers (plan 5.1/5.2) | **5.1:** clk_114 intra WNS of B >= reference - 0.1 ns = **+0.001 ns**; failing endpoints of B (setup and hold, all clocks) a subset of the reference's known set; `report_clocks` lists `spi_sck`; `hostcpu` hierarchical utilisation recorded for B and the reference. **5.2** (only if 5.1 fails): WNS >= -0.2 ns and no failing endpoint under `openaars_virtual_top/hostcpu` -- and then Paul decides whether that image goes on the board (Task 4). |
| Model per task | Opus for build integration and timing (Tasks 1, 3, 4); Sonnet for mechanical work (Tasks 2, 5, 6). |
| Runtime facts | The reference build (v2023 worktree, 2026-10-17): synthesis 14 min, implementation to bitstream 29 min, reports 3 min, peak ~4 GB. One build: est. 45-55 min wall. |

## Review Focus

1. **The wrong CPU in the bitstream** (the parameter not reaching the bridge, or the disabled 832 file group still elaborating, or the RV group missing into a black box): Task 2's synth-log check and Task 3's netlist cell counts (`REF_NAME` of the hostcpu children).
2. **A project left switched** (832 group left disabled / RV group left in) after a crashed build: Task 1's restore block; the build runs in its own worktree copy of the project, so nothing leaks into another tree.
3. **The handshake crossing untimed or mis-excepted** (`osd_rx_seq` dll_28 -> clk_114 resync, `osd_tx_seq` -> `host_req_q` clk_114 -> dll_28): Task 3 reports those paths by name and shows they are constrained by the wizard.xdc 1:4 rules, and `report_exceptions -ignored` gains no line against the reference.
4. **The shared `ip/` modified by a worktree build**: the md5 before/after rule in Global Constraints, checked in Task 2.
5. **Card files that do not boot B the way Paul's card boots A today** (wrong config byte order, RV firmware of the wrong commit): Task 5's sha256 gate and `cfgconv --check` of every converted file.
6. **Another top broken by the new parameters** (vendor-neutral): `minimig_virtual_top` defaults keep the 832; Task 1 shows every other instantiation of `minimig_virtual_top` is unchanged.

---

### Task 1: Board top defaults to the RISC-V, the build script's RV file group, file lists (plan 5.1 integration)

- **Phase / depends on:** plan 5.1 (`add_src`, top parameters, `host.qip`), 3.6, decision 12.10 / Phase 4 Task 12 done (5462a0f).
- **Model:** Opus.
- **Files:** modify `rtl/soc/minimig_openaars_top.v` (parameters `HOSTCPU_RISCV = 1`, `HOSTCPU_RVDEBUG = 0`, passed to `minimig_virtual_top` next to `.debug(1'b0)`), `rtl/soc/minimig_virtual_top.v` (parameters `hostcpu_riscv = 0`, `hostcpu_rvdebug = 0`; the bridge instance becomes named: `EightThirtyTwo_Bridge #(.debug(debug ? 1'b1 : 1'b0), .cpu_riscv(hostcpu_riscv ? 1'b1 : 1'b0), .rv_debug(hostcpu_rvdebug ? 1'b1 : 1'b0)) hostcpu`; instance name `hostcpu` unchanged -- wizard.xdc names `openaars_virtual_top/hostcpu/hw_req_reg`), `rtl/host/host.qip` (append `VERILOG_FILE` `rv_hostcpu.v`, `vexriscv/VexOsd.v`, `VHDL_FILE ../../fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`; never `rv_bscane2.v`, `VexOsd_DMT/DMJ.v`); create `tools/vivado/hostcpu.tcl`; modify `tools/vivado/build_ap040.tcl` (source it, apply before the run, restore with the other restores, extra reports), `tools/vivado/README.md` (a "Host CPU" paragraph: the board build is the RISC-V; the 832 board image is `stage_spicdc_49b1868` / branch `5.0-040-pipelined`; the B command of Task 2). `tools/vivado/build.tcl`, `build_bist.tcl`, `build_ila.tcl`, `build_no_ddr3.tcl`: each one that still opens `project_1` and synthesises this top gets one line `source [file dirname [info script]]/hostcpu.tcl` plus the apply/restore calls (with the new top default it would otherwise elaborate the RV without its sources); a script that is retired or cannot build today's design gets a comment "retired; not updated for the RISC-V host CPU (osd-riscv Phase 5)" instead; the task says which per script and why. `rebuild.tcl` is a Vivado 2023.2 export of 2024-03-09 that predates the AP040 sources and does not recreate today's project; it is **not** edited (Decision 3).
- **Interfaces (produces):**
  - `tools/vivado/hostcpu.tcl`: `hostcpu_apply {R}` adds (via the script's `add_src`) `$R/rtl/host/rv_hostcpu.v`, `$R/rtl/host/vexriscv/VexOsd.v`, `$R/fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd` if missing, sets `IS_ENABLED` true on the RV group and false on the 832 group (every `sources_1` file matching `*/EightThirtyTwo/RTL/*` plus `*/fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`), remembers what it changed, prints `build_ap040.tcl: host CPU = RISC-V (<n> RV files enabled, <m> 832 files disabled)`. `hostcpu_restore` undoes exactly what `hostcpu_apply` changed (files it added are removed again, enable flags back to what they were), printed. No environment switch; no 832 mode.
  - `build_ap040.tcl`: the generic line is unchanged (the CPU comes from the top's default; Global Constraints "B's generics"); after `open_run impl_1` it also writes `util_hier.rpt` (`report_utilization -hierarchical -hierarchical_depth 4`), `util_hostcpu.rpt` (`report_utilization -cells [get_cells openaars_virtual_top/hostcpu] -hierarchical -hierarchical_depth 3`), `clocks.rpt` (`report_clocks`), `hostcpu_cells.txt` (for `hostcpu`: every leaf-parent child cell with its `REF_NAME`, plus the counts of cells whose `REF_NAME` matches `eightthirtytwo*`, `OSDBoot_832_ROM*`, `debug_bridge_jtag*`, `VexOsd*`, `rv_hostcpu*`, `OSDBoot_rv_ROM*`), `handshake_timing.rpt` (`report_timing -setup -hold` with `-to` the cells `*mycfide/osd_tx_seq_reg*` and `*mycfide/host_req_q_reg*` and `-from` `*osd_rx_seq_reg*`, `-max_paths 4 -nworst 1`), `failing.rpt` (`report_timing -max_paths 100 -nworst 1 -slack_lesser_than 0` setup and hold) and `drc.rpt`. Deliverable copy message names `$out`, not `build/stage_ap040/`.
- **Test first:** the RTL/script change is checked before the full build by Task 2's synthesis check (step 3); this task's own red/green is static: `grep -c 'cpu_riscv' rtl/soc/minimig_virtual_top.v` = 0 before, >= 1 after; `tclsh` parse check `echo 'source tools/vivado/hostcpu.tcl' | tclsh` (procs only, no Vivado calls at source time) succeeds; a Verilog parse of the two tops' changed instantiations (e.g. `verilator --lint-only` or `iverilog -E`/`-t null` on what parses standalone; say what was run); every other instantiation of `minimig_virtual_top` (`rtl/chameleonv1`, `rtl/chameleonv2`, `rtl/soc/minimig_de10lite_top.vhd`, `rtl/soc/minimig_de0_nano_top.vhd`, `fpga/virtual`) unchanged and relying on the 0 defaults; `git diff --stat 5462a0f..` over `rtl fw fpga tools/vivado` lists only this task's files.
- **Project file check:** list the sources of the v2023 `project_1.xpr` (`$B/MinimigAGA_TC64-v2023/project_1/project_1.xpr`, read-only grep) against the RTL files added between 49b1868 and 5462a0f (`git diff --name-status 49b1868 5462a0f -- rtl fw/ctrl_boot_rv`): every file the RV build needs that is not in that project is added by `hostcpu_apply` (the three above, plus any other the diff shows the bridge or cfide now needs; say which).
- **Steps:** (1) the top parameters and the named bridge instance; (2) `hostcpu.tcl` and the `build_ap040.tcl` hooks and reports; (3) the other build scripts per the rule above; (4) `host.qip`; (5) the boot ROM check: `make -C fw/ctrl_boot_rv` into a scratch `B=` and `cmp` its `OSDBoot_rv_ROM.vhd` with the committed one (equal; if not, stop and report -- the committed ROM must match the committed sources, memory "Committed tree builds as is"); (6) README paragraph.
- **Pass gate:** static checks green; ROM `cmp` equal; `git diff` touches only the files listed; the commit message states that the QMTech board top now builds the RISC-V host CPU, that every other top keeps the 832 through the `minimig_virtual_top` defaults, and that the 832 board image is `stage_spicdc_49b1868`. The implementer commits on `p5-build` -> **C1**, written into the ledger.

### Task 2: Build worktree and build B

- **Phase / depends on:** plan 5.1 (stage) / Task 1 (C1).
- **Model:** Sonnet.
- **Files:** none tracked. Creates `$WB` (detached worktree), `$RV/build/stage_p5b_$C1/`.
- **Why this layout:** a worktree because `build_ap040.tcl` builds `$R/project_1`; detached at C1 so the tree is exactly the commit (no later edits arrive mid-build); a sibling of the main checkout so the xpr's `$PPRDIR/../../MinimigAGA_TC64/ip/ddr3/*.xcix` IP paths resolve to the main checkout's 2023.2 IPs as for `MinimigAGA_TC64-v2023`; the project is a copy of the v2023 project (same base 49b1868, IP runs already complete, so no IP synthesis writes into `$MAIN/ip`).
- **Steps and commands** (zsh; `B=/home/paul/work/fpga/Xilinx/artix7`):
  1. Worktree and submodules (the worktree-local submodule clones come from the main checkout's submodules, as v2023's did; `-c` overrides keep the shared `.git/config` untouched):
     `git -C $B/MinimigAGA_TC64-p5build worktree add --detach $B/MinimigAGA_TC64-p5b $C1`, then:
     `git -C $WB -c protocol.file.allow=always -c submodule.EightThirtyTwo.url=$B/MinimigAGA_TC64/EightThirtyTwo -c submodule.lib/AP68040.url=$B/MinimigAGA_TC64/lib/AP68040 -c submodule.lib/AP68040-pipelined.url=$B/MinimigAGA_TC64/lib/AP68040-pipelined -c submodule.rtl/tg68k.url=$B/MinimigAGA_TC64/rtl/tg68k submodule update --init`.
     Check: `git -C $WB submodule status` shows the four gitlinks of C1 without `-`/`+` (d1cd671 EightThirtyTwo, 530fc72 lib/AP68040, 972f0c5 lib/AP68040-pipelined, bfad0bd rtl/tg68k).
  2. Project copy: `cp -a $B/MinimigAGA_TC64-v2023/project_1 $WB/project_1`, then `rm -f $WB/project_1/.last_generics` (forces synthesis). Check: `grep -c 'MinimigAGA_TC64-v2023' $WB/project_1/project_1.xpr` = 0 (all paths `$PPRDIR`-relative); `grep -c '../../MinimigAGA_TC64/ip/ddr3' $WB/project_1/project_1.xpr` >= 4.
  3. The build, in the background (`nohup`, its own log): `md5sum $B/MinimigAGA_TC64/ip/ddr3/*.xcix > $OUT/ip_md5_before.txt` then
     `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C POST_CHIP=1 POST_CI=1 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log $OUT/vivado.log -source $WB/tools/vivado/build_ap040.tcl -tclargs $OUT 0 $WB` with `OUT=$RV/build/stage_p5b_$C1`. Record the launcher PID.
  4. Synthesis check (catches a wrong CPU early): within ~15 min `$WB/project_1/project_1.runs/synth_1/runme.log` must show `rv_hostcpu`/`VexOsd` elaborated under `hostcpu` with `cpu_riscv = TRUE` (or 1), no `EightThirtyTwo` CPU module, and no `black box` / `could not find module` line for the host CPU; if not, kill the build by its own PID (never `pkill -x vivado`: machine-wide) and report.
  5. Wait for `=== ALL DONE ===` in the log (match the line start, not a word: Vivado echoes the Tcl source).
  6. After the build: `md5sum ... > $OUT/ip_md5_after.txt`, `cmp` before/after; `cp $WB/project_1/.last_generics $OUT/generics.txt` and compare with the reference string of Global Constraints "B's generics"; `md5sum $OUT/minimig_openaars_top.bit > $OUT/bit.md5`; `echo $C1 > $OUT/COMMIT`; `git -C $WB status --porcelain` clean apart from untracked `project_1/`.
- **Estimate:** setup ~10 min; build ~45-55 min wall. Phase 4 keeps <= 2 Verilator jobs meanwhile. The controller may run Task 5 while the build runs (the build is a process, not an implementer).
- **Pass gate:** the log ends with `=== ALL DONE ===`, the `.bit` present, synthesis shows the RV under `hostcpu`, the IP md5 files equal, generics as Global Constraints says, the worktree's tracked files unchanged by the build. Failure of the build itself (error, not timing) -> stop and report with the log tail.

### Task 3: Fit and timing record (plan 5.1 gate)

- **Phase / depends on:** plan 5.1 gate / Task 2.
- **Model:** Opus.
- **Files:** create `findings/osd-riscv/phase5.md` (sections "Build", "Fit", "Timing", "Handshake paths", "Netlist CPU check"); `$RV/build/ref_spicdc/` (untracked) for the reference's hierarchical report.
- **Steps:**
  1. Reference hierarchy (the reference build wrote only flat reports): copy `$B/MinimigAGA_TC64-v2023/project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp` to `$RV/build/ref_spicdc/` (first check its timestamp is 2026-10-17 16:1x, i.e. still the reference's run, and say so; if not, use only the flat reports in `$MAIN/build/stage_spicdc_49b1868` and record that the hostcpu hierarchy of A is unavailable), then a no-project batch run: `open_checkpoint`, `report_utilization -cells openaars_virtual_top/hostcpu -hierarchical -hierarchical_depth 3`, `report_timing_summary`, `report_exceptions -ignored`, the `failing.rpt` command of Task 1 (~10 min, `env LD_LIBRARY_PATH=... LC_ALL=C vivado -mode batch -nojournal -log ... -source <scratch tcl>`; the scratch Tcl lives in the scratchpad, not in the repo).
  2. Tables in `phase5.md` (B and A = reference side by side): total LUT/FF/BRAM tiles/DSP/slices (% of the part); `hostcpu` LUT/FF/RAMB36/RAMB18/DSP with its children (`genrv.myrv`/`gen832.my832`, `bootrom`, `hostcache`); B - A delta next to the Phase 1 OOC expectation (+661 LUT, +278 FF, +2.5 BRAM tiles, `findings/osd-riscv/ooc-2023.2.md`; note that A also lacks the Phase 1-4 bridge/cfide changes, so the delta is not the CPU alone); intra-clock WNS/WHS per clock (clk_114, dll_28, clk_38, clk_148, clk_ddr100, spi_sck); the failing-endpoint list vs the reference's known set; `report_clocks` line of `spi_sck`; `exceptions_ignored.rpt` and `cdc.rpt` summary lines diffed against the reference's (new lines are listed and explained, the handshake crossing expected among them as `dll_28 <-> clk_114` paths covered by the wizard.xdc 1:4 rules).
  3. Handshake paths (Task 10 ledger note "Phase 5.1: report_timing on osd_rx_seq_reg/osd_tx_seq_reg/host_req_q_reg"): from B's `handshake_timing.rpt`: start/end clock, the exception applied (multicycle 4 setup / 3 hold), slack; none unconstrained.
  4. Netlist CPU check from `hostcpu_cells.txt`: B has 0 cells of the 832 group and >= 1 `VexOsd`.
  5. Verdict against the 5.1 gate numbers (Global Constraints).
- **Pass gate:** `phase5.md` complete; B meets 5.1 -> Task 4 is skipped and the ledger says so; B misses 5.1 -> Task 4. If B's `hostcpu` LUT exceeds the OOC rv0 figure by more than 15 % (1,532 LUT -> > 1,762), the reason is written down (it does not fail the gate by itself).

### Task 4: Timing / fit recovery (plan 5.2) -- conditional

- **Phase / depends on:** plan 5.2 / Task 3 verdict "miss" for B.
- **Model:** Opus.
- **Files:** `findings/osd-riscv/phase5.md` ("Recovery"); RTL only behind a new parameter defaulting off, and only after Paul's go (below).
- **Ladder** (stop at the first rung that passes 5.1; every rung recorded with numbers):
  1. **Classify** from `failing.rpt` / the worst 20 clk_114 paths: (a) inside `hostcpu` (VexRiscv register-file/I$ paths, the OOC worst paths); (b) elsewhere, route-dominated (net delay > 70 % of the path) -- congestion from the extra ~660 LUT at 98 % slices; (c) elsewhere, logic-dominated.
  2. **(b), and (a) when route-dominated:** rebuild B with `IMPL_EFFORT=high` (the script's existing switch: place `ExtraTimingOpt`, phys_opt/route/post-route `AggressiveExplore`; same RTL) in `$WB`, new `OUT=$RV/build/stage_p5b_${C1}_hi`, ~1.5 h. No Paul decision needed: the bitstream content is the same design. A is the reference and is not rebuilt (recorded: B then also differs from it in the implementation directive).
  3. **Iterate small** (memory "fpga-iterate-small"; minutes per run): `tools/vivado/ooc_hostcpu/go_bridge.sh rv0` at 8.815 ns and at a tightened period (e.g. 8.0 ns) to show which candidate fix moves the hostcpu paths: a VexRiscv regeneration with the I$ `twoCycleRam` option, or a pipeline register in `rv_hostcpu.v` on the bus outputs, each as a scratch copy (`VEXSRC=`, never the committed `.v`), measured in OOC only.
  4. **Stop and report to Paul** before any change to the committed CPU RTL or a regeneration: either changes the verified core (L1/L2/L3 re-runs: Phase 4's quick set `boot`, `hdd`, `fdd_rd` both CPUs plus L1 `all` and L2 `all`, ~1-1.5 h) -- Paul decides. Also stop if the 5.2 gate (WNS >= -0.2 ns, no failing endpoint under `hostcpu`) is met but 5.1 is not: Paul decides whether that B goes on the board.
- **Pass gate:** 5.1 met by a rebuilt B (its numbers in `phase5.md`, Task 3 step 4 repeated for it), or a stop report with the classification, the OOC numbers and the proposed fix.

### Task 5: The card files for B

- **Phase / depends on:** plan 5.3 (card with both firmware files), exec-4 "What Phase 5 consumes" item 5 / Task 1 (C1); may run while the build runs.
- **Model:** Sonnet.
- **Files:** none tracked. Creates `$RV/build/ab_card_$C1/` with `RV32OSDA.BIN`, `MINMGAR.CFG`, `MINMGAR1.CFG` .. `MINMGAR4.CFG`, `SHA256SUMS`, `PROVENANCE.txt`, and `orig/` (read-only copies of the live card's `MINMGAA*.CFG`, for provenance). **No** `832OSDAD.BIN`: Paul's card keeps its own (A reads it).
- **Decisions (justified):**
  - **`RV32OSDA.BIN`**: built from C1's `fw/ctrl_rv` the way L3 builds it (`hs_fwrv`: `make -C fw/ctrl_rv B=<dir>` under the `date` shim, `L3_DATE=2026-01-01`) in a clean tree of C1 (`$WB` after its build, or `$P5` if clean at C1; never `$RV`), so it is byte-identical to the image Phase 4 Task 12 verified (`$RV/sim/l3/run_fw12/fwrv/RV32OSDA.BIN`); gate: `git diff --quiet 5462a0f $C1 -- fw/ctrl_rv` and equal sha256. Its version string shows 2026-01-01 (said in the instructions). Needs a core with the Phase 4 RTL: B only (exec-4 ledger finding: on an older core it reads `audio_buf` at `0xFFFFFFB4`); A never loads it (the 832 boot ROM loads `832OSDAD.BIN`).
  - **Config files**: the live card has only the 832 family (`MINMGAA.CFG`, `MINMGAA1..4.CFG`). Copy them off read-only to `orig/`, convert each with `cfgconv --to-rv` (built as `sim/l3/card/Makefile` builds it: `make -C fw/ctrl_rv/tools/cfgconv B=<dir>`) to `MINMGAR.CFG`, `MINMGAR1..4.CFG`, and `cfgconv --check` each (fields equal; this is the round trip already closed on these five files in 6ef7d08). Pre-converted files make B's first boot deterministic; the first-boot conversion path is a Phase 6 parity row (Decision 2). The 832 files stay as they are (A reads them).
- **Steps:** build/copy as above; `sha256sum` everything into `SHA256SUMS`; `PROVENANCE.txt` = C1, the build commands, the sha256 of the L3 reference image, the cfgconv check output.
- **Pass gate:** RV image sha256 = Task 12's; five converted configs pass `--check`; nothing written to `/media/paul/AARSDISK55` (the task shows `find /media/paul/AARSDISK55 -newer <task start marker>` empty).

### Task 6: Board-test protocol, plan status, hand-over (STOP)

- **Phase / depends on:** plan 5.3 gate ("both CPUs boot from one card"), plan 9 (first rows) / Tasks 3 (and 4 if run), 5.
- **Model:** Sonnet.
- **Files:** create `findings/osd-riscv/ab-board-test.md` (the protocol, with an empty results table for Paul's paste-back); modify `doc/osd-riscv-plan.md` (header status: "Phase 5 build B done, A/B board test pending"; section 8 Phase 5: 5.1 done with build commit C1 and numbers, A = `stage_spicdc_49b1868` (Paul 2026-10-19: RISC-V only on this branch), 5.2 skipped/done, 5.3 card files ready, merge **deferred** until Paul's go, 5.4 not started) and `doc/osd-riscv-exec-5.md` status line.
- **Protocol content** (exact commands, `$RV/build/...` paths filled in):
  1. **Card copy**: on Paul's card **copy** (not the live card): add `RV32OSDA.BIN`, `MINMGAR.CFG`, `MINMGAR1..4.CFG` to the root next to the existing files (nothing replaced; `832OSDAD.BIN`, `MINMGAA*.CFG`, kickstarts, HDFs, ISO, `drivesnd.bin` stay); `sync`; `sha256sum -c SHA256SUMS` run in the mounted copy's root (the set's `SHA256SUMS` lists only the added files).
  2. **Serial**: `picocom -b 115200 /dev/ttyUSB0` = host-CPU log (boot ROM + firmware UART, decision 12.6; enable DebugMode in the OSD Misc page for the stack/`osd_rdy_timeouts` line); `/dev/ttyUSB1` = Amiga `SER:` (38400 or 57600; not needed for the first pass). Log each session to a file (`picocom --logfile`).
  3. **Loading**: power-cycle the board first (JTAG loads do not reset peripherals; memory "vivado-lab-gotchas"), then `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog -source $P5/tools/vivado/program.tcl -tclargs <bit>`; expect `=== DONE: ... DONE pin = 1 ===`. Between A and B: power-cycle, then load. Flash is not touched.
  4. **A (reference, 832, ~10 min)**: load `$MAIN/build/stage_spicdc_49b1868/minimig_openaars_top.bit` with the card copy: the 832 boot ROM loads `832OSDAD.BIN`; OSD opens; Kickstart boots to Workbench from the HDF. This shows the card copy (with the added files) still boots the board as today.
  5. **B (RISC-V, ~30 min)**: load `$RV/build/stage_p5b_$C1/minimig_openaars_top.bit`: ttyUSB0 shows the RV boot ROM banner and `RV32OSDA.BIN` loading, the firmware banner and platform line, `MINMGAR.CFG` loaded (no conversion message); OSD: open/close by button and keyboard, walk every main page, key repeat, file selector scroll; DebugMode line `osd_rdy_timeouts` stays 0; Kickstart load and boot to Workbench from the HDF; ADF read and write (survives reload); CD ISO listing + CD-DA play/pause/stop; config save to a slot and reload; reset from the OSD. Any lock-up: note the last ttyUSB0 line. Where B differs from A in a check, repeat that check on A.
  6. **Paste back**: the ttyUSB0 logs, the filled results table (row per check: A ok/fail, B ok/fail, note), and any OSD text that differs between A and B.
  7. **Fallback**: power-cycle, load A (`stage_spicdc_49b1868`) with the live card.
- **Pass gate (this run's end):** protocol committed with C1's paths and the sha256 of B and the card files (and A's md5 28b07e8c); plan status updated; the ledger says "STOP: waiting for Paul at the board (Task 6 protocol)". No further task runs until Paul reports.

---

## What Phase 6 consumes

1. B (`$RV/build/stage_p5b_$C1`, or its recovery rebuild) with its reports and `findings/osd-riscv/phase5.md` (fit, timing, handshake paths, CPU netlist check); A = `stage_spicdc_49b1868`.
2. Paul's A/B results (`findings/osd-riscv/ab-board-test.md`); any failure goes through systematic debugging before Phase 6 starts (L3 reproduction first).
3. The card files `$RV/build/ab_card_$C1/` on top of Paul's card as the Phase 6 parity/stress card base (plan 9, 7.4), plus the first-boot conversion row still to run.
4. The RISC-V board build path (`build_ap040.tcl` + `hostcpu.tcl`) and the worktree recipe of Task 2.
5. Open: merge into `5.0-040-pipelined` (only after the board A/B and Paul's go); Paul's RTL review of the handshake (waived before hardware); Phase 5.4 debug bridge; the 832 board Dhrystone (exec-4 Task 21, deferred to a board session); removal of the 832 sources (Phase 9).

## Decisions (controller rulings and Paul, 2026-10-19)

Paul was away from questions; the Phase 4 controller ruled on the planner's five questions, all
as proposed (Phase 4 ledger, line "Ruling (P5 planner Qs ..."; cost if wrong: Paul overrules,
rework small). Execution runs on branch `p5-build` (ledger line "Ruling: Phase 5 runs on branch
p5-build"). Paul's correction of ~17:30 then changed rulings 1 and 5 and the build scope.

0. **Paul 2026-10-19: RISC-V only on this branch; A = stage_spicdc_49b1868.** No 832 bitstream
   is built from `p5-build`; the board top and `build_ap040.tcl` default to the RISC-V (no
   `HOSTCPU=832` target, no new 832 build path; decision 12.10: one CPU per bitstream, the 832
   lives on its own branch). The 832 sources stay as simulation reference (removal: Phase 9).
   The card gets `RV32OSDA.BIN` + `MINMGAR*.CFG` added next to Paul's files; no replacement
   `832OSDAD.BIN`.
1. **Firmware image on the card**: the reproducible RV image the L3 differential ran (version
   string dated 2026-01-01), not a fresh-dated build. **Yes.** (The 832 half of the original
   question is void: Paul's card keeps its `832OSDAD.BIN`.)
2. **Configs**: pre-converted `MINMGAR*.CFG` (from the card's `MINMGAA*.CFG`) on the card copy;
   the first-boot conversion is tested in Phase 6. **Yes.**
3. **`rebuild.tcl`** (a 2024 project export that predates the AP040 sources): left untouched;
   `build_ap040.tcl` + `hostcpu.tcl` are the build path. **Yes.**
4. **Recovery without asking**: if B misses timing only on route-dominated paths, Task 4 rebuilds
   it with `IMPL_EFFORT=high` (same RTL) without asking; any RTL/core change waits for Paul.
   **Yes.**
5. **Board order**: A (= `stage_spicdc_49b1868`, reference) first, then B, each after a power
   cycle; fallback A with the live card. **Yes.**
