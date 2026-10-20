# OSD host CPU -> VexRiscv: executable plan, stage 5b (Phase 5.4 -- debug bring-up: simulation proof, hw_server bridge, lab bitstream, board session)

Status: **planned 2026-10-20**, executing on branch `p5-build` (worktree `MinimigAGA_TC64-p5build`,
after `fe2a7b4`). Stops at the first step that needs Paul at the board (Task 8: the GDB attach over
the real Platform Cable).

> For agentic workers: execute task by task with superpowers:subagent-driven-development
> (SDD tooling extracts tasks by their `### Task N` heading). Each task ends at its pass
> gate; one commit per task, only its files, on branch `p5-build` in the `p5-build` worktree
> (`$P5`); the implementer commits there.

**Goal.** Plan item 5.4 (`doc/osd-riscv-plan.md` section 8, 3.8, decision 12.6): GDB on the
board's VexRiscv OSD host CPU through the decided path -- the debug module tunnelled through the
FPGA's own JTAG chain (`BSCANE2` USER4, `rv_debug = 1`, `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v`),
Paul's Xilinx Platform Cable USB II, a **Vivado `hw_server` Tcl JTAG-scan bridge** that serves
OpenOCD's `remote_bitbang` adapter, OpenOCD 0.12 (`riscv` target, `riscv use_bscan_tunnel 6 1`) and
GDB. Everything that can be proven without the board is proven before the board session:

1. **Simulation proof of the debug chain** (Tasks 1-2): a Verilator model of the host CPU with the
   debug module -- first the pin-TAP variant (`DEBUG = 2`, `VexOsd_DMJ`, as `dm_smoke`), then the
   board's variant (`DEBUG = 1`, `VexOsd_DMT` behind a 7-series TAP + `BSCANE2` model) -- behind a
   `remote_bitbang` TCP server in the C++ harness; real OpenOCD 0.12 with the committed config
   attaches; a scripted GDB session halts, reads registers and memory, breaks in `main` of a small
   program, `load`s a changed image (checks `fence.i`: the I-cache must not run stale code) and
   resumes; pass/fail by script.
