# L2 bench: the RISC-V host CPU through the real bridge (xsim)

The L2 bench runs small RISC-V programs from the boot BRAM on the real host
side of the core. The bridge is `EightThirtyTwo_Bridge` with
`cpu_riscv => true`: it holds `rv_hostcpu` + `VexOsd`, `OSDBoot_rv_ROM` (the
test program) and `hostcache.v`. Behind it are the real `cfide` and an SDRAM
model of the host port. It checks five things at the bridge's bus: the byte
lanes, the cfide register offsets, back-to-back hw accesses (the four-phase
handshake), the SPI busy wait and cfide's interrupt through the firmware trap
entry.

The L1 bench (`sim/rv_l1`, iverilog) tests `rv_hostcpu` against an abstract
memory. This bench uses Vivado's xsim because `cfide` and the bridge are VHDL.

| File | What it is |
|---|---|
| `tb_host_bridge.v` | Top: bridge + cfide + SDRAM model + SPI slave, bus snoop, checks, verdict |
| `sdram_host_model.v` | 8 MB halfword SDRAM behind hostcache: latency, burst order, `sdram_ctrl` lanes, preload |
| `run.sh` | Copies the RTL, applies the simulation fixes, builds the ROMs, compiles, runs |
| `Makefile` | Test programs -> `<B>/<test>/OSDBoot_rv_ROM.vhd` (romgen, as `fw/ctrl_boot_832`) |
| `sw/crt0_rom.S`, `sw/rom.ld` | Start-up (reset at 0x0, trap at 0x20, `sp` = 0x2000, `.bss`, `main`, PASS/FAIL on the UART, DONE) and the 8 KB BRAM layout |
| `sw/hb.h`, `sw/check.h` | cfide register offsets, `CHECK` / `STAMP` macros |
| `sw/t_*.S`, `sw/t_*.c`, `sw/t_lanes.sdram.hex` | The five tests; the SDRAM preload of `t_lanes` |
| `sw/reset_fw.S` | Reset, trap at 0x20 and register clear for tests that start through `fw/ctrl_rv/arch/crt0.S` (`t_irq`) |
| `stub/` | Task 6's elaboration check of the bridge's RISC-V branch (`stub/elab.sh`) |

## Prerequisites

1. **RISC-V toolchain**: xPack `riscv-none-elf-gcc` 15.2.0-1 in
   `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`. Setup (download, checksum,
   Ubuntu fallback, verification) is in
   [`tools/riscv/README.md`](../../tools/riscv/README.md). In short:

   ```sh
   bash tools/riscv/fetch-xpack.sh          # installs into ~/opt
   bash tools/riscv/check-toolchain.sh      # must pass
   ```

   For another install: `export RV_GCC_DIR=/path/to/toolchain` (and
   `RV_PREFIX=` if its tools are not named `riscv-none-elf-*`).
2. **Vivado 2023.2** simulator (`xvlog`, `xvhdl`, `xelab`, `xsim`) in
   `/opt/Xilinx/Vivado/2023.2/bin`. Set `VIVADO_PATH=` for another location.
   On Ubuntu 24.04 the tools need `libtinfo.so.5`. Create a shim directory
   once:

   ```sh
   mkdir -p ~/lib/tinfo5
   ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5
   ```

   `run.sh` puts `$HOME/lib/tinfo5` first on `LD_LIBRARY_PATH` and sets
   `LC_ALL=C`.
3. GNU make, bash, gcc (to build `fw/romgen/romgen`), python3, sed.

Run only one xsim at a time.

## Run

From the repository root:

```sh
bash sim/host_bridge/run.sh all       # 5 tests x SLAT {2,8,20} x SJIT {0,8}: 30 runs, ~8 min
bash sim/host_bridge/run.sh mutant    # the four-phase handshake's teeth, ~2 min
```

`all` ends with `=== ALL PASS (30 runs)` (exit 0) or `=== SOME FAILED`
(exit 1). `mutant` ends with `=== MUTANT CAUGHT ...` (exit 0) or
`=== MUTANT SURVIVED or CONTROL FAILED` (exit 1).

To run one test or several, with settings from the environment (defaults
`SLAT=8 SJIT=0 EXTRA_WS=0 SEED=1`):

