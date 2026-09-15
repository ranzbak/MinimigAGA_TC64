# Build, program and test the AP68040 core — runbook

How to build a bitstream, load it on the board, write it to flash, and run the
hardware and simulation tests, without help. Every command here was run on
this machine on 2026-09-14/15, branch `stage-e`, unless it is marked
**not yet run**.

Stage E4a (`findings/ap68040/stage-e/2026-09-15-e4a-plan.md`) will remove some
things described here: build arguments 7–10, `tools/vivado/ila_snoop_check.tcl`,
the `WRSYNC` bench switch and the TG68K simulation legs. Those spots are marked
**(changes in E4a)**.

---

## 1. One-time setup

### 1.1 Tools

| Tool | Where / version | Used for |
|---|---|---|
| Vivado | `/opt/Xilinx/Vivado/2023.2` (2025.2 and 2026.1 are also installed; use **2023.2**) | synthesis, JTAG, ILA, xsim |
| Icarus Verilog | `iverilog` / `vvp` 12.0 | `sim/sdram_coherency` |
| Python | `python3` 3.12 | capture decoders |
| vasm | `vasmm68k_mot` in `~/bin` | 68k test programs in `sim/ddr3_cpu` |

### 1.2 The libtinfo shim (Vivado 2023.2 needs `libtinfo.so.5`)

Ubuntu only ships `libtinfo.so.6`. Make a directory with a `.so.5` name once:

```bash
mkdir -p ~/lib/tinfo5
ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5
```

The builds on 2026-09-14/15 used a symlink to
`/snap/core18/2999/lib/x86_64-linux-gnu/libtinfo.so.5` instead. If Vivado still
complains with the `.so.6` link, point the link there.

### 1.3 Environment for every Vivado or xsim command

```bash
export LD_LIBRARY_PATH=$HOME/lib/tinfo5
export LC_ALL=C LANG=C
V=/opt/Xilinx/Vivado/2023.2/bin/vivado
cd ~/work/fpga/Xilinx/artix7/MinimigAGA_TC64        # always start from the repo root
```

`LC_ALL=C` matters: without it, synthesis started while a simulation runs
aborts with `locale::facet::_S_create_c_locale name not valid`.

### 1.4 Rules that save hours

- **Never pass `-stack` to Vivado 2023.2.**
- **One Vivado hardware session at a time.** Loading a bitstream and an ILA
  capture must not overlap.
- **One simulation leg at a time** (see `sim/ddr3_cpu/run.sh`, header). A
  concurrent run once produced a false failure that was never explained.
- **Never edit a script or testbench while a run that uses it is going.** bash
  re-reads a running script from disk, and xelab reads the sources when a leg
  starts.
- **zsh does not split variables into words.** `F="a.v b.v"; git add $F` passes
  one argument called `a.v b.v`. Write file names and options out literally,
  or run the commands in `bash`.
- **zsh aborts on a glob that matches nothing** (`no matches found:
  build/x/*.bit`). Check with `ls` first.

---

## 2. Build a bitstream

### 2.1 Command

```bash
N=stage_ap040_mybuild                     # output directory name under build/
mkdir -p build/$N
$V -mode batch -nolog -nojournal -source tools/vivado/build_ap040.tcl \
   -tclargs $PWD/build/$N 0 $PWD 1 30 4096 1 1 3 0 > build/$N.log 2>&1
grep -q "=== ALL DONE ===" build/$N.log && echo BUILD OK || grep "^ERROR" build/$N.log
```

It takes about 35–45 minutes. `=== ALL DONE ===` at the end of the log means it
finished.

### 2.2 Arguments (in order)