2. **The bridge** (Tasks 3-4): a pure-Tcl `remote_bitbang` -> scan core (TAP state tracker,
   scan aggregation, long-scan splitting through `DRPAUSE`/`IRPAUSE`) with a Vivado back end
   (`scan_ir_hw_jtag`, `scan_dr_hw_jtag`, `run_state_hw_jtag`, `runtest_hw_jtag` on a target opened
   with `-jtag_mode on`); unit-tested in `tclsh` against a stub back end, then end to end
   OpenOCD -> bridge -> (a Tcl shim with Vivado's documented scan semantics) -> the Verilator model
   -> GDB test of Task 2; then, if `hw_server` can be kept off the USB cable, a dress rehearsal with
   **real Vivado + `hw_server`** driving the Verilator model over **XVC** (Xilinx Virtual Cable,
   `open_hw_target -xvc_url`), so the Vivado commands, their bit order and the device recognition
   are exercised before the board.
3. **The lab bitstream** (Tasks 5-7): a build switch `RV_DEBUG=1` for `build_ap040.tcl`
   (default off, build B unchanged), the lab build `build/stage_p5dbg_<C>` with `HOSTCPU_RVDEBUG = 1`,
   fit and timing against B recorded (lab only: a timing miss is recorded, not fatal, unless it is
   in the debug path).
4. **The board session for Paul** (Task 8): program the lab bitstream, start the bridge, OpenOCD,
   GDB command list, what to paste back; then **STOP**.

**Decision recorded here (controller, 2026-10-20, from the caller's brief): 5.4 is a lab build
only; the shipping build B (`build/stage_p5b_87577e2`) stays `rv_debug = 0`.** The lab bitstream is
a separate output directory and never replaces B on the card or in Paul's instructions as the
normal image. The `RV_DEBUG=1` switch stays in the tree, default off.

Parent plan: `doc/osd-riscv-plan.md` (5.4; 3.8; decisions 12.6, 12.10; risk row "Debug cable").
Stage before this one: `doc/osd-riscv-exec-5.md` (build B, Task 1's `hostcpu.tcl`, Task 2's build
worktree recipe, Task 6's board protocol `findings/osd-riscv/ab-board-test.md`). Board milestone of
2026-10-20 ~08:45 (Phase 4 ledger): build B + `RV32OSDA.BIN` sha256 `17bf2563` boot Workbench.

**Architecture summary.**

```text
 GDB --3333--> OpenOCD 0.12 --remote_bitbang TCP--> bridge (Tcl)  --scan_ir/scan_dr--> Vivado hw_server
   (xPack)       riscv target,                     rbb_core.tcl      (rv_jtag_bridge.tcl,      |
                 use_bscan_tunnel 6 1              TAP tracker,       -jtag_mode on)            v
                                                   scan aggregation           Platform Cable USB II -> XC7A100T TAP
                                                                                -> BSCANE2 USER4 -> VexOsd_DMT DTM/DM
 Simulation stand-ins (no board):
   Task 1-2:  OpenOCD --remote_bitbang--> Verilator harness (bit-level TCK/TMS/TDI/TDO) -> TAP model -> DMJ / DMT
   Task 3:    OpenOCD --rbb--> rbb_core.tcl --(shim: Vivado scan semantics -> bit-level rbb client)--> Verilator harness
   Task 4:    OpenOCD --rbb--> bridge in Vivado --hw_server--> XVC TCP --> Verilator harness (XVC server mode)
```

OpenOCD's `remote_bitbang` is bit-level (`0`-`7` = TCK/TMS/TDI writes, `R` = read TDO, `r`-`u`
resets, `B`/`b` blink, `Q` quit); Vivado's hardware manager offers only whole scans and stable
states. The bridge therefore tracks the IEEE 1149.1 TAP state from the TMS bits it is sent,
accumulates the TDI bits of a Shift-IR/Shift-DR, issues one Vivado scan when the shift ends (or a
partial scan ending in `DRPAUSE`/`IRPAUSE` when OpenOCD waits for read data mid-shift -- OpenOCD's
bitbang layer buffers `R` samples and reads them back in batches, so a long scan such as the
704-bit IDCODE autoprobe waits mid-shift), and answers every `R` with the TDO bit of the right
position. TMS-only paths map onto `run_state_hw_jtag` (stable states `RESET`, `IDLE`, `DRPAUSE`,
`IRPAUSE`) and Run-Test/Idle clocks onto `runtest_hw_jtag -tck N`. Vivado's documented transitions
(`help scan_dr_hw_jtag`, `help run_state_hw_jtag`, 2023.2, printed in a batch run without a board on
2026-10-20): a scan starts from the current stable state; from `DRPAUSE` a DR scan goes
`DREXIT2 -> DRSHIFT` (no capture: the split is transparent to the BSCANE2 user register, whose
SHIFT is low in Exit/Pause), and ends in `IDLE` or the stable state last set by
`run_state_hw_jtag`.

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Earlier constraints | Everything in `doc/osd-riscv-exec-5.md` "Global Constraints" still binds unless a row below changes it: branch **`p5-build`** in worktree `$P5`, one commit per task with only its files, never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`; `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` as the last line of every commit message; README rule (every new README: copy-pasteable build steps incl. toolchain setup); no `git push` except the controller's backup of `p5-build` after its reviews passed; no merge into `5.0-040-pipelined` or `osd-riscv`. |
| Paths | `$MAIN` = `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64` (**read-only** for every task), `$RV` = `.../MinimigAGA_TC64-riscv` (untracked outputs under `$RV/build/` only; never a git command that changes `$RV`, its branch or index), `$P5` = `.../MinimigAGA_TC64-p5build` (all commits), `$WD` = the lab build worktree (Task 6), `$SCR` = the agent's own scratchpad. Shell is zsh: no unquoted multi-word variables; write `vivado` calls out in full. |
| No board, no cable | **No agent programs the FPGA, opens a hardware target on the Platform Cable, or runs `hw_server`/Vivado hardware manager against a physical cable** (the cable is plugged in: `lsusb` shows `03fd:0008 Xilinx Platform Cable USB II`, firmware not loaded). The only `hw_server` use allowed is Task 4's XVC rehearsal under its cable guard. No `program.tcl`, no `open_hw_target` without `-xvc_url`. |
| SD card | Never write to `/media/paul/AARSDISK55` (Paul's live card) or any card. No card file changes in this stage (the lab bitstream uses the card set of B unchanged). |
| Shipping image | Build B (`$RV/build/stage_p5b_87577e2`, `rv_debug = 0`) is not rebuilt, not replaced, not modified. `build_ap040.tcl` without `RV_DEBUG=1` must make exactly the calls it makes today (same generic string, same file-group changes): Task 5 proves it. |
| Vivado | 2023.2 only: `/opt/Xilinx/Vivado/2023.2/bin/vivado` with `LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C` in the command's own `env`, **never `-stack`**, `-mode batch -nojournal -log <file>` (the bridge entry point may use `-mode tcl` for Paul interactively; agents use batch). `project_1.xpr` is opened only by the committed `tools/vivado/build_ap040.tcl` in batch mode in the lab worktree; never by hand, never the GUI, no `upgrade_ip`, no IP regeneration. IP md5 before/after rule of exec-5 (`md5sum $MAIN/ip/ddr3/*.xcix`) for every build. |
| CPU sharing with Phase 4 | Phase 4 runs Verilator/vvp simulations in the `-riscv` worktree. While the Task 6 Vivado build runs, the controller appends `VIVADO BUILDS STARTED <date +%H:%M>` and `VIVADO BUILDS FINISHED <time>` lines to `$RV/.superpowers/sdd/osd-riscv-exec-4/progress.md` (Phase 4 then caps Verilator at 2). Phase 5b's own simulations use at most 2 parallel jobs and never run during the Vivado build's synthesis. |
| Vendor-neutral | `rv_bscane2.v`, `VexOsd_DMT.v` and every `BSCANE2`/`BUFG`/`JTAG_SIME2` reference stay out of `rtl/host/host.qip` and out of every Quartus file. Bench-only models live under `sim/rv_dbg/`. No RTL change under `rtl/` in this stage (the `.rv_debug(hostcpu_rvdebug ? 1'b1 : 1'b0)` mapping of 2 to 1 stays an open finding: 5.4 uses value 1; see Questions). |
| Tools | OpenOCD 0.12.0 at `/usr/bin/openocd` (has `remote_bitbang`, no Platform Cable driver), its scripts in `/usr/share/openocd/scripts/` (`cpld/xilinx-xc7.cfg`); GDB = xPack `riscv-none-elf-gdb` 16.3 in `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin` (**no Python**: GDB scripts are plain command files, pass/fail by the shell parsing the batch output); GCC = the same xPack 15.2.0-1; Verilator 5.020 (`--binary` not required: a C++ harness with `--cc --exe --build`), `tclsh` 8.6 at `/usr/bin/tclsh`. |
| TCP ports | Sim harness remote_bitbang `RBB_PORT` default 44853, harness XVC 2542, bridge `remote_bitbang` server **33582** (next to 832bridge.tcl's 33581), OpenOCD GDB 3333 / telnet 4444 / tcl 6666, private `hw_server` for the XVC rehearsal `tcp::3131` (never the default 3121, which Vivado would auto-start against the USB cable). Every script binds to `127.0.0.1` and takes the port from the environment so two runs never collide; a run picks a free port when the default is in use and prints it. |
| Timeouts | Every scripted run (harness, OpenOCD, GDB, bridge) has a wall-clock timeout (`timeout`), kills its own children by PID on exit (`trap`), and never uses `pkill -x`/`killall` (machine-wide). |
| Model per task | Opus for the debug chain and the bridge (Tasks 1-5); Sonnet for the build run, the record and the board-session document (Tasks 6-8). Reviews: Opus for Tasks 1-5, Sonnet for 6-8. |

## Review Focus

1. **A simulation that proves less than it claims**: the TAP/BSCANE2 model differing from the
   silicon (CAPTURE/SHIFT/UPDATE timing, TDO edge, USER4 IR code `0x23`, IR length 6, IDCODE
   `0x?3631093`); Task 1's cross-check against Xilinx's own `JTAG_SIME2` + `BSCANE2` unisim models.
2. **A GDB test that passes without the feature**: the `fence.i` check must fail when the I-cache
   is not invalidated (a teeth run), the breakpoint must be proven hit (PC equals `main`'s address),
   memory reads compared with known values.
3. **Bridge bit order and splitting**: LSB-first hex for `-tdi` and the returned TDO, long scans,
   `R` sampled before vs after the rising edge, TCP fragmentation at every byte boundary.
4. **Build B touched**: the default path of `build_ap040.tcl`/`hostcpu.tcl` byte-for-byte the same
   calls; the lab build in its own worktree and output directory.
5. **The cable or board touched by an agent**: Task 4's guard; no `open_hw_target` without
   `-xvc_url`; `lsusb` PID before/after.

---

### Task 1: Verilator debug bench with a remote_bitbang server; OpenOCD attaches over the pin TAP and the BSCANE2 tunnel

- **Phase / depends on:** plan 5.4, 3.8 / L1 `dm_smoke` (pin TAP, iverilog) exists; OpenOCD configs `tools/openocd/minimig-rv-{bscan,pins}.cfg` exist.
- **Model:** Opus.
- **Files:** create `sim/rv_dbg/` with `tb_rv_dbg.v` (top: `rtl/host/rv_hostcpu.v` with `DEBUG` from a define/parameter, the L1 memory model `sim/rv_l1/mem_model.v` and bus checker `sim/rv_l1/bus_checker.v` reused by path, not copied; for `DEBUG = 1` the TAP model below), `xc7_tap.v` (7-series TAP + BSCANE2 stand-in, see "TAP model"), `harness.cpp` (Verilator main: clocks, the TCP servers, the run loop), `run.sh`, `Makefile` (test programs), `README.md`; modify `tools/openocd/minimig-rv-bscan.cfg` and `minimig-rv-pins.cfg` (adapter selectable as `remote_bitbang` with `RBB_HOST`/`RBB_PORT`; see "OpenOCD configs"), create `tools/openocd/remote-bitbang.cfg`, update `tools/openocd/README.md` (the sim usage; the board path stays "Task 4/8").
- **Harness (`harness.cpp`):** free-running system clock; a non-blocking TCP server on `127.0.0.1:$RBB_PORT` implementing the OpenOCD 0.12 `remote_bitbang` protocol on the TAP pins (`0`..`7` set TCK/TMS/TDI, `R` replies `'0'`/`'1'` with the current TDO immediately, `r`..`u` TRST/SRST ignored and counted, `B`/`b` ignored, `Q` closes the connection; unknown bytes abort the run with a message). Between two pin writes the model advances `TCK_HALF` system clocks (plusarg/env, default 4, i.e. TCK <= clk/8); while the socket is idle the clock keeps running (the program must run while no debugger talks). Exit conditions: a `+timeout` in cycles, the program's `DONE` MMIO (as in L1, `=== PASS`/`=== FAIL <code>`), or `+exit_on_disconnect`. Log: one line per connection, counts of bytes/`R`/resets, the TDO bit stream optionally to a file (`+rbblog=<file>`, used by Task 3 as a replay fixture). A second mode, XVC server (`+xvc=<port>`, protocol XVC 1.0: `getinfo:` -> `xvcServer_v1.0:<max bytes>\n`, `settck:<u32>` -> echo, `shift:<u32 bits><tms bytes><tdi bytes>` -> tdo bytes, LSB-first per byte), for Task 4 -- implemented here because it shares the pin driver; tested here by a small Python/Tcl client loopback (IDCODE read through XVC).
- **TAP model (`DEBUG = 1`):** `rv_hostcpu` `DEBUG = 1` instantiates `rv_bscane2`, which instantiates the unisim primitives `BSCANE2` (`JTAG_CHAIN = 4`) and `BUFG`. **First choice:** compile Vivado's own simulation models -- `$XILINX_VIVADO/data/verilog/src/unisims/JTAG_SIME2.v` (the 7-series TAP model, `PART_NAME` for the XC7A100T), `BSCANE2.v`, `BUFG.v` and `data/verilog/src/glbl.v` -- read in place, never copied into the repo, with Verilator 5.020 `--timing`; any lint waivers in a bench `.vlt`. **Fallback** (if Verilator cannot build them; the report says why): `sim/rv_dbg/xc7_tap.v` = a hand model (IEEE 1149.1 TAP, IR 6 bits, IR capture value with `01` in the two LSBs (IEEE 1149.1) and the upper bits as `JTAG_SIME2` produces them, IDCODE `0x13631093`, USER1..4 = `0x02, 0x03, 0x22, 0x23`, BYPASS = `0x3F`, BSCANE2 outputs for USER4: SEL, CAPTURE/SHIFT/UPDATE/RESET decoded as `JTAG_SIME2` drives them, TDI, TCK; TDO launched on the falling TCK edge) plus `BSCANE2`/`BUFG` stand-ins with the unisim port lists, and a **cross-check** bench (xsim, serial, `sim/rv_dbg/xcheck/`): the same pseudo-random TMS/TDI stream (>= 20,000 TCK cycles, IR loads of USER4/IDCODE/BYPASS/others, DR scans of 1..80 bits, pauses) into `JTAG_SIME2`+`BSCANE2` (unisims, `glbl`) and into `xc7_tap.v`; SEL/CAPTURE/SHIFT/UPDATE/RESET/TDI and TDO compared at every TCK edge, 0 mismatches. Either way the IDCODE read back by OpenOCD is the XC7A100T's (the `cpld/xilinx-xc7.cfg` expected list).
- **OpenOCD configs:** new `tools/openocd/remote-bitbang.cfg`: `adapter driver remote_bitbang`, `remote_bitbang host $RBB_HOST` (default `127.0.0.1`), `remote_bitbang port $RBB_PORT` (default 33582, the bridge). `minimig-rv-bscan.cfg`: default `ADAPTER` becomes `[file dirname [info script]]/remote-bitbang.cfg` (the decided path: the bridge), `SPEED_KHZ` ignored for remote_bitbang (say so; OpenOCD 0.12 prints a warning or not -- record which), everything below `# ---- target` unchanged. `minimig-rv-pins.cfg`: default stays the FTDI example (not planned for use), `ADAPTER` override documented for the sim. OpenOCD scripts of the run live in `sim/rv_dbg/` and source these committed configs (the configs under test are the ones Paul will use).
- **Test first:** before any harness code: `openocd -f tools/openocd/remote-bitbang.cfg ...` against nothing must fail with "connection refused" (shows the adapter config parses); after the harness: (1) `DEBUG = 2` (`VexOsd_DMJ`, pin TAP): `openocd -c "set ADAPTER .../remote-bitbang.cfg" -c "set RBB_PORT <p>" -f tools/openocd/minimig-rv-pins.cfg -c init -c "halt" -c "reg pc" -c "resume" -c shutdown` prints the TAP `riscv.cpu` IDCODE `0x10002fff`, "Examined RISC-V core", a halted PC inside the test program, exits 0; (2) the same over `DEBUG = 1` with `minimig-rv-bscan.cfg`: `xc7.tap` found with the XC7A100T IDCODE, "Examined RISC-V core; found 1 harts" through `use_bscan_tunnel`, halt/resume; (3) the L1 `dm_smoke` program still passes on iverilog (`bash sim/rv_l1/run.sh dm_smoke`; this task changes nothing there -- regression only); (4) XVC loopback: a client reads the IDCODE over the harness's XVC port (`DEBUG = 1`).
- **Teeth:** `DEBUG = 1` with the model's USER4 code changed to `0x22` (bench plusarg/define) must make OpenOCD fail to examine the hart (shows the tunnel IR really selects the DTM).
- **Commands:** `bash sim/rv_dbg/run.sh attach2` and `attach1` (build + harness + OpenOCD, verdict line `=== ATTACH PASS`/`FAIL`), `bash sim/rv_dbg/run.sh xcheck` if the fallback model is used, `bash sim/rv_dbg/run.sh xvc_loop`.
- **Pass gate:** (1), (2), (4) pass, teeth fail as designed, `dm_smoke` 6/6 PASS, xcheck 0 mismatches (fallback only), README with copy-pasteable steps (toolchain: `tools/riscv/README.md`; `apt install verilator openocd`), one commit.

### Task 2: Scripted GDB session in simulation (halt, registers, memory, breakpoint in main, load + fence.i, resume)

- **Phase / depends on:** plan 5.4 / Task 1 (harness, configs).
- **Model:** Opus.
- **Files:** `sim/rv_dbg/sw/` (`dbgtest.c` + start-up/linker reuse from `sim/rv_l1/sw/` by path; built `-g -O1 -march=rv32imc -mabi=ilp32` by the xPack GCC as the L1 Makefile does), `sim/rv_dbg/gdb/*.gdb` (plain GDB command files), `sim/rv_dbg/run.sh` targets `gdb1`, `gdb2`, `gdb_teeth`, `all`; README section.
- **Test program:** two images from one source, `IMG=A` and `IMG=B`, identical layout (same addresses for `main`, `work`, `mailbox`; checked by comparing `nm` output) and differing only in one constant returned by a `noinline` function `work()` (`0xA5A5_0001` vs `0xB5B5_0002`): `main` initialises a `volatile` counter and a known array (`pattern[8]` = fixed words), then loops forever: `mailbox = work(); counter++;` -- so `work()` sits in the 4 KB I-cache from the first iterations. The memory model starts with image A (as L1 loads a program); `DONE` is never reached in this test (the harness timeout or OpenOCD `shutdown` ends the run).
- **GDB script (`gdb/session.gdb`, run with `riscv-none-elf-gdb -batch -nx -x`):** `target extended-remote :$GDB_PORT`; `monitor halt`; `info registers pc sp ra`; `x/8wx &pattern` (must equal the known words); `print counter` twice with a `monitor resume`/`monitor halt` in between (must grow: the hart ran); `monitor reset halt` (ndmreset: the hart restarts at the reset vector halted -- record the PC), `break main`, `continue` -> stops at `main` (`info registers pc` equals `main`'s address from the ELF); `delete`; `load` **image B's ELF** (`file`/`load` of B; OpenOCD writes memory through the DM); `break work`; `continue` -> stops in `work`; `finish` / `continue` past one iteration, then `print/x mailbox` must be `0xb5b50002` (B's code ran: OpenOCD's `fence.i` on resume invalidated the I-cache that held A's `work`); `detach`; and an `echo` marker line after each check (`CHECK <name> <value>`) the shell compares against expected values -> `=== GDB PASS` or `=== GDB FAIL <check>`.
- **Teeth (`gdb_teeth`):** the same session with the I-cache invalidation suppressed -- either OpenOCD told not to `fence.i` (if 0.12 has a switch; check `riscv` command list) or the harness built with a bench define that makes the core ignore `fence.i` for the debug-resume path (bench-only, e.g. forcing the I-cache flush input low in a scratch copy of the generated core under `$SCR`, never the committed `.v`) -- must end `=== GDB FAIL mailbox` (the stale `0xa5a50001`). If neither can be built without editing committed RTL, the task says so and replaces the teeth by: GDB writes `work`'s instruction directly with `set *(int*)&work = ...` while running and shows the result depends on the resume path; the reviewer judges.
- **Runs:** `gdb2` over `DEBUG = 2` + `minimig-rv-pins.cfg`, `gdb1` over `DEBUG = 1` + `minimig-rv-bscan.cfg` (the board's transport). Each also passes at `TCK_HALF` 4 and 16 (TCK speed independence). Wall time of each recorded.
- **Pass gate:** `gdb1` and `gdb2` print `=== GDB PASS` at both `TCK_HALF` values; `gdb_teeth` fails at the `mailbox` check; OpenOCD log has no `Error:` line in a passing run (warnings listed in the report); `run.sh all` = attach1 + attach2 + gdb1 + gdb2 + teeth + xvc_loop (+ xcheck) with `=== RV_DBG ALL PASS`; one commit.

### Task 3: The bridge core (pure Tcl) with unit tests, and the end-to-end simulation through a Vivado-semantics shim

- **Phase / depends on:** plan 5.4, decision 12.6 (model: `EightThirtyTwo/tcl/832bridge.tcl`, read-only in `$MAIN`) / Tasks 1-2 (harness, GDB session).
- **Model:** Opus.
- **Files:** create `tools/rvdebug/rbb_core.tcl` (no Vivado commands: the remote_bitbang parser, the TAP state tracker, scan aggregation and splitting, the back-end interface), `tools/rvdebug/rv_jtag_bridge.tcl` (the Vivado entry point: back end = `scan_ir_hw_jtag`/`scan_dr_hw_jtag`/`run_state_hw_jtag`/`runtest_hw_jtag`; TCP server; self-test; target selection), `tools/rvdebug/shim_rbb_backend.tcl` (test back end with Vivado's documented semantics, implemented as bit-level TMS/TDI sequences sent to a `remote_bitbang` server -- the Verilator harness), `tools/rvdebug/test/` (`tclsh` unit tests + fixtures), `tools/rvdebug/README.md`, `sim/rv_dbg/run.sh` target `bridge_sim`.
- **Back-end interface** (what `rv_jtag_bridge.tcl` and the shim both implement): `be_scan ir|dr <nbits> <tdi-bits> <end-state>` -> TDO bits (a Tcl list or string of `0`/`1`, bit 0 first = first bit shifted), `be_goto <stable-state>`, `be_idle <n>` (Run-Test/Idle clocks), `be_reset`. The conversion to Vivado's hex arguments (LSB-first, the scan's bit 0 = LSB of `-tdi`, returned TDO hex likewise, as `help scan_ir_hw_jtag` documents; `-tdi` given on every call because the length changes) lives only in `rv_jtag_bridge.tcl`, in one proc pair with its own unit test against hand-computed vectors.
- **Core behaviour (each item has a unit test):**
  1. Every byte of the protocol: `0`..`7`, `R`, `r`..`u`, `B`, `b`, `Q`; any other byte -> error logged, connection closed.
  2. TAP state tracked from TMS on each rising TCK edge (`0`->`1` transition of the TCK bit), all 16 states; `R` answers the TDO that the current state presents before the next rising edge.
  3. In Shift-DR/Shift-IR, bits are accumulated (TDI at each rising edge, whether an `R` asked for each one); when TMS = 1 ends the shift, one `be_scan` with the accumulated bits, then the pending `R` replies in order. The end state follows the TMS path after the shift: the bridge holds the scan until that path reaches a stable state (`IDLE`, `DRPAUSE`, `IRPAUSE`, `RESET`) or the next shift. A path with no stable state in it (Exit1 -> Update -> Select-DR -> Capture-DR -> Shift-DR, which OpenOCD uses between back-to-back scans) must keep IEEE semantics -- every Update and Capture the target sees happens exactly once -- so the scan ends where Vivado can stop (`DRPAUSE`/`IRPAUSE` or `IDLE`) and the rest of the path is replayed with `run_state_hw_jtag -state {...}` or by the next scan's documented entry path; the implementer picks the mapping, writes it down in the README, and proves it on the unit tests (Update/Capture counts of the reference TAP equal) and in `bridge_sim`.
  4. **Mid-shift reads:** when the input buffer is drained, no further byte is readable and replies are pending inside a shift, the bridge issues the accumulated bits as a partial scan ending in `DRPAUSE`/`IRPAUSE`, replies, and continues the same shift from the pause state (Vivado's `DRPAUSE -> DREXIT2 -> DRSHIFT`, no capture) -- so OpenOCD's 704-bit IDCODE autoprobe and any scan longer than OpenOCD's sample buffer complete. An `R` whose rising edge has not arrived yet when the input drains is answered from a partial scan that excludes that bit only if the TDO it asks for is already known (the first bit of the next segment is what TDO shows in the pause-exit state); otherwise the bridge waits up to 2 ms for more input before splitting. The implementer reads OpenOCD 0.12.0's `src/jtag/drivers/remote_bitbang.c` and `bitbang.c` (tag `v0.12.0`, fetched read-only to `$SCR`) and records in the README when it blocks for replies (`buf_size`, flush points).
  5. TMS-only moves: Test-Logic-Reset via >= 5 TMS = 1 -> `be_reset`; Run-Test/Idle with n rising edges -> `be_idle n`; other paths to stable states -> `be_goto`.
  6. Unit equivalence: a bit-level reference TAP in Tcl (TAP + IR 6 + IDCODE + BYPASS + a 48-bit USER4 register with a known capture value) answers a byte stream directly; the bridge core + a stub back end (the same reference TAP driven scan-wise with Vivado's transition tables) must produce the **identical reply byte stream** for: OpenOCD-shaped streams (reset, IR 6-bit scans, 41-bit DMI-shaped DR scans with idle clocks, the 704-bit autoprobe), 1,000 random legal streams, and every stream fed in random TCP-sized chunks (1..300 bytes) and byte by byte. Plus the replay of a recorded OpenOCD session from Task 1's `+rbblog` (OpenOCD's real byte stream).
- **End to end (`bridge_sim`):** OpenOCD (`minimig-rv-bscan.cfg`, `RBB_PORT` = the bridge) -> `rbb_core.tcl` in `tclsh` with `shim_rbb_backend.tcl` -> the harness (`DEBUG = 1`) -> Task 2's GDB session: `=== GDB PASS` (and the teeth fail). The shim logs every back-end call; the report shows the number of scans, partial scans and the longest scan.
- **Vivado entry point (`rv_jtag_bridge.tcl`), not run against a cable in this task:** args/env `RBB_PORT` (33582), `HW_SERVER_URL` (default `localhost:3121` on the board, Task 4 passes its private one), `XVC_URL` (optional), `TARGET` (pattern for `get_hw_targets`, default the only one; more than one -> list and exit); `open_hw_manager`, `connect_hw_server`, `open_hw_target -jtag_mode on` (+ `-xvc_url` when given); **self-test before serving:** `run_state_hw_jtag RESET`, IR scan of IDCODE (`0x09`, 6 bits) then a 32-bit DR scan -> must match `0x?3631093` (prints it; mismatch -> exit with the value, which shows a bit-order or chain-length error), and a BYPASS check (IR all ones, DR `0x1` comes back delayed by one bit); then serves one OpenOCD connection at a time (`vwait` loop, `fileevent`, binary, non-blocking), logs connections and per-minute scan counts, closes the target on `Q`/disconnect only when asked (`-exit_on_disconnect`). A batch-mode syntax/load check in Vivado without any server: `vivado -mode batch -source <scratch script that sources rv_jtag_bridge.tcl with RVBRIDGE_NO_MAIN=1 and runs the hex-conversion unit test>`.
- **Pass gate:** `tclsh tools/rvdebug/test/run_all.tcl` all pass (counts in the report); `bridge_sim` `=== GDB PASS` and teeth fail; the Vivado batch load + hex test pass; README (how it works, how to run the tests, the board usage pointer to Task 8's file); one commit.

### Task 4: Dress rehearsal with real Vivado + hw_server over XVC (no board)

- **Phase / depends on:** plan 5.4 / Tasks 1 (harness XVC mode), 3 (bridge).
- **Model:** Opus.
- **Files:** `sim/rv_dbg/run.sh` target `xvc_vivado` (+ its helper scripts under `sim/rv_dbg/`), `tools/rvdebug/README.md` (rehearsal section); `tools/rvdebug/*.tcl` and their tests only for defects the rehearsal finds (each with a unit test that fails before the fix) and for the `RVBRIDGE_TEST_REVERSE` test switch.
- **Cable guard (must pass before `hw_server` starts; otherwise the task records "rehearsal not run" with the reason and ends DONE_WITH_CONCERNS -- the board session then carries the bit-order risk, covered by the bridge self-test):**
  1. `lsusb -d 03fd:` before -> record the PID (today `0008`, firmware not loaded).
  2. Start a **private** `hw_server` (`/opt/Xilinx/Vivado/2023.2/bin/hw_server -s tcp:127.0.0.1:3131 -p0 -I 600 -L <log> -l discovery,jtag2` plus the USB exclusion: find the `hw_server` setting that keeps it off USB cables (`-e "set jtag-port-filter ..."` is present in the binary; `strings`/UG908; record the exact form) and prove it with a 20 s start: the log lists no USB/`pcusb`/Platform Cable target and `lsusb -d 03fd:` still shows the same PID. If no setting is proven within the task, the rehearsal is not run.
  3. Vivado connects only with `connect_hw_server -url localhost:3131` and opens only `open_hw_target -xvc_url localhost:<xvc port> -jtag_mode on`; `get_hw_targets` output recorded; no other target opened.
  4. After the run: `lsusb -d 03fd:` PID unchanged; the private `hw_server` killed by its PID.
- **Run:** harness `DEBUG = 1` in XVC mode; Vivado batch `rv_jtag_bridge.tcl` (`XVC_URL`, `HW_SERVER_URL=localhost:3131`, `RBB_PORT`); the bridge self-test must read the model's IDCODE; OpenOCD + Task 2's GDB session through it -> `=== GDB PASS`; record Vivado's device recognition messages, the scan rate (scans/s, GDB `load` time), and the bit-order facts confirmed (`-tdi`/TDO LSB-first). Teeth: run once with the bridge's hex conversion deliberately bit-reversed (an env switch in the test only, `RVBRIDGE_TEST_REVERSE=1`) -> the self-test fails.
- **Pass gate:** guard proven and `=== GDB PASS` through real Vivado + hw_server + XVC, or the documented "not run" with the guard evidence; `lsusb` unchanged; one commit (scripts + README; outputs untracked).

### Task 5: Build switch `RV_DEBUG=1` for the lab bitstream (default path unchanged)

- **Phase / depends on:** plan 5.4, exec-5 Task 1 (`tools/vivado/hostcpu.tcl`, `build_ap040.tcl`) / none of Tasks 1-4 (may run after them; sequential by SDD rule).
- **Model:** Opus.
- **Files:** modify `tools/vivado/build_ap040.tcl`, `tools/vivado/hostcpu.tcl`; create `tools/vivado/rv_debug.xdc`; `tools/vivado/README.md` ("Debug lab build" paragraph); a static test `tools/vivado/test/hostcpu_mock_test.tcl` (or the nearest existing test location; `tclsh` with mocked Vivado commands).
- **Behaviour:** `RV_DEBUG` unset or `0` -> exactly today's behaviour (same generic string, same `hostcpu_apply` changes, same reports). `RV_DEBUG=1` -> the generic string gains ` HOSTCPU_RVDEBUG=1` (the board top's parameter, `minimig_openaars_top`; it reaches the bridge as `rv_debug = 1` through `minimig_virtual_top`'s `? 1'b1 : 1'b0`); `hostcpu_apply` additionally adds and enables `rtl/host/vexriscv/VexOsd_DMT.v` and `rtl/host/xilinx/rv_bscane2.v` to `sources_1` and `tools/vivado/rv_debug.xdc` to `constrs_1` (all recorded in the undo list / `.hostcpu_undo` and removed by `hostcpu_restore`); a one-line banner `build_ap040.tcl: host CPU = RISC-V, DEBUG MODULE (rv_debug = 1, LAB BUILD)`; after `open_run impl_1` an extra report `rv_debug.rpt`: the `BSCANE2` cell(s) with `JTAG_CHAIN`, the `rv_tck` clock in `report_clocks`, `report_timing -from/-to [get_clocks rv_tck]` and intra-clock, the `VexOsd_DMT` cell count. `.last_generics` then differs from B's by the one token (forces synthesis).
- **`rv_debug.xdc`:** `create_clock -name rv_tck -period 50.000 [get_pins -hier -filter {NAME =~ *u_bscan/u_bscane2/TCK}]` (20 MHz, above the Platform Cable's 12 MHz maximum; the cable default is 6 MHz) and `set_clock_groups -asynchronous -group [get_clocks rv_tck] -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *hostcpu*}] ...]` -- the implementer derives the host CPU clock name from the B build's `clocks.rpt` (`$RV/build/stage_p5b_87577e2/`) and the hierarchy (`openaars_virtual_top/hostcpu`), and documents why the crossing is safe (the VexRiscv DM's own clock-domain crossing, `FlowCCByToggle`/`BufferCC` in the generated `VexOsd_DMT.v`; name the registers). The XDC is processed after `wizard.xdc` (its `PROCESSING_ORDER LATE` or order in the fileset) and only in `RV_DEBUG=1` builds.
- **Test first:** a mock-Vivado `tclsh` test that sources `hostcpu.tcl` (and the generic-string fragment of `build_ap040.tcl` factored as needed, minimal change) with stub `get_files`/`add_files`/`set_property`/`remove_files` recording every call: (a) `RV_DEBUG` unset -> call list identical to the call list recorded on the parent commit `fe2a7b4` (the test records both and diffs: RED before the change only in the sense that the RV_DEBUG=1 cases fail); (b) `RV_DEBUG=1` -> the three extra files added and enabled, the generic token present, restore leaves the mock project as found; (c) a crash between apply and restore -> the next apply restores from `.hostcpu_undo` including the debug files. Plus `echo 'source tools/vivado/hostcpu.tcl' | tclsh` parses; `iverilog -g2005` elaboration of `rv_hostcpu.v` `DEBUG = 1` with the bench stand-ins (or the L1 gate 2 result) unchanged.
- **Pass gate:** mock tests pass; default call list byte-identical to `fe2a7b4`'s; `git diff` touches only the listed files; no file under `rtl/`; one commit -> **C2** (the lab build commit), written into the ledger.

### Task 6: Lab build `stage_p5dbg_<C2>`

- **Phase / depends on:** plan 5.4 / Task 5 (C2).
- **Model:** Sonnet.
- **Files:** none tracked. Creates the worktree `$WD` = `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5dbg` (detached at C2) and `$OUT` = `$RV/build/stage_p5dbg_<C2>/`.
- **Steps** (the exec-5 Task 2 recipe, with these differences): (1) `git -C $P5 worktree add --detach $WD $C2`; submodules with the same `-c submodule.*.url=$MAIN/...` overrides; `git -C $WD submodule status` shows the gitlinks of C2 without `-`/`+`. (2) `cp -a /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-v2023/project_1 $WD/project_1`, `rm -f $WD/project_1/.last_generics`; the `$PPRDIR`-relative checks of exec-5. (3) Controller appends `VIVADO BUILDS STARTED <HH:MM> (5.4 lab build stage_p5dbg_<C2>)` to the Phase 4 ledger **before** the launch; `md5sum $MAIN/ip/ddr3/*.xcix > $OUT/ip_md5_before.txt`; launch in the background: `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C POST_CHIP=1 POST_CI=1 RV_DEBUG=1 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log $OUT/vivado.log -source $WD/tools/vivado/build_ap040.tcl -tclargs $OUT 0 $WD`, record the PID. (4) Synthesis check within ~15 min: `runme.log` shows `VexOsd_DMT` and `rv_bscane2`/`BSCANE2` under `hostcpu`, `rv_debug` = 1, no black box; the debug banner in `vivado.log`; otherwise kill by PID and report. (5) Wait for a line starting `=== ALL DONE ===`. (6) Post checks: IP md5 equal; `generics.txt` = B's string + ` HOSTCPU_RVDEBUG=1` exactly; `bit.md5`; `COMMIT`; `git -C $WD status --porcelain` clean apart from untracked `project_1/`; `hostcpu_restore` undid every change (log). Controller appends `VIVADO BUILDS FINISHED <HH:MM>` to the Phase 4 ledger.
- **Estimate:** ~10 min setup, 45-60 min build. No simulation of this stage runs during synthesis (Global Constraints).
- **Pass gate:** `=== ALL DONE ===`, `.bit` present, DMT + BSCANE2 in the netlist (`hostcpu_cells.txt` / `rv_debug.rpt`), md5 files equal, generics as stated, worktree clean. A build error -> stop and report with the log tail.

### Task 7: Fit and timing record of the lab build

- **Phase / depends on:** plan 5.4 / Task 6.
- **Model:** Sonnet.
- **Files:** create `findings/osd-riscv/debug.md` (sections "Lab build", "Simulation proof" (summary + pointers to Tasks 1-4's run outputs and numbers), "Board session" (empty: filled after Paul's session)).
- **Content:** lab vs B side by side (from `$RV/build/stage_p5b_87577e2` and `$OUT`): total LUT/FF/BRAM/DSP/slices (%), `hostcpu` LUT/FF with children, the delta next to the Phase 1 OOC expectation for `rv1` (`findings/osd-riscv/ooc-2023.2.md`: ~+470 LUT, +844 FF); intra-clock WNS/WHS per clock incl. `rv_tck`; failing endpoints vs B's known set (the 16 `clk_gen_sdram -> clk_114` endpoints); `rv_tck` crossings (must be covered by the asynchronous group; `report_clock_interaction` line); `report_exceptions -ignored` and `cdc.rpt` summary lines vs B; md5 and paths. **Verdict:** lab only -- a clk_114 WNS below B's is recorded, not fatal; **fatal** (stop and report, Task 8 not written) only for a failing endpoint in the debug path (`rv_tck` intra-clock, the `BSCANE2` paths, or any path under `hostcpu` with a `VexOsd_DMT` debug-module start or end point) or an unconstrained `rv_tck`.
- **Pass gate:** `debug.md` complete with the verdict; one commit.

### Task 8: Board-session protocol for Paul (then STOP)

- **Phase / depends on:** plan 5.4 gate ("session log in `findings/osd-riscv/debug.md`") / Tasks 1-7.
- **Model:** Sonnet.
- **Files:** create `findings/osd-riscv/debug-board-session.md`; append a pointer in `debug.md` "Board session"; plan status lines (`doc/osd-riscv-plan.md` 5.4 status; this file's Status line).
- **Firmware ELF for GDB:** the card image is `RV32OSDA.BIN` sha256 `17bf2563788e3b62d2cedc170c448654617537779f21edab5b2feeb9240ed66f` (osd-riscv `6ea1b76`); its ELF is `$RV/build/ab_card_87577e2/work/fwrv_6ea1b76/RV32OSDA.elf`. The task proves the pair (the way the firmware Makefile derives the `.BIN` from the `.elf`, re-run into `$SCR`, `cmp` with the card's `.BIN`) and copies both into `$OUT/fw/` with a `SHA256SUMS`; the protocol names that path.
- **Protocol content (copy-pasteable, zsh-safe, every command with its expected output and the abort rule):**
  0. What it is: lab bitstream (`$OUT/minimig_openaars_top.bit`, md5), same card set as B, B stays the normal image; recovery = program B again / power cycle.
  1. Before: close every Vivado hardware manager (hw_server owns the cable); serial log on ttyUSB0 as in `ab-board-test.md` (picocom options there).
  2. Program the lab bitstream exactly as `findings/osd-riscv/ab-board-test.md` programs B (same program command, the lab path), boot to Workbench (sanity: the OSD works as on B).
  3. Bridge: `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log ~/rvbridge.log -source tools/rvdebug/rv_jtag_bridge.tcl` (cwd `$P5` or wherever the tree is; port 33582); expected self-test line with the IDCODE; abort rule if it fails (paste the log).
  4. OpenOCD: `openocd -f tools/openocd/minimig-rv-bscan.cfg -d2 -l ~/openocd.log`; expected "Examined RISC-V core; found 1 harts", "Listening on port 3333".
  5. GDB with the ELF of `$OUT/fw/`: read-only first (`monitor halt`, `info registers`, `bt`, `x/16wx` of a known variable/string such as the version string, `continue`; the Amiga keeps running), then a breakpoint on a function the OSD hits on a key press (the implementer picks one from the firmware's main loop, e.g. the OSD key handler; Paul presses the OSD key), `delete`, `continue`; then `load` of the **same** ELF over the running image + `continue` (bytes equal, exercises `fence.i` harmlessly); optional and last: `monitor reset halt` (ndmreset restarts the OSD firmware from the boot ROM; the Amiga side is not reset) + `continue`.
  6. Detach (`detach`, `quit`), stop OpenOCD and the bridge (Ctrl-C; `Q` handling), check the OSD still works.
  7. What to paste back: `~/rvbridge.log`, `~/openocd.log`, the GDB transcript (`set logging file ~/gdb.log`, `set logging enabled on`), the ttyUSB0 log, and one line per step "ok"/"what happened".
  8. **STOP** marker: nothing after this needs the agents until Paul returns the logs; then `debug.md` "Board session" is filled from them.
- **Pass gate:** protocol complete; every path in it exists (the task lists `ls -l` of each); the ELF/BIN pair proven; the plan's 5.4 status says "lab build + sim proof done, board session pending"; one commit. **The controller then stops (first step needing Paul at the board).**

## What Phase 6 consumes

1. The `RV_DEBUG=1` switch and `stage_p5dbg_<C2>` as the debug lab image when a parity or stress
   failure needs the CPU stopped on the board (`findings/osd-riscv/debug-board-session.md`).
2. `sim/rv_dbg` (`run.sh all`) as the regression for the debug chain whenever the VexRiscv is
   regenerated (Phase 7 performance options such as I$ `twoCycleRam` touch the same core).
3. `tools/rvdebug` (bridge) and `tools/openocd/minimig-rv-bscan.cfg` as the documented GDB path.
4. After Paul's session: `findings/osd-riscv/debug.md` "Board session" with his logs (plan 5.4 gate).

## Questions for Paul (each with the proposed answer the plan executes on)

1. **Bridge port.** Proposed: 33582 (832bridge.tcl used 33581), `RBB_PORT` overrides.
2. **The `rv_debug` 2 -> 1 mapping** in `minimig_virtual_top` (`.rv_debug(hostcpu_rvdebug ? 1'b1 : 1'b0)`). Proposed: not fixed in 5.4 (5.4 uses 1, the top is build B's RTL); when the pin variant is wanted, pass the integer (`.rv_debug(hostcpu_rvdebug)`), one-line change with an L1 gate.
3. **JTAG clock on the board.** Proposed: the Platform Cable's Vivado default (6 MHz); the bridge prints it and takes `JTAG_FREQ` (e.g. 3 MHz) if scans are unreliable; `rv_debug.xdc` constrains TCK at 20 MHz.
4. **`monitor reset halt` on the board** (restarts the OSD firmware, not the Amiga). Proposed: last, optional step of the session.
5. **Keep `RV_DEBUG=1` in the tree after 5.4.** Proposed: yes, default off, documented in `tools/vivado/README.md`; production images stay `rv_debug = 0`.
6. **The XVC rehearsal starts a private `hw_server`** while the Platform Cable is plugged in. Proposed: allowed only with the USB exclusion proven and `lsusb` unchanged (Task 4 guard); otherwise skipped, and the board session's bridge self-test carries the bit-order check.
