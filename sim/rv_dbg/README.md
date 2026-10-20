# Debug bench: OpenOCD on the simulated OSD host CPU (Verilator)

The OSD host CPU block `rtl/host/rv_hostcpu.v` (VexRiscv with its RISC-V
Debug Module) runs on Verilator; a C++ harness serves the JTAG pins over TCP,
and the real OpenOCD 0.12 attaches through the same configs that are used on
the board (`tools/openocd/`). There are two debug variants:

| `DEBUG` | Core | JTAG path in the bench | OpenOCD config |
|---|---|---|---|
| 2 | `VexOsd_DMJ` | its own TAP (IDCODE `0x10002FFF`, IR 5) on the pins | `minimig-rv-pins.cfg` |
| 1 | `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v` | the XC7A100T TAP model `xc7_tap.v` (IDCODE `0x03631093`, IR 6) -> `BSCANE2` USER4 -> DTM | `minimig-rv-bscan.cfg` (`riscv use_bscan_tunnel`) |

`DEBUG = 1` is the decided board path (rv_debug = 1, plan 5.4). The
harness's second server mode, XVC 1.0, lets Vivado's `hw_server` drive the
same model (Task 4 of `doc/osd-riscv-exec-5b.md`).

| File | What it is |
|---|---|
| `tb_rv_dbg.v` | Top: `rv_hostcpu` + the L1 memory model and bus checker (`sim/rv_l1/mem_model.v`, `bus_checker.v`, used by path); for `DEBUG = 1` the TAP model |
| `xc7_tap.v` | 7-series TAP + `BSCANE2`/`BUFG` stand-ins (see "The TAP model") |
| `harness.cpp` | Verilator main: system clock, pin driver, `remote_bitbang` and XVC servers, run loop |
| `run.sh` | Builds and runs the targets below |
| `attach.tcl` | OpenOCD script of the attach runs (after the board config) |
| `xvc_idcode.py` | XVC client: IDCODE, IR capture and BYPASS through the harness |
| `xcheck/` | xsim cross-check of `xc7_tap.v` against Vivado's `JTAG_SIME2` + `BSCANE2` |
| `Makefile`, `tests/attach.S` | Test program (an endless counter loop), linked with `sim/rv_l1/sw` |

## Prerequisites

1. **RISC-V toolchain**: xPack `riscv-none-elf-gcc` 15.2.0-1 in
   `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1` (setup in
   [`tools/riscv/README.md`](../../tools/riscv/README.md)):

   ```sh
   bash tools/riscv/fetch-xpack.sh          # installs into ~/opt
   bash tools/riscv/check-toolchain.sh      # must pass
   ```

2. **Verilator 5.020** or later (`--timing`), g++, and **OpenOCD 0.12.0**
   (the `riscv` target with `use_bscan_tunnel` and the `remote_bitbang`
   adapter); `ccache` is used when present; `python3` for `xvc_loop`:

   ```sh
   sudo apt install verilator openocd ccache python3
   verilator --version                      # Verilator 5.020 2024-01-01
   openocd --version                        # Open On-Chip Debugger 0.12.0
   ```

3. Only for `xcheck`: **Vivado 2023.2** (xsim) at `/opt/Xilinx/Vivado/2023.2`
   (`VIVADO_PATH=` overrides). On this machine Vivado needs the libtinfo5
   shim in `~/lib/tinfo5`; the script sets `LD_LIBRARY_PATH` and `LC_ALL=C`
   itself.

## Run

From the repository root:

```sh
# DEBUG=2: OpenOCD over the pin TAP (minimig-rv-pins.cfg)
bash sim/rv_dbg/run.sh attach2
# DEBUG=1: OpenOCD over the BSCANE2 tunnel (minimig-rv-bscan.cfg)
bash sim/rv_dbg/run.sh attach1
# DEBUG=1 with the TAP's USER4 code 0x22 instead of 0x23: examine must fail
bash sim/rv_dbg/run.sh teeth
# DEBUG=1, harness as XVC server: IDCODE/IR capture/BYPASS through XVC
bash sim/rv_dbg/run.sh xvc_loop
# xsim: xc7_tap.v against JTAG_SIME2 + BSCANE2 (0 mismatches) and its teeth
bash sim/rv_dbg/run.sh xcheck
# all five: "=== RV_DBG ALL PASS"
bash sim/rv_dbg/run.sh all
```