| # | Name | Shipping value | Meaning |
|---|---|---|---|
| 1 | report dir | `$PWD/build/<name>` | where the bitstream and reports are copied |
| 2 | ila | `0` | `1` adds the debug ILAs (`ila_cpu040`, `ila_fastram`) |
| 3 | repo root | `$PWD` | the tree to build (see 2.5 for parallel builds) |
| 4 | post stores | `1` | the 040 cache's posted stores; `0` = all stores synchronous (A/B only) |
| 5 | CPU clock divide | `30` | `30` = clk_114/3 = 37.8 MHz (D3); `40` = /4, the pre-D3 rate |
| 6 | CPU ILA depth | `4096` | **use `1024` with `ila = 1`**, or the ILA does not fit (2.4) |
| 7 | phase gate | `1` | **(changes in E4a)** `0` removes the chip-RAM phase gate |
| 8 | data register | `1` | **(changes in E4a)** `0` = read data not registered with the grant |
| 9 | gate delay | `3` | **(changes in E4a)** clk cycles the gate opens after enaWRreg; `3` is the fix, `0` corrupts |
| 10 | request gate | `0` | **(changes in E4a)** unused option |

Typical builds:

```bash
# shipping image, no debug logic
... -tclargs $PWD/build/$N 0 $PWD 1 30 4096 1 1 3 0
# same with ILAs, for a phase-histogram or RTG capture
... -tclargs $PWD/build/$N 1 $PWD 1 30 1024 1 1 3 0
```

### 2.3 What to check after every build

**Output files** in `build/<name>/`: `minimig_openaars_top.bit`, plus
`minimig_openaars_top.ltx` when built with ILAs, `timing_summary.rpt`,
`utilization.rpt`, `clock_interaction.rpt` and the `cdc*.rpt` reports.

**Timing:**

```bash
grep -E "^(clk_114 +clk_38|clk_38 +clk_38|clk_38 +clk_114|clk_gen_sdram +clk_114) " \
  build/$N/clock_interaction.rpt | awk '{printf "%-14s -> %-14s WNS %7s  fail %s / %s\n",$1,$2,$6,$8,$9}'
```

- The three CPU clock rows (`clk_114->clk_38`, `clk_38->clk_114`,
  `clk_38->clk_38`) must show `fail 0`.
- `clk_gen_sdram -> clk_114` fails on 16 endpoints by about −0.3 to −0.65 ns in
  **every** build since the start of the project, including the stable ones.
  That's known and not a new problem. A much worse value would be.

**Build switches that were really used.** The build log only echoes
`$phgate`-style names, so read synthesis's own record, and only its **last**
run (the file keeps earlier runs):

```bash
f=project_1/project_1.runs/synth_1/runme.log
last=$(grep -n 'Starting synth_design' $f | tail -1 | cut -d: -f1)
tail -n +$last $f | grep -iE '(cpu_clk_ratio|cpu_phase_gate_en|cpu_data_reg_en|cpu_phase_gate_dly|cpu_phase_gate_req|CPU040_DEBUG_ILA|DDR3_FASTRAM_ILA)[^a-z].*bound to' \
  | sed -E 's/.*Parameter ([A-Za-z0-9_]+) bound to: *([0-9]+).*/\1=\2/' | sort -u
```

**ILA present or not:** the `.ltx` exists, and `utilization.rpt` shows about
127 block RAM tiles with ILAs against about 60 without.

### 2.4 Known build failure: block RAM over-utilised

`[DRC UTLZ-1] Resource utilization: RAMB18 and RAMB36/FIFO over-utilized` means
the ILA's sample storage doesn't fit. An ILA stores every probe at full depth.
Use argument 6 = `1024` with ILAs on.

### 2.5 Two builds at the same time

Builds use `project_1/` inside the repo root, so two builds on one tree collide.
Copy the tree (without the big output directories) and give the copy as argument 3:

```bash
C=~/build_tree2
rsync -a --delete --exclude=/.git --exclude=/build --exclude=/sim --exclude=/findings \
  --exclude=/doc --exclude=/project_1/project_1.runs --exclude=/project_1/project_1.cache ./ $C/
(cd $C && $V -mode batch -nolog -nojournal -source $C/tools/vivado/build_ap040.tcl \
   -tclargs $PWD/build/$N 1 $C 1 30 1024 1 1 3 0 > build/$N.log 2>&1)
```

Before a second build in the copy, sync the changed sources again
(`rsync -a rtl/ $C/rtl/; rsync -a tools/ $C/tools/`). Its synthesis log is
`$C/project_1/project_1.runs/synth_1/runme.log`.

