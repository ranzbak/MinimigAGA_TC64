# OpenOCD + GDB for the RISC-V OSD host CPU

Two OpenOCD configurations attach GDB to the VexRiscv host CPU
(`rtl/host/rv_hostcpu.v`) through its RISC-V Debug Module (debug spec 0.13,
upstream OpenOCD `riscv` target). Which one you use depends on how the
bitstream was built:

| Config | Bitstream generic (`host_bridge`) | Core | JTAG path | Adapter connects to |
|---|---|---|---|---|
| `minimig-rv-bscan.cfg` | `rv_debug = 1` | `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v` | tunnelled through the FPGA's own TAP (`BSCANE2` USER4) | default `remote-bitbang.cfg`: the Phase 5.4 `hw_server` bridge (port 33582) on the board's FPGA JTAG header (where Vivado programs) |
| `minimig-rv-pins.cfg` | `rv_debug = 2` | `VexOsd_DMJ` | its own TAP (IDCODE `0x10002FFF`, IR 5 bits) on `rv_jtag_tck/tms/tdi/tdo` | four FPGA header pins |

Production images use `rv_debug = 0` (no Debug Module); neither config works
with them. `rv_debug = 1` is Xilinx 7-series only (Vivado); a Quartus build
must use `rv_debug = 0` or `2`. The board top level does not pass
`rv_debug` yet and has no pins for `rv_jtag_*`: the debug lab
stage (plan section 5.4) adds them. Until then both configs are tested in
simulation only: real OpenOCD attaches to the Verilator model of the core
through them (`sim/rv_dbg`, see "Simulation" below); the L1 smoke test
`bash sim/rv_l1/run.sh dm_smoke` drives the Debug Module with a simulated
JTAG master.

## The cable and the transport (decided 2026-10-17)

The board is programmed with a **Xilinx Platform Cable USB II**. On this
machine `lsusb` shows it as **`03fd:000f`** (observed 2026-10-16, with its
firmware loaded); other documents give `03fd:0008`, which was not observed
here. Check yours with `lsusb | grep 03fd`. OpenOCD 0.12.0 (the Ubuntu 24.04
package installed here) has no driver for it (`openocd -c "adapter list" -c
shutdown` lists parport, dummy, ftdi, usb_blaster, ..., jlink, cmsis-dap,
xds110, st-link, rshim and nothing for Xilinx cables). There is **no FTDI
adapter** for this board; none will be bought (plan decision 12.6, final).

Decision: debug uses `rv_debug = 1` (BSCANE2 tunnel) on the FPGA's own
6-wire JTAG header with the Platform Cable USB II. The transport is a
**Vivado `hw_server` Tcl JTAG-scan bridge** that serves OpenOCD's
`remote_bitbang` adapter on `127.0.0.1:33582`, and OpenOCD serves GDB.
`minimig-rv-bscan.cfg` uses that adapter by default (`remote-bitbang.cfg`).
**The bridge does not exist yet**: it is written and rehearsed in Phase 5.4
(`doc/osd-riscv-exec-5b.md` Tasks 3 and 4) and used on the board in the
board session (Task 8). Until then nothing below that needs a cable can be
run on the board. Firmware logging goes over the Amiga-side serial `ttyUSB0` (UART TX
only) and needs none of this.

Because `hw_server` owns the Platform Cable, close any other Vivado hardware
manager before starting the bridge, and the other way round.

The pin variant (`minimig-rv-pins.cfg`, `rv_debug = 2`, four spare FPGA pins
and any OpenOCD-supported adapter) stays in the tree but is not planned for
use.

## Install OpenOCD

OpenOCD 0.12.0 or later (the `riscv` target with `use_bscan_tunnel` is in
0.12.0).

```sh
sudo apt install openocd                 # Ubuntu 24.04: 0.12.0
openocd --version                        # Open On-Chip Debugger 0.12.0
```

USB access without root applies only to the pin variant with an FTDI adapter
(Digilent HS2/HS3 = `0403:6014`; not part of the decided setup, skip it for
the Platform Cable path):
the package ships `/usr/lib/udev/rules.d/60-openocd.rules`; make sure your
user is in the group it names (`plugdev`), then replug the cable:

```sh
grep 6014 /usr/lib/udev/rules.d/60-openocd.rules
sudo usermod -aG plugdev $USER           # log out and in again
```

## Choose the adapter

Both configs source the adapter config named by the Tcl variable
`ADAPTER`. The default of `minimig-rv-bscan.cfg` is `remote-bitbang.cfg`
(next to it): OpenOCD's `remote_bitbang` adapter to `RBB_HOST`:`RBB_PORT`,
default `127.0.0.1:33582`, the bridge. The default of `minimig-rv-pins.cfg`
stays `interface/ftdi/digilent-hs2.cfg` (Digilent JTAG-HS2; the pin variant
is not planned for use). Set another one with `-c "set ..."` **before** `-f`:

| Adapter | `ADAPTER` |
|---|---|
| `remote_bitbang` (default of `minimig-rv-bscan.cfg`; also set `RBB_PORT` / `RBB_HOST`) | `tools/openocd/remote-bitbang.cfg` |
| Digilent JTAG-HS2 (default of `minimig-rv-pins.cfg`) | `interface/ftdi/digilent-hs2.cfg` |
| Digilent JTAG-HS3 | `interface/ftdi/digilent_jtag_hs3.cfg` |
| SEGGER J-Link | `interface/jlink.cfg` |
| CMSIS-DAP probe | `interface/cmsis-dap.cfg` |
| your own file | `/path/to/my-adapter.cfg` |

