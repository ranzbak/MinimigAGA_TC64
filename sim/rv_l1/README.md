# L1 bench: `rv_hostcpu` + big-endian memory model (iverilog, Verilator)

The L1 bench runs RISC-V programs on the OSD host CPU block
`rtl/host/rv_hostcpu.v` (VexRiscv behind the 832 req/ack bus) against an
abstract memory model with per-region latency and a few simulation-only
registers. A bus checker asserts the bus contract every cycle. One run takes
seconds and needs no Vivado. It runs on Icarus Verilog (default, the
X-checking reference) or on Verilator (`SIM=verilator`, much faster, see
"Verilator").

| File | What it is |
|---|---|
| `tb_rv_l1.v` | Top: `rv_hostcpu` + `mem_model` + `bus_checker`, plusargs, end of run |
| `mem_model.v` | 1 MB BE memory, latency per region, sim MMIO, interrupt register |
| `bus_checker.v` | Bus contract assertions (`=== BUS VIOLATION ...`) |
| `jtag_bfm.v` | JTAG master BFM (`jtag_reset`, `jtag_idle`, `jtag_ir`, `jtag_dr`), TCK 50 ns, for `dm_smoke` |
| `run.sh` | Builds the simulator, runs one program or the whole matrix; `compare` diffs two run directories |
| `verilator/l1.vlt` | Verilator lint waivers (bench side; `rtl/` is not edited for Verilator) |
| `Makefile` | Builds the test programs into `build/<prog>.hex` |
| `sw/crt0_l1.S`, `sw/l1.ld`, `sw/l1.h` | Start-up code, linker script, MMIO header |
| `sw/boot_fw.S` | Boot ROM stand-in for programs linked as firmware (`irq_sig`, `irq_c`, `exc`) |
| `tests/` | Test programs (`.S` or `.c`) and expected memory dumps (`.mem`); `tests/dm_smoke.v` is the debug smoke test sequence |
| `prog/Makefile`, `sw/syscalls.c`, `sw/l1_newlib.ld` | Firmware-unit programs (newlib-nano) built from `FWDIR` (default `fw/ctrl_rv`) and their runtime, see "Firmware units"; `fmt_rv` (the firmware's C library link), see "C library check (`fmt`)" |

## Prerequisites

1. **RISC-V toolchain**: xPack `riscv-none-elf-gcc` 15.2.0-1 in
   `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`. Setup (download, checksum,
   Ubuntu fallback, verification) is in [`tools/riscv/README.md`](../../tools/riscv/README.md);
   in short:

   ```sh
   bash tools/riscv/fetch-xpack.sh          # installs into ~/opt
   bash tools/riscv/check-toolchain.sh      # must pass
   ```

   Another install: `export RV_GCC_DIR=/path/to/toolchain` (and
   `RV_PREFIX=` if its tools are not `riscv-none-elf-*`).
2. **Icarus Verilog 12** at `/usr/local/bin/iverilog` and `/usr/local/bin/vvp`
   (`IVERILOG=` / `VVP=` override the paths). The gates of `all` always use
   it. Ubuntu 24.04's package is 12.0 (`sudo apt install iverilog`, installed
   to `/usr/bin`): put `IVERILOG=/usr/bin/iverilog VVP=/usr/bin/vvp` in front
   of `bash sim/rv_l1/run.sh ...`.
3. Optional, **Verilator 5.020** or later (`--timing` support), for
   `SIM=verilator`: `sudo apt install verilator` (Ubuntu 24.04 ships 5.020;
   `VERILATOR=` overrides the path), plus g++; `ccache` is used when present.
4. GNU make, bash, `od`, `awk`.

## Build the tests and run

From the repository root:

```sh
# build/<prog>.hex, .elf, .lst, .map
make -C sim/rv_l1 tests
# gates + full matrix + teeth, ~4 min on 8 cores
bash sim/rv_l1/run.sh all
# the same on Verilator, ~15 s
SIM=verilator bash sim/rv_l1/run.sh all
```

`run.sh` runs the make itself first (`make tests`; `units`: `make -C prog
FWDIR=...`; `dhry`: `make -C fw/dhrystone_rv`), so a changed test source is
never run from a stale image. The program lists come from the Makefiles
(`make -C sim/rv_l1 print-progs`, `make -C sim/rv_l1/prog print-progs`):
`run.sh` itself only names the teeth (`TEETH`, `uart_read`), the `irq` set and
the programs that need the `-DDM_SMOKE` bench; every other program the
Makefile builds is in the matrix.

`all` ends with `=== ALL PASS` (exit 0) or `=== SOME FAILED` (exit 1). It runs:

