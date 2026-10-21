# fw/ctrl_boot: boot ROM for the RISC-V OSD host CPU

The 8 KB boot BRAM of the VexRiscv RV32IMC host CPU. It initialises the SD
card, finds the FAT16/FAT32 partition, loads `RV32OSDA.BIN` to `0x2000` and
jumps to it.

It was ported from the boot ROM of the previous host CPU, the EightThirtyTwo
(`fw/ctrl_boot_832` at commit **8340590**, retired in Phase 9; last state in
tag `osd-832-final`). That ROM loads `832OSDAD.BIN`; the file names differ
because the architectures do, so a card can hold both, and this ROM never
loads `832OSDAD.BIN`.

## Build from a fresh machine

All commands from the repository root.

    # 1. toolchain (about 413 MB, sha256 checked, installs to $HOME/opt)
    bash tools/riscv/fetch-xpack.sh
    #    other install options and the Ubuntu fallback: tools/riscv/README.md
    # 2. build, check, sizes
    sudo apt install make gcc          # gcc = host compiler for romgen and the host test
    make -C fw/ctrl_boot
    make -C fw/ctrl_boot check size im
    # 3. host test (needs mtools dosfstools fdisk python3; see tools/sim/README.md)
    sudo apt install mtools dosfstools fdisk python3
    make -C fw/ctrl_boot test

`make` targets in `fw/ctrl_boot`:

| target | does |
|---|---|
| `all` (default) | `OSDBoot_rv.bin` and `OSDBoot_rv_ROM.vhd` |
| `check` | disassembles and fails if a `lr.w/sc.w/amo*` opcode is present (the core has no A extension) |
| `size` | `size` of the rv32imc image |
| `im` | rv32im (no compressed) build in `build_im/`, size printed, not committed |
| `test` | host minfat test (`test/`) |
| `clean` | removes `build/`, `build_im/`, `test/out/` (the committed outputs stay) |

The toolchain comes from `tools/riscv/toolchain.mk`
(`RV_GCC_DIR ?= $HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1`); override
`RV_GCC_DIR` / `RV_PREFIX` for another install.

## How the ROM VHDL is generated

`OSDBoot_rv_ROM.vhd` = `rom_prologue.vhd` (with `soc_firmware` renamed to
`OSDBoot_rv_ROM`) + the word table printed by `../romgen/romgen OSDBoot_rv.bin`
(built from `../romgen/romgen.c` with the host gcc; each 4 bytes of the image
in file order become one `x"b0b1b2b3"` word, the first byte in bits 31:24,
which is the memory lane rule the bridge undoes with its byte swap) +
`rom_epilogue.vhd`.
Both generated files are committed; rebuilding gives byte-identical output.

Compile `OSDBoot_rv_ROM.vhd` as **plain VHDL (VHDL-93)**, not VHDL-2008: the
RAM is a non-protected shared variable (below), which VHDL-93 allows and
VHDL-2008 rejects (2008 requires a protected type). Vivado and xsim (`xvhdl`
without `-2008`) and Quartus (default VHDL 1993) compile it as 93 unless told
otherwise; do not add it to a project as a "VHDL 2008" file.

`rom_prologue.vhd` / `rom_epilogue.vhd` are copies of the previous boot ROM's
template with one change: that template kept the RAM in a *signal* written by two processes
(one per port), which makes every write resolve to `X` in simulation. Here the
RAM is a *shared variable* (the form of the Vivado and Quartus true-dual-port
templates): the same dual-port, byte-enable, read-first RAM, no X in
simulation, and Vivado still infers 2 RAMB36 (checked with an out-of-context
`synth_design`: "2 K x 32 READ_FIRST" on both ports). A single process
writing through both ports does not work: Vivado then dissolves the RAM into
registers ("multiple writes via different ports in same process"). Test:
`test/run_rom_xsim.sh` (Vivado 2023.2 xsim, all 16 byte-select patterns on
both ports, fails on any X or wrong lane).

## Layout and map

- `crt0.S`: `0x00 j _start`, `0x20 boot_trap` (mtvec; resets `sp`, prints
  `TRAP <mcause> <mepc> <mtval>` on the UART through `boot_trap_c`, then
  `ErrorCode(0xf0f)` and parks), `_start` (clear x1-x31, sp = `0x2000`, gp,
  mtvec, clear `.bss`, `main`). The register clear gives the firmware defined
  registers after a soft reset as well, and keeps X off the bus in simulation:
  the simulated register file starts as X, and a function prologue that saves
  an unused callee-saved register would store it (the L2 bench fails on X).
- `boot.ld`: everything in `0x0-0x1FFF`, `.data` in place (the BRAM is
  initialised RAM), `ASSERT(_end <= 0x1C00)` keeps at least 1 KB of stack,
  `ASSERT(boot_trap == 0x20)`.
- Hardware windows (value at offset 0 of each 16-byte window): SPI data / CS /
  speed at `0xFFFFFFE0 / E4 / E8`, UART at `0xFFFFFFF0`, platform at
  `0xFFFFFFC0`. The UART is write-only: cfide acks a write only once the
  transmitter is free (so `putchar` needs no ready poll), and never acks a
  read, which would hang the CPU. There is no TX-ready bit; never read
  `0xFFFFFFF0`.
- Changes against the previous boot ROM's sources: `spi.h`/`uart.h` addresses; `OSDNAME`
  `RV32OSDABIN`; on-disk little-endian fields through `le16/le32` (`swap.h`);
  the MBR partition start (offset 454, misaligned) read bytewise; `minfat.h`
  structs use 32-bit `unsigned int` (so the host test sees the same layout);
  sector buffer word aligned; `spi.c` stores each SPI word big-endian
  (`be32`) so the sector bytes land in order on a little-endian CPU; `_boot()`
  runs `fence.i` before jumping to `0x2000`; `small_printf.c` is a minimal
  printf (the previous ROM linked lib832's); `puts(const char *)`.
- `bootdiag.h` is the committed 68k byte array; `make` rebuilds it only if
  `bootdiag.s` is newer and `vasmm68k_mot` is installed.

## Sizes (xPack gcc 15.2.0, `-Os`)

| build | text | data | bss | text+data+bss |
|---|---|---|---|---|
| rv32imc (`OSDBoot_rv.bin` = 3580 bytes) | 3556 | 24 | 580 | 4160 |
| rv32im (`make im`, not committed) | 4972 | 24 | 580 | 5576 |

Gate: text+data+bss at most 6 KB; stack room: `_end = 0x1040` of the `0x1C00`
limit. (The x1-x31 clear in `crt0.S` added 60 bytes over the first build.)

## Host test

`test/minfat_test.c` links `minfat.c` and `swap.c` (gcc, ASan + UBSan) against a
mock `sd_read_sector()` that reads a card image made by `tools/sim/mkcard.sh`.
Images: MBR card with `RV32OSDA.BIN` (3000 random bytes) plus the decoys
`OLDOSDAD.BIN` (ahead of it, a firmware-like name such as the previous
`832OSDAD.BIN`) and `RV32OSDB.BIN` (file loaded byte-identical); MBR card
without the file (`LoadFile` returns 0, the decoys are not taken); FAT16
superfloppy (no MBR); FAT32 superfloppy with a 40000-byte file.
The SD SPI path in `spi.c` is not covered by the host test (it needs the
hardware windows); the L2 boot bench (sim/host_bridge, with the SD model of
`sim/common`) exercises it.