Each attach run builds the Verilator image (`run_${RUNTAG:-wt}/vl_d<n>/`),
builds the test program (`make -C sim/rv_dbg`), starts the harness with
`+HEX=build/attach.hex +exit_on_disconnect`, then runs

```sh
openocd -c "set ADAPTER tools/openocd/remote-bitbang.cfg" -c "set RBB_PORT <port>" \
        -f tools/openocd/minimig-rv-pins.cfg -f sim/rv_dbg/attach.tcl     # attach2
openocd -c "set RBB_PORT <port>" \
        -f tools/openocd/minimig-rv-bscan.cfg -f sim/rv_dbg/attach.tcl    # attach1
```

(`minimig-rv-bscan.cfg` uses `remote-bitbang.cfg` by default, so only the
port is set). `attach.tcl` disables the GDB/telnet/Tcl servers, then `init`,
`halt`, prints the state and `reg pc`, `resume`, `shutdown`. The verdict line
is `=== ATTACH PASS ...` or `=== ATTACH FAIL <what>`; PASS needs OpenOCD exit
0, the TAP found with its IDCODE (`riscv.cpu` `0x10002fff`, or `xc7.tap`
`0x03631093`, which is in `cpld/xilinx-xc7.cfg`'s list), `Examined RISC-V
core` (`attach1`: `; found 1 harts`), `halted` after `halt`, the PC in
`[attach_loop, attach_loop_end)` of `build/attach.elf`, `running` after
`resume`, and the harness closing on OpenOCD's `Q`. Logs:
`run_<RUNTAG>/<target>.openocd.log`, `<target>.harness.log`, and the
`remote_bitbang` stream `<target>.rbb` (TDO replies) / `<target>.rbb.in`
(bytes received).

Environment: `RBB_PORT` (default 44853), `XVC_PORT` (default 2542),
`TCK_HALF` (default 4), `RUNTAG`, `VERILATOR`, `OPENOCD`, `PYTHON`,
`VIVADO_PATH`, `JOBS` (C++ build jobs, default 2). A port in use: the
harness takes a free one and prints it (`run.sh` passes it on). Every run has
a wall-clock limit (`timeout`) and kills its own children by PID on exit.

### By hand (a debugger session)

```sh
# harness in the foreground, DEBUG=2 (or 1), port 44853, no time limit
bash sim/rv_dbg/run.sh harness 2 +rbb_port=44853
# another terminal: OpenOCD (GDB on 3333), then GDB
openocd -c "set ADAPTER tools/openocd/remote-bitbang.cfg" -c "set RBB_PORT 44853" \
        -f tools/openocd/minimig-rv-pins.cfg
~/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gdb sim/rv_dbg/build/attach.elf \
        -ex "target extended-remote localhost:3333"
```

For `DEBUG = 1`: `bash sim/rv_dbg/run.sh harness 1 +rbb_port=44853` and
`openocd -c "set RBB_PORT 44853" -f tools/openocd/minimig-rv-bscan.cfg`.
`harness` passes further plusargs on (`+HEX=` replaces the test program).

## Harness (`harness.cpp`)

The harness owns time: system clock `clk_114` (8.816 ns), each pin write is
applied in the middle of a clock low phase and followed by `TCK_HALF` whole
system clocks (TCK <= clk / 8 by default); while no debugger talks, the clock
keeps running, so the program runs.

**remote_bitbang** (OpenOCD 0.12): `0`..`7` set TCK (bit 2), TMS (bit 1),
TDI (bit 0); `R` replies `0`/`1` with the current TDO; `r`..`u` (TRST/SRST)
and `B`/`b` (LED) are ignored and counted; `Q` closes the connection; any
other byte ends the run (`=== FAIL rbb unknown byte ...`, exit 3).

**XVC 1.0** (`+xvc=<port>` instead): `getinfo:` -> `xvcServer_v1.0:2048\n`;
`settck:<u32>` -> the same 4 bytes; `shift:<u32 bits><tms><tdi>` -> TDO,
`ceil(bits/8)` bytes each, LSB first per byte. Each bit is the bitbang
sequence (TCK 0 with TMS/TDI, sample TDO, TCK 1).

| Plusarg | Meaning |
|---|---|
| `+rbb_port=<p>` | listen port (default `$RBB_PORT`, else 44853; 0 = any free port) |
| `+xvc=<p>` | XVC server on `p` instead of `remote_bitbang` |
| `+tck_half=<n>` | system clocks per TCK half period (default `$TCK_HALF`, else 4) |
| `+timeout=<cycles>` | end after that many system clocks (`=== TIMEOUT`); absent = no limit |
| `+exit_on_disconnect` | end when the first connection closes (`=== EXIT disconnect`) |
| `+rbblog=<file>` | replies (the TDO bit stream) to `<file>`, bytes received to `<file>.in` |
| `+HEX=` `+WS=` `+ROMWS=` | the memory model's (`sim/rv_l1/README.md`) |

Output: `=== RBB listening 127.0.0.1:<port> ...` (or `XVC`), one line per
connection opened and one per connection closed (bytes, pin writes, `R`,
reset and LED bytes), the bench's verdict (`=== PASS` when the program
writes DONE 0, `=== FAIL <code>`, `=== FAIL bus violation`/`bad
address`/`uart read`), `=== CYCLES`. Exit status 0 = PASS or exit on
disconnect, 1 = FAIL, 2 = TIMEOUT, 3 = harness error.

## The TAP model (`xc7_tap.v`) and the cross-check

The first choice was Vivado's own TAP model
`$XILINX_VIVADO/data/verilog/src/unisims/JTAG_SIME2.v` with `BSCANE2.v`,
`BUFG.v` and `glbl.v`, compiled in place. Verilator 5.020 cannot build
`JTAG_SIME2.v`:

```
%Error-UNSUPPORTED: .../unisims/JTAG_SIME2.v:819:37: Unsupported tristate construct: ASSIGNDLY
  819 |                           TDO_latch <= IDregLastBit_sig;
%Error: .../unisims/JTAG_SIME2.v:829:45: Unsupported tristate construct (not in propagation graph): COND
  829 |                           TDO_latch <= glbl.JTAG_USER_TDO4_GLBL;
```

(its procedural `TDO_latch <= 1'bz`), so `xc7_tap.v` is a hand model of what
`JTAG_SIME2` (`PART_NAME` `7A100T`) and `BSCANE2` do, quirks included: IR 6
bits captured as `0x11`, IDCODE `0x09` -> `0x03631093`, BYPASS `0x3F`, USER1-4
`0x02 0x03 0x22 0x23`, IR = IDCODE on every falling edge in
Test-Logic-Reset, the global CAPTURE/SHIFT/UPDATE/RESET/RUNTEST registered on
the falling TCK edge, SEL rising at once and falling on the next falling
edge, TDO launched on the falling edge and high-Z outside Shift-IR/DR (the
bench reads high-Z as 1). The `BSCANE2` stand-in finds the TAP by its
instance name `xc7_jtag`, as the unisims find `glbl`. The comments in
`xc7_tap.v` list every behaviour.

`run.sh xcheck` (`xcheck/run_xcheck.sh`, xsim, serial) proves the model:
the same pseudo-random stream (>= 20,000 TCK cycles; IR loads of USER4,
IDCODE, BYPASS, USER1-3 and random values; DR scans of 1..80 bits; pauses in
and after scans; scans chained from Update; idle runs; resets; random TMS
walks) drives `JTAG_SIME2` + two `BSCANE2` (chains 4 and 1, with `glbl`,
compiled from the Vivado install in place) and `xc7_tap` + two
`xc7_bscane2`; TDO and, per chain, SEL, CAPTURE, SHIFT, UPDATE, RESET,
RUNTEST, TDI, TCK, TMS are compared just before and 2 ns after every TCK
edge. It must end with 0 mismatches; its teeth (the model's USER4 = 0x22)
must mismatch. `SEED=` and `NCYC=` change the stream.

## Wall time

This machine (Intel i7-1165G7, 4 cores / 8 threads, load average 10-12 from
other simulations, 2026-10-20), whole target including the build; Verilator
image rebuilt from a warm ccache, and cold (`OBJCACHE=` empty, a new
`RUNTAG`; the C++ build uses `JOBS=2`):

| Target | Warm | Cold |
|---|---|---|
| `attach2` | 1-4 s | 19 s |
| `attach1` | 3 s | 22 s |
| `teeth` | 11 s | 19 s |
| `xvc_loop` | < 1 s | (shares `attach1`'s image) |
| `xcheck` (both xsim runs) | 52 s | 52 s |
| `all` | | 113 s |

OpenOCD itself needs well under a second of the attach: about 25,000 pin
writes and 9,500 `R` (attach2) or 40,000 and 12,000 (attach1, the tunnel),
170,000-220,000 system clocks at `TCK_HALF=4`. Both attaches pass at
`TCK_HALF` 1, 4 and 16.
