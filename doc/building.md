# Building

How to build the bitstream and the OSD firmware, and get them onto the board.
The in-depth runbook, with the debug (ILA) captures and the hardware test
list, is [build-program-test.md](build-program-test.md); parts of it describe
older stages of the project, so where the two differ, this file and the
scripts are current.

Everything here is for Linux (the commands were written on Ubuntu) and the
QMTech XC7A100T build only.

## 1. Tools

| Tool | Version | For |
|---|---|---|
| Vivado | **2023.2** (the project file is 2023.2) | synthesis, implementation, JTAG, flash, xsim |
| git | any recent | the repository and its submodules |
| xPack `riscv-none-elf-gcc` | **15.2.0-1** (pinned, installed by `tools/riscv/fetch-xpack.sh`) | the OSD firmware and its boot loader |
| gcc, gcc-multilib, make, curl, mtools, dosfstools, fdisk | | the firmware's host tests and test card images |
| `vasmm68k_mot` | vasm, Motorola syntax | 68k snippets in the firmware and the benches |
| `xxd` | | firmware build |
| Icarus Verilog | 12 | most simulations ([simulation.md](simulation.md)) |
| python3 | 3.x | decoders and bench helpers |

### Vivado 2023.2 on current Ubuntu

Vivado 2023.2 wants `libtinfo.so.5`, which Ubuntu no longer ships. Make a
directory that holds only a `.so.5` link, once:

```bash
mkdir -p ~/lib/tinfo5
ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5
```

Then run Vivado with that directory on `LD_LIBRARY_PATH`, per command, and
check it starts:

```bash
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C LANG=C \
    /opt/Xilinx/Vivado/2023.2/bin/vivado -version
```

- Never put a whole library directory from a snap on `LD_LIBRARY_PATH`: it
  carries an old libc and breaks every other program in that shell.
- Don't pass `-stack` to Vivado 2023.2 (the router crashes). Some shell
  aliases add it; call the binary by its full path.
- `LC_ALL=C` avoids a locale error when synthesis runs next to a simulation.
- In zsh, `V="vivado -mode batch"; $V ...` runs nothing (zsh doesn't split
  words). Use a function or bash.

## 2. Getting the source

```bash
git clone --recursive -b 5.0-040-pipelined https://github.com/ranzbak/MinimigAGA_TC64.git
cd MinimigAGA_TC64
```

In an existing clone, `git submodule update --init` does the same.

| Submodule | What | Needed for |
|---|---|---|
| `lib/AP68040-pipelined` | the 68040 CPU core | the bitstream |
| `lib/AP68040` | the non-pipelined reference 68040 (branch `ap68040-reference` of the AP68040-pipelined repository); the core itself is no longer built | `ap040_bus16_adapter.v`, which the faster core's build (`FASTER`) and its `sim/ddr3_cpu` leg take from it, and the pipelined core's own `compat:` test legs |

All submodule URLs are HTTPS (since commit 829167b), so no GitHub SSH key is
needed. On 2026-09-25 each submodule's pinned commit was fetched from its
GitHub URL; a complete `--recursive` clone was not run for this document.

## 3. Building the bitstream

Run from the repository root, in bash:

```bash
N=my_build                       # output directory under build/
mkdir -p build
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C LANG=C \
    AP040_PIPE_MMU=1 AP040_PIPE_FPU=1 IMPL_EFFORT=high \
    /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal \
    -source tools/vivado/build_ap040.tcl \
    -tclargs $PWD/build/$N 0 $PWD 1 30 1024 > build/$N.log 2>&1
grep -q "=== ALL DONE ===" build/$N.log && echo BUILD OK || grep "^ERROR" build/$N.log
```

It takes about 35-45 minutes (a figure from the runbook, for the earlier
core). The bitstream is `build/$N/minimig_openaars_top.bit`, next to the
timing and utilisation reports.

**Arguments** of `build_ap040.tcl`, in order:

| # | Value above | Meaning |
|---|---|---|
| 1 | `$PWD/build/$N` | where the bitstream and reports go |
| 2 | `0` | `1` adds the debug ILAs |
| 3 | `$PWD` | the source tree to build |
| 4 | `1` | posted stores in the data cache (`0` only for experiments) |
| 5 | `30` | CPU clock divider: 30 = 113.4375 / 3 = 37.8 MHz |
| 6 | `1024` | CPU ILA depth; use 1024 whenever argument 2 is `1` |