The adapter configs live in `/usr/share/openocd/scripts/interface/`.
`SPEED_KHZ` sets the JTAG clock (defaults: 5000 for the tunnel, 1000 for
the pins; lower it if the scan is unreliable). `remote_bitbang` has no clock
of its own and ignores it: OpenOCD 0.12 prints `Info : This adapter doesn't
support configurable speed` (an Info line, not a warning); the server sets
the TCK rate. With `remote_bitbang` OpenOCD 0.12 also prints `Warn :
Transport "jtag" was already selected` (the driver selects JTAG itself
before the configs' `transport select jtag`); harmless.

## Connect

From the repository root, with the board powered and running a bitstream
built with the matching `rv_debug`. On the board, `rv_debug = 1` (the
decided path) has to wait for the Phase 5.4 bridge (Tasks 3, 4, 8 of
`doc/osd-riscv-exec-5b.md`); then, with the bridge serving port 33582:

```sh
# rv_debug = 1, through the hw_server bridge (remote_bitbang, 127.0.0.1:33582)
openocd -f tools/openocd/minimig-rv-bscan.cfg
# rv_debug = 2, J-Link on the four pins, 500 kHz (needs a bitstream with the pins, see above)
openocd -c "set ADAPTER interface/jlink.cfg" -c "set SPEED_KHZ 500" -f tools/openocd/minimig-rv-pins.cfg
```

A good start prints the TAP it found (`xc7.tap` with IDCODE `0x?3631093`
for the XC7A100T, the top nibble is the silicon revision; or `riscv.cpu`
with `0x10002fff`) and a line like `[cpu.0] Examined RISC-V core; found 1
harts` (`riscv.cpu.0` for the pin config). OpenOCD then listens for GDB on
port 3333 (telnet 4444). Both lines are what the simulation prints
(`sim/rv_dbg`); not yet tried on the board (plan 5.4): if the first attempt
fails, keep the OpenOCD log (`-d3 -l openocd.log`).

## Simulation (`sim/rv_dbg`)

The Verilator bench `sim/rv_dbg` runs the core (`rv_hostcpu`, `DEBUG = 2`
or `1`) behind a `remote_bitbang` server; the configs above attach to it
unchanged (README there: prerequisites, harness, the XC7A100T TAP model):

```sh
bash sim/rv_dbg/run.sh attach2           # minimig-rv-pins.cfg, pin TAP
bash sim/rv_dbg/run.sh attach1           # minimig-rv-bscan.cfg, BSCANE2 tunnel
```

By hand, harness in one terminal, OpenOCD (GDB on 3333) in another:

```sh
bash sim/rv_dbg/run.sh harness 1 +rbb_port=44853
openocd -c "set RBB_PORT 44853" -f tools/openocd/minimig-rv-bscan.cfg
# or DEBUG = 2:
bash sim/rv_dbg/run.sh harness 2 +rbb_port=44853
openocd -c "set ADAPTER tools/openocd/remote-bitbang.cfg" -c "set RBB_PORT 44853" \
        -f tools/openocd/minimig-rv-pins.cfg
```

`openocd -f tools/openocd/remote-bitbang.cfg` with no server listening ends
with `Error: Error on socket 'Failed to connect': errno==9, message: Bad
file descriptor.` (OpenOCD 0.12 reports the refused connection with the
wrong errno).

## GDB

GDB from the xPack toolchain the firmware is built with
(`tools/riscv/README.md`):

```sh
GDB=$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gdb
$GDB path/to/firmware.elf \
     -ex "target extended-remote localhost:3333"
```

Then, for example:

```
(gdb) monitor halt
(gdb) info registers pc
(gdb) break main
(gdb) monitor reset halt      # ndmreset: CPU restarts at 0x0, halted (unverified, see notes)
(gdb) load                    # writes the ELF's sections (firmware from 0x2000)
(gdb) continue
```

Notes:

* The CPU has a 4 KB instruction cache and no data cache. OpenOCD issues
  `fence.i` when it resumes after writing memory, so `load` and software
  breakpoints are seen by the core.
* `monitor reset halt` is **unverified until the debug lab stage (plan
  5.4)**: no OpenOCD session has run against the core on the board yet, and
  the simulation (`sim/rv_dbg`) so far attaches, halts, reads the PC and
  resumes only. What is known:
  with no SRST line configured, OpenOCD resets through
  `dmcontrol.ndmreset`, and in `rv_hostcpu` that is the CPU reset only (the
  boot ROM runs again from 0x0, the Debug Module keeps its state; the Amiga
  side is not reset). The L1 smoke test (`sim/rv_l1/run.sh dm_smoke`)
  checks that ndmreset sequence with a simulated JTAG master, not OpenOCD's
  own reset-halt handshake (haltreq held across the reset).
* Memory map for GDB: boot ROM BRAM `0x0-0x1FFF` (writable), SDRAM from
  `0x2000`, hardware registers at `0xFFFFFF00-0xFFFFFFFF` (16-bit, avoid
  reading them from GDB: some reads have side effects, e.g. the interrupt
  register clears its pending flag).

## Files

| File | What |
|---|---|
| `minimig-rv-bscan.cfg` | `rv_debug = 1`: `cpld/xilinx-xc7.cfg` + `riscv use_bscan_tunnel 6 1` (VexRiscv README); adapter default `remote-bitbang.cfg` |
| `remote-bitbang.cfg` | `adapter driver remote_bitbang`, `RBB_HOST` (default `127.0.0.1`), `RBB_PORT` (default 33582, the bridge) |
| `minimig-rv-pins.cfg` | `rv_debug = 2`: `jtag newtap riscv cpu -irlen 5 -expected-id 0x10002FFF` |
