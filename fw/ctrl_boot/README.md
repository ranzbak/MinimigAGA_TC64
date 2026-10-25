# fw/ctrl_boot: boot ROM for the RISC-V OSD host CPU

The 8 KB boot BRAM of the VexRiscv RV32IMC host CPU. It initialises the SD
card through the SD card peripheral (`rtl/host/sdcard_spi.v`), finds the
FAT16/FAT32 partition, loads `RV32OSDB.BIN` to `0x2000`, checks that the
file was built for this bitstream (the lock-step check below) and jumps to
it.

The name is written once, in `fw/ctrl/fwname.mk` (`FW_83` = `RV32OSDBBIN`,
the 8.3 directory entry; the Makefile passes it as `OSDNAME`), which
`fw/ctrl/Makefile` reads for its output file too; `make -C fw/ctrl check`
(i) fails when the committed `OSDBoot_rv.bin` looks for another name or the
committed `OSDBoot_rv_ROM.vhd` is not the VHDL of that `.bin` (`make
romvhd_check ROMVHD_OUT=<file>` writes it with the same recipe as the
committed file).

It was ported from the boot ROM of the previous host CPU, the EightThirtyTwo
(`fw/ctrl_boot_832` at commit **8340590**, retired in Phase 9; last state in
tag `osd-832-final`). That ROM loads `832OSDAD.BIN`; the file names differ
because the architectures do, so a card can hold both, and this ROM never
loads `832OSDAD.BIN`. Likewise the RISC-V boot ROM from before the SD card
peripheral (card on cfide's SPI, firmware without the trailer) loads
`RV32OSDA.BIN`: this ROM never loads that file (it would refuse it at the
lock-step check anyway), so old and new bitstreams boot from one card that
holds both firmwares (decision of 2026-10-25, SD card engine Task 13b).

## Build from a fresh machine

All commands from the repository root.

    # 1. toolchain (about 413 MB, sha256 checked, installs to $HOME/opt)
    bash tools/riscv/fetch-xpack.sh
    #    other install options and the Ubuntu fallback: tools/riscv/README.md
    # 2. build, check, sizes
    sudo apt install make gcc          # gcc = host compiler for romgen and the host test
    make -C fw/ctrl_boot
    make -C fw/ctrl_boot check size im
    # 3. host tests (needs mtools dosfstools fdisk python3; see tools/sim/README.md);
    #    build fw/ctrl first so the lock-step test also checks its RV32OSDB.BIN
    sudo apt install mtools dosfstools fdisk python3
    make -C fw/ctrl
    make -C fw/ctrl_boot test
    # 4. the boot ROM on the RTL (Verilator, about 2 minutes for the four;
    #    each RUNTAG names a fresh run directory)
    SIM=verilator RUNTAG=boot  bash sim/host_bridge/run.sh boot
    SIM=verilator RUNTAG=bootn bash sim/host_bridge/run.sh boot_nofile
    SIM=verilator RUNTAG=bootm bash sim/host_bridge/run.sh boot_mismatch
    SIM=verilator RUNTAG=bootb bash sim/host_bridge/run.sh boot_both

`make` targets in `fw/ctrl_boot`:

| target | does |
|---|---|
| `all` (default) | `OSDBoot_rv.bin` and `OSDBoot_rv_ROM.vhd` |
| `check` | disassembles and fails if a `lr.w/sc.w/amo*` opcode is present (the core has no A extension) |
| `size` | `size` of the rv32imc image |
| `im` | rv32im (no compressed) build in `build_im/`, size printed, not committed |
| `test` | host tests (`test/`): minfat, lock-step |
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
- Hardware windows (value at offset 0 of each 16-byte window): cfide's SPI
  data / CS / speed at `0xFFFFFFE0 / E4 / E8` (the OSD only: `ErrorCode`,
  the chipset reset), UART at `0xFFFFFFF0`, platform at `0xFFFFFFC0`. The
  SD card peripheral's 16-bit registers at `0xFFFFFF00..2C` (offsets and
  bits from `fw/ctrl/sdc.h`, included by `spi.c` and `lockstep.c`). The UART is write-only: cfide acks a write only once the
  transmitter is free (so `putchar` needs no ready poll), and never acks a
  read, which would hang the CPU. There is no TX-ready bit; never read
  `0xFFFFFFF0`.