**Environment switches:**

| Variable | Effect |
|---|---|
| `AP040_PIPE_MMU=1` | build the MMU in (the OSD then shows `/MMU`) |
| `AP040_PIPE_FPU=1` | build the FPU in (`/FPU`); without it the CPU is a 68LC040 |
| `IMPL_EFFORT=high` | stronger placement and routing directives for this run |
| `FASTRAM_ILA=0` | with ILAs on, keep only the CPU ILA (both don't fit in block RAM) |
| `AP040_PIPE_DIR=<dir>` | build the pipelined core from another checkout |
| `STOP_AFTER_ROUTE=1` | stop before writing a bitstream (timing experiments) |

**CPU switches.** Without any of them the build is the configuration the
board runs (since 2026-10-05, build/stage_r04mis): MMU and FPU in, and
`STORE_BUF FWD RAS PRECISE SB_MMU COPYBACK LDX BTFN DFP_MIS WALLOC` all `1`;
`BTB`, `MISPLIT`, `POST_CHIP`, `POST_CI` and `CWF` `0`. Set one to `0` (e.g. `COPYBACK=0`) for an A/B; the
build log's `PIPELINED build from` line lists what the run used.

| Variable | Default | Effect |
|---|---|---|
| `AP040_PIPE_MMU` / `AP040_PIPE_FPU` | 1 | the MMU / the FPU (`0`: a 68LC040, or no MMU) |
| `STORE_BUF` | 1 | posted stores (findings/storebuf) |
| `FWD`, `RAS` | 1 | store-to-load forwarding, return-address stack |
| `PRECISE`, `SB_MMU` | 1 | address-precise fast reads; posting with translation on |
| `COPYBACK` | 1 | the copyback data cache (CM = 01 pages on the DDR3 board) |
| `LDX`, `BTFN` | 1 | late-operand load dispatch; forward branches guessed not taken |
| `DFP_MIS` | 1 | misaligned accesses served from the data cache |
| `WALLOC` | 1 | write-allocate: a copyback store miss fills its line (needs `COPYBACK`) |
| `BTB`, `MISPLIT` | 0 | branch target buffer; misaligned split (both off: not board-proven) |
| `POST_CHIP`, `POST_CI` | 0 | with the MMU on, stores to chip RAM (`POST_CHIP=1`) and to cache-inhibited pages (`POST_CI=1`: CM = 11 -- MuFastChip, a demo's DTT0 = $0000C060; `2`: CM = 10 as well) posted too (findings/postchip; not board-proven) |
| `CWF` | 0 | critical-word-first data-cache line fills with early restart: a read miss fetches the missed longword first, the CPU goes on when it arrives and the line finishes in the background (M68040UM 4.6.1; not board-proven) |

Without `AP040_PIPE_DIR`, the script uses the `lib/AP68040-pipelined`
submodule. It sets its options on the project for the one run and clears them
afterwards, and it re-synthesises only when sources or options changed.

Notes:

- Builds use `project_1/` inside the tree, so two builds in one tree collide.
  The runbook (section 2.5) shows how to build a second copy.
- The boot loader's ROM, `fw/ctrl_boot/OSDBoot_rv_ROM.vhd`, goes into the
  bitstream. It is committed together with its sources and
  `make -C fw/ctrl_boot` rebuilds it byte for byte (section 6).

### Checking timing

```bash
grep -E "^(clk_114 +clk_38|clk_38 +clk_38|clk_38 +clk_114|clk_gen_sdram +clk_114) " \
  build/$N/clock_interaction.rpt | awk '{printf "%-14s -> %-14s WNS %7s  fail %s / %s\n",$1,$2,$6,$8,$9}'
```

- The CPU clock rows (`clk_114 -> clk_38`, `clk_38 -> clk_38`,
  `clk_38 -> clk_114`) must show `fail 0`.
- `clk_gen_sdram -> clk_114` fails on **16 endpoints** (the SDRAM data input
  registers) by about -0.3 to -0.65 ns in every build since the start of the
  project, including the ones that work on the board. That's known. More
  endpoints, or a much worse number, is a new problem.
- `build/$N/timing_summary.rpt` has the full picture.

## 4. Loading the bitstream over JTAG

Temporary: it lasts until the board is powered off. Connect the JTAG cable,
then:

```bash
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C LANG=C \
    /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal \
    -source tools/vivado/program.tcl \
    -tclargs $PWD/build/$N/minimig_openaars_top.bit 2>&1 | grep -E "^===|ERROR"
```

It prints `=== DONE: ...minimig_openaars_top.bit loaded, DONE pin = 1 ===`.
Only one Vivado session may use the cable at a time.

After a JTAG load: no HDMI picture can just mean the board needs a power cycle,
and RTG should only be judged after a cold start. See
[troubleshooting.md](troubleshooting.md).

## 5. Writing the flash (permanent)

This is how Paul puts an image on the board for good: in the Vivado GUI's
Hardware Manager. Only flash an image that has worked when loaded over JTAG.

The constraints set the configuration to 4-bit SPI (`SPI_BUSWIDTH 4`) at
3.3 V (`fpga/openaars/aars_v5.0/xc7a100t/generic.xdc`). The runbook names the
flash chip as a Micron **MT25QL128** (16 MB); the constraints don't say, so
check the part on your board (unverified).

1. **Tools → Generate Memory Configuration File**: format MCS, memory part the
   board's flash (for the MT25QL128, the `mt25ql128-spi-x1_x2_x4` entry),
   interface SPIx4, load the `.bit` at address `0x00000000`, write for example
   `build/$N/minimig_openaars_top.mcs`.
2. **Open Hardware Manager → Open Target → Auto Connect.**
3. Right-click the `xc7a100t` device → **Add Configuration Memory Device** →
   the same part.
4. **Program Configuration Memory Device** with the `.mcs`, with Erase,
   Program and Verify ticked.
5. When it reports success, power-cycle the board and check it boots the new
   image.

The same `.mcs` can be made in Tcl with Vivado's standard command (not run for
this document):

```tcl
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x00000000 build/my_build/minimig_openaars_top.bit" \
    -file build/my_build/minimig_openaars_top.mcs
```

No flash script is in the repository.

## 6. Building the OSD firmware

The firmware runs on the OSD host CPU, a VexRiscv RV32IMC soft CPU
(`rtl/host/rv_hostcpu.v`), and is built with the pinned xPack
`riscv-none-elf-gcc` 15.2.0-1. Details: [fw/ctrl/README.md](../fw/ctrl/README.md),
[tools/riscv/README.md](../tools/riscv/README.md).

**Packages and the toolchain, once** (Ubuntu 24.04). `fetch-xpack.sh`
downloads the toolchain into `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1` and
checks its sha256; newlib-nano comes with it:

```bash
sudo apt install build-essential gcc-multilib git curl python3 xxd mtools dosfstools fdisk
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
```

Another install of the toolchain: put `RV_GCC_DIR=... RV_PREFIX=...` in front
of every `make` (`tools/riscv/toolchain.mk`).

**The firmware** (the boot loader first: the firmware's `check` reads its map):

```bash
make -C fw/ctrl_boot
make -C fw/ctrl
make -C fw/ctrl check
```

It writes `fw/ctrl/build/RV32OSDB.BIN` (and `fw/ctrl/build/version.h` with the
build date; `build/` is not in git). Copy it to the root of the SD card as
`RV32OSDB.BIN`. No bitstream rebuild or JTAG load is needed: the boot loader
reads it from the card at every power-on and after a card swap. The host
tests: `make -C fw/ctrl/test`.

Build the firmware and the bitstream from the same commit: the HDMI clock
delay the firmware sets (`fw/ctrl/adv7511.c`, register `0xBA`) has to match
the bitstream's video output timing
([troubleshooting.md](troubleshooting.md#2-firmware-and-bitstream-belong-together)).

**The boot loader** (`fw/ctrl_boot`) is part of the bitstream as
`OSDBoot_rv_ROM.vhd`. It looks for `RV32OSDB.BIN` on the card and runs it only
when the file's lock-step trailer names this bitstream's SD card peripheral
(otherwise it stops with a message on the UART and a cyan screen). The name
is written once, in `fw/ctrl/fwname.mk`, for both builds; `make -C fw/ctrl
check` fails if the committed boot loader looks for another one. Bitstreams
from before the SD card peripheral load `RV32OSDA.BIN` instead, so one card
can hold the firmware of both. Rebuilding it
(`make -C fw/ctrl_boot`) reproduces the committed `OSDBoot_rv.bin` and
`OSDBoot_rv_ROM.vhd`; when its sources change, commit both with them and
rebuild the bitstream.