---

## 3. Load a bitstream over JTAG (temporary)

```bash
$V -mode batch -nolog -nojournal -source tools/vivado/program.tcl \
   -tclargs $PWD/build/$N/minimig_openaars_top.bit 2>&1 | grep -E "^===|ERROR"
```

Expected: `=== DONE: …minimig_openaars_top.bit loaded, DONE pin = 1 ===`.

- It lasts until the next power cycle; then the flash image boots again.
- **The AP68040 takes about two minutes to reach Workbench** (ROM init still
  runs at 60 s). A black screen inside the first minute is not a failure.
- **If the first boot after loading hangs** (gray screen, firmware never
  starts), load the same bitstream once more. It happened on 2026-09-14 and the
  reload booted normally.
- After using the reset while the firmware loader shows a white screen, the
  white screen can come back after the reset. That's a known open issue with
  the reset circuitry.

---

## 4. Write the SPI flash (permanent) — not yet run

**Only flash an image that has passed the hardware test in section 5.** No
flash script exists in the repo yet, and nobody has flashed through this
procedure on this board so far. The steps below are the standard Vivado
procedure, filled in with this board's settings.

Board facts: configuration flash **Micron MT25QL128** (16 MB). The constraints
set **4-lane SPI** (`BITSTREAM.CONFIG.SPI_BUSWIDTH 4` in
`fpga/openaars/aars_v5.0/xc7a100t/generic.xdc`) and **3.3 V** configuration
voltage.

In the Vivado 2023.2 GUI:

1. **Tools → Generate Memory Configuration File.** Format **MCS**, memory part
   **mt25ql128** (search for it; pick the `spi-x1_x2_x4` variant), interface
   **SPIx4**. Load the bitstream `build/<name>/minimig_openaars_top.bit` at
   address `0x00000000`. Write e.g. `build/<name>/minimig_openaars_top.mcs`.
2. **Open Hardware Manager → Open Target → Auto Connect.**
3. Right-click the `xc7a100t` device → **Add Configuration Memory Device** →
   the same mt25ql128 part.
4. **Program Configuration Memory Device:** the `.mcs` file, with **Erase**,
   **Program** and **Verify** ticked.
5. Wait for "Flash programming completed successfully", then **power-cycle**
   the board and confirm it boots the new image.

---

## 5. Hardware test (every build that might be kept)

### 5.1 By eye

1. Load the build (section 3) and boot to Workbench.
2. **Workbench icons:** no missing runs of 8 pixels.
3. In the OSD, set **Turbo for Chip RAM and Kickstart** on. Run **Way Too Rude**
   (Revision 2020 demo) to the end: no graphics or sound corruption.
4. **SysInfo** speed: at least **0.28×** an A4000/040-25 for the D3 core.
   Without turbo it's slower.
5. **Boot once with Turbo off** (Chip RAM and Kickstart). On 2026-09-15 the
   `--ap040 --chipbus` simulation leg (chip RAM over the chipset bus) hung with
   the shipping gate delay 3, so this configuration must be seen working on the
   board before an image is flashed.

### 5.2 Phase histogram (needs a build with ILAs)

The ILA counts where chip-RAM accesses finish in the SDRAM controller's 16-step
cycle. With the demo running:

```bash
mkdir -p ~/captures
$V -mode batch -nolog -nojournal -source tools/vivado/ila_phase_hist.tcl \
   -tclargs $PWD/build/$N ~/captures/demo 10 3 2>&1 | grep -E "^===|ERROR"
python3 tools/vivado/phase_hist.py ~/captures/demo_*.csv | tail -3
```

(10 samples, 3 s apart.) Reading the `SUM` line:

| Result | Meaning |
|---|---|
| peaks on steps **2, 6, 10, 14** (13 may also be high), under 1 % elsewhere | good: the D3 fix is working |
| peaks on **3, 7, 11, 15** | bad placement: this corrupted Way Too Rude |
| all counts 0 | no chip-RAM accesses were measured: the CPU is stuck, or chip turbo is off, or the demo wasn't running. On the 2026-09-14 hang the address sat on `$DFF09A` |

