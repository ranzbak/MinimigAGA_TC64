# Handoff: implementing the SD card SPI peripheral

For a fresh implementation session that did not take part in the planning
(2026-10-24).  Read this page, then `design.md`, then `plan.md`, in this
directory.  Everything needed is in those three files and the repository;
the planning conversation is not needed.

## 1. What and why, in five lines

Paul's OSD gets slow and disk copies crawl under heavy SD card traffic (a
500 MB small-files copy FAT -> HDF took 1 hour).  The fix: a new
protocol-agnostic, interrupt-driven SPI peripheral for the card (FIFOs with
watermark interrupts, CRC16 accumulator, wait-for-byte mode, block DMA to and
from Gayle's sector FIFO); the firmware runs the SD protocol as
interrupt-driven state machines.  Correctness (no corrupted block on the card
or to the Amiga) outranks speed.  Target: the same copy in ~10 minutes.

## 2. Where things are

| What | Where |
| --- | --- |
| Worktree (work here only) | `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-sdio` |
| Branch | `sdio` |
| Based on | `retire-832` 410470a3 (removes the retired 832 CPU; renames `fw/ctrl_rv` -> `fw/ctrl`, `fw/ctrl_boot_rv` -> `fw/ctrl_boot`).  Not merged yet. |
| Design (approved) | `findings/sdcard-engine/design.md` (commit 282c0faa) |
| Plan (14 tasks) | `findings/sdcard-engine/plan.md` (commit 45b2b50d) |
| Older, different idea (SD native mode, set aside) | `findings/sdio/2026-09-19-sdio-implementation-plan.md` -- background only |
| Main checkout (do not touch) | `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64`, branch `5.0-040-pipelined` |
| CPU core submodule | `lib/AP68040-pipelined` at 972f0c5 (not touched by this work) |

**State at handoff:** nothing implemented.  Start at plan Task 1.  The
worktree is clean; `make -C fw/ctrl` builds and `make -C fw/ctrl/test run`
passes (checked 2026-10-24).

## 3. How to execute

- Use **superpowers:subagent-driven-development**: one fresh implementer per
  task, a fresh reviewer per task before the next starts, a whole-branch
  review at the end.  Implementation agents run on **Opus** (Paul's cost rule).
- Tasks in order.  **Task 3 is a gate:** it needs Paul to run the copy on the
  board; show him the numbers before starting Phase B (Task 4).
- **Task 8 step 5 is a gate:** if the out-of-context synthesis shows more than
  ~600 LUTs or more than one RAMB18, stop and report to Paul.
- Record any decision the design leaves to the builder (design section 10)
  in `design.md` with a one-line reason, in the same commit.

## 4. Tools on this machine

- RISC-V toolchain: `/home/paul/opt/xpack-riscv-none-elf-gcc-15.2.0-1` (the
  Makefiles find it).  Firmware: `make -C fw/ctrl`; boot loader:
  `make -C fw/ctrl_boot`; host tests: `make -C fw/ctrl/test run` (`-j8` fine).
- The firmware image embeds its build date, so two builds never compare
  byte-identical; compare behaviour (tests), not checksums.
- Simulation: prefer **Verilator** (VHDL through GHDL -> Verilog, see
  `sim/common/hostsim.sh`); iverilog/xsim as X-check references.  iverilog
  (`vvp`) runs are single-core: run independent ones in parallel.  xsim runs
  and `sim/l3` runs stay serial, each with its own `RUNTAG` (never reuse one).
- Vivado: 2023.2 for builds -- call `/opt/Xilinx/Vivado/2023.2/bin/vivado`
  directly, with `LD_LIBRARY_PATH` pointing at a `libtinfo.so.5` shim; never
  pass `-stack` (router segfault).  2026.1 at `/opt/Xilinx/2026.1` is fine for
  opening DCPs and reports.  Pattern for small out-of-context runs:
  `findings/ap040-pipelined/tests/synth/ooc.sh`.
- Full build: `tools/vivado/build_ap040.tcl` opens `<root>/project_1/project_1.xpr`,
  which is **untracked and missing in this worktree**.  Copy it from
  `../MinimigAGA_TC64-retire/project_1` (same base) before the first full
  build (plan Task 14); do not point the build at another checkout's sources.

## 5. Paul's rules that apply here

- **The 832 is retired.** Never plan or touch 832 code.
- **Amiga-visible hardware stays exactly as it is** (Gayle registers, IDE
  status/DRQ/IRQ behaviour and order, PIO, floppy).
- **Write-done timing as today**; no write-back caching.
- **Never write the SD card yourself.**  Board write tests only on a scratch
  card or a copy of an HDF -- never Paul's real disk (a bad image corrupted
  his PFS3 disk once).  Paul puts files on cards.
- **JTAG loading of test bitstreams is allowed** (`program_hw_devices`), and so
  is the debug bridge; afterwards leave the board on the shipping image.
  Power cycling via `uhubctl -l 3-5 -p 3 -a cycle` is allowed.  Serial: the
  Amiga's serial port is `/dev/ttyUSB1`.
- **Core stays vendor-neutral:** no vendor primitives in new RTL; other board
  tops must still elaborate (they need not work).
- **Commits:** coherent, buildable commits on `sdio`; never stage
  `fw/ctrl/version.h`-style generated files, `.wcfg`, or
  `tools/vivado/ila_fastram_check.py`.  **No push and no merge** into
  `5.0-040-pipelined` until Paul says so (pushes go over SSH).
- **Reporting to Paul:** lead with the result; numbers measured vs estimated
  said plainly; failures with their output.

## 6. Facts found during planning (save yourself the digging)

- `TIMER` (`0xFFFFFFD0`) counts **5.804 ms**, not milliseconds; several old
  comments are wrong by that factor (`fw/ctrl/hardware.c:180-205`).
- Every new `%` printf format must be added to `fw/ctrl/test/gold/formats.txt`
  and `fw/ctrl/test/fmt_cases.h`, or `make run` fails.  No new discarded
  `TIMER` reads.
- The CPU's hardware window is **16 bits** wide and aliases every 256 bytes;
  free register windows are `0xFFFFFF00/10/20` (`cfide.vhd` decode
  `addr(7 downto 4)` = 0, 1, 2).
- `cfide`'s `irq_src(15 downto 4)` exists but is **not driven** anywhere;
  firmware uses only the legacy interrupt flag today.  Moving to `IrqInstall()`
  turns the legacy flag off, so Akiko and keyboard handlers move too
  (plan Task 9).
- Gayle raises DRQ when its FIFO is full and fires the Amiga's IRQ on the
  **rising DRQ edge** (`gayle_port.v:278-284, 337`): keep "drain, then refill".
- Any IDE command over the `scs(4)` SPI link re-latches `hdd_port`; that is
  why `CD_AudioPoll` must never run inside a transfer (`fw/ctrl/cdrom.h`).
- Gayle-side strobes are levels held for exactly one `clk7_en` sample (about
  4 clk_28 cycles), not single clk_28 pulses (`paula_floppy.v:279-318, 359-380`).
- `sim/l3/tb_l3.v` wires `paula_floppy`, `gayle` and `cfide` directly (not via
  `minimig_virtual_top.v`), so every top-level wiring change is needed there
  too.
- `sim/common/sd_spi_model.v` has no CRC at all; the firmware host tests have
  their own card emulator in `fw/ctrl/test/mock_hw.c:42-230` (no IRQ mock).
- Boot loader code must end below `0x1400` (the main firmware's stack floor
  in the shared 8 KB boot RAM); today `_end` is `0x1040`.
- The firmware binary has no header; `_start` must stay at byte 0.  The
  lock-step version therefore goes in an 8-byte trailer (plan Task 12).
- Card detect: `FPGA_SD_SW`, pin **F23, bank 15**, low = inserted, 10 k
  pull-up + 100 nF on the board; `sd_m_cdet` has no `PACKAGE_PIN` yet.
- Board SD wiring: 10 k pull-ups on CMD, DAT0-3 and CLK; card VDD hard-wired
  (the FPGA cannot power-cycle the card); no 1.8 V.

## 7. Open items outside this plan

- `retire-832` misses clk_114 by -0.144 ns; Paul has not picked a fix yet
  (study in `../MinimigAGA_TC64-retire`, uncommitted
  `findings/timing/retire-clk114-closure.md`).  Measure this work's timing
  against the `retire-832` base build; if `retire-832` gets new commits,
  rebase `sdio` onto it.
- Later, optional (design step 7): a second instance of the peripheral for
  `cfide`'s on-chip links (Gayle/floppy, OSD).  Not part of this plan.

## 8. Prompt to start the new session

> You are implementing the SD card SPI peripheral for the Minimig AGA core on
> the QMTech XC7A100T board.  Work only in the worktree
> `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-sdio` (branch `sdio`).
> Read `findings/sdcard-engine/HANDOFF.md`, then `design.md` and `plan.md` in
> the same directory.  Execute `plan.md` with
> superpowers:subagent-driven-development, Opus implementers, starting at
> Task 1.  Stop at the gates (Task 3: Paul's baseline measurement; Task 8
> step 5: size budget) and report to Paul.
