# OSD host CPU -> VexRiscv: executable plan, stage 5 (Phase 5 -- build integration, builds A and B, the A/B card, the board-test protocol)

Status: **planned 2026-10-19**, executing on branch `p5-build` (worktree `MinimigAGA_TC64-p5build`, off `osd-riscv` 5462a0f). Stops at the first step that needs Paul at the board (Task 6).

> For agentic workers: execute task by task with superpowers:subagent-driven-development
> (SDD tooling extracts tasks by their `### Task N` heading). Each task ends at its pass
> gate; one commit per task, only its files, on branch `p5-build` in the `p5-build` worktree
> (`$P5`); the implementer commits there (Phase 4 does not share this worktree).

**Goal.** Two bitstreams from **one** `p5-build` commit that differ only in the host-CPU
selection -- **A** = the 832 (`HOSTCPU_RISCV=0`), **B** = the VexRiscv (`HOSTCPU_RISCV=1`,
`rv_debug=0`) -- both implemented, timed and recorded against the board-verified 832 reference
`build/stage_spicdc_49b1868`; one SD-card file set that serves both (`RV32OSDA.BIN`,
`832OSDAD.BIN`, both config families) with exact copy instructions for Paul's card **copy**; and a
board-test protocol for Paul. Phase 5.4 (debug bridge) and the merge into `5.0-040-pipelined` are
out of scope.

Parent plan: `doc/osd-riscv-plan.md` (section 8 Phase 5, 5.1-5.3; 3.6; 3.8; 6.4; 7.4; 9;
decisions 12.4, 12.6, 12.10, 12.13). Stage before this one: `doc/osd-riscv-exec-4.md`
("What Phase 5 consumes", items 2, 3, 5). Spec for this stage: the planner brief
`$RV/.superpowers/sdd/osd-riscv-exec-5-planner-brief.md` (untracked) and Paul's decisions of
2026-10-19 (recorded in the Phase 4 ledger lines 153-155, 196 and below).

