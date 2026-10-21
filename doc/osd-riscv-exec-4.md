# OSD host CPU -> VexRiscv: executable plan, stage 4 (Phase 4 -- L3 co-simulation, 832-vs-RV differential, OSD reply-ready handshake)

Status: **Phase 4 done (gate run 2026-10-21; T20 4 KB I$ kept by Paul 2026-10-21; T21 deferred to the Phase 5 board session); merged with fix-cdpoll and p5-build at 43c6cc7; build B rebuilt from 43c6cc7 (results: controller).** Planned 2026-10-18. Revised the same day after Paul's answers (section "Decisions (Paul, 2026-10-18)"): the xsim scope is cut to Paul's time budget (Decision 1).

> For agentic workers: execute task by task with superpowers:subagent-driven-development
> (SDD tooling extracts tasks by their `### Task N` heading). Each task ends at its pass
> gate; the orchestrator commits.

**Goal.** Prove in simulation, before any board test, that the RISC-V firmware
`fw/ctrl_rv` drives the real Minimig SPI slaves -- `userio_osd`, `paula_floppy`,
`gayle` (IDE and the ATAPI CD on port 2) -- with the same function and timing
as the 832 firmware does (decision 12.13): an L3 co-simulation that runs the real
boot ROM and firmware of **either** CPU against the real slaves, an Amiga-side
bus-functional model and reproducible card images, with data checks against
golden images, a normalised 832-vs-RV trace diff whose only differences are
listed ones, and margin monitors for every row of plan 7.1. On the way, a small
backward-compatible OSD "reply byte ready" handshake (RTL + RV firmware) replaces
`SPI_reply()`'s four `SPIN`s and the 40-cycle gap rule. The phase ends at a gate
from which Phase 5 (build integration, A/B) starts; what Phase 5 consumes is at
the end.

Parent plan: `doc/osd-riscv-plan.md` (sections 7.1, 7.2, 8 Phase 4 4.1-4.6, 6.4,
12; decisions 12.4, 12.6, 12.10-12.13 bind). Stage before this one:
`doc/osd-riscv-exec-3.md` (its "What Phase 4 consumes", items 1-11, is the input
of this plan). Spec for this stage: the planner brief
`.superpowers/sdd/osd-riscv-exec-4-planner-brief.md` (untracked) and decision
12.13 (plan section 12).