```sh
bash sim/host_bridge/run.sh t_lanes
SLAT=20 SJIT=8 EXTRA_WS=3 bash sim/host_bridge/run.sh t_b2b t_spibusy
XARGS="+VERBOSE=1" bash sim/host_bridge/run.sh t_hwoff     # log every hw access
```

Outputs go to `sim/host_bridge/run_${RUNTAG:-wt}/`:

- `results.txt`
- one log per run, `tb_<test>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log`
- `compile.log` and `make.log`
- `src/`: the RTL copies with the fixes
- `build/<test>/`: the ROM, `.elf`, `.lst` and `.map`

Use a new `RUNTAG` for each code change when you compare runs.

To build the test ROMs without running anything (`run.sh` builds its own into
`run_*/build`):

```sh
make -C sim/host_bridge                 # -> sim/host_bridge/build/<test>/OSDBoot_rv_ROM.vhd
make -C sim/host_bridge B=/tmp/hb       # elsewhere
```

## Bench

- **Clocks**: as `sim/spi_cdc/host832/tb_832_dmode.v`. `clk_114` has
  T = 8.8154 ns. `clk_28` = `clk_114` / 4, with its edges 0.3 ns after a
  `clk_114` edge.
- **cfide**: generics as in host832 (`spimux`, `havespirtc`, `havei2c` and
  `havevpos` are all false). The inputs are `tick_in = 1` (the timer counts
  every `clk_28`, so TIMER = `timecnt[23:8]` steps every 1024 `clk_114`),
  `menu_button = 1`, `audio_buf = 1`, `audio_amiga = 0` and `sd_ack = 1`.
- **SDRAM model** (`sdram_host_model.v`): 8 MB of halfwords at host address
  0.
  - Latency: `SLAT` + random 0..`SJIT` `clk_114` cycles from accept to the
    one-cycle `ram_ack`.
  - Reads are an 8-halfword burst of the 4-word line, starting with the
    requested word and wrapping (word0.hi on the ack cycle). This is the
    order of tb_832_dmode, which hostcache's fill states expect.
  - Writes happen at the ack.
  - It checks that addr, wr, q and sel do not change between accept and ack
    (`=== BUS VIOLATION`).
- **vbl_int**: cfide's VBL interrupt input, 0 except in `t_irq` (pulses
  from checkpoint 1, see the test table).
- **SPI slave**: active while `sd_cs[1]` is low.
  - It samples `sd_do` on the rising edge of `sd_clk` and drives MISO from
    the falling edge.
  - Its MISO script is byte n = `0xA5 + 0x11 * n`.
  - It logs every byte, and the bench logs every change of `sd_cs`.
- **Snooped at the bridge's bus**: a hw access completes on a `clk_114` edge
  with `hw_req = hw_ack = 1`.
  - UART `0xFFFFFFF0`: the character log (`UART: PASS`).
  - TIME `0xFFFFFF00`: a test checkpoint (`=== TIME <n> cycle <c>`).
  - DONE `0xFFFFFF04`: the end of the run.
  - cfide acks TIME and DONE as unmapped registers.
- **Checks in every run**. Each failed check prints a `BENCH ERROR` line.
  - **Stale ack**: a hw access completed although no `clk_28` edge saw its
    `hw_req`.
  - **SPI accept**: a write to SPI DATA completed although cfide never
    accepted it. Accepted means a `clk_114` edge with req, wr, SPI DATA and
    `SD_busy = 0`; `SD_busy` is read hierarchically from cfide.
  - **X on the bus**: X in the read data the bridge returns, or in a byte that
    is written. The core treats an X branch condition as not taken, so a CPU
    check against X data would pass.
  - The SDRAM model's bus checks.
- **Verdict**: `=== PASS` when DONE = 0 and no bench error was seen, else
  `=== FAIL code <c>, bench errors <n>` or `=== FAIL timeout`. The line before
  it is `=== HW accesses .., stale acks .., X .., SDRAM reads .. writes ..,
  main done .., cycles ..`. "main done" is the cycle of the first UART
  write, when `main` has returned. Compare runs on that number: the UART
  bit clock quantises the end of the run.

### Plusargs and parameter