* **gates**: `rv_hostcpu.v` with the cores parses and elaborates with
  `iverilog -g2005` (the Verilog-2005 subset Quartus needs) for `DEBUG` 0 and
  2; `DEBUG=1` without `rtl/host/xilinx/rv_bscane2.v` misses only
  `rv_bscane2`, and with it only `BSCANE2` and `BUFG` (unisims; the xsim
  elaboration with `unisims_ver` is `sim/host_bridge/stub/elab.sh dmt`);
  `DEBUG=3` fails elaboration; no `BSCANE2`/`BUFG*` instance in `rtl/host`
  outside `rv_bscane2.v`, and `rtl/host/host.qip` does not name it;
* **matrix**: every program x `WS` {0, 3, 8} x `ROMWS` {0, 1} x `EXTRA_WS`
  {0, 3} must print `=== PASS`, and match `tests/<prog>.mem` if that exists;
* **teeth**: `fencei_nofencei` (fencei without `fence.i`) over the same
  matrix must print `=== FAIL 1` (the stale I$ line); `irq_sig_mut`
  (`irq_sig` with `fw/ctrl_rv/arch/trap.S` minus the restore of t3) must
  print `=== FAIL 11c`; `uart_read` (a read of the cfide UART register) once
  at `WS=3 ROMWS=1` must print `=== FAIL uart read`;
* **debug variant**: every program once with `DEBUG=2` (`VexOsd_DMJ`);
* **dm**: `dm_smoke` (below) at `WS` {0, 3, 8} x `EXTRA_WS` {0, 3};
* no run may print `=== BUS VIOLATION`.

One program, settings from the environment (defaults `WS=3 ROMWS=1
EXTRA_WS=0 DEBUG=0`):

```sh
bash sim/rv_l1/run.sh lanes
WS=8 ROMWS=0 EXTRA_WS=3 bash sim/rv_l1/run.sh refill fencei
```

The interrupt and trap set (`fw/ctrl_rv/arch`): `irq`, `irq_sig`, `irq_c`
and `exc` at `WS` 0, 3 and 8 (`ROMWS`, `EXTRA_WS`, `DEBUG` from the
environment, defaults 1/0/0) plus `irq_sig_mut` once at `WS=3` (expected
`=== FAIL 11c`); ends `=== IRQ PASS (13 runs)` or `=== IRQ FAILED`, summary in
`run_${RUNTAG:-wt}/irq.txt`. (The name `irq` is this set; the `irq` program
alone runs in it.)

```sh
bash sim/rv_l1/run.sh irq
```

The debug smoke test: `tests/dm_smoke.v` drives the `VexOsd_DMJ` pin TAP
(`DEBUG=2`) through `jtag_bfm.v` (TCK 50 ns, asynchronous to the CPU clock)
while `tests/dm_smoke.S` counts in a loop; at `WS` 0, 3, 8 x `EXTRA_WS` 0, 3
(`ROMWS` from the environment, default 1); ends `=== DM_SMOKE PASS (6 runs)`
or `=== DM_SMOKE FAILED`, summary in `run_${RUNTAG:-wt}/dm_smoke.txt`. (The
name `dm_smoke` is this set; one setting by hand: `-DDM_SMOKE` under "Bench".)

```sh
bash sim/rv_l1/run.sh dm_smoke
```

Steps, each checked (a failed check ends the run with `=== FAIL dm <what>`):

1. IDCODE after Test-Logic-Reset and with IR `0x01` = `0x10002FFF`;
2. `dtmcs` (IR `0x10`): version 1, abits 7 (its `idle` hint is used between
   DMI scans);
3. `dmcontrol.dmactive = 1` (read back); `dmstatus`: version 2 (debug spec
   0.13), authenticated, allrunning; `ackhavereset` clears the power-on
   havereset;
4. `haltreq` -> `dmstatus.allhalted`;
5. abstract command (access register, 32 bit) read of `x10` (regno
   `0x100A`) = the loop counter the program stores at 0x4000 (or that + 1,
   if halted between the `addi` and the `sw`); `x12` = boot count 1;
6. 2000 cycles later `x10` and the memory word are unchanged;
7. `resumereq` -> allresumeack + allrunning; halted again, `x10` grew;
8. `dmcontrol.ndmreset` set: `rv_hostcpu`'s `core_rst` is 1; cleared:
   `core_rst` 0, all/anyhavereset set (then acknowledged), the program
   restarted from 0x0 (`x12` = boot count 2, memory word 0x4004 = 2); the
   log says whether the reset hit a bus transaction (`drop`);
9. abstract command write `x11` = `x10` + 1000 (read back), resume: the
   program runs 1000 more iterations to `x10 == x11` and DONE 0. The bench
   accepts DONE only after the whole sequence and with the counter word =
   that target.

DMI accesses (IR `0x11`, 41 bits `{addr[6:0], data[31:0], op[1:0]}`) are a
request scan, `idle` TCKs in Run-Test/Idle and a nop scan that returns the
status (0 ok, 2 failed: the run fails, 3 busy: `dtmcs.dmireset`, idle + 4,
retry; the log prints the retry count, 0 so far).

