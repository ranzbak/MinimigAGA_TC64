# OpenOCD + GDB for the RISC-V OSD host CPU

Two OpenOCD configurations attach GDB to the VexRiscv host CPU
(`rtl/host/rv_hostcpu.v`) through its RISC-V Debug Module (debug spec 0.13,
upstream OpenOCD `riscv` target). Which one you use depends on how the
bitstream was built:

| Config | Bitstream generic (`EightThirtyTwo_Bridge`) | Core | JTAG path | Adapter connects to |
|---|---|---|---|---|
| `minimig-rv-bscan.cfg` | `cpu_riscv = true`, `rv_debug = 1` | `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v` | tunnelled through the FPGA's own TAP (`BSCANE2` USER4) | the board's FPGA JTAG header (where Vivado programs) |
| `minimig-rv-pins.cfg` | `cpu_riscv = true`, `rv_debug = 2` | `VexOsd_DMJ` | its own TAP (IDCODE `0x10002FFF`, IR 5 bits) on `rv_jtag_tck/tms/tdi/tdo` | four FPGA header pins |

Production images use `rv_debug = 0` (no Debug Module); neither config works
with them. `rv_debug = 1` is Xilinx 7-series only (Vivado); a Quartus build
must use `rv_debug = 0` or `2`. The board top level does not pass
`cpu_riscv` / `rv_debug` yet and has no pins for `rv_jtag_*`: the debug lab
stage (plan section 5.4) adds them. Until then these configs are tested only
for syntax (OpenOCD's dummy adapter) and the Debug Module only in simulation
(`bash sim/rv_l1/run.sh dm_smoke`).

## The cable: the board's Platform Cable USB II does not work

The board is programmed with a **Xilinx Platform Cable USB II**. On this
machine `lsusb` shows it as **`03fd:000f`** (observed 2026-10-16, with its
firmware loaded); other documents give `03fd:0008`, which was not observed
here. Check yours with `lsusb | grep 03fd`. **OpenOCD 0.12.0
(the Ubuntu 24.04 package installed here) has no driver for it**:
`openocd -c "adapter list" -c shutdown` lists parport, dummy, ftdi,
usb_blaster, esp_usb_jtag, ft232r, ..., jlink, cmsis-dap, xds110, st-link,
rshim and nothing for Xilinx cables. You need another cable. Two options:

1. **FTDI-based JTAG cable on the FPGA JTAG header, `rv_debug = 1`**
   (recommended): a Digilent JTAG-HS2 or JTAG-HS3 (OpenOCD `ftdi` driver;
   Vivado's hardware manager drives the same cable, so one cable programs the
   FPGA and debugs the CPU). Config `minimig-rv-bscan.cfg`. No extra pins, no
   wiring beyond the 6-wire header (VREF, GND, TCK, TDO, TDI, TMS).
2. **Any OpenOCD JTAG adapter on four spare FPGA pins, `rv_debug = 2`**
   (J-Link, CMSIS-DAP probe, FT232H/FT2232H breakout, Raspberry Pi GPIO,
   ...): config `minimig-rv-pins.cfg`. The pins carry `rv_jtag_tck`,
   `rv_jtag_tms`, `rv_jtag_tdi` (FPGA inputs) and `rv_jtag_tdo` (FPGA
   output), 3.3 V, plus GND; the FPGA's own JTAG header stays on the
   Platform Cable for Vivado.

Only one program can own a USB cable at a time: close Vivado's hardware
manager (or `hw_server`) before starting OpenOCD on an HS2/HS3, and the
other way round.

## Install OpenOCD

OpenOCD 0.12.0 or later (the `riscv` target with `use_bscan_tunnel` is in
0.12.0).

```sh
sudo apt install openocd                 # Ubuntu 24.04: 0.12.0
openocd --version                        # Open On-Chip Debugger 0.12.0
```

USB access without root for FTDI cables (Digilent HS2/HS3 = `0403:6014`):
the package ships `/usr/lib/udev/rules.d/60-openocd.rules`; make sure your
user is in the group it names (`plugdev`), then replug the cable:

```sh
grep 6014 /usr/lib/udev/rules.d/60-openocd.rules
sudo usermod -aG plugdev $USER           # log out and in again
```

## Choose the adapter

Both configs source the adapter config named by the Tcl variable
`ADAPTER`; the default is `interface/ftdi/digilent-hs2.cfg` (Digilent
JTAG-HS2). Set another one with `-c "set ADAPTER ..."` **before** `-f`:

| Adapter | `ADAPTER` |
|---|---|
| Digilent JTAG-HS2 (default) | `interface/ftdi/digilent-hs2.cfg` |
| Digilent JTAG-HS3 | `interface/ftdi/digilent_jtag_hs3.cfg` |
| SEGGER J-Link | `interface/jlink.cfg` |
| CMSIS-DAP probe | `interface/cmsis-dap.cfg` |
| your own file | `/path/to/my-adapter.cfg` |

The adapter configs live in `/usr/share/openocd/scripts/interface/`.
`SPEED_KHZ` sets the JTAG clock (defaults: 5000 for the tunnel, 1000 for
the pins; lower it if the scan is unreliable).

## Connect

From the repository root, with the board powered and running a bitstream
built with the matching `rv_debug`:

```sh
# rv_debug = 1, HS2 on the FPGA JTAG header
openocd -f tools/openocd/minimig-rv-bscan.cfg

# rv_debug = 2, J-Link on the four pins, 500 kHz
openocd -c "set ADAPTER interface/jlink.cfg" -c "set SPEED_KHZ 500" -f tools/openocd/minimig-rv-pins.cfg
```

A good start prints the TAP it found (`xc7.tap` with IDCODE `0x?3631093`
for the XC7A100T, the top nibble is the silicon revision; or `riscv.cpu`
with `0x10002fff`) and a line like `[cpu.0] Examined RISC-V core; found 1
harts` (`riscv.cpu.0` for the pin config). OpenOCD then listens for GDB on
port 3333 (telnet 4444). Not yet tried on the board (plan 5.4): if the
first attempt fails, keep the OpenOCD log (`-d3 -l openocd.log`).

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
  5.4)**: no OpenOCD session has run against the core yet. What is known:
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
| `minimig-rv-bscan.cfg` | `rv_debug = 1`: `cpld/xilinx-xc7.cfg` + `riscv use_bscan_tunnel 6 1` (VexRiscv README) |
| `minimig-rv-pins.cfg` | `rv_debug = 2`: `jtag newtap riscv cpu -irlen 5 -expected-id 0x10002FFF` |