| Plusarg | Default | Meaning |
|---|---|---|
| `+TEST=<name>` | none | enables the test's checkpoint and end-of-run checks (`run.sh` sets it) |
| `+SLAT=<n>` | 8 | SDRAM latency, `clk_114` cycles |
| `+SJIT=<n>` | 0 | plus a random 0..n per access |
| `+SEED=<n>` | 1 | `$urandom` seed (jitter) |
| `+SDRAM_HEX=<file>` | none | preload, `$readmemh` of BE 32-bit words, `@` = word address; first 1 MB (`run.sh` passes `sw/<test>.sdram.hex` if it exists) |
| `+TIMEOUT=<n>` | 3000000 | `clk_114` cycles until `=== FAIL timeout` |
| `+VERBOSE=1` / `2` | 0 | log hw accesses and SPI bytes / also every change of the bus address |

The bench parameter `EXTRA_WS` is the bridge's `rv_extra_ws`: idle cycles
before every RISC-V request. It is set with `xelab -generic_top EXTRA_WS=<n>`,
or with `EXTRA_WS=<n>` for `run.sh`.

## Lane rule

`sel[i]` is the byte at A+i, and byte A+0 is bits 31:24 on the memory side
(`rtl/sdram/sdram_ctrl.v`: `slot1_dqm = {!sel[0], !sel[1]}`; the boot ROM's
`wea(3) = bytesel(0)`). `rv_hostcpu` swaps the four data bytes for
`addr[23] = 0` and passes `sel` through unchanged. The SDRAM model writes:

| `sel` bit | data bits | halfword byte |
|---|---|---|
| `sel[0]` | `q[31:24]` | upper byte of halfword A (byte A+0) |
| `sel[1]` | `q[23:16]` | lower byte of halfword A (byte A+1) |
| `sel[2]` | `q[15:8]` | upper byte of halfword A+2 (byte A+2) |
| `sel[3]` | `q[7:0]` | lower byte of halfword A+2 (byte A+3) |

So `sw 0x12345678` to 0x3000 leaves the halfwords `0x7856 0x3412`: big-endian
byte order, as the 68k sees memory. The SDRAM model in
`sim/spi_cdc/host832/tb_832_dmode.v` maps `sel[3]` to `q[31:24]`. That model
is not the reference for lanes; `sdram_ctrl.v` is.

## Tests and expectations

