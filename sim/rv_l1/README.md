# L1 bench: `rv_hostcpu` + big-endian memory model (iverilog)

The L1 bench runs RISC-V programs on the OSD host CPU block
`rtl/host/rv_hostcpu.v` (VexRiscv behind the 832 req/ack bus) against an
abstract memory model with per-region latency and a few simulation-only
registers. A bus checker asserts the bus contract every cycle. One run takes
seconds and needs no Vivado.

| File | What it is |
|---|---|
| `tb_rv_l1.v` | Top: `rv_hostcpu` + `mem_model` + `bus_checker`, plusargs, end of run |
| `mem_model.v` | 1 MB BE memory, latency per region, sim MMIO, interrupt register |
| `bus_checker.v` | Bus contract assertions (`=== BUS VIOLATION ...`) |
| `jtag_bfm.v` | JTAG master BFM (`jtag_reset`, `jtag_idle`, `jtag_ir`, `jtag_dr`), TCK 50 ns, for `dm_smoke` |
| `run.sh` | Builds the simulator, runs one program or the whole matrix |
| `Makefile` | Builds the test programs into `build/<prog>.hex` |
| `sw/crt0_l1.S`, `sw/l1.ld`, `sw/l1.h` | Start-up code, linker script, MMIO header |
| `sw/boot_fw.S` | Boot ROM stand-in for programs linked as firmware (`irq_sig`, `irq_c`, `exc`) |
| `tests/` | Test programs (`.S` or `.c`) and expected memory dumps (`.mem`); `tests/dm_smoke.v` is the debug smoke test sequence |
| `prog/Makefile`, `sw/syscalls.c`, `sw/l1_newlib.ld` | Firmware-unit programs (newlib-nano) and their runtime, see "Firmware units" |

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
   (`IVERILOG=` / `VVP=` override the paths).
3. GNU make, bash, `od`, `awk`.

## Build the tests and run

From the repository root:

```sh
make -C sim/rv_l1 tests            # build/<prog>.hex, .elf, .lst, .map
bash sim/rv_l1/run.sh all          # gates + full matrix + teeth, ~1 min on 8 cores
```

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
  print `=== FAIL 11c`;
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
parallel `vvp` runs (default `nproc`).

By hand (waveform):

```sh
cd sim/rv_l1
iverilog -g2012 -DRV_HOSTCPU_STATS -s tb_rv_l1 -P tb_rv_l1.EXTRA_WS=0 -o /tmp/l1.vvp \
  tb_rv_l1.v mem_model.v bus_checker.v ../../rtl/host/rv_hostcpu.v ../../rtl/host/vexriscv/VexOsd*.v
vvp -N /tmp/l1.vvp +HEX=build/lanes.hex +WS=3 +ROMWS=1 +VCD=/tmp/lanes.vcd
```

## Bench

* **Plusargs**: `+HEX=<file>` (one 32-bit BE word per line, file byte i in
  lane i: the romgen order), `+WS=` (default 3), `+ROMWS=` (default 1),
  `+TIMEOUT=<cycles>` (default 20 M), `+DUMP_ADDR=<hex> +DUMP_N=<words>`
  (print `=== MEM <addr> <word>` after DONE), `+VCD=<file>`.
* **Parameters** (`iverilog -P tb_rv_l1.<name>=<n>`): `EXTRA_WS` (idle
  cycles before every request), `DEBUG` (0 or 2).
* **`-DDM_SMOKE`** (with `DEBUG=2`, plus `jtag_bfm.v tests/dm_smoke.v`): the
  BFM drives the `jtag_*` pins and `dm_smoke` runs its sequence; without it
  the pins are tied idle (TCK 0, TMS 1). By hand:
  `iverilog -g2012 -DDM_SMOKE -s tb_rv_l1 -P tb_rv_l1.DEBUG=2 -o /tmp/dm.vvp tb_rv_l1.v mem_model.v bus_checker.v jtag_bfm.v tests/dm_smoke.v ../../rtl/host/rv_hostcpu.v ../../rtl/host/vexriscv/VexOsd*.v`
  and `vvp -N /tmp/dm.vvp +HEX=build/dm_smoke.hex`.