Outputs go to `sim/rv_l1/run_${RUNTAG:-wt}/` (one log per run, named
`<prog>_ws<WS>_r<ROMWS>_x<EXTRA_WS>_d<DEBUG>.log`, plus `results.txt`); use a
new `RUNTAG` per code change when comparing runs. `JOBS=` sets the number of
parallel runs (default `nproc`).

By hand (waveform):

```sh
cd sim/rv_l1
iverilog -g2012 -DRV_HOSTCPU_STATS -s tb_rv_l1 -P tb_rv_l1.EXTRA_WS=0 -o /tmp/l1.vvp \
  tb_rv_l1.v mem_model.v bus_checker.v ../../rtl/host/rv_hostcpu.v ../../rtl/host/vexriscv/VexOsd*.v
vvp -N /tmp/l1.vvp +HEX=build/lanes.hex +WS=3 +ROMWS=1 +VCD=/tmp/lanes.vcd
```

## Verilator

Every target runs on Verilator too: `SIM=verilator` in front of any
`run.sh` command. Same programs, plusargs, parameters, verdict lines
(`=== PASS/FAIL/TIMEOUT`, `=== CYCLES`, `=== STATS`), logs and run
directories as on iverilog; the image of each build is
`run_${RUNTAG:-wt}/vl_x<EXTRA_WS>_d<DEBUG>[_dm]/Vtb_rv_l1` instead of
`tb_x<EXTRA_WS>_d<DEBUG>[_dm].vvp`. The default stays iverilog.

```sh
# Ubuntu 24.04: Verilator 5.020
sudo apt install verilator ccache
# needs 5.x: --binary --timing
verilator --version
SIM=verilator bash sim/rv_l1/run.sh all
SIM=verilator bash sim/rv_l1/run.sh units
SIM=verilator bash sim/rv_l1/run.sh irq
SIM=verilator bash sim/rv_l1/run.sh dhry
SIM=verilator bash sim/rv_l1/run.sh dm_smoke
SIM=verilator WS=8 ROMWS=0 EXTRA_WS=3 bash sim/rv_l1/run.sh refill
```

Tested with Verilator 5.020 (2024-01-01, Debian 5.020-1), g++ 13.3. Build:
`verilator --binary --timing` with the waivers in `verilator/l1.vlt`
(warnings are fatal), C++ at `-O2`, through `ccache` when it is installed
(`OBJCACHE=` empty switches it off). A build takes 10-40 s cold (the
`DEBUG=2` cores are the big ones) and a few seconds from ccache; `all` builds
five.

What differs:

* **2-state.** Verilator has no X or Z: the bench's X checks (`bus_checker`
  "X on request / write data / read data", `!== 1'bx` tests) cannot fire,
  and registers without a reset start at 0 where iverilog starts at X. A
  missing reset or an X on the bus shows only on iverilog. **iverilog is the
  X-checking reference**: run it (`run.sh all`) before a commit; use
  Verilator for the long runs and quick iterations.
* `$urandom` initialisers in the generated `VexOsd_DMJ` (JTAG-side flow
  control, synchronisers, TAP state) get other values than on iverilog (on
  iverilog the flow control toggles twice during the reset, with an X
  command; the JTAG sequence starts with Test-Logic-Reset); the results are
  the same.
* `+VCD=` works only on iverilog (the Verilator images are built without
  `--trace`; the bench prints `=== WARNING +VCD ignored`).
* The gates of `all` always run on iverilog (they check what Quartus and
  Vivado parse, not what the simulator does).
* `DEBUG=1` (BSCANE2 tunnel) is xsim-only on both backends.

**Agreement check.** Both backends must give the same verdict and the same
`=== CYCLES` for every run. `compare` takes two `RUNTAG`s and diffs every
run log of both (verdict, cycles, stats, memory dumps, TIME stamps, program
and debug-test output; only the simulator's own `$finish` line and the order
of the start-up lines are ignored):

```sh
RUNTAG=iv bash sim/rv_l1/run.sh all && RUNTAG=iv bash sim/rv_l1/run.sh dm_smoke
SIM=verilator RUNTAG=vl bash sim/rv_l1/run.sh all && SIM=verilator RUNTAG=vl bash sim/rv_l1/run.sh dm_smoke
# "SAME ..." per log, "=== COMPARE n logs: n same, 0 differ, ..."
bash sim/rv_l1/run.sh compare iv vl
```

(`all` clears the logs of its run directory first, so run it before the
other targets of the same `RUNTAG`.) A difference is a race in the bench,
to be fixed there: two found while adding Verilator, both fixed in the bench
(see the comments in `tb_rv_l1.v` and `tests/dm_smoke.v`):