Every test prints `PASS` or `FAIL` on the cfide UART and writes its exit code
to DONE (`sw/crt0_rom.S` does it when `main` returns; `t_irq`, started
through the firmware's `crt0.S`, does it in `main`). The exit code is 0, or the number of the first failing `CHECK`. An
unexpected trap writes `0x8000 | mcause`.

| Test | Program | Bench checks (`+TEST=`) |
|---|---|---|
| `t_lanes` | Loads of every width and alignment from SDRAM 0x4000 (preloaded bytes `11 22 .. 88`) and from `.rodata` in the boot BRAM. Stores of every width and alignment to SDRAM 0x3000.. and to BRAM 0x1800.., read back through the CPU; the SDRAM reads miss hostcache, because a write invalidates the line. | At the end, the SDRAM model's halfwords 0x3000..0x301F: `7856 34AB 01FF FFFF FF02 FFFF FFFF 03FF EFBE 0000 0000 FECA BBAA 9988 1122 3344`. |
| `t_hwoff` | PLATFORM read = `0x0003` (halfword, byte and word); AUDIO read = `0x0001`. TIMER read twice: it advances by exactly 1. SPI: CS `0x02`, DATA `0x5A`, DATA read = `0xA5`, CS `0x03`. | STAMP 1/2: `scandoubler` 0/1 after PLATFORM writes 0/1. STAMP 3/4/5: `{audio_clear, audio_ena}` = 01/10/00. STAMP 6: `sd_cs = 0xFC`. STAMP 7: the slave got exactly one byte, `0x5A`. STAMP 8: `sd_cs = 0xFF`. |
| `t_b2b` | 64 `sh` to PLATFORM (1, 0, 1, ...), 64 `sh` to AUDIO, then 32 `sb` to SPI CS (0x02, 0x03, ...). Each block is straight-line code and runs twice; the first call fills the I-cache, so the measured call has no line refill between the stores. Then it reads PLATFORM and AUDIO back; neither register reads back the written value. | 64 `scandoubler` toggles, ending at 0; 64 `audio_ena` toggles, ending at 0; 32 `sd_cs` changes `FC FF FC ...`. Each block prints its request gap. No stale ack. |
| `t_irq` | Started through `fw/ctrl_rv/arch` (`sw/reset_fw.S`, then `crt0.S`, `trap_entry`, `rv_trap`; linked with `sw/rom.ld`). `SetIntHandler`, `EnableInterrupts`, STAMP 1, then waits for 20 handler calls (the handler counts and clears with `GetInterrupts()`), at most 100 TIMER steps; still 20 six TIMER steps later. | STAMP 1: start 20 `vbl_int` pulses, one `clk_28` cycle each, 2000 `clk_114` apart. STAMP 2: all 20 were sent. |
| `t_spibusy` | `SPI_slow()` (SPEED `0xEF`, about 7700 `clk_114` per byte), CS `0x02`, 8 straight-line `sb` to SPI DATA (`01 80 55 AA FF 00 3C C3`), then a DATA read (`0x1C`, the 8th MISO byte), then CS `0x03`. | The slave got the 8 bytes in order. At least 7 DATA writes found `SD_busy` high. No DATA write completed without cfide accepting it. |

## Simulation fixes (run copies only)

`run.sh` copies the RTL into `run_*/src` and changes only those copies:

- `hostcache.v`: `ack <= #1 1'b0` becomes `ack <= 1'b0`, as in
  `host832/run.sh`. With the delay, the ack is a 1 ns glitch that the bridge
  never sees.
- `cfide.vhd`: `timecnt` and `clkgen` get an initial value of 0. They have
  no reset; on the FPGA they power up at 0. In simulation they stay `'U'`, so
  TIMER never counts and the UART never shifts: `txbusy` stays high after the
  first character and the second UART write never gets an ack.
- `hostcache.v` and `dpram_inf_generic.v`: a `` `timescale `` line is added,
  to avoid an xelab warning.
- `OSDBoot_rv_ROM.vhd`: port B's write is removed in `*_sim.vhd`. The
  prologue/epilogue template writes the one signal `ram` from two processes.
  In VHDL each process has a driver for all of `ram`, and port B's driver
  keeps the initial image, so every port-A write that changes a bit resolves
  to `'X'`. Synthesis infers a true dual-port BRAM. The bridge leaves port B
  unused (`we2 = '0'`). Without this fix the stack, `.data` and the BRAM part
  of `t_lanes` read X; the bench's X check catches that.

## Why the mutant needs the fast master

`run.sh mutant` runs `t_b2b` three ways:

| Leg | Bridge | Master | Expected |
|---|---|---|---|
| gate | mutant: the `-- 4PHASE` line becomes `state <= waiting;` (two-phase) | fast master | every run `=== FAIL` (stale acks, lost writes) |
| control | real (four-phase) | fast master | every run `=== PASS` |
| info | mutant | real `rv_hostcpu` | printed only; passes today |

cfide's `ack` is a `clk_28` register. After the bridge drops `hw_req`, the
ack stays high until the next `clk_28` edge, which is up to 4 `clk_114`
cycles later. A two-phase bridge takes that old ack for a new request only
if the new request rises before that edge.

The real `rv_hostcpu` idles one cycle after every ack. The bridge samples
cfide's ack at `clk_114` edge e0 (the first edge after the `clk_28` edge
that set it). That leads to `hw_req` rising at e3, and the next `clk_28` edge
comes after that rise: at e3 + 0.3 ns in this bench, where it samples the new
request, so the ack the bridge sees at e4 is genuine. In hardware that
`clk_28` edge coincides with e3 and still sees `hw_req = 0`, so the ack falls
and the bridge waits for a fresh one. Either way the stale ack is never
taken. The info leg shows this (stale acks 0).

The fast master is a run copy of `rv_hostcpu.v` that accepts the core's next
dBus command in the ack cycle. It is the fastest master the bus contract
allows: "in the cycle after ack, req is 0 or a new request". With it,
`hw_req` rises at e2, and at e3 the two-phase bridge takes the old ack before
any `clk_28` edge has seen the request. In the gate leg, 161 of the 332 hw
accesses complete on a stale ack, and neither `scandoubler` nor `audio_ena`
toggles once in the measured blocks. The four-phase bridge passes with the
same master. The gate therefore shows that the bench catches the race and that
`hw_release` fixes it.