**Architecture summary.** One new bench `sim/l3/` (plan 7.2 called it
`sim/spi_cdc/hostrv/`; one bench serves both CPUs, so it gets its own directory --
Decision 5). It is built from the L2 bench's parts (the real
`EightThirtyTwo_Bridge` with `hostcache`, the real `cfide`, `sdram_host_model.v`,
`sd_spi_model.v`, the GHDL->Verilog conversion for Verilator), with the L2
monitors moved into a shared include so both benches use one copy (Task 2). The
bridge is built with `cpu_riscv = true` (VexRiscv + `OSDBoot_rv_ROM`, card file
`RV32OSDA.BIN`) or `false` (the 832 + `OSDBoot_832_ROM`, `832OSDAD.BIN` built from
the unchanged `fw/ctrl_832` in a scratch copy): `CPU=rv|832`. Behind cfide sit the
real slaves wired as `minimig_virtual_top.v` / `minimig.v` wire them, and the
Amiga side is a set of small bus-functional models (floppy CIA lines + Agnus disk
DMA, 68k-side Gayle/ATA/ATAPI driver, audio-ring player, OSD key injector, RTC,
Akiko requester), driven by a scenario script (`+SCENARIO=`). Data checks run
offline in Python against the card's own files. The differential compares the
two CPUs' normalised SPI (`spi.txt`) and hw-register (`hw.txt`) traces after a
committed list of expected differences.

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Earlier constraints | Everything in `doc/osd-riscv-exec-3.md` "Global Constraints" still binds unless a row below changes it: worktree/branch `osd-riscv`, one commit per task with only its files, never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`; commit message ends with the implementer's `Co-Authored-By` line; I/O map, UART write-only, interrupts (legacy path only), C dialect/flags, C library, byte order, host-test rules, sizes; and the exec-1/exec-2 rows they cite (run directories `run_${RUNTAG}`, never reuse a RUNTAG across a code change, lane rule, bus contract, toolchain pin, interrupt controller semantics, Verilator backends). |
| Branch | Nothing of this phase merges into or is pushed to `5.0-040-pipelined` (or superproject `main`): `osd-riscv` only, until the Phase 5.3 board A/B and Paul's go. No `git push` by any task. |
| Scope (decision 12.13) | `sim/**` benches, `tools/sim/**`, `findings/osd-riscv/**`, `doc/**`. **RTL**: only Tasks 9 and 10 (the reply-ready handshake) touch `rtl/`: `rtl/minimig/userio_osd.v`, `userio.v`, `minimig.v`, `rtl/host/cfide.vhd`, `rtl/soc/minimig_virtual_top.v`. Floppy, HDD and CD RTL (`paula*.v`, `gayle*.v`, the audio path) are **not** changed; a defect L3 finds there is reported to Paul with its evidence, not fixed (Decision 8). **Firmware** (`fw/ctrl_rv`): only Task 11 (the handshake) and the fix-on-finding rule below. `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/ctrl_boot_rv`, `fw/dhrystone_832` stay read-only (benches build copies of them in run directories). |
| RTL review | Tasks 9 and 10 are flagged **"RTL: Paul reviews before any bitstream"**. Each argues in its commit message and in `findings/osd-riscv/phase4.md` why the 832 build behaves unchanged, and shows it with a bench (Task 10: the 832 L3 traces before/after identical, `sim/spi_cdc/host832/run.sh` PASS). The 832 bitstream reference stays `build/stage_spicdc_49b1868` (md5 28b07e8c). Plain Verilog/VHDL, no vendor primitive, new ports defaulted so every other top still elaborates (core vendor-neutral rule). |
| Fix-on-finding (firmware) | A parity defect that L3 finds in `fw/ctrl_rv` (the RV run differs from the 832 run of the same scenario beyond `sim/l3/expected_diff.txt`, or fails a data check the 832 passes) is fixed as its own commit with: the failing RV run (RUNTAG), the passing 832 run of the same scenario, a host test or L1/L2 case that is red before and green after (where the code is host-testable), the RV re-run green, the host suite (`make -C fw/ctrl_rv/test run mutants`) and L2 `fwboot` green, a README "Differences" row only if behaviour now differs from the 832, and an Opus review of the hunk. A defect present in both firmwares is **not** fixed (parity): it gets a line in `findings/osd-riscv/phase4.md` "Shared defects" for Paul's backlog. |
| Simulators (Decision 1: Paul's time budget, xsim at most ~4 h for the whole phase) | All L3 scenarios and the L2 regressions run on **Verilator** (`SIM=verilator`, GHDL `--synth` for the VHDL as in L2). **xsim 2023.2 runs only:** the shortened boot cross-check `boot_short` once per CPU (Task 4 RV, Task 6 832; `run.sh compare` SAME against the Verilator `boot_short` of the same tree), the handshake RTL's unit benches (Task 10: `tb_spi_cdc` `+RDY=1`, its mutant and default grid; L2 `t_osdrdy` and L2 `all`, the L2 README's rule for RTL commits) and Task 1's measurement sweep. Budget: Task 1 ~0.5 h, Task 4 ~0.7 h, Task 6 <= 1.5 h, Task 10 ~1 h = ~3.7 h; nothing else on xsim, and Task 23 does not repeat them. **X-sensitivity check instead of xsim per scenario:** every L3 scenario that is a pass gate (and L2 `fwboot` where a task re-runs it) also runs a second Verilator build with randomised uninitialised state, and the two runs must `compare` SAME. Build flags `--x-assign unique --x-initial unique` (instead of the default `--x-assign 0 --x-initial 0`), run with `+verilator+rand+reset+2 +verilator+seed+<n>` (probed with Verilator 5.020 on this machine 2026-10-18: without `+verilator+rand+reset+2` the state still starts at 0; two seeds give different values); `XRAND=1` selects it in `run.sh` (both benches, through `hostsim.sh`), `XSEED=<n>` sets the seed (default: `cksum` of the RUNTAG, printed as `=== XRAND seed <n>`, a line `compare` ignores). `run.sh xpair <scenario>` runs the pair (`run_<RUNTAG>` and `run_<RUNTAG>_xr`) and compares them. A difference between the two is a finding (state the design or a bench model reads before it is written; Phase 3 Task 6's undriven I2C status read is the kind it catches): a bench-model cause is fixed in the bench, an RTL or firmware cause is reported (Decision 8 / fix-on-finding). **One xsim at a time** (machine-wide). Verilator runs may run in parallel: at most 6 at once (8 threads, 46 GB). iverilog stays the reference for the Verilog-only benches (`sim/osd_keyq`, `sim/gayle`). |
| Simulation speed (for estimates) | Measured in Phase 3: Verilator ~0.47 M `clk_114` cycles/s (`fwboot` 176.4 M cycles in 372 s), xsim ~22.5 k cycles/s (`fwboot` 7,835 s). L3 estimates below assume those rates; Task 4 measures the RV cycles to the main loop and Task 6 the 832's, and both write the measured rates into `sim/l3/README.md`; later tasks re-estimate from them. |
| Long runs | A run expected to take more than 1 h is started in the background (`run_in_background` or `nohup`) with its log in the run directory, and only when the session has the time left to collect it; never queue work behind a session-limit reset. Report each run's wall time. |
| TIMER in L3 | cfide's `tick_in` comes from the bench's tick generator: `+TICKDIV=<n>` = one pulse every n `clk_28` cycles. `n = 1` (default) is L2's 643x-fast TIMER (one count = 256 `clk_28`); `n = 643` is the board's 44.1 kHz (one count = 5.804 ms = 658,432 `clk_114`). `+TICKDIV_AT=scenario` switches from 1 to n when the scenario script starts (after the main-loop milestone), so boot stays fast. Every scenario states its rate; a scenario whose result depends on the TIMER rate (CD-DA, CD timeouts) runs at 643 from its start. The audio player model advances one frame per tick, like the hardware. |
| cfide generics in L3 | The board's (`rtl/soc/minimig_openaars_top.v` -> `minimig_virtual_top`): `spimux false`, `havespirtc true`, `havei2c true`, `havevpos true`. No I2C slave (SCL/SDA inputs 1: every ADV7511 transfer NACKs, as in L2 `fwboot`). |
| OSD reply rule | Until Task 11 the RV firmware keeps `SPI_reply()`'s four `SPIN`s. From Task 11 on it polls `HOST_REQ` bit 0 (`OSD_RDY`, cfide `0xFFFFFFB4`) before each reply byte. The L3 monitor `OSD EARLY` (a reply byte loaded by `userio_osd` while a previous byte was still in its synchroniser) is a bench error in every L3 run except runs that pass `+OSD_EARLY_OK=1` (the "before" measurements of Task 8). The 832 firmware is unchanged and keeps its `SPIN`s. |
| No new count-based delays | As exec-3: no new `SPIN`, empty counted loop or `timeout++` bound in `fw/ctrl_rv`. Task 11 **removes** the `SPIN`s of `SPI_reply()`; afterwards the live `SPIN` sites are exactly two: `fpga.c:226` (after the version read) and `config.c:618` (after the reset command). A status poll bounded by TIMER is not a count delay. |
| Card images | `sim/l3/card/Makefile` on `tools/sim/mkcard.sh` (8.3 upper-case names, reproducible with `SOURCE_DATE_EPOCH`); every content file comes from a generator in `sim/l3/gen/` (python3 stdlib, `python3 -I`) or an apt tool (`xorriso`), never from a copyrighted file: the kickstart is a synthetic 256 KB file (`KICK.ROM`, size 0x40000: the firmware only checks the size), no real ROM anywhere. Two firmwares on every card: `RV32OSDA.BIN` and `832OSDAD.BIN`; config in the order the scenario says (`MINMGAR.CFG` LE and/or `MINMGAA.CFG` BE). |
| 832 firmware for the twin | Built by `sim/l3/fw832/Makefile` from a copy of `fw/ctrl_832` (unchanged since 8f8cf88, i.e. the sources of `build/stage_spicdc_49b1868`) in the run directory, with `832DIR=$(E832DIR)` (default `$(TOP)/EightThirtyTwo`; this worktree's submodule is not initialised, so set `E832DIR=<main checkout>/EightThirtyTwo`: vbcc832, 832a, lib832 are built there) and a `date` shim on `PATH` that prints `L3_DATE` (default `2026-01-01`), so the image is reproducible. The worktree's `fw/ctrl_832` is never built in place (its tracked `version.h` would change). The 832 CPU RTL comes from `E832=<main checkout>/EightThirtyTwo/RTL` as in `sim/spi_cdc/host832/run.sh`. |
| Reproducible RV firmware | L3 runs take `FW=<RV32OSDA.BIN>`; default: built by `sim/l3/run.sh` into the run directory with `make -C fw/ctrl_rv B=<run>/fwrv` under the same `date` shim, so two runs of one tree see byte-identical images (the version string has the build minute). |
| Expected differences | The only allowed differences between the RV and the 832 traces of one scenario are the rules of `sim/l3/expected_diff.txt` (Task 7), each with a comment naming its source: exec-3 hand-over item 3 (config file names/sectors and first-boot conversion writes, firmware file name/size/sectors, version strings, timeout lengths of failure paths, every line of `fw/ctrl_rv/test/gold/fmt_diff_expected.txt` in UART lines and OSD text, the string-semantics table) plus what this phase adds with evidence. |
| README rule (Paul) | Every README a task creates or changes has copy-pasteable commands from a fresh Ubuntu 24.04 machine, toolchain setup included (`bash tools/riscv/fetch-xpack.sh`, `bash tools/riscv/check-toolchain.sh`, apt packages by name: `ghdl verilator ccache mtools dosfstools fdisk xorriso python3 iverilog`), works in zsh and bash (no unquoted variable splitting; no own-line `#` comment containing `( [ {`), and uses no absolute personal path. |
| Model per task | Opus for RTL, timing-sensitive bench work, debugging and review; Sonnet for mechanical work (Paul's preference); stated per task. |

## Review Focus

1. **A late "byte done" from the previous OSD frame** (an `OSD_CMD_OSD_WR` frame written back to back, then a reply frame started within ~40 `clk_114`): a ready flag must not report the new frame's first reply byte as ready. Task 9/10 tests: the cross-frame case in `sim/osd_keyq` and in `tb_spi_cdc +RDY=1`.
2. **Bench model faults that look like firmware faults.** Every scenario runs on the 832 too, and a data check that fails on the 832 is a bench bug first (Tasks 13-18 gates require the 832 leg to pass the same checks).
3. **Timing-dependent trace content** (poll counts, key repeat, the RTC's minute, CD-DA position) making the differential noisy or masking a real difference. Task 7's normaliser collapses only listed poll frames; Task 19's teeth show a real one-byte difference survives normalisation.
4. **TIMER-rate assumptions**: a timeout or pacing that is only right at 643x speed. Scenarios declare `TICKDIV`; Task 17 runs CD-DA at the board rate, Task 16 one CD timeout path at the board rate.
5. **A stalled main loop starving the floppy FIFO or the CD-DA ring under load** (7.1 items 6/7, plan 4.4). Task 13/14 monitors with `EXTRA_WS` up to 64 in Task 19; Task 17 CD-DA during an HDF transfer.

---

### Task 1: Pin the OSD reply failure edge of the real `userio_osd` (measurement)

- **Phase / depends on:** plan 7.1 item 2 (exec-3 hand-over item 8: "pin it once with `tb_spi_cdc +SWEEP=1` on the `osd` test") / none.
- **Model:** Sonnet.
- **Files:** create `findings/osd-riscv/phase4.md` (title, a "Measurements" section with this task's table, a "Shared defects" section, empty). No bench change (Task 22 writes `sim/spi_cdc/README.md`).
- **Interfaces:** produces the measured edge `E_osd` (the smallest `+GAP` at which `osd` passes 3/3 in every skew pair) that Tasks 8 and 12 quote.
- **Test first:** none (a measurement); the reference is `tb_spi_cdc`'s own `=== PASS` at its default grid (`RUNTAG=p4t1ref bash sim/spi_cdc/run.sh`) before the sweep.
- **Steps:** run the sweep (`+SWEEP=1`: every even gap 2..80) on the `osd` test only (`+TESTS=8`) with `+OSD_MIN_GAP=0` (count every failure) and `+REPS=10`, over the seven default (SCKDLY, C28DLY) pairs; Table per pair: the largest failing gap and the smallest gap from which all larger gaps pass. Note that `tb_spi_cdc`'s `+GAP` adds a random 0..3 per access, so the edge is a band.
- **Commands:** `RUNTAG=p4t1ref bash sim/spi_cdc/run.sh` (~15 min), then `RUNTAG=p4t1 XARGS="+SWEEP=1 +TESTS=8 +OSD_MIN_GAP=0 +REPS=10" bash sim/spi_cdc/run.sh` (one seed, ~15-20 min). xsim total ~0.5 h.
- **Pass gate:** the table is in `phase4.md` with `E_osd` and its band; the default-grid reference PASS; `git status rtl` clean. (If the osd test fails at gaps >= 40 in any pair, record it and stop: it would contradict the 1e135e7 finding.)

### Task 2: Shared L2/L3 simulation infrastructure (no behaviour change)

- **Phase / depends on:** plan 7.2 reuse rule / none.
- **Model:** Sonnet.
- **Files:** create `sim/common/hostsim.sh` (bash functions), `sim/common/hostmon.vh` (Verilog monitor blocks); modify `sim/host_bridge/run.sh`, `sim/host_bridge/tb_host_bridge.v`, `sim/host_bridge/README.md` (one paragraph: where the shared parts live; also the final re-review nit: "+OSD_MIN_GAP=41 passes" -> "gives no bench error").
- **Interfaces (produces):**
  - `hostsim.sh`, sourced by `run.sh` of both benches: `hs_copy_rtl <run> <rev>` (the RTL copies of `src/`, with the `hostcache.v` `#1` fix), `hs_ghdl_convert <run> <cpu_riscv> <extra_ws> <cfide generics...>` (the L2 conversion incl. the RAM note check, black-box deletion, `romcheck.py`; `cpu_riscv` only `true` for now, Task 6 adds `false`), `hs_verilate <run> <top> <defines> <sources...>` (ccache, `-O2`, the waiver file; `XRAND=1`: `--x-assign unique --x-initial unique` and the run plusargs of the Global Constraints "Simulators" row, new in this task), `hs_xsim_build`, `hs_compare <runA> <runB>` (the L2 `compare` rules, unchanged), `hs_fwrv <run>` (Task 4 uses it: firmware build into the run directory under the `date` shim of the Global Constraints).
  - `hostmon.vh`, `` `include``d inside the bench module after the bus wires are declared (the including module defines `HM_*` macros for the names it differs in): the hw-bus snoop checks (stale ack, SPI accept, X on the bus), UART line printer, the FWBOOT SPI frame log (`+SPI_LOG`), the OSD reply-gap monitor, the stack low-water monitor, the end-of-run counters. Exactly the code of `tb_host_bridge.v` today, moved.
- **Test first:** before any edit, run and keep: `SIM=verilator RUNTAG=p4t2a bash sim/host_bridge/run.sh all`, `... mutant` (`p4t2m`), `... irqmut` (`p4t2q`), `... boot` (`p4t2b`), `... fwboot` (`p4t2f`, FW fixed: copy the BIN first).
- **Steps:** move the code; switch `run.sh`/`tb_host_bridge.v` to it; re-run every baseline target with new RUNTAGs (`p4t2*n`) and `compare` each pair.
- **Commands:** the baseline runs above, then the same with `n`-suffixed RUNTAGs, then `bash sim/host_bridge/run.sh compare p4t2a p4t2an` (and for each pair); then the X-sensitivity twin `SIM=verilator XRAND=1 RUNTAG=p4t2fr FW=<same BIN> bash sim/host_bridge/run.sh fwboot && bash sim/host_bridge/run.sh compare p4t2fn p4t2fr`. Verilator ~45 min in total (no xsim).
- **Pass gate:** every pair `compare` SAME (logs and `spi.txt`); the `XRAND` `fwboot` SAME against `p4t2fn` (or each difference explained and fixed in the bench); `wc -l sim/host_bridge/run.sh` smaller; `grep -c 'og_rw_min' sim/host_bridge/tb_host_bridge.v` = 0 (moved); README replay of the touched block in zsh and bash.

### Task 3: L3 card recipes and content generators

- **Phase / depends on:** plan 4.1 (card), exec-3 hand-over item 4 / none (uses `tools/sim/mkcard.sh`, `fw/ctrl_rv/tools/cfgconv`, `fw/ctrl_rv/test/gold/mkcfg832.py`, `mfm.py`).
- **Model:** Sonnet.
- **Files:** create `sim/l3/card/Makefile`, `sim/l3/gen/mkkick.py`, `mkadf.py`, `mkhdf.py`, `mkcue.py`, `mkiso.sh`, `mkcfg.py`, `sim/l3/card/manifest.txt` (generated: name, size, sha256 per file and image; committed so a generator change shows in review), `sim/l3/.gitignore` (`run_*/`, `card/build/`), `sim/l3/README.md` (section "Cards").
- **Interfaces (produces; all output in `sim/l3/card/build/`, `B=` overrides):**
  - `KICK.ROM`: 262,144 bytes, deterministic (word i = `0x4B49_0000 | i` BE, plus the ASCII tag `L3 SYNTHETIC KICKSTART` at 0x18 so `PatchKick1xMemoryDetection` matches nothing).
  - `TEST.ADF`: 901,120 bytes, sector s (0..1759) = 512 bytes of `(s, byte index)` tags (the layout `fw/ctrl_rv/test/gold` uses for Task 13's generator).
  - `SYNTH.HDF` (no RDB: the firmware synthesises one; size chosen so that the geometry `OpenHardfile()` computes has **more than 255 cylinders**, at most 8 MB; the generator prints the CHS it expects) and `RDB.HDF` (2 MB with its own RDB at block 0, `rdb_Flags != 0x12` so the firmware's patch path `hdd.c` "rdb_ChkSum += rdb_Flags - 0x12" runs); every 512-byte block tagged with its LBA and the file id.
  - `TEST.ISO` (`mkiso.sh`: `xorriso -as mkisofs` with fixed dates/volume id, one file `DATA.BIN` of 256 KB LBA-tagged 2048-byte blocks) and `TEST.CUE` + `TEST.BIN` (`mkcue.py`: track 1 MODE1/2352 data of 64 sectors, tracks 2 and 3 AUDIO of 2 s each, deterministic sample pattern `L = frame & 0xFFFF, R = ~frame`, standard 2 s pregap rules as `cue.c` parses them).
  - `MINMGAR.CFG` / `MINMGAA.CFG` (`mkcfg.py` builds the 832 BE file from a field table with `mkcfg832.py`'s packing, the RV file with `cfgconv --to-rv`): kickstart `KICK    ROM`; hardfile[0] = `SYNTH   HDF` synthesised RDB, hardfile[1] = `RDB     HDF`; IDE port 2 master = ATAPI CD with `TEST    CUE` (variant `cd_iso`: `TEST    ISO`); floppy drives 1, normal speed; everything else the 832 defaults.
  - Cards (`make <name>`; each 32 MB unless said): `boot` (both firmwares, both configs, KICK.ROM), `boot832cfg` (only `MINMGAA.CFG`: the RV first-boot conversion path), `fdd` (boot + TEST.ADF + `DRIVESND.BIN`), `hdd` (boot + both HDFs), `cd` (boot + TEST.CUE/BIN + TEST.ISO, config variant per `CDCFG=cue|iso`), `cdhdd` (boot + both HDFs + TEST.CUE/BIN, `CDCFG=cue`). The firmwares are inputs (`FWRV=`, `FW832=`), so `run.sh` builds them first.
- **Test first:** `make -C sim/l3/card check` (written first, red before the generators exist): builds every card twice in two directories and compares bytes; `fsck.fat -n` on each image; `mdir` lists the 8.3 names; `cfgconv --check` of both config files prints the field table `mkcfg.py` was given (field by field); `python3 -I sim/l3/gen/mkhdf.py --chs SYNTH.HDF` prints cylinders > 255.
- **Commands:** `make -C sim/l3/card check FWRV=fw/ctrl_rv/build/RV32OSDA.BIN FW832=<any 84 KB file for this check>`
- **Pass gate:** `check` PASS (reproducible, fsck clean, fields equal, CHS rule); `manifest.txt` committed; no image (card, HDF, ISO, ADF, ROM or other generated binary) is committed under `sim/l3/`, and no committed binary file there is larger than 64 KB (images are built, not tracked; the rule is about images: text sources such as `README.md` or `l3check.py` may be larger, final review M6); README "Cards" replayed in zsh and bash.

### Task 4: L3 bench and the `boot` scenario (RV)

- **Phase / depends on:** plan 4.1 (bench, cold boot to the main loop) / Tasks 2, 3.
- **Model:** Opus.
- **Files:** create `sim/l3/tb_l3.v`, `sim/l3/bfm_audio.v`, `sim/l3/run.sh`, `sim/l3/scenarios.vh`, `sim/l3/milestones_boot.txt`, `sim/l3/l3check.py` (subcommand `kick`); modify `sim/host_bridge/sdram_host_model.v` (task `dump(file)` and `+SDRAM_DUMP=<file>`, called by the bench before the verdict; L2 runs do not call it, their logs stay identical); `sim/l3/README.md` (sections "Bench", "Run", "boot").
- **Interfaces:**
  - Consumes: `hostsim.sh`, `hostmon.vh` (Task 2); cards (Task 3); `spitrace.py check` milestone syntax (Phase 3).
  - `tb_l3.v` (module `tb_l3`, parameter `EXTRA_WS`): clocks/resets as `tb_host_bridge.v` plus `+SCKDLY=<ns>` (sck at the slaves after cfide's pin register, default 1.5) and `+C28DLY=<ns>` (clk_28 after its clk_114 edge, default 0.3), as `tb_spi_cdc.v`; the bridge (`CPU` chosen at conversion), cfide (generics of the Global Constraints), `sdram_host_model` (`+SLAT`, `+SJIT`), `sd_spi_model #(.IMG_SECTORS(65536))` on `sd_cs[1]`; the real `userio_osd` (with the `CORE_CAPS` value `minimig.v` passes to `userio`, IDE2 bit included), `paula_floppy` and `gayle #(.IDE_PORTS(2))`, wired as `minimig.v` wires them (paula `_scs` = `sd_cs[4]`, userio `_scs` = `sd_cs[5]`, `direct_scs` = `~sd_cs[6]`, the hdd_* bus between paula and gayle, `ide_config0/1` -> `hdc_ena`/`hdd0_ena`/`hdd1_ena`/ATAPI bits, `floppy_config` -> `floppy_drives`) and cfide's `sd_di`/`sd_dimm` as `minimig_virtual_top.v` (~1103-1125) builds them; `userio_osd.host_ack` tied 0 with a bench error if `host_cs` ever rises (the firmware does not use `OSD_CMD_WR`); the Amiga side idle in this task (CIA lines deselected, no Gayle access, `osd_ctrl` 0); `bfm_audio` (module `bfm_audio(clk28, tick, audio_ena, audio_clear, output [15:0] aud_addr)`: the frame counter `rtl/soc/minimig_virtual_top.v` feeds the ring player from, one frame per tick while enabled, reset by `audio_clear`; cfide `audio_buf` = `aud_addr[15]`); the tick generator (Global Constraints "TIMER in L3").
  - Logs per run (Phase 3 formats): `spi.txt` (via `hostmon.vh`), `spi_t.txt` (same frames with start/end cycle, for Task 20 only, never diffed), UART lines, `=== OSD GAP`, `=== STACK low`, `=== STATS` (whole run) and `=== STATS@<event>` (cut at the scenario's end event; for `boot`: the 20th HandleFpga frame after the first one).
  - New monitor `=== OSD EARLY <n> of <m> reply bytes`: a reply byte is "early" when `userio_osd_spi` loads `sdo_reg` from `in` (negedge `sck`, `bit_cnt == 0`, `_scs` low, not the frame's first byte) while `osd1.spi0.new_byte | osd1.spi0.rx_sync | osd1.spi0.rx` is 1 (the previous byte is not yet through the clk7 synchroniser, so the reply counters have not moved). Bench error when `n > 0` unless `+OSD_EARLY_OK=1`. The `OSD GAP` lines stay as in L2.
  - Stress plusargs (used from Task 12 on): `+FAST_HW=1` = the SD model's `+SD_TOKEN_DLY=0 +SD_BUSY=1 +SD_NCR=1` and the SDRAM model's `+SLAT=2 +SJIT=0` (the fastest CPU-visible timing, plan 7.2); `EXTRA_WS` = the bridge's `rv_extra_ws` (RV only).
  - `+SCENARIO=boot_short` (the xsim cross-check, Global Constraints "Simulators"): `boot` cut at the 10th `20 0c` frame after the `OSD_CMD_VERSION` reply (the boot screen of `BootInit()`, before the kickstart upload): boot ROM, firmware load, `MMC_Init`, `LoadConfiguration`, `fpga_init` with the real `userio_osd`; est. ~55 M cycles RV (Phase 3: jump to 0x2000 at 43 M). `+SHORT_END=version` cuts it at the end of the `OSD_CMD_VERSION` frame instead (for the 832 if its run is too long).
  - `run.sh <scenario>` with `CPU=rv` (default), `SIM=verilator|xsim`, `RUNTAG`, `FW=`, `EXTRA_WS=`, `XARGS=`; `run.sh compare <a> <b>` (`hs_compare`), `run.sh xpair <scenario>` (the X-sensitivity pair). It builds the firmware(s) and the card, runs, then the scenario's checks (`spitrace.py check` milestones, `l3check.py`), and prints `=== <scenario> PASS|FAILED`.
  - `scenarios.vh`: `+SCENARIO=boot`: wait for the main-loop milestone (first HandleFpga frame), then 20 more HandleFpga frames, then end with DONE-less PASS. Later tasks add their scenarios here.
  - `l3check.py kick <run>`: the 256 KB Amiga memory the firmware uploaded (the SDRAM model's dump at the host addresses `SendFileV2` writes, `(0xf80000 + i) ^ 0x680000` and the 0xfc0000 mirror, read through the model's `+SDRAM_DUMP=<file>` task called before the verdict) equals `KICK.ROM` byte for byte.
- **Test first:** `milestones_boot.txt` from the sources (boot ROM lines, `MMC_Init`, `LoadConfiguration` finding `MINMGAR.CFG`, `fpga_init` version reply as the real `userio_osd` answers it -- compute the bytes from `rtl/minimig/minimig_version.vh` and the caps --, `Loading kickstart ROM...`, the kickstart file size line, no `ROM loading failed`, `OsdDoReset` release frame, then >= 20 HandleFpga frames `10 00 00 00 00 00 00 / ..` -- the real main loop, not the fatal-error loop). Run against the Phase 3 image on the `boot` card with the kickstart removed (`make -C sim/l3/card boot NOKICK=1`): must FAIL (the error loop).
- **Steps:** bench + models + run.sh; first Verilator run, measure cycles to the main-loop milestone and set `L3_BOOT_TO` = 1.5x; record cycles/s; the `XRAND` twin; then `boot_short` on Verilator and once on xsim.
- **Commands:** `make -C fw/ctrl_rv && SIM=verilator RUNTAG=p4t4 bash sim/l3/run.sh xpair boot && SIM=verilator RUNTAG=p4t4n NOKICK=1 bash sim/l3/run.sh boot && SIM=verilator RUNTAG=p4t4s bash sim/l3/run.sh boot_short && RUNTAG=p4t4x bash sim/l3/run.sh boot_short && bash sim/l3/run.sh compare p4t4x p4t4s`. Estimate: Verilator `boot` 5-8 min (130-180 M cycles), its `XRAND` twin ~1.3x, `NOKICK` ~6 min, `boot_short` ~2 min (in parallel: ~10 min wall); xsim `boot_short` ~40 min (the RV's whole xsim share of Phase 4).
- **Pass gate:** `boot` PASS and its `XRAND` twin SAME; `boot_short` PASS on Verilator and xsim (compare SAME, xsim `X 0`); `NOKICK` run FAILS at the main-loop milestone; `l3check.py kick` PASS; no `EXC`/`TRAP` line; `OSD EARLY 0` -- **if `OSD EARLY` > 0 or the version reply is wrong**: that is the "before" finding of plan 7.1 item 2 on the real `userio_osd`; record it in `phase4.md`, re-run with `+OSD_EARLY_OK=1` to finish the other checks, and the controller runs Tasks 9-11 before Task 5 (the gate's other items stay); `OSD GAP`, `STACK low` (first kickstart card: re-take of the Phase 3 figures, final review "Rulings in hindsight"), `STATS@boot`, cycles to the main loop and the measured cycles/s written to `sim/l3/README.md`.

### Task 5: Margin monitors and boot data checks (7.1 items 1, 3, 4, 5, 12, 14) + RTC model

- **Phase / depends on:** plan 7.1 / 7.2 "margin monitors" / Task 4.
- **Model:** Opus.
- **Files:** create `sim/l3/rtc_model.v`, `sim/l3/mon_l3.vh` (L3-only monitors), `sim/l3/gold/mmc_init_rv.txt`; modify `tb_l3.v`, `scenarios.vh`, `l3check.py` (`order`), `README.md` ("Monitors").
- **Interfaces:**
  - `rtc_model` (module `rtc_model(input cs_n, sck, mosi, output miso)`): the SPI RTC `fw/ctrl_rv/rtc.c` talks to on `sd_cs[7]` (read the protocol from `rtc.c`), answering reads with a fixed BCD time `2026-01-01 00:00:00` that does not advance (so the RTC frames are time-independent), recording writes; it prints `=== RTC CS high min <n> ns` (shortest CS-inactive time between two RTC transfers) and the datasheet minimum the task takes from the part `rtc.c` names (cite the datasheet value in the README; if no datasheet is in `doc/rtc/`, write "not found" and use the firmware's own spacing as the record).
  - `mon_l3.vh` prints one line per 7.1 item, `=== MARGIN <item> <name> min <value> <unit> (bound <value>, <ok|LOW>)`:
    1 stale ack count (bound 0); 3 direct mode: cycles from the 4096th `sck` edge of a direct transfer to `direct_scs` release, and RDSPI ack -> DisableDMode request (`tb_832_dmode.v`'s `L`), bound: 202e077's "word latched on its last sck edge" means any value >= 0 passes, the figure is recorded; 4 per slave (paula `sd_cs[4]`, userio `sd_cs[5]`): cycles from the last `sck` rising edge of a frame to its select rising, bound 2 `clk7_en` periods = 32 `clk_114` (derive it from `userio_osd_spi.v`/`paula_floppy.v` in the README and correct the number if the RTL says otherwise); 5 SPI DATA write accepted while `SD_busy` (bound 0); 12 RTC CS high (above); 14 kickstart order: the cycle of the last SDRAM write into the kickstart region and the cycle `userio_osd.cpurst` falls (bound: write before release).
  - `+SD_LOG=1` in `boot`: the firmware's `MMC_Init` command sequence after the jump to 0x2000 is compared with `gold/mmc_init_rv.txt` (taken from `fw/ctrl_rv/test`'s `mmc_test` golden for the same card model; exec-3 deferred: "CMD golden from the boot ROM log; the firmware's MMC_Init log is stronger").
  - `l3check.py order <run>`: item 14 from the log lines.
- **Test first:** each monitor gets a red case in a run copy of the bench (not committed): a forced stale ack (the L2 mutant bridge) for item 1; `+SCKDLY` large enough to break item 4's bound if it can, else a bench-side early CS release task; a deliberately wrong golden line for the MMC check.
- **Commands:** `SIM=verilator RUNTAG=p4t5 bash sim/l3/run.sh xpair boot` (~15 min wall; no xsim: the monitors are bench code, the RTL is unchanged).
- **Pass gate:** `boot` PASS with every `=== MARGIN` line present and `ok`; the red cases each turn their line `LOW`/FAIL (listed in the README with the RUNTAG); MMC sequence equal; RTC frames present and constant across two runs with different `+SLAT`; `XRAND` twin SAME.

### Task 6: The 832 in L3 (`CPU=832`)

- **Phase / depends on:** plan 4.2 (golden traces from the 832 with the same card) / Tasks 4, 5.
- **Model:** Opus.
- **Files:** create `sim/l3/fw832/Makefile`, `sim/l3/fw832/date.sh` (the shim); modify `sim/common/hostsim.sh` (`hs_ghdl_convert` with `cpu_riscv=false`: the EightThirtyTwo VHDL from `E832`, `fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`, `sim/spi_cdc/host832/debug_bridge_stub.vhd`), `sim/l3/run.sh` (`CPU=832`), `tb_l3.v` (the 832 has no `RV_HOSTCPU_STATS`/`EXC`; `boot_seen` = first read of 0x2000 works for both), `milestones_boot.txt` (per-CPU lines: `UART`/`SPI` milestones that differ get a `CPU=rv|832` prefix -- only boot ROM file name, firmware version string, config name), README ("832").
- **Interfaces:** `make -C sim/l3/fw832 B=<dir> E832DIR=<dir>` -> `<dir>/832OSDAD.BIN` (+ `.map`); `run.sh` passes it as `FW832=`. `CPU=832` runs the same scenarios and checks; logs carry `=== CPU 832`.
- **Test first:** `make -C sim/l3/fw832` twice -> byte-identical BINs (date shim works); `cmp` against an in-place build is not done (never build `fw/ctrl_832` in place).
- **Steps:** the 832 conversion: if `ghdl --synth` cannot convert the EightThirtyTwo sources, stop and report (an xsim-only 832, hours per boot run, does not fit Decision 1's budget: Paul decides); else Verilator `boot` with `CPU=832` and its `XRAND` twin, measure cycles to the main loop (the 832 factor) and cycles/s; then `boot_short` `CPU=832` on Verilator and once on xsim (the conversion's X-check). If the Verilator `boot_short` takes more than 120 M cycles on the 832, both the xsim run and its Verilator twin use `+SHORT_END=version`, so the xsim run stays <= 1.5 h.
- **Commands:** `make -C sim/l3/fw832 E832DIR=<main>/EightThirtyTwo && CPU=832 E832=<main>/EightThirtyTwo/RTL E832DIR=<main>/EightThirtyTwo SIM=verilator RUNTAG=p4t6 bash sim/l3/run.sh xpair boot && CPU=832 ... SIM=verilator RUNTAG=p4t6s bash sim/l3/run.sh boot_short && CPU=832 ... RUNTAG=p4t6x bash sim/l3/run.sh boot_short && bash sim/l3/run.sh compare p4t6x p4t6s`. Estimate: Verilator `boot` 10-25 min plus its twin (in parallel), `boot_short` 3-6 min; xsim `boot_short` 1-1.5 h (the 832's whole xsim share).
- **Pass gate:** `CPU=832 boot` PASS and its `XRAND` twin SAME; `CPU=832 boot_short` on xsim SAME against Verilator (xsim `X 0`); same data checks (`kick`, monitors) as RV; `OSD EARLY 0` on the 832 (it is slow); the 832 factor (cycles to main loop / RV's) and both cycles/s in the README; `git status fw/ctrl_832` clean.

### Task 7: Differential tooling: normalised traces and the expected-difference list

- **Phase / depends on:** plan 4.2 / Task 6.
- **Model:** Opus.
- **Files:** modify `sim/host_bridge/spitrace.py` (subcommands `norm`, `diff`, `osd`), `sim/common/hostmon.vh` (`+HW_LOG=<file>`: `hw.txt`), `sim/l3/run.sh` (`diff <rvrun> <832run>`); create `sim/l3/expected_diff.txt`, `sim/l3/test/spitrace_test.sh` (fixtures), README ("Differential").
- **Interfaces:**
  - `hw.txt`: one line per hw-register **write** the CPU makes other than SPI DATA/CS, UART, `0xFFFFFF00/04` (bench), as `<addr> <value16>` (PLATFORM, AUDIO, INTERRUPT enable, keyboard, Akiko, RTC base, I2C, VIDEOSCALE...), and per Amiga-memory region written (`kickstart`, `AUDIO_BUFFER` ring) one `MEM <region> <sha256>` line at the scenario end; no cycles.
  - `spitrace.py norm <spi.txt> <hw.txt> <uart.txt> -r <expected_diff.txt> > <norm.txt>`: (1) drops the listed poll frames -- `10` six-byte status frames whose MISO status is "no request", `20 00 ..` (`OSD_CMD_READ`) whose level equals the previous one, `20 98 ..` with count 0, every `80` RTC frame -- replacing each run of them by nothing; (2) decodes `20 0c ..` (`OSD_CMD_OSD_WR`) frames to text lines with `fw/ctrl_rv/charrom.h` (`osd` subcommand: OSD page text per redraw); (3) SD card frames become `SD CMD<n> <lba> <sha256 of data>`; (4) applies the `expected_diff.txt` rules; (5) writes one merged stream in frame order.
  - `expected_diff.txt` rule syntax, one per line with a `#` comment naming the source: `SUBST <stream> <python-regex> <replacement>` (stream = `uart|osd|hw|sd|all`), `SDFILE <8.3 name> <alias>` (every SD access inside that file's clusters is printed as `<alias>+<offset>`, so `RV32OSDA.BIN` and `832OSDAD.BIN` both become `FIRMWARE+..`; the sizes differ, so the rule also drops the count of such reads), `DROP <stream> <regex>`. Initial rules: firmware file, config names (`MINMGAR`/`MINMGAA`, `MINMGAR%dCFG`), version strings (`-RV` suffix, build date), and one `SUBST uart/osd` per line of `fw/ctrl_rv/test/gold/fmt_diff_expected.txt` that a scenario's output reaches.
  - `spitrace.py diff <norm_rv> <norm_832>`: unified diff; exit 0 only if empty.
- **Test first:** `spitrace_test.sh`: fixtures with (a) the same frames and different poll counts -> empty diff; (b) one changed data byte in an SD read, an FPGA data frame and an OSD text line -> each a diff line (the normaliser must not hide real content); (c) an `expected_diff` rule removed -> its difference reappears.
- **Commands:** `bash sim/l3/test/spitrace_test.sh && bash sim/l3/run.sh diff p4t5 p4t6`
- **Pass gate:** fixtures PASS; `boot` RV vs 832 diff empty with the initial rules; every rule used by the diff has a comment with its source; a rule nobody uses is reported by `diff --unused-rules` and removed.

### Task 8: OSD key injection, the `keys` scenario, and the "before" OSD measurement

- **Phase / depends on:** plan 7.1 items 2 and 15, exec-3 hand-over item 8 (the per-key loop `osd.c` ~1004 was never measured) / Tasks 4-7.
- **Model:** Opus.
- **Files:** create `sim/l3/bfm_keys.v`, `sim/l3/keys/menu_tour.txt`, `sim/l3/osdtext_expect/keys.txt`; modify `tb_l3.v`, `scenarios.vh` (`keys`), `l3check.py` (`keys`), `expected_diff.txt` (if needed, with evidence), README ("keys"), `findings/osd-riscv/phase4.md` (the "before" table).
- **Interfaces:**
  - `bfm_keys` (module `bfm_keys(input clk28, clk7_en, output reg [7:0] osd_ctrl)`, driving `userio_osd.osd_ctrl`) reads a key script: one line per step, `KEY <hex code> <hold clk_114 cycles>` (osd_ctrl takes the code, then 0 after the hold), `BURST <code> <code> ...` (several changes within one main-loop pass, so `OSD_CMD_KEYQ` returns count > 1 and the loop `kq_buf[i] = SPI_reply()` runs), `WAIT_OSD_IDLE <cycles>` (no `20 0c` frame for that long), `WAIT_KEYQ <n>` (n more KEYQ frames). Codes from `fw/ctrl_rv/osd.h` (`KEY_MENU`, `KEY_UP`, `KEY_DOWN`, `KEY_ENTER`, `KEY_ESC`, ...).
  - `menu_tour.txt`: open the menu, walk down and up the main page, enter and leave two sub-pages, one `BURST` of 6 alternating up/down events, close the menu.
  - `l3check.py keys <run>`: the KEYQ frames' MISO bytes equal the events the script queued, in order, none twice, none lost (count byte included); the OSD pages decoded by `spitrace.py osd` equal `osdtext_expect/keys.txt` after the expected-diff substitutions.
- **Test first:** `osdtext_expect/keys.txt` written from `menu.c` (page titles and the items the tour passes) before the run; the BURST must be seen as one KEYQ frame with count 6 (if the firmware drains it in two, the script spaces it so it is one: say how).
- **Steps:** run `keys` on both CPUs with `+OSD_EARLY_OK=1` (the RV still has the `SPIN`s) and record the "before" table: per (command, reply byte index) the minimum `OSD GAP`, the `OSD EARLY` count, and whether every reply byte was right, for `OSD_CMD_VERSION`, `OSD_CMD_KEYQ` byte 0 and the per-key bytes 1..6; next to `E_osd` from Task 1.
- **Commands:** `SIM=verilator RUNTAG=p4t8 XARGS=+OSD_EARLY_OK=1 bash sim/l3/run.sh xpair keys && CPU=832 SIM=verilator RUNTAG=p4t8c bash sim/l3/run.sh xpair keys && bash sim/l3/run.sh diff p4t8 p4t8c` (Verilator ~10 min per run, the four in parallel: ~15 min wall; no xsim).
- **Pass gate:** the 832 leg passes `l3check.py keys` (the bench is right) with `OSD EARLY 0`; the RV leg's figures are recorded whatever they are (a wrong reply byte or `EARLY > 0` on the RV is the expected "before" evidence, not a failure of this task); diff empty or every difference explained (a timing-only RV failure is listed under 7.1 item 2, not added to `expected_diff.txt`); both `XRAND` twins SAME (on the RV a twin difference only in a stale reply byte is itself 7.1 item 2 evidence: recorded, not a failure).

### Task 9: RTL -- `userio_osd` reply sequence output `osd_rx_seq`

**RTL: Paul reviews before any bitstream.**

- **Phase / depends on:** decision 12.13 (a), plan 6.4 P1 (reply-ready part) / Task 8 (the "before" data; or Task 4's, if Task 4 found `OSD EARLY > 0` and the controller moved Tasks 9-11 forward).
- **Model:** Opus.
- **Files:** `rtl/minimig/userio_osd.v`, `rtl/minimig/userio.v`, `rtl/minimig/minimig.v` (pass-through output port each); `sim/osd_keyq/osd_keyq_tb.v`, `sim/osd_keyq/run.sh`; `findings/osd-riscv/phase4.md` ("Handshake design").
- **Interfaces (produces):** `userio_osd` output `reg [1:0] osd_rx_seq = 2'd0` in the `clk` (`CLK_28`) domain, **not** cleared by `reset` (initial value only, vendor-neutral), incremented at exactly the `clk7_en` edge at which `rx` is 1 -- the edge at which `cmd_dat`, `dat_cnt`, `ver_cnt` and `kq_rptr` take that byte -- so after an increment `rddat` already holds the reply for the next byte. One increment per byte received under `_scs` low. `userio` output `osd_rx_seq` and `minimig` output `osd_rx_seq` pass it through; nothing else changes. Why a sequence and not a "done" flag: a flag set by a done pulse can be set by the late pulse of the previous frame's last byte after the next frame's command byte has been written (the rx window ends up to ~40 `clk_114` after a byte's last edge, the RV can start the next frame sooner), which would report the first reply byte ready too early (Review Focus 1; Decision 2). The comparison against cfide's own byte count is Task 10.
- **832 unchanged (argument for the commit):** a new output port and a 2-bit counter that drives nothing inside the Minimig; no existing signal changes value; the 832 bitstream wires nothing to it until Task 10, and Task 10's register is read-only and never read by the 832 firmware.
- **Test first (`osd_keyq_tb.v`, iverilog):** new checks, red against the unmodified RTL (the port does not exist: compile error is the red case; then a run-copy mutant): (a) `osd_rx_seq` advances by exactly one per byte for VERSION, KEYQ (count + 6 events) and a 40-byte `OSD_CMD_OSD_WR` frame; (b) a host that starts each reply byte only after `osd_rx_seq` has advanced reads the right byte at a host gap of 0 extra cycles (the bench task's fast mode), for VERSION and a 6-event KEYQ; (c) the same host ignoring the sequence at gap 0 reads wrong bytes (proves the check bites); (d) cross-frame: an `OSD_WR` frame of 3 bytes, CS released and a KEYQ frame started 8 `clk_114`-equivalents later, polling the sequence: right bytes; (e) mutant (run copy): increment one `clk7_en` period earlier (on `rx_sync`) -> (b) fails. Existing checks unchanged and PASS (`./run.sh` and the `KEYQ_MUTANT` teeth).
- **Commands:** `RUNTAG=p4t9 bash sim/osd_keyq/run.sh && bash sim/osd_keyq/run.sh mutant_seq` (seconds); `RUNTAG=p4t9g bash sim/gayle/run.sh all` (unaffected, sanity); one L3 `boot` per CPU on Verilator (`p4t9r`, `p4t9c`): `spi.txt` identical to Task 5/6's (the port is unconnected at the top).
- **Pass gate:** all osd_keyq checks PASS, (c) and (e) FAIL as intended; L3 traces identical; the design note in `phase4.md` (the rx window timing from `userio_osd_spi.v`, why no reset, the 2-bit width); `git diff --stat` touches only the three RTL files and the bench files listed.

### Task 10: RTL -- cfide `HOST_REQ` (`0xFFFFFFB4`, bit 0 `OSD_RDY`) and the top wiring

**RTL: Paul reviews before any bitstream.**

- **Phase / depends on:** decision 12.13 (a) / Task 9.
- **Model:** Opus.
- **Files:** `rtl/host/cfide.vhd`, `rtl/soc/minimig_virtual_top.v` (`minimig.osd_rx_seq` -> `cfide.osd_rx_seq`); `sim/spi_cdc/tb_spi_cdc.v`, `sim/spi_cdc/run.sh` (the `+RDY` mode), `sim/host_bridge/tb_host_bridge.v` + `run.sh` (`t_osdrdy` test), `sim/host_bridge/README.md`, `findings/osd-riscv/phase4.md`.
- **Interfaces (produces):**
  - cfide port `osd_rx_seq : in std_logic_vector(1 downto 0) := "00"` (`clk_28`, same net as `userio_osd`'s `clk`: `CLK_28` in `minimig_virtual_top.v`, so no synchroniser; the task checks the net and says so).
  - cfide internal `osd_tx_seq` (2 bits, `sysclk` domain, initial "00", no reset): +1 when cfide **starts** a byte transfer (SPI DATA write accepted, `SD_busy` rising) while the OSD select `scs(5)` is '0'. Resync: when `scs(5)` has been '1' for 64 consecutive `sysclk` cycles, `osd_tx_seq <= osd_rx_seq` (longer than the ~40-cycle rx window, so every earlier byte has been counted by then; heals a lost byte at the next idle frame boundary).
  - `HOST_REQ` = read of `0xFFFFFFB4` (audio window `X"B"`, `addr(3 downto 2) = "01"`): `X"000" & "000" & osd_rdy` with `osd_rdy = '1'` when `osd_tx_seq = osd_rx_seq`. Bits 15..1 read 0 (reserved for P1). Reads of the audio window with `addr(3 downto 2) /= "01"` return `audio_q` as today; writes anywhere in the window are unchanged (no new write register). Decision 3.
- **832 unchanged (argument + bench):** the 832 firmware reads the audio window only at `0x0FFFFFB3` (`fw/ctrl_832/hardware.h:27`, `addr(3 downto 2) = "00"`): show with `grep -rn 'fffffb[4-9a-f]\|AUDIO *+' fw/ctrl_832 fw/ctrl_boot_832` (empty) and in the 832 binary (`832d` disassembly of `832OSDAD.BIN` from Task 6: no `li` building `0x0fffffb4..b7`); writes and every other read value unchanged; the counters drive only the new read mux. Bench: `E832=... bash sim/spi_cdc/host832/run.sh` PASS with the same `L` histogram as before; `CPU=832` L3 `boot` and `keys` `spi.txt`/`hw.txt` identical to Tasks 6/8.
- **Test first:**
  - `tb_spi_cdc.v +RDY=1`: before each OSD reply byte the bus model reads `0x0FFFFFB4` until bit 0 is 1 (each read a bus access with the same `gap`); `osd` must PASS at **every** gap from 2 in all seven skew pairs (plan 8.1's "osd test passing at GAP=2" gate, moved here); red before the RTL change (the register reads `audio_q`, bit 0 = `audio_buf` = 0: the poll never ends -> the bench's watchdog fails it: add one, 100 k cycles). The bench drives cfide's `osd_rx_seq` from its own `userio_osd` instance's new port. Mutant `RDY_MUT=1` (run copy of cfide: `osd_rdy` forced '1'): `osd` fails below `E_osd` (Task 1).
  - Cross-frame case in `tb_spi_cdc` (`+TESTS=16`, new): a 3-byte `OSD_CMD_OSD_WR` frame, then `cs_w(21)`, `cs_w(20)` at gap 2, then the VERSION read with `+RDY=1`: right bytes in every pair and gap.
  - L2 `t_osdrdy` (`tb_host_bridge.v`, the bench drives `osd_rx_seq` from a register it sets per checkpoint): `HOST_REQ` bit 0 after reset 1; after an SPI DATA write with OSD selected 0 until the bench advances the sequence; the resync after 64 idle cycles with the sequence deliberately off by one; `0xFFFFFFB0` still returns `audio_q`.
- **Commands:** `RUNTAG=p4t10 XARGS="+RDY=1 +TESTS=24 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh && RUNTAG=p4t10m RDY_MUT=1 XARGS="+RDY=1 +TESTS=8 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh; RUNTAG=p4t10d bash sim/spi_cdc/run.sh` (default grid unchanged: PASS); `SIM=verilator RUNTAG=p4t10l bash sim/host_bridge/run.sh t_osdrdy && RUNTAG=p4t10lx bash sim/host_bridge/run.sh t_osdrdy && bash sim/host_bridge/run.sh compare p4t10lx p4t10l`; `SIM=verilator RUNTAG=p4t10a bash sim/host_bridge/run.sh all` and `RUNTAG=p4t10ax bash sim/host_bridge/run.sh all` (xsim, ~5 min: the L2 README's rule for RTL commits; L2 unchanged); `E832=... RUNTAG=p4t10h bash sim/spi_cdc/host832/run.sh`; L3 `CPU=832` `boot`/`keys` (`p4t10c`, `p4t10k`) and `diff` against Tasks 6/8 runs (must be identical, not only normalised-equal). xsim: the three `tb_spi_cdc` runs ~15-20 min each, L2 `t_osdrdy` ~3 min, L2 `all` ~5 min: ~1 h (the handshake RTL's whole xsim share).
- **Pass gate:** all of the above; the mutant FAILS; the default `tb_spi_cdc` grid still PASS; L2 `all` (Verilator and xsim) compare SAME with Task 2's `p4t2an` and with each other; 832 traces byte-identical; `phase4.md` "Handshake design" complete with the register, the counter rules, the clock-domain statement and the 832 argument.

### Task 11: Firmware -- `SPI_reply()` polls `OSD_RDY`; L2 stub and host tests

- **Phase / depends on:** decision 12.13 (a) / Task 10.
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/hardware.h` (`#define HOST_REQ (*(volatile unsigned short *)0xFFFFFFB4)`, `#define HOST_REQ_OSD_RDY 0x0001`, the `HOSTTEST` hook `hosttest_host_req()`), `fw/ctrl_rv/hardware.c` (`SPI_reply`), `fw/ctrl_rv/README.md` ("Differences", TIMER table row, the live-`SPIN` list), `fw/ctrl_rv/test/mock_hw.c`, `mock_hw.h`, `hwmap_test.c` (the new register), create `fw/ctrl_rv/test/spireply_test.c`, `fw/ctrl_rv/test/check_io/` (fixture: three small `.dis` snippets with expected `check_io.awk` verdicts, exec-3 deferred #18) and its `test/Makefile` target; `sim/host_bridge/minimig_spi_stub.v` (an `osd_rx_seq` output, `+STUB_RDY_DLY=<clk_114 cycles>` default 40 after each OSD byte's last edge), `sim/host_bridge/tb_host_bridge.v` (wire it to cfide; new monitor line `=== OSD RDY early <n>`: reply bytes started before the stub's sequence caught up, bench error if > 0), `sim/host_bridge/README.md`.
- **Interfaces:** `unsigned char SPI_reply(void)`: `if (!(HOST_REQ & HOST_REQ_OSD_RDY)) { t = GetTimer(2); while (!(HOST_REQ & HOST_REQ_OSD_RDY)) if (CheckTimer(t)) { osd_rdy_timeouts++; break; } }` then `return SPI(0xff);` -- the bound is 2 TIMER counts (>= 5.8 ms on the board, Decision 4); `extern unsigned long osd_rdy_timeouts;` printed in the DebugMode stack/debug line where `StackHighWater()` is printed. No `SPIN` in `SPI_reply`.
- **Test first:** `spireply_test.c` (host, both ABIs, mock): the mock's `HOST_REQ` returns 0 n times then 1; `SPI_reply()` reads it until 1 and only then writes SPI DATA (the mock records the order poll... poll, write, read); with `HOST_REQ` stuck 0 the call returns after the TIMER bound with `osd_rdy_timeouts` = 1 and the mock's TIMER read count bounded (`mock_timer_reads()`); mutant: the poll removed -> order check fails; mutant: bound 0 -> the stuck case returns at once (count check fails). `hwmap_test`: `&HOST_REQ == 0xFFFFFFB4`, width 2. L2 `fwboot` with the stub's sequence frozen (`+STUB_RDY_DLY=-1`): every reply times out, the run still reaches its milestones (bounded wait works), `osd_rdy_timeouts` visible.
- **Commands:** `make -C fw/ctrl_rv clean all check size && make -C fw/ctrl_rv/test run mutants && SIM=verilator RUNTAG=p4t11 bash sim/host_bridge/run.sh fwboot && SIM=verilator XRAND=1 RUNTAG=p4t11r bash sim/host_bridge/run.sh fwboot && bash sim/host_bridge/run.sh compare p4t11 p4t11r && SIM=verilator RUNTAG=p4t11c bash sim/host_bridge/run.sh fwboot_cfg && SIM=verilator RUNTAG=p4t11f XARGS=+STUB_RDY_DLY=-1 bash sim/host_bridge/run.sh fwboot` (Verilator ~7 min each, in parallel: ~10 min wall; no xsim -- the RTL it needs was X-checked in Task 10).
- **Pass gate:** host tests and mutants PASS (both ABIs); `check` a-g PASS (c: `-76(zero)` is offset 4 of a window); `fwboot`/`fwboot_cfg` PASS with `OSD RDY early 0` and `OSD GAP min` >= the stub delay; the frozen-sequence run reaches its milestones; the `XRAND` twin SAME; the no-new-delays grep shows `SPIN` removed from `hardware.c` and exactly two live sites left; README rows: "`SPI_reply` polls `HOST_REQ` (RV only; needs a core with the Phase 4 RTL; the 832 keeps its four `SPIN`s)"; size delta recorded.

### Task 12: The "after" OSD measurement on L3, and the handshake's teeth

- **Phase / depends on:** decision 12.13 (a) "measure before and after on L3 with the real `userio_osd`" / Task 11.
- **Model:** Sonnet.
- **Files:** `findings/osd-riscv/phase4.md` (before/after table), `sim/l3/README.md` ("keys"), `doc/osd-riscv-plan.md` is **not** touched here (Task 23).
- **Steps:** `keys` and `boot` on the RV without `+OSD_EARLY_OK`; the same with `EXTRA_WS=0` and `+FAST_HW=1`, and in the two extreme skew pairs (`SCKDLY/C28DLY` 0.3/4.0 and 9.5/0.3); teeth: a run copy of cfide with `osd_rdy` forced '1' (Task 10's mutant) under the RV firmware -> `OSD EARLY > 0` and wrong KEYQ bytes (`l3check.py keys` fails); a run copy of the firmware with the poll removed and no `SPIN`s -> the same. Table: per (command, byte) the RV gap before/after, `OSD EARLY` before/after, the 832's figures, `E_osd`.
- **Commands:** `SIM=verilator RUNTAG=p4t12 bash sim/l3/run.sh keys`, `... p4t12b ... boot`, `... p4t12f XARGS=+FAST_HW=1 ... keys`, `... p4t12s1 XARGS="+SCKDLY=0.3 +C28DLY=4.0" ... keys`, `... p4t12s2 XARGS="+SCKDLY=9.5 +C28DLY=0.3" ... keys`, the two mutant runs (`p4t12m1`, `p4t12m2`); `bash sim/l3/run.sh diff p4t12 p4t8c` (RV after vs 832: empty). In parallel, ~15 min.
- **Pass gate:** every non-mutant run PASS with `OSD EARLY 0` and `l3check.py keys` PASS; both mutants FAIL as stated; RV-vs-832 diff empty; plan 7.1 item 2's new status written into `phase4.md`: "closed in simulation by the handshake; board confirmation in Phase 6".

### Task 13: Floppy read scenario `fdd_rd` (7.1 item 6)

- **Phase / depends on:** plan 4.1 ("ADF read of 10 tracks compares equal") / Tasks 8 (key injection), 12.
- **Model:** Opus.
- **Files:** create `sim/l3/bfm_floppy.v`, `sim/l3/keys/insert_df0.txt`; modify `tb_l3.v`, `scenarios.vh` (`fdd_rd`), `l3check.py` (`fdd_rd`), `mon_l3.vh` (item 6), `expected_diff.txt` (only with evidence), README ("fdd_rd").
- **Interfaces:**
  - `bfm_floppy` (module `bfm_floppy(input clk28, clk7_en, ...)`): drives `paula_floppy`'s CIA-side inputs (`_sel`, `_motor`, `side`, `_step`, `direc`) and its register interface (`reg_address_in`, `data_in`) the way the 68k and Agnus do: tasks `fdd_select(drive)`, `fdd_motor(on)`, `fdd_seek(track)` (step pulses with the trackdisk spacing, `_track0` honoured), `fdd_side(s)`, `fdd_dma_read(words, sync)` (DSKSYNC, `DSKLEN` written twice with DMA enable, then one DMA slot per `dmal` request as Agnus grants disk slots -- 3 per 227-colour-clock line, `reg_address_in = DSKDATR` -- until `blckint`, collecting `data_out` words to `<run>/fdd_rd_<track>_<side>.hex`). Read `paula_floppy.v` for `dmal`/`dmas`/`blckint` and say in the README which Agnus behaviour the model reproduces.
  - `insert_df0.txt` (key script, Task 8 syntax): open the menu, reach df0's file selector, select `TEST    ADF`, close; `l3check.py` confirms the OSD text shows `TEST` in df0's slot.
  - `fdd_rd`: after the insert, read 10 tracks (cylinders 0, 1, 2, 39, 40, 41, 77, 78, 79 side 0 and cylinder 79 side 1), each a full-track DMA of 6,334 words with sync 0x4489.
  - `l3check.py fdd_rd <run>`: MFM-decode each dumped track with `fw/ctrl_rv/test/gold/mfm.py` (sectors, header/data checksums) and compare the 11 sectors with `TEST.ADF`; for tracks 0 and 79/1 also byte-compare with the committed golden track streams of exec-3 Task 13 (where the DMA start aligns with the stream; else decode-only, say which).
  - Monitor item 6: `=== MARGIN 6 fdd_fifo_empty_dma <count>` = `clk_28` cycles in which DMA is on (`dmaon`) and the FIFO is empty while Agnus offers a slot (bound 0 at `EXTRA_WS=0`; Task 19 sweeps it), and the minimum FIFO fill level during each track.
  - TIMER: `TICKDIV` 1 (fdd.c is request-driven; say so after reading it). Drive sounds on (`DRIVESND.BIN` on the `fdd` card): `drivesounds_fill` runs in the main loop as on the board.
- **Test first:** `l3check.py fdd_rd` against a dumped track with one byte flipped -> FAIL; the 832 leg first (bench validation).
- **Commands:** `CPU=832 SIM=verilator RUNTAG=p4t13c bash sim/l3/run.sh xpair fdd_rd && SIM=verilator RUNTAG=p4t13 bash sim/l3/run.sh xpair fdd_rd && bash sim/l3/run.sh diff p4t13 p4t13c`. Estimate: a track ~15-23 M cycles at Agnus rate; RV ~12-15 min, 832 ~20-40 min, the four runs in parallel: ~45 min wall.
- **Pass gate:** both CPUs: 10 tracks equal to the ADF, item 6 count 0, no `EXC`; RV-vs-832 diff empty; both `XRAND` twins SAME.

### Task 14: Floppy write scenario `fdd_wr` (7.1 item 7)

- **Phase / depends on:** plan 4.1 ("write of 10 tracks compare equal") / Task 13.
- **Model:** Opus.
- **Files:** create `sim/l3/gen/mkwrtrack.py`; modify `bfm_floppy.v` (`fdd_dma_write(file)`), `scenarios.vh` (`fdd_wr`), `l3check.py` (`fdd_wr`), `mon_l3.vh` (item 7), README.
- **Interfaces:**
  - `mkwrtrack.py <adf> <track> <side> <out.hex>`: the MFM word stream AmigaDOS writes for that track with new sector contents (each data block re-tagged `W<track>`), built with `mfm.py`'s encoder (real clock bits), gap and sync as trackdisk writes them; option `--bad-header <sector>`: that sector's header checksum wrong (exec-3 deferred: an `fdd.c` error path, both CPUs must take it the same way).
  - `fdd_dma_write(file)`: `DSKLEN` with the write bit, DMA slots with `reg_address_in = DSKDAT`, `data_in` from the file, until `blckint`.
  - `fdd_wr`: insert (as `fdd_rd`), write 10 tracks (same cylinders; track 40/0 with `--bad-header 3`), then `+SD_SAVE`.
  - `l3check.py fdd_wr <run>`: extract `TEST.ADF` from the saved card (`mtools`); it differs from the original exactly in the written sectors, which hold the new data; for the bad-header sector: whatever the 832 leg wrote (record which: written, skipped, or error) and the RV leg equal to it.
  - Monitor item 7: `=== MARGIN 7 fdd_fifo_full_write <count>` (cycles with the write FIFO full while Agnus offers a DSKDAT slot) and the maximum fill.
- **Test first:** `mkwrtrack.py` round trip: its stream decoded by `mfm.py` gives back the new sectors; the mutant firmware of exec-3 Task 13 (`SectorToFpga` loop bound - 1, built in a run copy with `FW=`) fails `fdd_rd` (re-used here as the data-compare teeth; Task 19 repeats it).
- **Commands:** as Task 13 (`xpair`, both CPUs, ~45 min wall) with `fdd_wr` and RUNTAGs `p4t14*`; plus `SIM=verilator RUNTAG=p4t14m FW=<mutant BIN> bash sim/l3/run.sh fdd_rd` (must FAIL).
- **Pass gate:** both CPUs: written ADF equals the expected image; bad-header behaviour equal on both; item 7 count 0; diff empty; both `XRAND` twins SAME; the mutant FAILS.

### Task 15: Hard disk scenario `hdd` (7.1 item 8; synthesised and own RDB)

- **Phase / depends on:** plan 4.1 ("HDF 64-sector read and write compare equal") / Task 12.
- **Model:** Opus.
- **Files:** create `sim/l3/bfm_ide.v`; modify `tb_l3.v`, `scenarios.vh` (`hdd`), `l3check.py` (`hdd`), `mon_l3.vh` (item 8), README ("hdd").
- **Interfaces:**
  - `bfm_ide` (module `bfm_ide(input clk28, clk7_en, ...)` on `gayle`'s 68k side: `address_in`, `data_in`, `data_out`, `rd`, `hwr`, `lwr`, `sel_ide`, `sel_gayle`, `irq`, `nrdy`; timing as `sim/gayle/gayle_tb.v`'s bus tasks, which it reuses by copy or include, say which): tasks `ata_cmd(port, dev, cmd, lba, count)`, `ata_wait(bsy_clear, drq)` (status polling + `irq`), `ata_pio_in(words, file)`, `ata_pio_out(file, words)`, `ata_identify(port, dev, file)`, `atapi_packet(port, dev, bytes[12], bytecount)` (for Tasks 16/17: PACKET 0xA0, 6 command words, DRQ/IO/CoD phases, `bytecount` per DRQ block). Each wait counts the cycles the 68k side spent waiting on `nrdy`/`BSY` (the firmware's service latency).
  - `hdd` on the `hdd` card: unit 0 (`SYNTH.HDF`, synthesised RDB): IDENTIFY -> compare with `fw/ctrl_rv/test/gold/identify.py` for that file name and geometry; READ SECTORS LBA 0..1 -> RDSK/PART blocks vs `rdb.py`; READ SECTORS of 64 sectors from LBA 100; SET MULTIPLE 16 + READ MULTIPLE 64 from a CHS address with cylinder > 255 (exec-3 deferred: "no test with cylinder > 255"); WRITE SECTORS 64 at LBA 2000 + WRITE MULTIPLE 32, read back. Unit 1 (`RDB.HDF`, own RDB): READ MULTIPLE 16 from LBA 0 (exec-3 deferred: "the RDB patch only tested via READ SECTORS") -> block 0 shows the patched `rdb_Flags`/`rdb_ChkSum` as `hdd.c` patches them (expected value computed by `rdb.py` from the file), the rest unchanged. Then `+SD_SAVE`.
  - `l3check.py hdd <run>`: every read equals the HDF (block tags), every write lands in the saved card's HDF at the right LBA and nowhere else.
  - Monitor item 8: per command the 68k-side wait cycles (min/median/max) on `nrdy`/BSY.
  - TIMER: `TICKDIV` 1 (`hdd.c` is status-driven; the `hdd.c:910` TIMER user: say what it bounds).
- **Test first:** `l3check.py hdd` with one byte flipped in a dump -> FAIL; the 832 leg first.
- **Commands:** as Task 13 (`xpair`, both CPUs) with `hdd`, RUNTAGs `p4t15*`. Estimate: ~200 KB through SD + gayle: RV ~10 min, 832 ~20 min, in parallel ~25 min wall.
- **Pass gate:** both CPUs: all data checks PASS, IDENTIFY/RDB equal to the goldens and to each other; diff empty; both `XRAND` twins SAME.

### Task 16: CD-ROM data scenario `cd` (7.1 item 9; ISO and CUE/BIN)

- **Phase / depends on:** plan 4.1 ("CD READ(10) of 32 sectors compares equal") / Task 15 (`bfm_ide`'s ATAPI task).
- **Model:** Opus.
- **Files:** modify `scenarios.vh` (`cd`), `l3check.py` (`cd`), README ("cd").
- **Interfaces:** `cd` on the `cd` card, IDE port 2 master: IDENTIFY PACKET DEVICE (compare with what `atapi.c` builds, field by field against its source: model string, packet size), TEST UNIT READY, REQUEST SENSE, INQUIRY, READ CAPACITY, READ TOC (format 0) -> the track list of `TEST.CUE` (`CDCFG=cue`) or one data track (`CDCFG=iso`), READ(10) of 32 sectors from LBA 16 and READ(12) of 8 sectors -> equal to the ISO's / the BIN's data-track blocks (2048-byte user data from the 2352-byte MODE1 sectors), MODE SENSE as `cdrom.c` answers it; one command the firmware does not support (expect the sense key `cdrom.c` returns). One run per `CDCFG`. One CD timeout path at the board TIMER rate (`TICKDIV 643`): the firmware's `CD_TIMEOUT` (10000 counts = 58 s on the board) must **not** be reached by a normal READ(10) -- the scenario records the firmware's longest service time instead (exec-3 hand-over item 9: no 58 s simulation).
- **Test first:** `l3check.py cd` with a wrong sector in a dump -> FAIL; the 832 leg first.
- **Commands:** `CPU=832 SIM=verilator RUNTAG=p4t16c CDCFG=cue bash sim/l3/run.sh xpair cd`, the same `CDCFG=iso` (`p4t16ci`, plain run), RV `p4t16` (`xpair`), `p4t16i` (plain), diffs per pair. Estimate: RV ~10 min per config, 832 ~20 min, in parallel ~25 min wall.
- **Pass gate:** both CPUs, both configs: data equal to the image files, TOC equal to the CUE, IDENTIFY/INQUIRY/sense equal on both CPUs; diff empty; the `CDCFG=cue` `XRAND` twins SAME.

### Task 17: CD audio scenario `cdda` (plan 4.4 ring fill; ring under HDF load)

- **Phase / depends on:** plan 4.1 ("CD-DA fill of both halves compares with the BIN"), 4.4 / Tasks 15, 16.
- **Model:** Opus.
- **Files:** modify `bfm_audio.v` (ring snapshot at every half flip: the 32 KB the player is about to play, read through the SDRAM model, dumped to `<run>/cdda_half_<n>.bin`), `scenarios.vh` (`cdda`, `cdda_load`), `l3check.py` (`cdda`), `mon_l3.vh` (ring timing), README ("cdda").
- **Interfaces:**
  - `cdda` on the `cd` card (`CDCFG=cue`), `TICKDIV 643` from the scenario start: PLAY AUDIO MSF from track 2 start for 1.5 s; the player runs at the board rate (one 32 KB half = 8,192 frames = 186 ms = ~21.1 M `clk_114`); at least 6 half flips; then PAUSE, READ SUB-CHANNEL (position), RESUME, STOP.
  - `l3check.py cdda <run>`: each dumped half equals the BIN's frames at the position the firmware's cursor says (`cdaudio.c`: the ring holds LE 16-bit stereo, `scale()` at the configured volume -- compute the expected bytes with the firmware's rule, read from `cdaudio.c`), no zero-filled half (= no underrun) except the ones the PAUSE/STOP produce; READ SUB-CHANNEL position within one half of the expected.
  - Ring timing (plan 4.4): per half flip, `=== CDDA fill <n> start <cycle> done <cycle> (<ms> ms at 113.4375 MHz)`: from the flip to the firmware's last write into the half that is now free; min/median/max; and the main-loop latency during the run.
  - `cdda_load`: `cdda` plus, from the second flip on, the Amiga side reading 256 sectors from `SYNTH.HDF` with READ MULTIPLE (the 7.4 "HDF copy with CD audio" analogue, plan 1.2: "underruns come from foreground jobs blocking the loop >150 ms"); on the `cdhdd` card (Task 3).
- **Test first:** `l3check.py cdda` with a half zeroed -> FAIL; the 832 leg first.
- **Commands:** `CPU=832 SIM=verilator RUNTAG=p4t17c bash sim/l3/run.sh xpair cdda`, RV `p4t17` (`xpair`), `cdda_load` both (`p4t17lc`, `p4t17l`, plain runs), diffs. Estimate: 6 flips ~130 M cycles after boot: RV ~12 min, 832 ~20 min; `cdda_load` +256 sectors; in parallel ~35 min wall.
- **Pass gate:** both CPUs: every half equal to the BIN, 0 underruns in `cdda`; `cdda_load`: underruns counted and reported for both (the gate is RV <= 832, not 0); RV fill time <= 832 fill time (plan 4.4 gate); diff empty modulo listed position/timing rules (each with evidence); the `cdda` `XRAND` twins SAME.

### Task 18: Akiko request service `akiko` (7.1 item 13; legacy IRQ path in L3)

- **Phase / depends on:** plan 7.1 item 13; plan 8.0 "L3 differential once it exists" (the legacy interrupt path) / Task 12.
- **Model:** Sonnet.
- **Files:** create `sim/l3/bfm_akiko.v`; modify `tb_l3.v` (cfide `amiga_req/amiga_addr/amiga_d/amiga_wr` from the model, `amiga_q/amiga_ack` to it), `scenarios.vh` (`akiko`), `l3check.py` (`akiko`), README.
- **Interfaces:** `bfm_akiko` tasks `akiko_write(addr, data)`, `akiko_read(addr) -> data`: hold `amiga_req` until `amiga_ack`, as the TG68 side does in `minimig_virtual_top.v` (read the Akiko C2P register protocol from `fw/ctrl_rv/akiko.c`); `akiko`: one full C2P block (32 longword writes, 32 reads) with a known pattern, during an idle main loop, and a second block while a `fdd_rd` track is in progress; latency per request (`amiga_req` rise to `amiga_ack`), min/median/max, both CPUs.
- **Test first:** `l3check.py akiko`: the C2P output equals the planar conversion computed in Python from the input pattern; red with one wrong word.
- **Commands:** `CPU=832 SIM=verilator RUNTAG=p4t18c bash sim/l3/run.sh xpair akiko`, RV `p4t18` (`xpair`), diff. Verilator ~10 min each, in parallel ~15 min wall.
- **Pass gate:** both CPUs correct; latency table in `phase4.md`; diff empty; both `XRAND` twins SAME.

### Task 19: Differential over all scenarios, stress grid, teeth, margin table (plan 4.1/4.2 gate)

- **Phase / depends on:** plan 4.1 gate (monitors report every 7.1 margin; teeth fail), 4.2 gate (documented in `findings/osd-riscv/phase4.md` with the margin table for both CPUs across the stress grid), 7.2 stress mode / Tasks 13-18.
- **Model:** Opus.
- **Files:** create `sim/l3/grid.sh` (runs a grid, at most 6 Verilator at once, writes `grid_<tag>.txt`), `sim/l3/margins.py` (collects every `=== MARGIN` line into one table); modify `findings/osd-riscv/phase4.md` ("Differential", "Stress grid", "Margins", "Teeth").
- **Grid:**
  - RV, `EXTRA_WS` in {0, 4, 16, 64} x {`boot`, `fdd_rd`, `fdd_wr`, `hdd`, `cdda`} (default skew); skew pairs (0.5,0.2) (0.2,0.5) (4.0,0.3) (0.3,4.0) (9.5,0.3) x {`fdd_rd`, `hdd`, `keys`} at `EXTRA_WS=0`; `+FAST_HW=1` (SD token delay 0, busy 1, `SLAT=2 SJIT=0`) x {`boot`, `hdd`, `cd`, `keys`}; `SJIT=8` x {`hdd`, `cdda`}.
  - 832: every scenario at default, plus skew (0.3,4.0) and (9.5,0.3) x {`fdd_rd`, `hdd`}.
  - No xsim and no `XRAND` twins in the grid (Decision 1: every scenario's X-sensitivity pair ran in Tasks 4-18 and runs again in Task 23).
- **Teeth (each must FAIL, run copies only):** (a) `paula_floppy.v` with 202e077 reverted (`git show 202e077^:rtl/minimig/paula_floppy.v`) -> `hdd` (direct-mode reads) data check or item 3 (if it passes, run it again with `+FAST_HW=1` and in the skew pair (0.3,4.0); if it still passes, record the measured item-3 margin and report: the RV firmware then does not reach the race, which is a finding, not a bench fault); (b) the bridge without the four-phase handshake (L2 `mutant` copy) -> item 1 stale acks; (c) the short-MFM-sector firmware -> `fdd_rd`; (d) cfide `osd_rdy` forced '1' -> `OSD EARLY` (Task 12's run, re-used); (e) `sim/gayle`'s `GAYLE_MUT_SHARED` -> `hdd` (two units); (f) a firmware run copy whose `cdaudio.c` advances the cursor one frame short per half -> `cdda`; (g) one SD data byte changed in the 832 run's `spi.txt` -> `spitrace.py diff` non-empty.
- **Steps:** run the grid (Verilator, 6 in parallel: ~41 RV runs of ~10-20 min and ~10 832 runs of ~20-40 min, ~3-4 h wall), the teeth (~1 h wall), `spitrace.py diff` for every RV/832 pair of the same scenario and configuration, `margins.py`.
- **Commands:** `bash sim/l3/grid.sh p4g` (prints the run list and wall time), the teeth runs (`p4t19ta`..`p4t19tg`), `python3 -I sim/l3/margins.py sim/l3/run_p4g* > <table>`.
- **Pass gate:** every grid run PASS (data checks, monitors `ok`, no `EXC`) or a failure analysed: a latency-bound item (6, 7, 8, CD-DA) that goes `LOW` only at `EXTRA_WS` 64 is recorded with the bound it reached, not a failure, if the 832 at default shows the same or less margin; every RV/832 pair's diff empty modulo `expected_diff.txt`; all seven teeth FAIL; `phase4.md` has the margin table (rows = 7.1 items 1-15, columns = CPU x grid point) and the differential summary.

### Task 20: Speed (plan 4.4) and real-firmware I$ hit rate (plan 4.5)

- **Phase / depends on:** plan 4.4, 4.5, exec-3 hand-over item 10 (STATS cut at the end condition) / Task 19 (runs to reuse).
- **Model:** Sonnet.
- **Files:** create `sim/l3/speed.py`; modify `tb_l3.v` (RV only, under `RV_HOSTCPU_STATS`: `=== RETIRED <n>` from `` `HB_RV``'s core instance `u_core.writeBack_arbitration_isFiring`, counted per cycle, and printed with every `=== STATS@<event>`; the event windows per scenario: `boot` main loop = first to 21st HandleFpga frame, `fdd_rd` = first to last track DMA, `hdd` = first to last command, `cdda` = flip 2 to 6, `keys` = first to last key), `findings/osd-riscv/phase4.md` ("Speed", "I-cache").
- **Interfaces:** `speed.py <run>` from `spi_t.txt` and the log: SPI byte loop ns/byte (bytes per cycle inside SD read data frames of non-direct reads, CMD17/18), SD sector read time end to end (CMD18 frame start to the last data byte), 32 KB ring fill ms (Task 17's lines), menu redraw (key event to the last `20 0c` frame of the redraw, Task 8's tour), per CPU. I$: per window, refills, retired instructions, `refills / retired` (the miss ratio per instruction), `8 x refills / retired` (fetched words per instruction from refills) and the refill share of busy cycles.
- **Gate rule (plan 4.5):** if the main-loop window's miss ratio is above 5 % on any scenario, **stop and report** to Paul with the table (8 KB is a regeneration + OOC: Decision 7); do not regenerate.
- **Commands:** `python3 -I sim/l3/speed.py sim/l3/run_p4g_<...>` over the default-grid runs of both CPUs (no new simulation unless a window line is missing: then re-run that scenario with a new RUNTAG).
- **Pass gate:** tables in `phase4.md` (both CPUs side by side); RV ring fill <= 832 (plan 4.4 gate, from Task 17); the I$ decision line ("4 KB frozen" or "stopped: miss ratio x %"); STATS now cut at the end condition, not whole run.

### Task 21: 832 Dhrystone on the board (plan 4.6)

- **Phase / depends on:** plan 2.3 "confirm once on the board" / none (needs Paul with the board; Decision 6).
- **Model:** Sonnet (build, instructions, record); Paul runs it.
- **Files:** `findings/osd-riscv/phase4.md` ("832 Dhrystone, board"), `fw/dhrystone_832` read-only (built in a scratch copy with `832DIR=<main>/EightThirtyTwo`).
- **Steps:** build `fw/dhrystone_832` (its Makefile, scratch copy, date shim); write the card instructions for Paul (copy the binary as `832OSDAD.BIN` on a spare card or rename the card's file and restore it after; bitstream `build/stage_spicdc_49b1868`; UART 115200 on the host-firmware port, the one plan 12.6 calls ttyUSB0; how many runs; what to paste back).
- **Pass gate:** Paul's UART output pasted; DMIPS/MHz computed at 113.4375 MHz next to the bench's 0.113; the ratio RV/832 recomputed with the board 832 figure and the L1/L2 RV figure. If Paul defers it, the task records "deferred to Phase 5 board session" and does not block Task 23.

### Task 22: READMEs replay

- **Phase / depends on:** README rule / Tasks 1-21.
- **Model:** Sonnet.
- **Files:** `sim/l3/README.md` (complete: prerequisites from a fresh Ubuntu 24.04 incl. the apt line, toolchain fetch/check, `E832`/`E832DIR` (main checkout, or `git submodule update --init EightThirtyTwo` and building vbcc832/832a there -- say how, or say it is not covered), cards, each scenario with its run time, compare, diff, grid, monitors, expected-diff rules), `sim/host_bridge/README.md`, `sim/spi_cdc/README.md` (create if missing: `+RDY`, the sweep), `sim/osd_keyq` header comment, `fw/ctrl_rv/README.md`, `fw/ctrl_rv/test/README.md`.
- **Commands:** extract every fenced `sh` block of `sim/l3/README.md` into a script and run it with `zsh -f` and `bash --norc` in a scratch clone (`git clone . <scratch>/clone`; toolchain installed: skip the fetch line with a note; simulation blocks run in their `boot_short` form only; the xsim blocks are read-checked, not run).
- **Pass gate:** both shells run the blocks without error; no absolute personal path in any touched README; every command line in a README names a script/target that exists.

### Task 23: Phase 4 gate run and plan status

- **Phase / depends on:** end of Phase 4 / Tasks 1-22.
- **Model:** Sonnet.
- **Files:** `doc/osd-riscv-plan.md` (header status, 7.1 statuses of items 1-15 after Phase 4, 7.2 L3 path, section 8 Phase 4 marked done with the commit range and the gate results, 6.4 P1 note "reply-ready done in Phase 4"), this file (status line), `findings/osd-riscv/phase4.md` (final).
- **Gate run (on the committed tree, record results in plan section 8 Phase 4):** `make -C fw/ctrl_rv clean all check size stack`; `make -C fw/ctrl_rv CLANG=1 all check`; `make -C fw/ctrl_rv/test run mutants`; `make -C fw/ctrl_832/test`; L1 (Verilator) `all`, `irq`, `units`, `fmt`; L2 (Verilator) `all`, `mutant`, `irqmut`, `t_osdrdy`, `boot`, `fwboot`, `fwboot_cfg`, `fwboot_trap`; `sim/osd_keyq/run.sh` + `mutant_seq`; `sim/gayle/run.sh all`; `tb_spi_cdc` `+RDY=1` only if cfide changed after Task 10 (it is an xsim bench, ~20 min); `host832/run.sh`; L3 (Verilator) every scenario on both CPUs at default as `xpair` (each `XRAND` twin SAME), every `diff` empty modulo the list (~36 runs, 6 in parallel: ~2-2.5 h wall); no xsim (Decision 1: the two `boot_short` cross-checks of Tasks 4/6 and the unit benches of Task 10 are not repeated); the **trap log** (plan 4.3): `grep -l 'EXC mcause=\|TRAP' sim/l3/run_p4*/tb_*.log` lists only the deliberate teeth/trap runs; `STACK low` maximum over all L3 runs (stays above 0x1400: exec-3 deferred "high-water ColdBoot only"); the no-new-delays grep; `git status fw/ctrl_832 fw/ctrl_boot_832 fw/ctrl_boot_rv` clean; `git diff <Phase-4 base> -- rtl` = exactly Tasks 9 and 10.
- **Pass gate:** all green; plan updated; "What Phase 5 consumes" below true for the tree as committed.

---

## What Phase 5 consumes (the Phase 4 exit gate)

1. **The L3 bench** `sim/l3/run.sh <scenario>` (`CPU=rv|832`, Verilator, `xpair` for the X-sensitivity twin; xsim only for `boot_short`) as the regression for every Phase 5 change: `boot`, `hdd`, `fdd_rd` as the quick set (RV ~35 min in parallel), the full list and `grid.sh` before a merge.
2. **The handshake RTL** (Tasks 9, 10: `userio_osd.osd_rx_seq`, cfide `HOST_REQ` at `0xFFFFFFB4`, the top wiring), reviewed by Paul before the first `stage_rv` bitstream; Phase 5.1 checks that the new `clk_28`/`clk_114` paths are timed (no new XDC expected, same MMCM).
3. **The firmware** `RV32OSDA.BIN` with `SPI_reply()` on `OSD_RDY` (size in `fw/ctrl_rv/README.md`); it needs a core with the Phase 4 RTL (the bounded wait keeps it alive on one without, slowly: `osd_rdy_timeouts`).
4. **`findings/osd-riscv/phase4.md`**: the margin table of 7.1 for both CPUs over the stress grid, the before/after OSD table, the differential summary, the shared defects for Paul's backlog, speed and I$ tables, the Akiko latency, the 832 board Dhrystone (or "deferred").
5. **The A/B card recipe** (Task 3's `boot` card: both firmwares, both config files) for Phase 5.3, and the converted-config path (`boot832cfg`): **recipe only, not run in L3** (final review M3). No L3 scenario boots the `boot832cfg` card, and `SDFILE ... CONFIG` strips the data hash of every config read and write, so a wrong RV config write has neither a diff line nor a data check yet; a `boot` run on `boot832cfg` that checks the written `MINMGAR.CFG` with `cfgconv --check` would close it.
6. **The I$ decision** (4 KB frozen, or Paul's answer to the 8 KB question) and the speed figures that decide whether P5 (SPI FIFO) is needed.
7. **7.1 status after Phase 4**: items 1-15 with their L3 margin; items that only the board can close (2 on hardware, 12 against the real RTC part, the ADV7511 INT polarity of 6.3) listed for Phase 6.
8. **Simulation facts**: measured L3 cycles/s per simulator and CPU, cycles to the main loop per CPU, the 832 factor, xsim wall times; the `TICKDIV` rule.

## Appendix A: Phase 3 deferred items -- where they went

| Item (ledger / final review) | Assigned | Note |
|---|---|---|
| OPEN RISK: L2 OSD GAP min 40, zero margin over the rule | Tasks 1, 8-12 | edge pinned, before/after on the real `userio_osd`, handshake |
| Final review I3: per-key loop `osd.c` ~1004 never measured; first kickstart card should re-take OSD GAP and STACK | Tasks 4, 8, 12 | `keys` BURST; `boot` with KICK.ROM |
| Final review I3: pin the failure edge with `tb_spi_cdc +SWEEP=1` | Task 1 | |
| Final re-review nit: host_bridge README "+OSD_MIN_GAP=41 passes" | Task 2 | wording |
| Final re-review nit: exec-3 OSD reply-rule row keeps "fails 3/3" | left | exec-3 is a closed record; this plan's "OSD reply rule" row supersedes it |
| T10/#44: MMC command golden from the boot ROM log; firmware `MMC_Init` log stronger | Task 5 | `gold/mmc_init_rv.txt` |
| T10/#43: mock direct-mode clocking gated on card select | Task 5 (closed by L3) | L3 uses the real cfide; item 3 monitor |
| T12/#50: no test with cylinder > 255 | Tasks 3, 15 | `SYNTH.HDF` geometry |
| T12/#51: unit-0 RDB patch only via READ SECTORS | Task 15 | READ MULTIPLE from LBA 0 on `RDB.HDF` |
| T13/#56: `fdd.c` error paths untested | Task 14 (one path) | bad header checksum; the rest left (unchanged 832 code) |
| T17/#73: stack high-water only on the ColdBoot path | Tasks 4, 23 | maximum over all L3 scenarios (menu, file selector included) |
| T6 ruling: main-loop milestone was the error loop; kickstart cards are Phase 4 | Task 4 | real main loop |
| Final review "Declined": I$ hot-set adequacy | Task 20 | |
| Final review "Declined": `userio_osd` behaviour / P1 need | Tasks 8-12 | |
| exec-3 hand-over 10: STATS whole run, cut at the end condition is a 4.5 bench change | Tasks 4, 20 | `=== STATS@<event>` |
| exec-3 hand-over 9: board-length timeouts | Global Constraints "TIMER in L3", Tasks 16, 17 | `TICKDIV` |
| #18: `check_io.awk` fixture before the I/O map changes | Task 11 | the map gains `HOST_REQ` |
| #33 / T8: unhooked registers SEGV on the host | Task 11 (for `HOST_REQ`) | others left |
| Plan 8.0 "L3 differential / 832 A/B once those exist" | Task 18 (legacy path), Phase 5/6 | the 8.0 controller is unused by Phase 3/4 firmware |
| #9: `boot.c` `printf(str)` in `fw/ctrl_832` | later | backlog line on `5.0-040-pipelined` (outside this branch) |
| T9/T10 parity quirks (FileCreate one cluster, FAT32 free count, stale CSD, ReadMultiple after CMD12 timeout), FileCreate when FAT full | later | `phase4.md` "Shared defects" collects them for Paul's backlog (`doc/backlog.md` on `5.0-040-pipelined`) |
| Final review Minor 7: Save menu "(overwrite)" for an 832-only slot | later | cosmetic, after parity |
| Final review Minor 10: `cue.c` local `le32` | later | rename when `cue.c` is next touched |
| T14/#60: DRIVESND loaded twice untested | later | |
| T16/#69: `num()`/`cd_name83` refusal tests | later | host tests, cosmetic |
| T17/#70: DebugMode print only in the main loop | later | |
| T11/#47: `SaveConfiguration` result ignored | later | |
| T11/#46: `CFG_MIN_SIZE` and v1/v2 832 files | closed (doc, Phase 3) | real-file gate closed 2026-10-18 |
| Remaining "Leave" rows of the final-review triage (#1-4, 6, 8, 12-14, 17, 20, 22, 24, 26, 28-31, 34, 35, 40-42, 48, 49, 52-55, 57, 61-65, 70-72, 74, 78, 79, 84) | later | cosmetic or test-structure; no Phase 4 dependency |

## Decisions (Paul, 2026-10-18)

Answers to the planner's eight questions; they bind every task above.

1. **xsim scope (revised).** Paul: the proposed xsim times (~25 h) were excessive ("this takes too long"). Controller ruling: at most ~4 h of xsim for the whole phase -- one `boot_short` cross-check per CPU (Task 4 RV, Task 6 832, `compare` SAME against Verilator), the handshake RTL's unit benches (Task 10) and Task 1's sweep; everything else on Verilator, and every pass-gate scenario also runs as an X-sensitivity pair (`--x-assign unique --x-initial unique`, `+verilator+rand+reset+2 +verilator+seed+<n>`) whose two runs must compare SAME (Global Constraints "Simulators").
2. **Handshake scheme:** byte-count compare (`userio_osd.osd_rx_seq` vs cfide `osd_tx_seq`), resync after 64 idle cycles with the OSD deselected -- accepted.
3. **Register:** `HOST_REQ` read-only at `0xFFFFFFB4`, bit 0 `OSD_RDY`, bits 1-15 reserved for P1 -- accepted.
4. **Bounded wait:** `SPI_reply()` waits at most 2 TIMER counts and counts `osd_rdy_timeouts` -- accepted.
5. **L3 location:** `sim/l3/`, one bench, `CPU=rv|832` -- accepted.
6. **832 Dhrystone on the board (4.6):** in Phase 4 if the board is at hand, else in the first Phase 5 board session; not blocking the Phase 4 gate -- accepted.
7. **I-cache:** a main-loop miss ratio above 5 % stops Task 20 and goes to Paul; no automatic 8 KB regeneration -- accepted.
8. **RTL defects L3 finds** in `paula_floppy`, `gayle` or `userio_osd` (beyond the handshake): reported with evidence, not fixed in Phase 4 -- accepted.

## Questions for Paul

None open.
