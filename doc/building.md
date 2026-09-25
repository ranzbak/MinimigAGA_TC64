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
| gcc, make, wget, patch | | the EightThirtyTwo toolchain (vbcc832) |
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
| `EightThirtyTwo` | the OSD controller CPU and its C toolchain | the firmware |
| `lib/AP68040` | the non-pipelined reference 68040 (branch `ap68040-reference` of the AP68040-pipelined repository) | `AP040_PIPE_DIR=none` builds and some benches |
| `rtl/tg68k` | the TG68K CPU | only the older ports; not in this build's project |

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
| `AP040_PIPE_DIR=none` | build the non-pipelined reference core from `lib/AP68040` |
| `STOP_AFTER_ROUTE=1` | stop before writing a bitstream (timing experiments) |

Without `AP040_PIPE_DIR`, the script uses the `lib/AP68040-pipelined`
submodule. It sets its options on the project for the one run and clears them
afterwards, and it re-synthesises only when sources or options changed.

Notes:

- Builds use `project_1/` inside the tree, so two builds in one tree collide.
  The runbook (section 2.5) shows how to build a second copy.
- The files `fw/ctrl_boot_832/OSDBoot_832_ROM.vhd` and
  `fw/ctrl_boot_832/rom_prologue.vhd` are generated by the boot loader's
  firmware build and go into the bitstream. They show as modified after a
  firmware build; don't commit them.

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

The firmware runs on the EightThirtyTwo soft CPU and is built with vbcc832.

**The toolchain, once.** The `EightThirtyTwo` Makefile fetches vbcc 0.9g,
patches it and builds it for the 832 (from the Makefile; not run for this
document):

```bash
make -C EightThirtyTwo vbcc      # download, patch and build vbcc; accept the defaults it asks for
make -C EightThirtyTwo           # assembler, linker, libraries
```

Check the license terms vbcc prints if you plan to distribute firmware you
built.

**The firmware:**

```bash
make -C fw/ctrl_832
```

It writes `fw/ctrl_832/832OSDAD.bin` (and regenerates `fw/ctrl_832/version.h`
with the build date: don't commit that file). Copy it to the root of the SD
card as `832OSDAD.BIN`. No bitstream rebuild or JTAG load is needed: the boot
loader reads it from the card at every power-on and after a card swap.

Build the firmware and the bitstream from the same commit: the HDMI clock
delay the firmware sets (`fw/ctrl_832/adv7511.c`, register `0xBA`) has to match
the bitstream's video output timing
([troubleshooting.md](troubleshooting.md#2-firmware-and-bitstream-belong-together)).

**The boot loader** (`fw/ctrl_boot_832`) is part of the bitstream as
`OSDBoot_832_ROM.vhd`. It looks for `832OSDAD.BIN` on the card. Rebuilding it
(`make -C fw/ctrl_boot_832`) is only needed when its sources change, and then
the bitstream has to be rebuilt too.
