# Simulation

The test benches, what each one checks, and how to run it. Three groups:

1. the CPU core's own benches, in the `lib/AP68040-pipelined` submodule
   (Icarus Verilog);
2. `sim/ddr3_cpu`, the SoC-level bench: the CPU inside its Minimig wrapper
   with the real memory controllers (Vivado xsim);
3. small benches in `sim/` for single modules (mostly Icarus Verilog).

Tool setup (Icarus Verilog, `vasmm68k_mot`, Vivado 2023.2 with the libtinfo
shim) is in [building.md](building.md#1-tools).

**Rules that save hours:**

- Icarus (`vvp`) benches are single-threaded and independent, so they can run
  in parallel.
- **xsim benches run one at a time.** A pass run next to a mutant run once
  produced a false failure that was never explained (`sim/ddr3_cpu/run.sh`
  header).
- Don't edit a script or bench while a run that uses it is going.
- Several benches overwrite **tracked reference logs** when run without
  `RUNTAG` (listed below). Use `RUNTAG=<word>` for your own runs, and check
  `git status` afterwards.
- Many benches have a **mutant** mode: a deliberately broken copy of the RTL
  that must fail. A mutant that passes means the bench can't see the bug.

## 1. The CPU core: `lib/AP68040-pipelined/tb`

```bash
cd lib/AP68040-pipelined/tb
./run_pipe_tests.sh
```

Needs only Icarus Verilog for the core legs; each line says `pass` or
`FAIL`, and the script exits non-zero on any failure. Build files go to
`tb/build/` (ignored by git). Every bench runs the core alone, so a failure is
the CPU's, not the Minimig integration's.

Some legs need files outside the submodule and are skipped (with a message)
without them:

| Variable | Default | Legs |
|---|---|---|
| (`vasmm68k_mot` on `PATH`) | | the program benches (`pipe_asm/`, the FPU, MMU and interrupt programs) |
| `FPSP_LIB=<path>/68040.library` | a path on Paul's machine | the FPSP legs: MMULib's `68040.library` 40.2 run on the core |
| `AP040_REF=<repo>/lib/AP68040` | `../../MinimigAGA_TC64/lib/AP68040`, which doesn't exist inside the submodule | the `compat:` legs (the core in its Minimig wrapper, on the reference core's test programs) |
| `AP040_MAIN=<clone of apolkosnik/AP68040 main>` | `../../AP68040-reference` | `t_movem_restart`, `t_fpu_resume`, `t_fpu_frames` |

So inside this repository, run it as:

```bash
cd lib/AP68040-pipelined/tb
AP040_REF=$PWD/../../AP68040 FPSP_LIB=/path/to/68040.library ./run_pipe_tests.sh
```

On 2026-09-25 (submodule at 9efe490) a plain `./run_pipe_tests.sh` ran
**198 legs, all passing**, in about 7 minutes (the FPSP legs ran because the
library was at the default path). With `AP040_REF` and `AP040_MAIN` set as
well it ran **220 legs, all passing**; the `compat:` legs make that run much
longer (about 21 minutes on this machine).

Other scripts in `tb/`: `fpsp_mutants.sh` (18 broken FPSP-path variants, all
must be caught), `run_tests.sh` (the old sequential core in `rtl_old/`).

## 2. The SoC bench: `sim/ddr3_cpu` (xsim)

The CPU wrapper `rtl/soc/TG68K.vhd` with the 68040 inside, the real
`sdram_ctrl` with an SDRAM chip model, a chipset DMA agent, and the DDR3
Zorro III fast RAM with its controller and a DDR3 model. A 68k test program
(`asm/ddr3_cpu_test.asm`, assembled with vasm by the script) runs on it.

```bash
cd sim/ddr3_cpu
export LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C LANG=C
PIPELINED=1 PIPE_DIR=$(cd ../../lib/AP68040-pipelined && pwd) RUNTAG=mine \
    ./run.sh --ap040 > /tmp/ddr3_cpu.out 2>&1; echo "exit=$?"
grep "DDR3 CPU TB" xsim_run_pass_ap040_pipe_mine.log
```

- **`PIPELINED=1` selects the pipelined core.** Without it the bench builds
  the reference core from `lib/AP68040`. `PIPE_DIR` defaults to a clone next
  to the repository (`../AP68040-pipelined`), so point it at the submodule.
- **Verdict:** the last `DDR3 CPU TB:` line must say `2 passed, 0 failed`;
  the exit code agrees. `PASS (68k program completed all phases)` alone only
  means the program finished.
- **Time:** 15-25 minutes a leg.
- **Log:** `xsim_run_<variant>.log`, with the variant built from the flags:
  `pass_ap040`, then `_chipbus`, `_pipe`, `_<RUNTAG>`.

Legs (from the header of `run.sh`):

| Command | Checks | Must |
|---|---|---|
| `./run.sh --ap040` | the CPU with the DDR3 fast RAM, SDRAM and chipset DMA | pass |
| `./run.sh --ap040 --chipbus` | chip RAM over the 7 MHz chipset bus (Turbo off) | pass |
| `./run.sh --mmu` | an MMU table-walk program (tables in chip RAM and DDR3) | pass |
| `./run.sh --snoop` | chipset DMA writes reach the CPU's data cache | pass |
| `./run.sh --ackmutant`, `--mmumutant`, `--snoopmutant`, `--gatemutant` | broken copies of the wrapper | print `mutant failed as required` |