- Changes against the previous boot ROM's sources: `spi.h`/`uart.h` addresses; `OSDNAME`
  `RV32OSDBBIN` (`RV32OSDABIN` until the SD card peripheral); on-disk little-endian fields through `le16/le32` (`swap.h`);
  the MBR partition start (offset 454, misaligned) read bytewise; `minfat.h`
  structs use 32-bit `unsigned int` (so the host test sees the same layout);
  sector buffer word aligned; `spi.c` (since the SD card peripheral) stores
  the first byte of each RXW pop (bits 15:8) first, so the sector bytes land
  in order; `_boot()`
  runs `fence.i` before jumping to `0x2000`; `small_printf.c` is a minimal
  printf (the previous ROM linked lib832's); `puts(const char *)`.
- `bootdiag.h` is the committed 68k byte array; `make` rebuilds it only if
  `bootdiag.s` is newer and `vasmm68k_mot` is installed.

## Card path (`spi.c`)

The card is on the SD card peripheral (`rtl/host/sdcard_spi.v`, its header
comment is the contract), not on cfide's SPI: the openaars top
(`SD_ENGINE = 1`) has no card there. Board tops without the peripheral
(`SD_ENGINE = 0`: VERSION reads 0) are not supported by this ROM: it stops
with `ErrorCode(0xf00)` (and tries again, as for a missing card).

The ROM polls STATUS bit 0 (nothing else runs at boot; the peripheral's irq
stays off, IRQEN 0) and runs one op at a time; every op ends in hardware
(XFER after LEN bytes, the waits by TIMEOUT, any op at once when the card is
gone), so no poll loop can hang.

- Init: the VERSION check (must be `SDC_VERSION` of `sdc.h`), ABORT (a soft
  re-run of the ROM: the firmware's op), IRQEN 0, both FIFOs flushed, MATCH
  FF; 400 kHz (div 141), 80 clocks with CS high, CS on; CMD0; CMD8 (R7 echo
  `01 AA`; an illegal-command R1 = SD v1); CMD55 + ACMD41 (HCS for v2) until
  R1 0, at most 5000 polls (at least 1.8 s); CMD58 (CCS: SDHC); CMD59 1 (CRC
  on: the card checks every command's CRC7); SD v1 / SDSC: CMD16 512; then
  18.9 MHz (div 2). MMC (CMD1) is not supported.
- A command: `FF`, the 6 bytes with their CRC7 (`crc7`, bitwise, as
  `fw/ctrl/sdproto.c`) pushed with TXB, XFER TX 7, TX_FLUSH (TX keeps sent
  bytes until a flush or commit), WAIT_NE FF with TIMEOUT 16 (2.3 ms) for
  R1. No R1, card gone, or an R1 with the CRC bit (`08`): the command again,
  4 tries in all.
- A sector: CMD17 (byte address for SDSC), WAIT_NE FF with TIMEOUT 1732
  (250 ms) for the token `FE`, XFER RX 512 with the CRC16 check (CMD bit 7:
  STATUS bit 1), 256 RXW pops. R1 not 0, no token or an error token, or a
  CRC mismatch (then RX_FLUSH: the block is poisoned): the sector again, 4
  tries; from the 3rd try on the SCK is div 13 (4.1 MHz) for the rest of
  the boot. 4 failed tries: `sd_read_sector` returns 0 and the boot ends in
  `ErrorCode` (below).
- `minfat.c`: a failed directory read ends `FileOpen` (it used to go on
  with the stale buffer), and `LoadFile` stops on a failed FAT read
  (`GetCluster` 0) instead of reading cluster 0.

## Lock-step check (`lockstep.c`)

A firmware file built for another card path cannot work with this
bitstream (design 5.5), so the ROM, which is part of the bitstream, refuses
it. `RV32OSDB.BIN` ends with an 8-byte trailer that `fw/ctrl/Makefile`
appends after `objcopy` (`_start` stays byte 0):

    'S' 'D' 'C' 'V' 00 00 <SDC_VERSION 15:8> <SDC_VERSION 7:0>

(`fw/ctrl/sdctrailer.c`, compiled from `sdc.h`: the one place the version
is written; `make -C fw/ctrl check` (h) checks the built file.) After
`LoadFile`, `fw_start()` takes the last 8 bytes of the file (its length
from the FAT directory entry, not a fixed offset) and compares them with
the peripheral's VERSION register:

- match: `Firmware SDC 5D02, bitstream SDC 5D02`, `fence.i`, jump to 0x2000;
- anything else (another version, no `SDCV` magic, bytes 4-5 not 0, a file
  shorter than 8 bytes; a firmware from before the trailer has none):
  `Firmware does not match this bitstream (need SDC 5D02)`, the OSD
  message (below), `ErrorCode(0x0ff)` (cyan on the Amiga screen through
  BootDiag; the ROM's last hardware access, as `sim/host_bridge`
  `boot_mismatch` checks), then `boot_halt()`: interrupts off, the CPU
  parks. No retry, no fallback.

The OSD message (design 5.5; final review fix wave, Paul 2026-10-25):
`FIRMWARE MISMATCH`, centred on OSD line 3 (`LOCKSTEP_OSD_AT`), the rest of
the OSD blank, then the OSD switched on. One write frame of the whole buffer
(`0c 00 00 00 00` and 2,048 bytes: the old menu of a soft restart goes too)
and `28 01`, with cfide's SPI at `fw/ctrl`'s `SPI_fast` speed (1). The
glyphs are `fw/ctrl/charrom.h`'s, columns 0-6 of the 11 letters and the
space (84 bytes); the message is 17 table offsets. The two-byte OSD command
frames of `main` / `ErrorCode` and the OSD's enable share `osd_cmd()`
(`boot.c`), which paid for most of it. `ErrorCode`'s chipset reset does not
touch the OSD (its enable and buffer have no reset), so the message stays.

The boot ROM and `RV32OSDB.BIN` must come from the same commit; a new
`SDC_VERSION` in `sdc.h` (a new peripheral contract) changes both, and
`rtl/host/sdcard_spi.v`'s `VERSION` with it (`fw/ctrl` `make check` (j)).
0x5D02 since the final review's fix wave (the bridge's `IDEF_CMD_WR`).

## UART lines

On the controller UART (115200), every line printed by `small_printf`
(formats `%d %u %x %02x %04x %s`):

| line | when |
|---|---|
| `Initializing SD card` | each pass of the boot loop |
| `SD init: VERSION 5D02, card 1` | the peripheral's VERSION and card-present bit (STATUS 3) |
| `SD init: CMD0 01`, `CMD8 01`, `ACMD41 00`, `CMD58 00`, `CMD59 00`, (`CMD16 00`) | each init step's R1 (`FF`: no R1) |
| `SD init: CMD8 echo <b>` | CMD8's echo was not `01 AA` |
| `SD card: SDHC` / `SD card: SD` | the card type |
| `SD CMD<n>: R1 <r1>, try <t>` | a command try without a usable R1 (`FF`: none in 2.3 ms or card gone; `08`/`09`: CRC error) |
| `SD read <lba>: R1 <r1>, try <t>` / `token <b>, try <t>` / `CRC <st>, try <t>` | a failed sector try (token `FF`: none in 250 ms; CRC: the STATUS bits) |
| `SD: SCK div 13` | the step down at a read's 3rd try |
| `Firmware SDC <v>, bitstream SDC <v>` | the lock-step check passed |
| `Firmware does not match this bitstream (need SDC <v>)` | it did not |

## Error codes (`ErrorCode`, the BootDiag colour on the Amiga screen)

| code | meaning |
|---|---|
| `0xfff` | booting (set at start) |
| `0xf00` | SD init failed: no peripheral (VERSION not `SDC_VERSION`), no card, no answer |
| `0xff0` | no FAT16/FAT32 partition (or a read failed while looking) |
| `0x0f0` | `RV32OSDB.BIN` not found or a read failed while loading |
| `0x0ff` | lock-step mismatch: halted |
| `0xf0f` | CPU trap (`boot_trap`) |

After `0xf00`, `0xff0` and `0x0f0` the ROM starts over (`Initializing SD
card`); after `0x0ff` and `0xf0f` it halts.

## Sizes (xPack gcc 15.2.0, `-Os`)

| build | text | data | bss | text+data+bss |
|---|---|---|---|---|
| rv32imc (`OSDBoot_rv.bin` = 4496 bytes) | 4472 | 24 | 580 | 5076 |
| rv32im (`make im`, not committed) | 5872 | 24 | 580 | 6476 |

Gate: `_end` below `0x1400` (`fw/ctrl/Makefile` check (g): the firmware's
stack floor in the shared boot BRAM); today `_end = 0x13D4` (44 bytes
left; `0x1328` before the OSD message of the lock-step stop, `0x1040` with
the card on cfide's SPI). `boot.ld` keeps its
`0x1C00` assert as the outer limit. (The x1-x31 clear in `crt0.S` added 60
bytes over the first build.)

## Host tests

`test/lockstep_test.c` runs `fw_start()` (`lockstep.c`, gcc, ASan + UBSan,
`-DHOSTTEST`: `sdc.h`'s `SDC_R` reads the test's mock VERSION) with the
ROM's own `small_printf` (`putchar` renamed: the UART text is compared byte
for byte) and mock `_boot` / `ErrorCode` / `boot_halt`: trailer 5D00 against
VERSION 5D01 (message + `ErrorCode(0x0ff)` + halt), 5C01 (the high byte),
5D01 (jumps), VERSION 5D02 (the message names the register's value), no
magic, wrong magic,
bytes 4-5 not 0, the trailer one byte off the end either way, a trailer
inside the file but none at its end, an odd length, 8 / 7 / 0 bytes, 16-bit
compare; every mismatch case also checks the OSD bytes (`hosttest_osd`:
SPI_fast, the one buffer frame against `fw/ctrl/charrom.h`'s glyphs of
`FIRMWARE MISMATCH` at line 3, every other byte 0, then `28 01`) and every
boot case that the OSD is not touched; and fw/ctrl's built `RV32OSDB.BIN` (`FWBIN=`, default
`fw/ctrl/build/RV32OSDB.BIN`, skipped with a note when not built) boots with
VERSION = `SDC_VERSION` and stops with `SDC_VERSION + 1`.

`test/minfat_test.c` links `minfat.c` and `swap.c` (gcc, ASan + UBSan) against a
mock `sd_read_sector()` that reads a card image made by `tools/sim/mkcard.sh`.
Images: MBR card with `RV32OSDB.BIN` (3000 random bytes) plus the decoys
`OLDOSDAD.BIN` (a firmware-like name such as the previous `832OSDAD.BIN`)
and `RV32OSDA.BIN` (the previous RISC-V chain's firmware), both ahead of
it in the directory (file loaded byte-identical: the old firmware beside it
is not taken); MBR card without the file, only the decoys (`LoadFile`
returns 0, the decoys are not taken); FAT16 superfloppy (no MBR); FAT32
superfloppy with a 40000-byte file. The names come from
`fw/ctrl/fwname.mk` (`test/Makefile` includes it).
The card path in `spi.c` is not covered by the host tests (it needs the
peripheral); the L2 boot runs (`sim/host_bridge` `boot`, `boot_nofile`,
`boot_mismatch`, `boot_both`: `sdcard_spi.v` with the SD model of `sim/common` on its
pins, CRC on) run the committed ROM on the RTL; the full system (L3,
`sim/l3` `sdc_boot`) is the SD card engine plan's Task 13.