Start the capture only once the demo is running. A capture during boot shows
different, less useful traffic.

### 5.3 "Did it boot?" without looking at the screen

```bash
$V -mode batch -nolog -nojournal -source tools/vivado/ila_boot_probe.tcl \
   -tclargs $PWD/build/$N ~/captures/boot 1 150
python3 tools/vivado/ila_bus_decode.py ~/captures/boot_now.csv --longs --pc
```

Arguments: bitstream dir, output prefix, `1` = load the bitstream first,
seconds to wait. The script's header describes the reference signature of a
booted machine.

### 5.4 RTG capture (needs a build with the `dbg_rtg` probe, e.g. `build/stage_ap040_e0rtg_ila`)

1. Load the build, boot to Workbench, **don't activate RTG yet**.
2. Arm the capture (5-minute timeout):

   ```bash
   $V -mode batch -nolog -nojournal -source tools/vivado/ila_rtg_capture.tcl \
      -tclargs $PWD/build/stage_ap040_e0rtg_ila ~/captures/rtg.csv 5 2>&1 | grep -E "^===|ERROR"
   ```

3. When `=== armed: ACTIVATE AN RTG SCREEN MODE NOW` appears, switch on an RTG
   screen mode.
4. Decode:

   ```bash
   python3 tools/vivado/rtg_decode.py ~/captures/rtg.csv
   ```

   It lists every Akiko register read/write, and the framebuffer address the
   driver wrote. An address at or above `$01000000` that isn't Zorro III board 1
   means scan-out can't reach the framebuffer. See
   `findings/ap68040/stage-e/2026-09-15-stage-e-design.md` §7.

### 5.5 ILA capture problems