1. The reset release was `repeat (8) @(posedge clk); rst <= 0;` in an
   initial block. Verilator (`--timing`) commits the nonblocking assignments
   of a process resumed by an edge before it runs that edge's `always`
   blocks, so they saw `rst = 0` one edge earlier: the core started one clock
   earlier in absolute time. Only `dm_smoke` showed it (its JTAG BFM runs in
   absolute time; every other result counts from the reset), by one cycle.
   Now a clocked block counts the reset cycles.
2. `dm_smoke` drives JTAG a multiple of 25 ns after a clock edge, and 25 ns
   and the 4.408 ns half period meet on a common 8 ps grid: TCK edges and
   the bench's samples of `cycles`/`core_rst` could land on a clock edge in
   the same time step, in an order the simulator picks. `wait_clk` now adds
   1.001 ns, off that grid.

Wall time, this machine (Intel i7-1165G7, 4 cores / 8 threads, 2026-10-17),
whole target including the builds; Verilator from a warm ccache and cold
(`OBJCACHE=`, no ccache):

| Target | Runs | iverilog | Verilator | Verilator, cold build |
|---|---|---|---|---|
| `all` | 122 + gates | 228 s | 6.4 s | 77 s |
| `irq` | 13 | 24.7 s | 0.9 s | 6.2 s |
| `dhry` | 3 | 87.5 s | 1.1 s | 6.5 s |
| `dm_smoke` | 6 | 16.6 s | 5.1 s | 60 s |
| `units` | 3 in parallel (`fw/ctrl_rv`, `cdaudio_emu` 19.9 M cycles; 2026-10-18) | 2937 s (49 min) | 12 s | 17.4 s (2026-10-17, `fw/ctrl_832`) |

Same day, both backends over all five targets: `compare` 128 logs, 128
same (every verdict incl. the teeth, every `=== CYCLES`, `=== STATS` and
dump).

## Bench

* **Plusargs**: `+HEX=<file>` (one 32-bit BE word per line, file byte i in
  lane i: the romgen order; the path may be up to 1024 characters; a file
  that cannot be opened or read ends the run at once with `=== FAIL ...`),
  `+WS=` (default 3), `+ROMWS=` (default 1),
  `+TIMEOUT=<cycles>` (default 20 M), `+DUMP_ADDR=<hex> +DUMP_N=<words>`
  (print `=== MEM <addr> <word>` after DONE), `+VCD=<file>` (iverilog only).
* **Parameters** (`iverilog -P tb_rv_l1.<name>=<n>`, `verilator -G<name>=<n>`): `EXTRA_WS` (idle
  cycles before every request), `DEBUG` (0 or 2).
* **`-DDM_SMOKE`** (with `DEBUG=2`, plus `jtag_bfm.v tests/dm_smoke.v`): the
  BFM drives the `jtag_*` pins and `dm_smoke` runs its sequence; without it
  the pins are tied idle (TCK 0, TMS 1). By hand:
  `iverilog -g2012 -DDM_SMOKE -s tb_rv_l1 -P tb_rv_l1.DEBUG=2 -o /tmp/dm.vvp tb_rv_l1.v mem_model.v bus_checker.v jtag_bfm.v tests/dm_smoke.v ../../rtl/host/rv_hostcpu.v ../../rtl/host/vexriscv/VexOsd*.v`
  and `vvp -N /tmp/dm.vvp +HEX=build/dm_smoke.hex`.
* **Results**: `=== PASS` (DONE 0), `=== FAIL <code>` (DONE code in hex;
  `run.sh` adds the decimal value, the numbering of the checks:
  `got 'FAIL a' = FAIL 10 (0xa)`),
  `=== FAIL bus violation`, `=== FAIL bad address`, `=== FAIL uart read`,
  `=== TIMEOUT`; every run
  also prints `=== STATS` (I$ line refills, dBus reads/writes, busy cycles)
  and `=== CYCLES`.
* **Clock**: 8.8154 ns (`clk_114`).

### Memory map (CPU byte addresses)

| Address | What | Latency, accept to ack |
|---|---|---|
| `0x00000000-0x00001FFF` | "ROM" region (boot BRAM), R/W here | `1 + ROMWS` |
| `0x00002000-0x000FFFFF` | memory ("SDRAM") | `1 + WS` |
| `addr[23] = 1` | hw window (below) | 4 |
| anything else | `=== BAD ADDRESS`, the run fails | |

Memory is big endian: byte A+0 is bits 31:24 of the word (the lane rule's
memory side, as `rtl/sdram/sdram_ctrl.v`); `rv_hostcpu` swaps the bytes for the
little-endian core.

### hw window (sim MMIO)

16-bit registers, value in bits 15:0 of the bus word, no lane swap; reads
return `{16'h0, value}`, unmapped registers read 0 and ignore writes.
Decoded on `addr[7:2]`. Offsets for `x0`-relative access are in `sw/l1.h`
(`sw a0, L1_DONE_OFS(zero)`).