**Architecture summary.** Phase 1 left the CPU choice as bridge generics (`cpu_riscv`,
`rv_debug`) with both CPUs bound through component declarations, but the board top still
instantiates the bridge as `EightThirtyTwo_Bridge #( debug ? 1'b1 : 1'b0)` -- nothing above the
bridge can select the RISC-V. Task 1 threads two top-level parameters
(`minimig_openaars_top.HOSTCPU_RISCV/HOSTCPU_RVDEBUG` -> `minimig_virtual_top.hostcpu_riscv/
hostcpu_rvdebug` -> bridge `cpu_riscv/rv_debug`, defaults 0 = today's 832) and gives the board
build script one switch, `HOSTCPU=832|rv`, that sets the generic and enables exactly one CPU's
file group in `project_1` (the RV group: `rv_hostcpu.v`, `VexOsd.v`, `OSDBoot_rv_ROM.vhd`; the 832
group: the EightThirtyTwo RTL, `OSDBoot_832_ROM.vhd`, `debug_bridge_jtag` and its Altera
helpers), restoring the project afterwards like the script's other switches. That commit (**C1**)
is the build commit: it descends from 5462a0f (Phase 4 Task 12, the handshake RTL + `SPI_reply`
poll) and differs from it in `rtl/ fw/ fpga/ tools/vivado/` only by Task 1's files. A and B are
built **in parallel** in two fresh detached worktrees of C1 (each with its own `project_1` copy,
IPs still read from the main checkout's `ip/`), outputs to the `osd-riscv` worktree's
git-ignored `build/` (`$RV/build/`: the long-lived worktree, so Paul finds A, B and the card set
there after `p5-build` is merged and its worktree removed; build outputs are untracked). Task 3 records fit and timing against A and the reference; Task 4 is the
5.2 recovery ladder, run only if B (or A) misses a gate; Task 5 prepares the card files; Task 6
writes the board protocol and stops.

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Earlier constraints | Everything in `doc/osd-riscv-exec-4.md` "Global Constraints" still binds unless a row below changes it (branch **`p5-build`** in worktree `$P5`, one commit per task with only its files, never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`, `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` as the last line of every commit message, README rule, no `git push` except the controller's backup of `p5-build`). |
| Parallel Phase 4 | Phase 4 (Tasks 13-23) keeps committing `sim/**`, `findings/osd-riscv/phase4.md`, `doc/osd-riscv-exec-4.md` on `osd-riscv` in the `osd-riscv` worktree `$RV` under its own orchestrator. Phase 5 commits only on `p5-build` in `$P5` (off 5462a0f; merged into `osd-riscv` later by the controller) and never runs git commands that change `$RV`, its branch or the Phase 4 lane worktrees (`-p4disk`, `-p4akiko`); it never touches Phase 4's files. Writing untracked outputs under `$RV/build/` is allowed. Phase 5 builds wait only for Phase 4 Tasks 11 and 12 (done: 5462a0f), not for 13-23. While a Vivado build runs, Phase 4 runs at most **4** Verilator jobs at once (ledger line 196); the controller writes `VIVADO BUILDS STARTED/FINISHED` lines into the Phase 4 ledger. |
| Branch / merge | **No merge into `5.0-040-pipelined`**, no cherry-pick, no push of anything but `p5-build` (backup, only after its reviews passed). `p5-build` merges into `osd-riscv` later via the controller. Merge only after the board A/B and Paul's go (overrides plan 5.3's "Merge" line). |
| RTL review gate | Waived by Paul 2026-10-19 08:45: the handshake (Phase 4 Tasks 9-10) passed its unit benches, so bitstreams are built now; Paul reviews the RTL after hardware verification. |
| A and B | Both from C1, both with the generics of the 832 reference except the CPU: `POST_CHIP=1 POST_CI=1`, `<ila>` argument `0`, every other `build_ap040.tcl` default (the reference's `.last_generics`: `HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=0 CPU040_DEBUG_ILA=0 AP040_POST_STORES=1 CPU_CLK_DIVIDE=30 CHIP32=1 AP040_PIPELINED=1 AP040_HAS_MMU=1 AP040_HAS_FPU=1 AP040_FREE_CORE=1 AP040_STORE_BUF=1 AP040_FWD=1 AP040_RAS=1 AP040_PRECISE=1 AP040_MISPLIT=0 AP040_SB_MMU=1 AP040_COPYBACK=1 AP040_BTB=0 AP040_LDX=1 AP040_BTFN=1 AP040_DFP_MIS=1 AP040_WALLOC=1 AP040_XC7=0 AP040_POST_CHIP=1 AP040_POST_CI=1 AP040_CWF=0`). A's generic string = that string + ` HOSTCPU_RISCV=0 HOSTCPU_RVDEBUG=0`; B's = that string + ` HOSTCPU_RISCV=1 HOSTCPU_RVDEBUG=0`; the task checks both `.last_generics` files and diffs them (exactly one token differs). |
| One CPU per bitstream (12.10) | B contains no EightThirtyTwo, no `OSDBoot_832_ROM`, no `debug_bridge_jtag` (file group disabled **and** no such cell in the routed netlist); A contains no `VexOsd`/`rv_hostcpu`/`OSDBoot_rv_ROM` cell. `rv_bscane2.v`, `VexOsd_DMT.v`, `VexOsd_DMJ.v` are never added (production `rv_debug=0`). |
| Fallback | `build/stage_spicdc_49b1868` (main checkout, md5 28b07e8c) stays the board-verified fallback, with the files already on Paul's live card. It is **not** A. |
| Vivado | 2023.2 only: `/opt/Xilinx/Vivado/2023.2/bin/vivado` called directly with `LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C` in the command's own `env` (never exported shell-wide; the shim directory holds only `libtinfo.so.5`), **never `-stack`**, `-mode batch -nojournal -log <file>`. `project_1.xpr` is opened only by the committed `tools/vivado/build_ap040.tcl` in batch mode, never by hand, never in the GUI; no `upgrade_ip`, no `report_ip_status -upgrade`, no IP regeneration. Before and after every build: `md5sum <main>/ip/ddr3/*.xcix > <out>/ip_md5_{before,after}.txt` and the two must be equal (the IPs live in the main checkout and escape worktrees: memory "vivado-lab-gotchas"). Incremental synthesis and incremental implementation stay off (the script forces it). A timing-only experiment may use `STOP_AFTER_ROUTE=1`. |
| Where builds run | Two detached worktrees of C1, siblings of the main checkout: `<base>/MinimigAGA_TC64-p5a` (A) and `<base>/MinimigAGA_TC64-p5b` (B), `<base>` = `/home/paul/work/fpga/Xilinx/artix7`. Not the main checkout (Paul's uncommitted files), not the `osd-riscv` worktree (Phase 4 commits there, and it has no `project_1` and no submodules), not the `p5-build` worktree `$P5` (later Phase 5 commits land there while the builds run), not `MinimigAGA_TC64-v2023` (keeps the reference's runs). Justification and recipe: Task 2. Outputs (bit, reports, logs) go to the `osd-riscv` worktree's git-ignored `build/` (`$RV/build/stage_p5a_<C1>`, `$RV/build/stage_p5b_<C1>`), so Paul finds A, B and the card set in one place; nothing is written into the main checkout. |
| Paths | `$MAIN` = `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64` (read-only for every task), `$RV` = `.../MinimigAGA_TC64-riscv` (outputs only), `$P5` = `.../MinimigAGA_TC64-p5build` (branch `p5-build`, all Phase 5 commits), `$WA`/`$WB` = the two build worktrees, `$C1` = the 7-char hash of Task 1's commit. Shell is zsh: no unquoted multi-word variables, write `vivado` calls out in full or as a function (memory "vivado-lab-gotchas", zsh no-word-split). |
| SD card | **Never write to `/media/paul/AARSDISK55`** (Paul's live card). Reading it is allowed (copy files off). Paul copies the prepared set onto his card **copy** himself. |
| Vendor-neutral | The top parameters default to 0 (today's 832, every other top and the Quartus ports unchanged); `host.qip` lists the RV sources (never `rv_bscane2.v`); no vendor primitive added. A recovery switch (Task 4) is a parameter defaulting to off. |
| Timing reference | `build/stage_spicdc_49b1868/timing_summary.rpt` (main checkout): clk_114 intra-clock WNS **+0.101 ns**, WHS +0.056; spi_sck +19.166; the only failing paths are the known inter-clock `clk_gen_sdram -> clk_114` set (-0.525 ns, 16 endpoints, memory "osd-riscv" 10-17). Utilisation 53,409 LUT (84.24 %), 15,460 slices (97.54 %), 26,066 FF. |
| Gate numbers (plan 5.1/5.2) | **5.1:** clk_114 intra WNS of B >= reference - 0.1 ns = **+0.001 ns**, and >= A's clk_114 WNS - 0.1 ns; failing endpoints of B (setup and hold, all clocks) a subset of the reference's known set; `report_clocks` lists `spi_sck`; `hostcpu` hierarchical utilisation recorded for A, B and the reference. **5.2** (only if 5.1 fails): WNS >= -0.2 ns and no failing endpoint under `openaars_virtual_top/hostcpu` -- and then Paul decides whether that image goes on the board (Task 4). The same 5.1 gate applies to A against the reference (A differs from it by the Phase 1-4 bridge/cfide changes). |
| Model per task | Opus for build integration and timing (Tasks 1, 3, 4); Sonnet for mechanical work (Tasks 2, 5, 6). |
| Runtime facts | The reference build (v2023 worktree, 2026-10-17): synthesis 14 min, implementation to bitstream 29 min, reports 3 min, peak ~4 GB. Two builds in parallel on this machine (8 threads, 46 GB): est. 65-80 min wall. |

## Review Focus

1. **The wrong CPU in a bitstream** (generic not reaching the bridge, or the disabled file group still elaborating into a black box): Task 1's synth-log check and Task 3's netlist cell counts (`REF_NAME` of the hostcpu children) for both builds.
2. **A project left switched** (`HOSTCPU=rv` files enabled, generic left set) after a crashed build, so the next "832" build is not one: Task 1's restore block and Task 2's `.last_generics` diff; Task 2 builds in separate worktrees, so one switch cannot leak into the other build.
3. **The handshake crossing untimed or mis-excepted** (`osd_rx_seq` dll_28 -> clk_114 resync, `osd_tx_seq` -> `host_req_q` clk_114 -> dll_28): Task 3 reports those paths by name and shows they are constrained by the wizard.xdc 1:4 rules, and `report_exceptions -ignored` gains no line against the reference.
4. **The shared `ip/` modified by a worktree build**: the md5 before/after rule in Global Constraints, checked in Task 2.
5. **A card file set that does not boot the way Paul's card does today** (wrong config byte order, RV firmware of the wrong commit, 832 firmware that differs from the board's beyond its version string): Task 5's sha256 gates and `cfgconv --check` of every converted file.

---

### Task 1: Top parameters, the build switch `HOSTCPU`, file lists (plan 5.1 integration)

- **Phase / depends on:** plan 5.1 (`add_src`, top parameters, `host.qip`), 3.6, decision 12.10 / Phase 4 Task 12 done (5462a0f).
- **Model:** Opus.
- **Files:** modify `rtl/soc/minimig_openaars_top.v` (parameters `HOSTCPU_RISCV = 0`, `HOSTCPU_RVDEBUG = 0`, passed to `minimig_virtual_top` next to `.debug(1'b0)`), `rtl/soc/minimig_virtual_top.v` (parameters `hostcpu_riscv = 0`, `hostcpu_rvdebug = 0`; the bridge instance becomes named: `EightThirtyTwo_Bridge #(.debug(debug ? 1'b1 : 1'b0), .cpu_riscv(hostcpu_riscv ? 1'b1 : 1'b0), .rv_debug(hostcpu_rvdebug)) hostcpu`; instance name `hostcpu` unchanged -- wizard.xdc names `openaars_virtual_top/hostcpu/hw_req_reg`), `rtl/host/host.qip` (append `VERILOG_FILE` `rv_hostcpu.v`, `vexriscv/VexOsd.v`, `VHDL_FILE ../../fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`; never `rv_bscane2.v`, `VexOsd_DMT/DMJ.v`); create `tools/vivado/hostcpu.tcl`; modify `tools/vivado/build_ap040.tcl` (source it, apply before the generic is set, restore with the other restores, extra reports), `tools/vivado/README.md` (a `HOSTCPU` paragraph with the A/B commands of Task 2). `tools/vivado/build.tcl`, `build_bist.tcl`, `build_ila.tcl`, `build_no_ddr3.tcl`: one line each `source [file dirname [info script]]/hostcpu.tcl; hostcpu_apply` only if the script still opens `project_1` with this top and sets `generic` on `sources_1` -- otherwise a comment "832 only; HOSTCPU not supported (retired/diagnostic script)"; the task says which per script. `rebuild.tcl` is a Vivado 2023.2 export of 2024-03-09 that predates the AP040 sources and does not recreate today's project; it is **not** edited (Question 3).
- **Interfaces (produces):**
  - `tools/vivado/hostcpu.tcl`: `hostcpu_apply {R}` reads `::env(HOSTCPU)` (`832` default, `rv`; anything else -> `error`), adds (via the script's `add_src`) `$R/rtl/host/rv_hostcpu.v`, `$R/rtl/host/vexriscv/VexOsd.v`, `$R/fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd` if missing, sets `IS_ENABLED` true on one group and false on the other (RV group above; 832 group = every `sources_1` file matching `*/EightThirtyTwo/RTL/*` plus `*/fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`), remembers what it changed, and returns the generic suffix ` HOSTCPU_RISCV=<0|1> HOSTCPU_RVDEBUG=0`; prints `build_ap040.tcl: HOSTCPU=<832|rv> (<n> files enabled, <m> disabled)`. `hostcpu_restore` re-enables the 832 group and disables the RV group (the project's default state = 832), printed. `HOSTCPU_RVDEBUG` other than 0 is refused (Phase 5.4 is out of scope).
  - `build_ap040.tcl`: the generic line becomes `"HAVEDDR3=1 ... CHIP32=$chip32$pipe_gen$hc_gen"`; after `open_run impl_1` it also writes `util_hier.rpt` (`report_utilization -hierarchical -hierarchical_depth 4`), `util_hostcpu.rpt` (`report_utilization -cells [get_cells openaars_virtual_top/hostcpu] -hierarchical -hierarchical_depth 3`), `clocks.rpt` (`report_clocks`), `hostcpu_cells.txt` (for `hostcpu`: every leaf-parent child cell with its `REF_NAME`, plus the counts of cells whose `REF_NAME` matches `eightthirtytwo*`, `OSDBoot_832_ROM*`, `debug_bridge_jtag*`, `VexOsd*`, `rv_hostcpu*`, `OSDBoot_rv_ROM*`), `handshake_timing.rpt` (`report_timing -setup -hold` with `-to` the cells `*mycfide/osd_tx_seq_reg*` and `*mycfide/host_req_q_reg*` and `-from` `*osd_rx_seq_reg*`, `-max_paths 4 -nworst 1`), `failing.rpt` (`report_timing -max_paths 100 -nworst 1 -slack_lesser_than 0` setup and hold) and `drc.rpt`. Deliverable copy message names `$out`, not `build/stage_ap040/`.
- **Test first:** the switch is checked before any full build by a short Vivado batch run in Task 2's worktree (see Task 2 step 3, "elaboration smoke"), not here; this task's own red/green is a static one: `grep -c 'cpu_riscv' rtl/soc/minimig_virtual_top.v` = 0 before, >= 1 after; `tclsh` parse check `echo 'source tools/vivado/hostcpu.tcl' | tclsh` (procs only, no Vivado calls at source time) succeeds; `git diff --stat 5462a0f..` over `rtl fw fpga tools/vivado` lists only this task's files plus nothing else.
- **Steps:** (1) the top parameters and the named bridge instance; (2) `hostcpu.tcl` and the `build_ap040.tcl` hooks and reports; (3) the other build scripts per the rule above; (4) `host.qip`; (5) the boot ROM check: `make -C fw/ctrl_boot_rv` into a scratch `B=` and `cmp` its `OSDBoot_rv_ROM.vhd` with the committed one (equal; if not, stop and report -- the committed ROM must match the committed sources, memory "Committed tree builds as is"); (6) README paragraph.
- **Pass gate:** static checks green; ROM `cmp` equal; `git diff` touches only the files listed; the commit message states that every default is the 832 and why the 832 build's behaviour is unchanged (a named generic map with the same value). The orchestrator commits -> **C1**, written into the ledger.

### Task 2: Build worktrees and builds A and B in parallel

- **Phase / depends on:** plan 5.1 (stage) / Task 1 (C1).
- **Model:** Sonnet.
- **Files:** none tracked. Creates `$WA`, `$WB` (detached worktrees), `$RV/build/stage_p5a_$C1/`, `$RV/build/stage_p5b_$C1/`.
- **Why this layout:** two worktrees because `build_ap040.tcl` builds `$R/project_1` and one project cannot run two builds; detached at C1 so the trees are exactly the commit (no Phase 4 edits arrive mid-build); siblings of the main checkout so the xpr's `$PPRDIR/../../MinimigAGA_TC64/ip/ddr3/*.xcix` IP paths resolve to the main checkout's 2023.2 IPs as for `MinimigAGA_TC64-v2023`; the project is a copy of the v2023 project (same base 49b1868, IP runs already complete, so no IP synthesis writes into `$MAIN/ip`).
- **Steps and commands** (zsh; `B=/home/paul/work/fpga/Xilinx/artix7`):
  1. Worktrees and submodules (the worktree-local submodule clones come from the main checkout's submodules, as v2023's did; `-c` overrides keep the shared `.git/config` untouched):
     `git -C $B/MinimigAGA_TC64-p5build worktree add --detach $B/MinimigAGA_TC64-p5a $C1` (same for `p5b`), then in each:
     `git -C $W -c protocol.file.allow=always -c submodule.EightThirtyTwo.url=$B/MinimigAGA_TC64/EightThirtyTwo -c submodule.lib/AP68040.url=$B/MinimigAGA_TC64/lib/AP68040 -c submodule.lib/AP68040-pipelined.url=$B/MinimigAGA_TC64/lib/AP68040-pipelined -c submodule.rtl/tg68k.url=$B/MinimigAGA_TC64/rtl/tg68k submodule update --init`.
     Check: `git -C $W submodule status` shows the four gitlinks of C1 without `-`/`+` (d1cd671 EightThirtyTwo, 530fc72 lib/AP68040, 972f0c5 lib/AP68040-pipelined, bfad0bd rtl/tg68k).
  2. Project copy: `cp -a $B/MinimigAGA_TC64-v2023/project_1 $W/project_1`, then `rm -f $W/project_1/.last_generics` (forces synthesis). Check: `grep -c 'MinimigAGA_TC64-v2023' $W/project_1/project_1.xpr` = 0 (all paths `$PPRDIR`-relative); `grep -c '../../MinimigAGA_TC64/ip/ddr3' $W/project_1/project_1.xpr` >= 4.
  3. Synthesis check of B first (catches a wrong switch before two hours are spent): start the B build (step 4) alone and watch its synthesis log: within ~15 min `$WB/project_1/project_1.runs/synth_1/runme.log` must show `rv_hostcpu`/`VexOsd` elaborated under `hostcpu` with `cpu_riscv = TRUE`, no `EightThirtyTwo` module, and no `black box` / `could not find module` line for the host CPU; if not, kill that build (`pkill -x vivado` is machine-wide: kill by the build's own PID from its `nohup` launcher instead) and report. A starts only after B's log passes this check (so a broken switch costs ~15 min, not two builds).
  4. The builds, each with its own log, in the background (`nohup`, `run_in_background`), one worktree each:
     `md5sum $B/MinimigAGA_TC64/ip/ddr3/*.xcix > $OUT/ip_md5_before.txt` then
     `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C HOSTCPU=rv POST_CHIP=1 POST_CI=1 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log $OUT/vivado.log -source $WB/tools/vivado/build_ap040.tcl -tclargs $OUT 0 $WB` with `OUT=$RV/build/stage_p5b_$C1`; the same for A with `HOSTCPU=832`, `$WA`, `OUT=$RV/build/stage_p5a_$C1`. Wait for `=== ALL DONE ===` in each log (match the line start, not a word: Vivado echoes the Tcl source).
  5. After both: `md5sum ... > $OUT/ip_md5_after.txt`, `cmp` before/after per build; `cp $W/project_1/.last_generics $OUT/generics.txt`; `diff` the two `generics.txt` (exactly the `HOSTCPU_RISCV` token differs; the rest equals the reference string of Global Constraints "A and B"); `md5sum $OUT/minimig_openaars_top.bit > $OUT/bit.md5`; `echo $C1 > $OUT/COMMIT`.
- **Estimate:** setup ~10 min; B smoke ~15 min; both builds in parallel ~65-80 min wall (A starts ~15 min after B). Phase 4 keeps <= 4 Verilator jobs meanwhile.
- **Pass gate:** both logs end with `=== ALL DONE ===`, both `.bit` present, synthesis of B shows the RV under `hostcpu`, the IP md5 files equal, generics differ in exactly the one token, worktrees `git status` clean (no tracked file changed by the build). Failure of the build itself (error, not timing) -> stop and report with the log tail.

### Task 3: Fit and timing record (plan 5.1 gate)

- **Phase / depends on:** plan 5.1 gate / Task 2.
- **Model:** Opus.
- **Files:** create `findings/osd-riscv/phase5.md` (sections "Builds", "Fit", "Timing", "Handshake paths", "Netlist CPU check"); `$RV/build/ref_spicdc/` (untracked) for the reference's hierarchical report.
- **Steps:**
  1. Reference hierarchy (the reference build wrote only flat reports): copy `$B/MinimigAGA_TC64-v2023/project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp` to `$RV/build/ref_spicdc/` (first check its timestamp is 2026-10-17 16:1x, i.e. still the reference's run), then a no-project batch run: `open_checkpoint`, `report_utilization -cells openaars_virtual_top/hostcpu -hierarchical -hierarchical_depth 3`, `report_timing_summary`, `report_exceptions -ignored`, the `failing.rpt` command of Task 1 (~10 min, `env LD_LIBRARY_PATH=... LC_ALL=C vivado -mode batch -nojournal -log ... -source <scratch tcl>`; the scratch Tcl lives in the scratchpad, not in the repo).
  2. Tables in `phase5.md` (A, B, reference side by side): total LUT/FF/BRAM tiles/DSP/slices (% of the part); `hostcpu` LUT/FF/RAMB36/RAMB18/DSP with its children (`genrv.myrv`/`gen832.my832`, `bootrom`, `hostcache`); B - A delta next to the Phase 1 OOC expectation (+661 LUT, +278 FF, +2.5 BRAM tiles, `findings/osd-riscv/ooc-2023.2.md`); intra-clock WNS/WHS per clock (clk_114, dll_28, clk_38, clk_148, clk_ddr100, spi_sck); the failing-endpoint list per build vs the reference's known set; `report_clocks` line of `spi_sck` per build; `exceptions_ignored.rpt` and `cdc.rpt` summary lines diffed against the reference's (new lines are listed and explained, the handshake crossing expected among them as `dll_28 <-> clk_114` paths covered by the wizard.xdc 1:4 rules).
  3. Handshake paths (Task 10 ledger note "Phase 5.1: report_timing on osd_rx_seq_reg/osd_tx_seq_reg/host_req_q_reg"): from `handshake_timing.rpt` of both builds: start/end clock, the exception applied (multicycle 4 setup / 3 hold), slack; none unconstrained.
  4. Netlist CPU check from `hostcpu_cells.txt`: B has 0 cells of the 832 group and >= 1 `VexOsd`; A has 0 RV cells and >= 1 `eightthirtytwo_cpu`.
  5. Verdict per build against the 5.1 gate numbers (Global Constraints).
- **Pass gate:** `phase5.md` complete; both builds meet 5.1 -> Task 4 is skipped and the ledger says so; a build that misses 5.1 -> Task 4. If B's `hostcpu` LUT exceeds the OOC rv0 figure by more than 15 % (1,532 LUT -> > 1,762), the reason is written down (it does not fail the gate by itself).

### Task 4: Timing / fit recovery (plan 5.2) -- conditional

- **Phase / depends on:** plan 5.2 / Task 3 verdict "miss" for B (or A).
- **Model:** Opus.
- **Files:** `findings/osd-riscv/phase5.md` ("Recovery"); RTL only behind a new parameter defaulting off, and only after Paul's go (below).
- **Ladder** (stop at the first rung that passes 5.1; every rung recorded with numbers):
  1. **Classify** from `failing.rpt` / the worst 20 clk_114 paths: (a) inside `hostcpu` (VexRiscv register-file/I$ paths, the OOC worst paths); (b) elsewhere, route-dominated (net delay > 70 % of the path) -- congestion from the extra ~660 LUT at 98 % slices; (c) elsewhere, logic-dominated.
  2. **(b), and (a) when route-dominated:** rebuild B with `IMPL_EFFORT=high` (the script's existing switch: place `ExtraTimingOpt`, phys_opt/route/post-route `AggressiveExplore`; same RTL) in `$WB`, new `OUT=$RV/build/stage_p5b_${C1}_hi`, ~1.5 h. No Paul decision needed: the bitstream content is the same design. A is **not** rebuilt (the A/B still differs only in the CPU and the implementation directive; recorded).
  3. **Iterate small** (memory "fpga-iterate-small"; minutes per run): `tools/vivado/ooc_hostcpu/go_bridge.sh rv0` at 8.815 ns and at a tightened period (e.g. 8.0 ns) to show which candidate fix moves the hostcpu paths: a VexRiscv regeneration with the I$ `twoCycleRam` option, or a pipeline register in `rv_hostcpu.v` on the bus outputs, each as a scratch copy (`VEXSRC=`, never the committed `.v`), measured in OOC only.
  4. **Stop and report to Paul** before any change to the committed CPU RTL or a regeneration: either changes the verified core (L1/L2/L3 re-runs: Phase 4's quick set `boot`, `hdd`, `fdd_rd` both CPUs plus L1 `all` and L2 `all`, ~1-1.5 h) -- Paul decides. Also stop if the 5.2 gate (WNS >= -0.2 ns, no failing endpoint under `hostcpu`) is met but 5.1 is not: Paul decides whether that B goes on the board.
- **Pass gate:** 5.1 met by a rebuilt B (its numbers in `phase5.md`, Task 3 step 4 repeated for it), or a stop report with the classification, the OOC numbers and the proposed fix.

### Task 5: The A/B card file set

- **Phase / depends on:** plan 5.3 (card with both firmware files), exec-4 "What Phase 5 consumes" item 5 / Task 1 (C1); runs while the builds run.
- **Model:** Sonnet.
- **Files:** none tracked. Creates `$RV/build/ab_card_$C1/` with `RV32OSDA.BIN`, `832OSDAD.BIN`, `MINMGAR.CFG`, `MINMGAR1.CFG` .. `MINMGAR4.CFG`, `SHA256SUMS`, `PROVENANCE.txt`, and `orig/` (read-only copies of the live card's `832OSDAD.BIN` and `MINMGAA*.CFG`).
- **Decisions (justified):**
  - **`RV32OSDA.BIN`**: built from C1's `fw/ctrl_rv` the way L3 builds it (`hs_fwrv`: `make -C fw/ctrl_rv B=<dir>` under the `date` shim, `L3_DATE=2026-01-01`) in `$WA` (clean tree), so it is byte-identical to the image Phase 4 Task 12 verified (`$RV/sim/l3/run_fw12/fwrv/RV32OSDA.BIN`); gate: `git diff --quiet 5462a0f $C1 -- fw/ctrl_rv` and equal sha256. Its version string shows 2026-01-01 (said in the instructions). Needs a core with the Phase 4 RTL: B only (exec-4 ledger finding: on an older core it reads `audio_buf` at `0xFFFFFFB4`).
  - **`832OSDAD.BIN`**: built by `make -C $WA/sim/l3/fw832 B=<dir> E832DIR=$MAIN/EightThirtyTwo` (the unchanged `fw/ctrl_832` of C1, the image the L3 832 legs ran), **not** the board's current file, because it is the exact binary whose SPI/hw traces the Phase 4 differential compared with the RV, and it is reproducible from C1. Safety check against the board's file (`/media/paul/AARSDISK55/832OSDAD.BIN` = `build/cdfw_phase3c/832OSDAD.BIN`, md5 204b4cbe, same sources 8f8cf88): `git log -1 --format=%h -- fw/ctrl_832` on C1 is 8f8cf88 or older, and `cmp -l` of the two images differs only inside the version-string bytes (locate them from `832OSDAD.map` / `strings -t x`); if anything else differs (toolchain drift), use the board's file instead and record why. Both are 832 firmware; A and the fallback `stage_spicdc_49b1868` both run either.
  - **Config files**: the live card has only the 832 family (`MINMGAA.CFG`, `MINMGAA1..4.CFG`). Copy them off read-only to `orig/`, convert each with `cfgconv --to-rv` (built as `sim/l3/card/Makefile` builds it: `make -C fw/ctrl_rv/tools/cfgconv B=<dir>`) to `MINMGAR.CFG`, `MINMGAR1..4.CFG`, and `cfgconv --check` each (fields equal; this is the round trip already closed on these five files in 6ef7d08). Pre-converted files make B's first boot deterministic; the first-boot conversion path is a Phase 6 parity row (Question 2). The 832 files stay as they are (A reads them).
- **Steps:** build/copy as above; `sha256sum` everything into `SHA256SUMS`; `PROVENANCE.txt` = C1, the build commands, the sha256 of the L3 reference images, the `cmp -l` summary, the cfgconv check output.
- **Pass gate:** RV image sha256 = Task 12's; 832 image check passed (or the fallback to the board's file recorded); five converted configs pass `--check`; nothing written to `/media/paul/AARSDISK55` (the task shows `find /media/paul/AARSDISK55 -newer <task start marker>` empty).

### Task 6: Board-test protocol, plan status, hand-over (STOP)

- **Phase / depends on:** plan 5.3 gate ("both bitstreams boot from one card"), plan 9 (first rows) / Tasks 3 (and 4 if run), 5.
- **Model:** Sonnet.
- **Files:** create `findings/osd-riscv/ab-board-test.md` (the protocol, with an empty results table for Paul's paste-back); modify `doc/osd-riscv-plan.md` (header status: "Phase 5 builds done, A/B board test pending"; section 8 Phase 5: 5.1 done with A/B commit C1 and numbers, 5.2 skipped/done, 5.3 card ready, merge **deferred** until Paul's go, 5.4 not started) and `doc/osd-riscv-exec-5.md` status line (the controller committed the plan as this file on `p5-build`).
- **Protocol content** (exact commands, `$RV/build/...` paths filled in):
  1. **Card copy**: on Paul's card **copy** (not the live card): copy `RV32OSDA.BIN`, `MINMGAR.CFG`, `MINMGAR1..4.CFG` to the root; rename the copy's `832OSDAD.BIN` to `832OSDAD.PRE` (`832OSDAD.OLD` is already taken on the card), then copy the set's `832OSDAD.BIN`; `sync`; `sha256sum -c SHA256SUMS` run against the mounted copy. Everything else on the card stays (kickstarts, HDFs, ISO, `drivesnd.bin`).
  2. **Serial**: `picocom -b 115200 /dev/ttyUSB0` = host-CPU log (boot ROM + firmware UART, decision 12.6; enable DebugMode in the OSD Misc page for the stack/`osd_rdy_timeouts` line); `/dev/ttyUSB1` = Amiga `SER:` (38400 or 57600; not needed for the first pass). Log each session to a file (`picocom --logfile`).
  3. **Loading**: power-cycle the board first (JTAG loads do not reset peripherals; memory "vivado-lab-gotchas"), then `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog -source $P5/tools/vivado/program.tcl -tclargs $RV/build/stage_p5a_$C1/minimig_openaars_top.bit`; expect `=== DONE: ... DONE pin = 1 ===`. Same for B. Between A and B: power-cycle, then load. Flash is not touched.
  4. **A (832, ~15 min)**: ttyUSB0 shows the 832 boot ROM loading `832OSDAD.BIN`; OSD opens; Kickstart boots to Workbench from the HDF; one ADF read; CD ISO directory listing; one CD-DA track plays. Same as the stage_spicdc acceptance: A must behave as the fallback does.
  5. **B (RISC-V, ~30 min)**: ttyUSB0 shows the RV boot ROM banner and `RV32OSDA.BIN` loading, the firmware banner and platform line, `MINMGAR.CFG` loaded (no conversion message); OSD: open/close by button and keyboard, walk every main page, key repeat, file selector scroll; DebugMode line `osd_rdy_timeouts` stays 0; Kickstart load and boot to Workbench from the HDF; ADF read and write (survives reload); CD ISO listing + CD-DA play/pause/stop; config save to a slot and reload; reset from the OSD. Any lock-up: note the last ttyUSB0 line.
  6. **Paste back**: the two ttyUSB0 logs, the filled results table (row per check: A ok/fail, B ok/fail, note), and any OSD text that differs between A and B.
  7. **Fallback**: power-cycle, load `$MAIN/build/stage_spicdc_49b1868/minimig_openaars_top.bit` with the live card.
- **Pass gate (this run's end):** protocol committed with C1's paths and the sha256 of A, B and the card files; plan status updated; the ledger says "STOP: waiting for Paul at the board (Task 6 protocol)". No further task runs until Paul reports.

---

## What Phase 6 consumes

1. A and B (`$RV/build/stage_p5a_$C1`, `stage_p5b_$C1`, or B's recovery rebuild) with their reports and `findings/osd-riscv/phase5.md` (fit, timing, handshake paths, CPU netlist check).
2. Paul's A/B results (`findings/osd-riscv/ab-board-test.md`); any failure goes through systematic debugging before Phase 6 starts (L3 reproduction first).
3. The card set `$RV/build/ab_card_$C1/` (both firmwares, both config families) as the Phase 6 parity/stress card base (plan 9, 7.4), plus the first-boot conversion row still to run.
4. The `HOSTCPU=832|rv` build switch and the two-worktree recipe for every later A/B build.
5. Open: merge into `5.0-040-pipelined` (only after the board A/B and Paul's go); Paul's RTL review of the handshake (waived before hardware); Phase 5.4 debug bridge; the 832 board Dhrystone (exec-4 Task 21, deferred to a board session).

## Decisions (controller rulings, 2026-10-19)

Paul was away from questions; the Phase 4 controller ruled on the planner's five questions, all
as proposed (Phase 4 ledger, line "Ruling (P5 planner Qs ..."; cost if wrong: Paul overrules,
rework small). Execution runs on branch `p5-build` (ledger line "Ruling: Phase 5 runs on branch
p5-build").

1. **Firmware images on the card**: the reproducible images the L3 differential ran (version
   string dated 2026-01-01), not the board's current `832OSDAD.BIN` and a fresh-dated RV build.
   **Yes** (byte-identical to the simulated images; the 832 one is checked to differ from the
   board's file only in the version string).
2. **Configs**: pre-converted `MINMGAR*.CFG` (from the card's `MINMGAA*.CFG`) on the card copy;
   the first-boot conversion is tested in Phase 6. **Yes.**
3. **`rebuild.tcl`** (a 2024 project export that predates the AP040 sources): left untouched;
   `build_ap040.tcl` + `hostcpu.tcl` are the build path. **Yes.**
4. **Recovery without asking**: if B misses timing only on route-dominated paths, Task 4 rebuilds
   it with `IMPL_EFFORT=high` (same RTL) without asking; any RTL/core change waits for Paul.
   **Yes.**
5. **Board order**: A first, then B, each after a power cycle; fallback `stage_spicdc_49b1868`
   with the live card. **Yes.**