| Symptom | Cause / fix |
|---|---|
| `NO dbg_phist PROBE` / `NO dbg_rtg PROBE` | the bitstream on the board was built without that probe, or you gave the wrong build directory (its `.ltx` must match what's loaded) |
| capture waits forever | `wait_on_hw_ila -timeout` is in **minutes**, not seconds |
| JTAG connection drops | close other Vivado sessions, then rerun |

---

## 6. Simulation

### 6.1 `sim/ddr3_cpu` — the AP68040, its wrapper and the memory controllers (xsim)

Run from `sim/ddr3_cpu`, with the environment from 1.3.

```bash
cd sim/ddr3_cpu
./run.sh --ap040 > /tmp/ap040.out 2>&1; echo "exit=$?"
grep -E "^DDR3 CPU TB" xsim_run_pass_ap040.log
```

**The verdict** is the last `DDR3 CPU TB:` line: `2 passed, 0 failed`, or
`N checks failed`. The exit code agrees (0 or 1). `DDR3 CPU TB: PASS (68k
program completed all phases)` only says the 68k program finished; a leg can
print that and still fail its checks. Each leg takes about 22–25 minutes; the
busy leg (below) about 40.

**Legs:**

| Command | What it tests | Must |
|---|---|---|
| `./run.sh --ap040` | AP68040 with the DDR3 fast-RAM model | pass |
| `./run.sh --mmu` | MMU table walker program | pass |
| `./run.sh --ap040 --chipbus` | chip RAM over the 7 MHz chipset bus (turbo off) | pass |
| `./run.sh --nofill` | line fills through the 16-bit adapter (A/B reference) | pass |
| `./run.sh --snoop` | chipset write snoops reach the 040's cache | pass |
| `./run.sh --lwmutant`, `--mmumutant`, `--fillmutant`, `--snoopmutant` | deliberately broken copies of the wrapper | print `mutant failed as required` |
| `./run.sh`, `./run.sh --mutant` | TG68K core **(changes in E4a: removed)** | pass / fail |

**Switches** (environment variables in front of `./run.sh`):

| Variable | Effect |
|---|---|
| `REALSDRAM=1` | real `sdram_ctrl` + SDRAM chip model + a chipset DMA agent instead of the memory model |
| `DMA_OVERLAP=1` | the chipset writes into the same cache lines the CPU uses, and reads back what the CPU wrote (P2C probe) |
| `P7LOOPS=<n>` | repeat program phase 7 n times (use 10 with `DMA_OVERLAP`) |
| `P2CBLOCK=<n>` | CPU writes a block of n longwords per loop for the chipset to read |
| `CPU_PHASE_GATE_DLY=<d>` | the wrapper's phase-gate delay; default **3** (shipping). `0` = the gate as first built |
| `CPU_RATIO=3` or `4` | CPU clock ratio (3 = D3) |
| `CPU_PHASE=0..3` | start the CPU clock 0–3 clk periods late |
| `WRSYNC=1` | hold CPU write acknowledges until SDRAM has them **(changes in E4a: removed)** |
| `NOCPU=1` | keep the CPU in reset: chipset-only control run |
| `RUNTAG=<word>` | own run directory and log (`xsim_run_<variant>_<word>.log`), so legs don't overwrite each other |
| `PATBYTES=64 MISLINES=2 CNTN=8` | smaller program regions for a quick debug run |
| `TRACE=1` | print a bus trace |

**The placement check** (`REALSDRAM=1`, `sim/ddr3_cpu/placement_monitor.vh`) prints
a 16-bin histogram of where chip-RAM acknowledges land:

- **Calibrated, not absolute.** The simulation lands everything **one step
  later** than the real board, so bench step 3 means board step 2. The check
  already allows for that (`PLACEMENT_OFFSET` = 1) and fails a run if more than
  10 % land off the good steps.
- Quiet leg `REALSDRAM=1 ./run.sh --ap040`: must pass. With
  `CPU_PHASE_GATE_DLY=0` it must fail. That proves the check can catch the old,
  corrupting gate.
- Busy leg `REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=10 ./run.sh --ap040`: the placement
  histogram is only reported. Its summary lines must match the saved reference
  `sim/ddr3_cpu/ref/overlap_gate3.txt` exactly (being created in E1).

**`run.sh` overwrites tracked reference logs.** Without `RUNTAG`, a leg writes
`xsim_run_<variant>.log`, and several of those are committed references
(`git ls-files sim/ddr3_cpu | grep xsim_run_`). Use `RUNTAG=<word>` for
experiments. If you ran without it, check `git status` and put the committed
version back with `git restore sim/ddr3_cpu/xsim_run_<variant>.log`, unless you
mean to update the reference.

**Before trusting a result, check the bench-trap list** in
`findings/ap68040/stage-e/e0-e1-results.md` and the notes at the top of
`sim/ddr3_cpu/run.sh`.

### 6.2 `sim/sdram_coherency` — the SDRAM controller alone (Icarus)

```bash
cd sim/sdram_coherency
./run.sh fast sg7 +nobg +rounds=50        # a few minutes
./run.sh fast sg7 +rounds=50              # background chipset load on
```

**Always pass `+rounds=50`.** Without it a leg runs well over 15 minutes. The
summary at the end lists each check with "checked / FAILED" and a total. The
two known controller defects fail on unmodified RTL. The reference (commit
85cac1b) is **52 errors** for `+nobg` and **14 errors** for the default leg.
The per-check table is in `findings/ap68040/stage-e/e4a-results.md`. A change
that shouldn't affect the controller must reproduce those numbers exactly.

### 6.3 Small checks

```bash
cd tools/vivado && python3 -m unittest test_rtg_decode -v    # decoder unit test, 3 tests
tools/complexity_report.sh mylabel                           # one row of the Stage E complexity budget
```

---

## 7. Where things are

| What | Where |
|---|---|
| Build outputs | `build/<name>/` (bitstream, `.ltx`, reports) |
| Stage E design, plans, results | `findings/ap68040/stage-e/` |
| D3 investigation record | `findings/ap68040/sdd-d3/d3-snoop-coherency.md` |
| Overall AP68040 plan and backlog | `findings/ap68040/plan-v2-with-ddr3.md` |
| Older Vivado helper scripts | `tools/vivado/README.md` |
| Known-good tags | `d3_stable` (D3 core, 0.28×), `unoptimized_040_working` (pre-optimisation 040) |