| Address | Name | Access |
|---|---|---|
| `0xFFFFFF00` | TIME | W: prints `=== TIME <value> cycle <n>` |
| `0xFFFFFF04` | DONE | W: ends the run; 0 = PASS, else FAIL `<code>` |
| `0xFFFFFF08` | IRQ_AT | W: interrupt event `<value>` cycles later (one timer) |
| `0xFFFFFF0C` | SCRATCH | R/W 16-bit; `sel[0]` writes bits 7:0, `sel[1]` bits 15:8 |
| `0xFFFFFFA0` | INTERRUPT | W bit 0 = enable; any access clears pending; an event sets pending if enabled (cfide-like); `irq_ext` = pending |
| `0xFFFFFFF0` | UART | W: character out (`$write`). A read fails the run (`=== FAIL uart read`): cfide never acks a UART read, so on the real bus the CPU would hang. There is no TX-ready bit; cfide holds a write until the transmitter takes it, so firmware never polls. |

### Program layout (`sw/l1.ld`, `sw/crt0_l1.S`)

| Address | Content |
|---|---|
| `0x0000` | reset vector, jumps to crt0 |
| `0x0020` | default trap entry (`mtvec` reset value): DONE = `0x8000 \| mcause[31]<<8 \| mcause[7:0]` |
| after it | crt0: zero x1-x31, `sp` = `0x00100000`, clear `.bss`, `call main`, DONE = return value |
| `0x0100` | `.text.rom`: code that runs from the ROM region |
| `0x2000` | `.text.entry`, `.text`, `.rodata`, `.data`, `.bss` |
| `0x4000` | `.at4000`: fixed data (lanes) |

Programs linked as firmware (`FWPROGS` in the `Makefile`: `irq_sig`,
`irq_c`, `exc`, `irq_sig_mut`) use `fw/ctrl_rv/arch` instead (its `crt0.S`,
`trap.S`, `trap.c`, `irq.c`, linked with its `firmware.ld`: `_start` at
0x2000, stack top 0x2000 in the ROM region). The image is `sw/boot_fw.S`
padded to 0x2000 bytes (reset: clear x1-x31, jump to 0x2000; trap at 0x20 as
above until crt0 sets `mtvec`), then the firmware binary. `main` ends the
run itself (`l1_done`): the firmware crt0 spins when `main` returns.

## Tests