* **Results**: `=== PASS` (DONE 0), `=== FAIL <code>` (DONE code in hex),
  `=== FAIL bus violation`, `=== FAIL bad address`, `=== TIMEOUT`; every run
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
| `0xFFFFFFF0` | UART | W: character out (`$write`); R: `0x0100` (TX ready) |

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
| `refill` | 24 functions, 5.9 KB, called in address order and in 4 KB conflict pairs, from SDRAM and from the ROM region (0x100); sum vs. a compile-time constant |
| `fencei` | code copied to 0x6000 by stores, run, overwritten, `fence.i`, run again = new code |
| `fencei_nofencei` | same without `fence.i`: must end `=== FAIL 1` (teeth) |
| `irq` | INTERRUPT disabled: no trap; enabled: one trap, `mcause` = `0x8000000B`, the handler's access clears the line |
| `irq_sig` | firmware trap entry keeps every register: x1, x3-x30 patterns, 50 events at pseudo-random distances, C handler (`tests/irq_sig_h.c`) trashes the caller-saved registers; linked `--no-relax` (gp holds a pattern) |
| `irq_c` | `fw/ctrl_rv/arch/irq.h` API: constructors, MIE/MEIE from crt0, default handler, `SetIntHandler`, `DisableInterrupts` loses events, `irq_save`/`irq_restore` nesting, handler switch while events arrive |
| `exc` | illegal instruction, misaligned `lw`, misaligned `sh` through `rv_trap` to an `rv_exception` override: mcause 2/4/6, mepc, mtval, resume after the instruction |
| `irq_sig_mut` | teeth: `irq_sig` with `trap.S` minus `lw t3`: must end `=== FAIL 11c` |
| `dm_smoke` | the program of the debug smoke test (`DEBUG=2`, `-DDM_SMOKE`, `run.sh dm_smoke`): boot count at 0x4004 in `x12`, counter `x10` stored to 0x4000, ends when `x10` equals `x11`, which only the debugger sets (alone it runs into TIMEOUT) |

## Adding a program

1. Write `tests/<name>.S` (entry `main` in `.section .text.entry`) or
   `tests/<name>.c` (`int main(void)`); `#include "l1.h"`. Return 0 for pass,
   a nonzero code for each failing check.
2. Add `<name>` to `PROGS` in the `Makefile` (or to `FWPROGS` with a link
   rule, for a program linked as firmware) and to `PROGS` in `run.sh` (or
   to `TEETH` with an `expect_of` entry if it must fail, or to `DMPROGS` if
   it needs the `-DDM_SMOKE` bench).
3. Optional: `tests/<name>.mem` with lines `<byte address> <BE word>` (hex,
   consecutive words); `run.sh` dumps that range after DONE and compares.
4. `make -C sim/rv_l1 tests && bash sim/rv_l1/run.sh <name>`, then `all`.

## Firmware units (`units` target)

`atapi_emu`, `cue_emu` and `cdaudio_emu` are the CD-ROM unit programs of
`fw/ctrl_832/test/emu` (they print `ok ...` lines and end with `PASS` or
`FAIL n`), built with the RISC-V gcc and newlib-nano and run on the L1 bench.
`printf` goes through `sw/syscalls.c` (`_write` = UART byte stores, `_sbrk` =
heap from `_end` to 0xE0000, `_exit` = DONE); `sw/l1_newlib.ld` puts the code
at 0x2000 and the stack top at 0xF0000. `main` returns the failure count.

```sh
make -C sim/rv_l1/prog FWDIR=../../../fw/ctrl_832   # build/<prog>.hex (FWDIR default as shown;
                                                    # fw/ctrl_rv in Phase 3)
bash sim/rv_l1/run.sh units                         # WS=3 ROMWS=1 EXTRA_WS=0 DEBUG=0
WS=8 bash sim/rv_l1/run.sh units                    # other settings from the environment
```

A unit passes when the bench prints `=== PASS`, no output line starts with
`FAIL`, a line is exactly `PASS` and there is no bus violation (the verdict
of `fw/ctrl_832/test/emu/Makefile`). `units` ends with `=== UNITS PASS` or
`=== UNITS FAILED`; logs (the programs' own output plus `=== CYCLES`) are
`run_${RUNTAG:-wt}/<prog>_ws3_r1_x0_d0.log`, the summary
`run_${RUNTAG:-wt}/units.txt`. The runs are slow (about 1.5-3 minutes per
million cycles of simulated time on this machine): `units` is not part of `all`.

Recorded cycles (WS=3 ROMWS=1 EXTRA_WS=0 DEBUG=0, 2026-10-16, all `PASS`):

| Program | Cycles | Wall time (vvp) |
|---|---|---|
| `cue_emu` | 764,056 | ~2 min |
| `atapi_emu` | 954,062 | ~2.5 min |
| `cdaudio_emu` | 19,059,807 | ~50 min |

`cdaudio_emu` fills the 64 KB ring byte by byte several times and lands just
under the bench's default 20 M-cycle timeout (`+TIMEOUT=`): a slower memory
setting (`WS=8`) needs it raised: `TIMEOUT=60000000 WS=8 bash sim/rv_l1/run.sh units`.