Switches, as environment variables: `RUNTAG=<word>` (own directory and log),
`PATBYTES=64 MISLINES=2 CNTN=8` (smaller program regions, a quick run),
`TRACE=1` (bus trace), `P7LOOPS=<n>` and `P2CBLOCK=<n>` (program options),
`VIVADO_PATH` (default `/opt/Xilinx/Vivado/2023.2`).

**Tracked logs:** `git ls-files sim/ddr3_cpu | grep xsim_run_` lists the
reference logs. A run without `RUNTAG` overwrites the one with its name;
`git restore` it unless you mean to update it.

Section 6.1 of [build-program-test.md](build-program-test.md) predates the
current script: its `--nofill`, `--fillmutant` and `--lwmutant` legs and the
`REALSDRAM` switch are gone (every leg now uses the real SDRAM controller).
Before trusting a surprising result, read the notes at the top of `run.sh`.

## 3. Module benches in `sim/`

Run from the repository root unless noted. Checked on 2026-09-25 where a
result is given.

| Bench | Tool | Command | Checks | Result |
|---|---|---|---|---|
| `sim/kbd_gate` | iverilog | `sim/kbd_gate/run.sh` | a key held when the OSD opens still sends its release to the Amiga; runs the normal and the mutant leg | normal PASS, mutant FAIL (as wanted) |
| `sim/osd_keyq` | iverilog | `sim/osd_keyq/run.sh` (add `mutant` for the teeth check) | the OSD key-event queue and the version reply's capability byte | PASS; mutant FAIL (as wanted) |
| `sim/cia_timer` | iverilog | `RUNTAG=x sim/cia_timer/run.sh` (add `inmode reload` for the mutants) | CIA timer count-source selection and the E-clock-aligned reload; its `run_<mode>/` logs are tracked, hence `RUNTAG` | PASS; both mutants FAIL (as wanted) |
| `sim/autoconfig` | iverilog | `sim/autoconfig/run.sh` (`-v` for register dumps) | which boards the autoconfig chain offers for every OSD memory setting, and where the OS puts the third Zorro III board | prints a table; the 8 rows marked FAIL are 64 MB platforms (`ram_64meg=1`), not this board |
| `sim/ddr3` | iverilog | `cd sim/ddr3 && ./run.sh [seed]` | the DDR3 fast RAM's cache backend and clock crossing, against a behavioural memory | `DDR3 FASTRAM TB: 9 passed, 0 failed` |
| `sim/sdram_coherency` | iverilog | `cd sim/sdram_coherency && ./run.sh fast sg7 +nobg +rounds=50` | CPU and chipset sharing chip RAM through the real `sdram_ctrl` | fails by design on two known controller defects; see below |
| `sim/sdram_timing` | iverilog | `cd sim/sdram_timing && ./run.sh fast sg7` | on which clock edge SDRAM read data arrives, per process corner | **doesn't build on this branch** (the bench's port list is older than `sdram_ctrl`) |
| `sim/ram_seq` | xsim | `sim/ram_seq/run.sh` | `ap040_ram_seq`, the unit splitter between the CPU and the RAM ports; open, gated and mutant legs | not run for this document |
| `sim/ddr3_full` | xsim | `cd sim/ddr3_full && ./run.sh [seed]` | the Zorro III fast RAM with the DDR3 controller and the Micron DDR3 model | not run; overwrites the tracked `xsim_run.log` |
| `sim/ddr3_island` | xsim | `cd sim/ddr3_island && ./run.sh [skew_ps ...]` | the DDR3 controller island at several clock skews (runs them in parallel) | not run; overwrites tracked logs |

**`sim/sdram_coherency`:** always pass `+rounds=50`; without it a leg runs well
over 15 minutes. Two known `sdram_ctrl` defects make it fail on unmodified
RTL. The runbook's reference is 52 errors for `+nobg` (commit 85cac1b); on
this branch on 2026-09-25 `+nobg +rounds=50` gave **57 errors** (50 in the
"C2P line buffer primed" check, 6 late P2C writes, 1 P2C longword write) in
about 9 minutes. Whether the extra 5 are a regression or a changed bench is
unverified. Drop `+nobg` to add background chipset load.

**Without a runner script:** `sim/rtc_spi_clock`, `sim/toccata`,
`sim/i2c_sender`, `sim/hostcpu-i2c-bridge` (Vivado simulator projects with
`.wcfg` waveform setups), `sim/tg68vswf68ksim`, `sim/rom-hostcpu-test`,
`sim/autoconfig_add_snd`. The directories containing only an `nc` folder
(`sim/minimig`, `sim/tg68`, `sim/sram` and others) are from the original
Minimig and its Cadence NC-Verilog flow, and aren't maintained.

## 4. Research benches

`findings/ap040-pipelined/tests/` holds the benches used while the pipelined
core was built: the retire-trace differential harness against the reference
core, the cputest replay, cycle-count checks and the Kickstart differential
bench (Verilator). Their READMEs describe them. They are a development record
rather than a regression suite. The Kickstart bench can't be built from the
repository: its `build.sh` is caught by the plain `build.sh` rule in
`.gitignore` and was never committed.