| Program | Checks |
|---|---|
| `lanes` | loads of every width/alignment from BE words `0x11223344 0x55667788` at 0x4000; stores of every width/alignment at 0x5000.., reloaded and dumped (`tests/lanes.mem`); hw window SCRATCH unswapped, unmapped = 0 |
| `refill` | 24 functions of 244 bytes on a 256-byte stride (6 KB), called in address order and in conflict pairs k, k + 16 exactly 4 KB apart (all eight I$ lines collide), from SDRAM and from the ROM region (0x100); sum vs. a compile-time constant |
| `fencei` | code copied to 0x6000 by stores, run, overwritten, `fence.i`, run again = new code |
| `fencei_nofencei` | same without `fence.i`: must end `=== FAIL 1` (teeth) |
| `irq` | INTERRUPT disabled: no trap; enabled: one trap, `mcause` = `0x8000000B`, the handler's access clears the line |
| `irq_sig` | firmware trap entry keeps every register: x1, x3-x31 patterns (x31 and x30 take turns as the check's scratch), 50 events at pseudo-random distances, C handler (`tests/irq_sig_h.c`) trashes the caller-saved registers; linked `--no-relax` (gp holds a pattern) |
| `irq_c` | `fw/ctrl_rv/arch/irq.h` API: constructors, MIE/MEIE from crt0, default handler, `SetIntHandler`, `DisableInterrupts` loses events, `irq_save`/`irq_restore` nesting, handler switch while events arrive; check 10 also sweeps one event over every cycle of a `SetIntHandler(h1 -> h2)` call (distance 1..64 cycles): it may reach h1 or nobody, never h2 before `EnableInterrupts()` (catches `SetIntHandler` changing the pointer before it disables the register, see "irq_c check 10") |
| `exc` | illegal instruction, misaligned `lw`, misaligned `sh` through `rv_trap` to an `rv_exception` override: mcause 2/4/6, mepc, mtval, resume after the instruction |
| `irq_sig_mut` | teeth: `irq_sig` with `trap.S` minus `lw t3`: must end `=== FAIL 11c` |
| `uart_read` | teeth for the model: one `lhu` of the UART register; must end `=== FAIL uart read` (in `all` once, `WS=3 ROMWS=1`) |
| `dm_smoke` | the program of the debug smoke test (`DEBUG=2`, `-DDM_SMOKE`, `run.sh dm_smoke`): boot count at 0x4004 in `x12`, counter `x10` stored to 0x4000, ends when `x10` equals `x11`, which only the debugger sets (alone it runs into TIMEOUT) |

## Adding a program

1. Write `tests/<name>.S` (entry `main` in `.section .text.entry`) or
   `tests/<name>.c` (`int main(void)`); `#include "l1.h"`. Return 0 for pass,
   a nonzero code for each failing check.
2. Add `<name>` to `PROGS` in the `Makefile` (or to `FWPROGS` with a link
   rule, for a program linked as firmware). `run.sh` reads that list and
   runs it in the matrix; only if it must fail, add it to `TEETH` in
   `run.sh` with an `expect_of` entry (or to `ONCE` for a run at
   `WS=3 ROMWS=1` only), or to `DMPROGS` if it needs the `-DDM_SMOKE` bench.
3. Optional: `tests/<name>.mem` with lines `<byte address> <BE word>` (hex,
   consecutive words); `run.sh` dumps that range after DONE and compares.
4. `make -C sim/rv_l1 tests && bash sim/rv_l1/run.sh <name>`, then `all`.

## Firmware units (`units` target)

`atapi_emu`, `cue_emu` and `cdaudio_emu` are the CD-ROM unit programs of
`<FWDIR>/test/emu` with the units they test (`atapi.c`, `cue.c`,
`cdaudio.c` of `<FWDIR>`; they print `ok ...` lines and end with `PASS` or
`FAIL n`), built with the RISC-V gcc and newlib-nano and run on the L1 bench.
`FWDIR` is `fw/ctrl_rv` by default (the RISC-V firmware tree, Phase 3);
`FWDIR=fw/ctrl_832` builds the 832 tree's copies (read-only) as before.
`printf` goes through `sw/syscalls.c` (`_write` = UART byte stores, `_sbrk` =
heap from `_end` to 0xE0000, `_exit` = DONE); `sw/l1_newlib.ld` puts the code
at 0x2000 and the stack top at 0xF0000. `main` returns the failure count.

```sh
# fw/ctrl_rv, WS=3 ROMWS=1 EXTRA_WS=0 DEBUG=0
bash sim/rv_l1/run.sh units
# the same on Verilator: seconds
SIM=verilator bash sim/rv_l1/run.sh units
# the 832 tree
FWDIR=fw/ctrl_832 SIM=verilator bash sim/rv_l1/run.sh units
# other settings from the environment
WS=8 TIMEOUT=60000000 bash sim/rv_l1/run.sh units
# build only: FWDIR=../../../fw/ctrl_rv is the default
make -C sim/rv_l1/prog
# FWDIR is relative to sim/rv_l1/prog
make -C sim/rv_l1/prog FWDIR=../../../fw/ctrl_832
```

`units` first prints the tree it uses (`=== UNITS FWDIR <absolute path>`,
also in `run_${RUNTAG:-wt}/units_fwdir.txt`; a relative `FWDIR` is taken
from the current directory), then always runs `make -C sim/rv_l1/prog
FWDIR=<that path>`, reads the program list from the Makefile (`make
print-progs`) and runs every program from that tree's hexes (`make
print-hexdir`).

Build layout (`prog/Makefile`), per tree (`<TREE>` = the last part of
`FWDIR`, e.g. `ctrl_rv`):

| What | Where |
|---|---|
| unit and emu objects, `.d` files, `.elf`/`.map`/`.bin` | `prog/build/<TREE>/` |
| hexes run by `units` | `build/<TREE>/<prog>.hex` |
| the absolute `FWDIR` those objects came from | `prog/build/<TREE>/fwdir` |
| bench runtime (`crt0_l1.o`, `syscalls.o`) and `fmt_rv` | `prog/build/`, `build/fmt_rv*.hex` |

So the two trees never share an object or an image, and a switch of
`FWDIR` never runs the other tree's code (before Task 15 one `build/` held
both, and a unit built from one tree ran as the other: a scratch copy's
`cue_emu.o` made `cue_emu` fail "want 2209" until `make -B`). Every object
is compiled with `-MMD -MP`: a change to any header a unit or emu program
includes (`<FWDIR>/*.h`, `<FWDIR>/test/emu/*.h`) rebuilds exactly the objects
that include it (touching `cdaudio.h` rebuilds `cdaudio.o`, `cdaudio_emu.o`
and relinks `cdaudio_emu`; `cue.h` everything, since all three include it;
check with `make -n -C sim/rv_l1/prog`). Every object also depends on
`fwdir`, which changes only when `FWDIR` names another tree with the same
last name: then everything is rebuilt.

**A change of the toolchain or of the flags needs `make -B`.** The objects
depend on their sources and headers (`-MMD`) and on `fwdir`, which holds the
path of `FWDIR` only. A new `RV_GCC_DIR` (another compiler) or a change of
`RV_CFLAGS_FW` in `tools/riscv/toolchain.mk` is therefore not seen: `units`
would run the old objects. Rebuild everything first (`run.sh units` runs `make` itself, which
finds the old objects up to date):

```sh
make -B -C sim/rv_l1/prog
```

Flags per tree: `fw/ctrl_rv` (any tree but `ctrl_832`) builds like the
firmware (`fw/ctrl_rv/Makefile`: `$(RV_CFLAGS_FW) -std=gnu23
--specs=nano.specs -Wall -Wextra -Werror`); the emu programs add
`-Wno-unused-parameter` as the host tests do (`main(argc, argv)`, port
stubs). `ctrl_832` keeps the flags it had before (gcc's default dialect,
`-Os -Wall`): its sources are not `-Wextra` clean and stay unchanged; its
cycles below are the ones recorded for it on 2026-10-16.

A unit passes when the bench prints `=== PASS`, no output line starts with
`FAIL`, a line is exactly `PASS` and there is no bus violation (the verdict
of `fw/ctrl_832/test/emu/Makefile`). `units` ends with `=== UNITS PASS` or
`=== UNITS FAILED`; logs (the programs' own output plus `=== CYCLES`) are
`run_${RUNTAG:-wt}/<prog>_ws3_r1_x0_d0.log`, the summary
`run_${RUNTAG:-wt}/units.txt`. The runs are slow on iverilog (about 1.5-3 minutes
per million cycles of simulated time on this machine) and take seconds on
Verilator (`SIM=verilator bash sim/rv_l1/run.sh units`, about 2 M cycles per
second): `units` is not part of `all`.

Recorded cycles (WS=3 ROMWS=1 EXTRA_WS=0 DEBUG=0, all `PASS`):

| Program | `fw/ctrl_rv` (2026-10-18) | `fw/ctrl_832` (2026-10-16, again 2026-10-18) | Wall time (vvp, `fw/ctrl_rv`) | Wall time (Verilator) |
|---|---|---|---|---|
| `cue_emu` | 738,808 | 764,056 | ~3 min | <1 s |
| `atapi_emu` | 890,566 | 954,062 | ~3 min | <1 s |
| `cdaudio_emu` | 19,916,613 | 19,059,807 | ~49 min | ~10 s |

`fw/ctrl_rv` on iverilog and on Verilator: `run.sh compare` 3 logs, 3 same
(2026-10-18). The two trees' unit sources are the same C (Task 2's copy; the
CD units needed no port change, see "CD units in fw/ctrl_rv" below): the
differences are the flags (`-ffreestanding -fno-builtin`, `-std=gnu23`),
not the code.

`cdaudio_emu` fills the 64 KB ring byte by byte several times and needs about
20 M cycles: `units` passes `+TIMEOUT=40000000` (`TIMEOUT=` from the
environment overrides it; the bench's own default stays 20 M). A slower memory
setting (`WS=8`) needs it raised: `TIMEOUT=60000000 WS=8 bash sim/rv_l1/run.sh units`.

### CD units in `fw/ctrl_rv` (audit, Task 15)

`cdaudio.c`, `cdrom.c`, `atapi.c` and `cue.c` of `fw/ctrl_rv` read, for byte
order, alignment and timing on the little-endian VexRiscv. Nothing needed a
change; the host tests `cue_test`, `cdaudio_test`, `atapi_test` and
`cdrom_test` (`make -C fw/ctrl_rv/test`, LP64 and `-m32`) and the three
`units` programs pass on this code.

| What | Verdict |
|---|---|
| `cdaudio.c` ring writes (`zero`, `copy`, `scale`, `produce`, `fill`) | `uint8_t` stores only; samples stay 16-bit little endian (red book) in the ring, `scale` reads and writes them byte by byte (`p[i] \| p[i + 1] << 8`): neutral, the 832 writes the same bytes |
| `CD_AudioPoll` / `cda_poll` timing | TIMER units, the same on both CPUs: one count = 256 x 643 `clk_28` = 5.804 ms = 256 frames at 44.1 kHz (cfide's `timecnt`, not CPU speed); `CDA_HALF_UNITS` = 32 counts per 32 KB half (8192 frames); the 16-bit TIMER wrap is masked (`& 0xFFFF`) |
| `cda_port_ring()` | `(uint8_t *)AUDIO_BUFFER` = 0x70000; `fw/ctrl_rv/arch/firmware.ld` asserts `_end < 0x70000` (today `_end` = 0x270ac in `build/RV32OSDA.map`) |
| `cdrom.c` `CD_TIMEOUT` | 10000 "ms" through `GetTimer`/`CheckTimer` = 10000 TIMER counts = 58 s on the board, on both CPUs (parity; the 16-bit window of `CheckTimer` allows up to 32767) |
| `cdrom.c` `cd_cue` | `static struct cue_parser` (0x910 = 2320 bytes in the map): stays static, the stack is still the 8 KB boot BRAM |
| `cd_identify` / `atapi_identify` | words built from values (`ata_string` puts the first character in bits 15:8) and sent low byte first byte by byte: neutral (unlike `hdd.c`'s `memcpy`'d strings, Task 12) |
| `cue.c` WAV header | `le16`/`le32` read byte by byte (file-local helpers): neutral at any alignment |
| pointer casts to wider types | none in the four files (`grep '(\(unsigned \)\?\(short\|long\|int\|uint16_t\|uint32_t\) \*)'`) |

Refill cost and ring-fill time on the RISC-V (cycles per half against the
185.8 ms a half plays) are Phase 4.4.

### irq_c check 10

`SetIntHandler` (`fw/ctrl_rv/arch/irq.c`) writes 0 to the INTERRUPT
register before it changes `_InterruptVector`, so no event reaches a handler
between the call and `EnableInterrupts()`. Check 10 sweeps one event
(`IRQ_AT` d, d = 1..64 cycles) over a `SetIntHandler(h1)`,
`EnableInterrupts()`, `IRQ_AT`, `SetIntHandler(h2)` sequence: before the
disable the event reaches h1, after it the event is lost; h2 must never run.
A run copy of `irq.c` with the two stores swapped (pointer first) ends
`=== FAIL a` (check 10) at every `WS` {0, 3, 8} x `ROMWS` {0, 1} x
`EXTRA_WS` {0, 3} and with `DEBUG=2` (Verilator; iverilog at WS=3 ROMWS=1
the same); the event hits h2 at d = 10..13 (WS=0 EXTRA_WS=0) up to d =
7..28 (WS=8 EXTRA_WS=3). The irq_c of before Task 15 passed against that
copy. The sweep adds about 31,000 cycles to `irq_c`.

## C library check (`fmt` target)

`fmt_rv` (`fw/ctrl_rv/test/rv/fmt_rv.c`, built by `prog/Makefile`) runs the
format-parity cases and newlib-nano's `mem*`/`str*` functions on the target
libc, linked the way the firmware is: `rvlibc.c` (`printf`, `vprintf`, the heap
stubs) + `libc_nano.a`, `crt0_l1.o` + `l1_newlib.ld` for the L1 memory map, no
`syscalls.o` (a call that needs `_sbrk` or `_write` fails the link), `-lc_nano
-lgcc` last. Its sources are taken from `fw/ctrl_rv` by explicit path (not
`FWDIR`) and it is not part of `PROGS` or `units`. Details and the gates:
`fw/ctrl_rv/README.md`, "Format parity" and "Host tests".

```sh
# all 909 cases: 30.5 M cycles, 25 s
SIM=verilator RUNTAG=p3t3b bash sim/rv_l1/run.sh fmt
# subset, 272 cases: 13.0 M cycles
FMT_SUBSET=1 SIM=verilator RUNTAG=p3t3s bash sim/rv_l1/run.sh fmt
# iverilog, about 38 minutes
FMT_SUBSET=1 RUNTAG=p3t3i bash sim/rv_l1/run.sh fmt
bash sim/rv_l1/run.sh compare p3t3i p3t3s
```

`fmt` (`FMT_SUBSET=1`: program `fmt_rv_subset`) first runs `make -C fw/ctrl_rv/test fmt.ok` (the host side; `LIB832=` is
passed on, see the README of `fw/ctrl_rv`), builds `fmt_rv`, runs it once with
WS=3 ROMWS=1 through the `units` verdict (bench `PASS`, a line `PASS`, no line
`FAIL`, no bus violation; `TIMEOUT` default 300000000), writes its
`FMT <n> S|P h=<digest>` lines to `run_${RUNTAG:-wt}/fmt_rv.txt` and checks:
a line `MEMSTR ok, failures 0` (offsets 0..3: a misaligned access would trap
and end the run `=== FAIL 80xx`), `HEAP calls=0`, no `EXC`; `fmt_rv.map` has
none of `_sbrk _sbrk_r __sinit __sfp _write` and `_malloc_r _realloc_r
_free_r` come from `rvlibc.o`; `fmt_rv.txt` equals the digests of the host's
`fmt_glibc_64.txt`; and the 832-versus-RV difference list equals
`fw/ctrl_rv/test/gold/fmt_diff_expected.txt`. It ends `=== FMT PASS` or
`=== FMT FAILED`. Last run 2026-10-18 after the Phase 3 final review (`fmt_cases.h` as of 123133e): `p3f_fmti` (iverilog) `=== FMT PASS`, 13,005,098 cycles, 544 records, 413 difference lines; `compare p3f_fmti p3f_fmts` 1 same, 0 differ. The log `run_*/fmt_rv_ws3_r1_x0_d0.log` is picked up by
`compare`.
