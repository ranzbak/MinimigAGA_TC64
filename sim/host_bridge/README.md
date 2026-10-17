# L2 bench: the RISC-V host CPU through the real bridge (xsim)

The L2 bench runs small RISC-V programs from the boot BRAM on the real host
side of the core. The bridge is `EightThirtyTwo_Bridge` with
`cpu_riscv => true`: it holds `rv_hostcpu` + `VexOsd`, `OSDBoot_rv_ROM` (the
test program) and `hostcache.v`. Behind it are the real `cfide` and an SDRAM
model of the host port. It checks six things at the bridge's bus: the byte
lanes, the cfide register offsets, back-to-back hw accesses (the four-phase
handshake), the SPI busy wait, cfide's interrupt through the firmware trap
entry and cfide's interrupt controller (0xFFFFFF30..3C, see
[Interrupt controller](#interrupt-controller)). The boot runs (`run.sh boot`, `boot_nofile`) put the committed boot
ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd` in the bridge and an SD card model
on `sd_cs[1]`: the ROM loads `RV32OSDA.BIN` from a FAT16 card image and runs
it (see [Boot](#boot)).

The L1 bench (`sim/rv_l1`, iverilog) tests `rv_hostcpu` against an abstract
memory. This bench uses Vivado's xsim because `cfide` and the bridge are VHDL.

| File | What it is |
|---|---|
| `tb_host_bridge.v` | Top: bridge + cfide + SDRAM model + SPI slave (or, `-d SDCARD`, the SD card model), bus snoop, checks, verdict |
| `sdram_host_model.v` | 8 MB halfword SDRAM behind hostcache: latency, burst order, `sdram_ctrl` lanes, preload |
| `run.sh` | Copies the RTL, applies the two simulation fixes, builds the ROMs, compiles, runs |
| `Makefile` | Test programs -> `<B>/<test>/OSDBoot_rv_ROM.vhd` (romgen with the `fw/ctrl_boot_rv` ROM template, as the boot ROM) |
| `sw/crt0_rom.S`, `sw/rom.ld` | Start-up (reset at 0x0, trap at 0x20, clear x1-x31, `sp` = 0x2000, `.bss`, `main`, PASS/FAIL on the UART, DONE) and the 8 KB BRAM layout |
| `sw/hb.h`, `sw/check.h` | cfide register offsets, `CHECK` / `STAMP` macros |
| `sw/t_*.S`, `sw/t_*.c`, `sw/t_lanes.sdram.hex` | The six tests; the SDRAM preload of `t_lanes` |
| `sw/reset_fw.S` | Reset, trap at 0x20 and register clear for tests that start through `fw/ctrl_rv/arch/crt0.S` (`t_irq`, `t_irqctl`) |
| `sw/dhry.S` | `dhry`: boot-ROM stand-in for `fw/dhrystone_rv` (clear x1-x31, jump to 0x2000; the firmware is preloaded with `+SDRAM_HEX`) |
| `stub/` | Elaboration check of the bridge's RISC-V branch: `stub/elab.sh` (`rv_debug` 0 and 2, neutral sources only), `stub/elab.sh dmt` (`rv_debug` 1: `VexOsd_DMT` + `rtl/host/xilinx/rv_bscane2.v`, BSCANE2/BUFG from `unisims_ver`), `stub/elab.sh all` |
| `boot/fwtest.c`, `boot/fwfill.S` | Boot runs: the test firmware `RV32OSDA.BIN` (on `fw/ctrl_rv/arch`, `firmware.ld`) |
| `boot/Makefile` | `RV32OSDA.BIN` (padded to 2560 bytes), `img.txt`, the card images `card.img` and `card_nofile.img` (`tools/sim/mkcard.sh`) |
| `boot/expect.txt`, `boot/expect_nofile.txt` | The expected `UART:` / `ERRORCODE:` lines of `boot` and `boot_nofile` |

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
4. Boot runs only: `mtools`, `dosfstools` and `fdisk` for
   `tools/sim/mkcard.sh` (see [`tools/sim/README.md`](../../tools/sim/README.md)).

Run only one xsim at a time.

## Run

From the repository root:

```sh
bash sim/host_bridge/run.sh all       # 6 tests x SLAT {2,8,20} x SJIT {0,8}: 36 runs, ~5 min
bash sim/host_bridge/run.sh mutant    # the four-phase handshake's teeth, 34 runs
bash sim/host_bridge/run.sh irqmut    # the interrupt controller's teeth, 4 runs, ~2 min
```

`all` ends with `=== ALL PASS (36 runs)` (exit 0) or `=== SOME FAILED`
(exit 1). `mutant` ends with `=== MUTANT CAUGHT ...` (exit 0) or
`=== MUTANT SURVIVED or CONTROL FAILED` (exit 1). `irqmut` ends with
`=== IRQ MUTANTS CAUGHT ...` (exit 0) or `=== IRQ MUTANT SURVIVED or CONTROL
FAILED` (exit 1); see [Interrupt controller](#interrupt-controller).

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

## Boot

`run.sh boot` is the end-to-end boot in L2: the committed boot ROM
`fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd` (compiled as it is, VHDL-93, not a run
copy) initialises the SD card model at the slow SPI clock, reads the MBR,
the boot sector and the root directory of an 8 MB FAT16 card image, loads
`RV32OSDA.BIN` to 0x2000 through dBus + hostcache, runs `fence.i` and jumps
there. The firmware (`boot/fwtest.c` on `fw/ctrl_rv/arch`) prints `FW OK`,
the `PAT` and `IMG` lines and runs the `t_irq` check with cfide's `vbl_int`.
`run.sh boot_nofile` boots a card without `RV32OSDA.BIN`: the error path.

From the repository root:

```sh
# 1. the boot ROM (committed; a rebuild gives the same file, git shows no change)
make -C fw/ctrl_boot_rv
git status --short fw/ctrl_boot_rv
# 2. the test firmware and the card images, into sim/host_bridge/boot/build
#    (run.sh builds its own copy into run_*/boot)
make -C sim/host_bridge/boot
# 3. the two runs, one after the other (about 90 s and 190 s of xsim)
RUNTAG=boot bash sim/host_bridge/run.sh boot
RUNTAG=bootn bash sim/host_bridge/run.sh boot_nofile
```

Expected end of `boot`:

```
boot ROM: fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd unmodified (= git HEAD), sha256 7fc4ae53fed88cb3
=== BOOT first read of 0x2000 at cycle 12392735, irefill 95 dread 5338 dwrite 7779 so far
=== HW accesses 11714, stale acks 0, X 0, SDRAM reads 191 writes 683, main done 79381, cycles 13134513
=== STATS irefill 120 dread 7986 dwrite 8326 busy_cycles 12931583 (rv_hostcpu, whole run)
=== SD card: 1 ErrorCode calls, last 0fff
ok   log = expect.txt (14 lines)
ok   bench verdict: === PASS
xsim wall time 92 s
=== boot PASS
```

Expected end of `boot_nofile`:

```
boot ROM: fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd unmodified (= git HEAD), sha256 7fc4ae53fed88cb3
=== cycle limit 27000000 reached, no DONE
=== HW accesses 38280, stale acks 0, X 0, SDRAM reads 0 writes 22, main done 79381, cycles 27000177
=== STATS irefill 102 dread 20557 dwrite 26396 busy_cycles 26364108 (rv_hostcpu, whole run)
=== SD card: 2 ErrorCode calls, last 00f0
ok   log = expect_nofile.txt (45 lines)
ok   bench verdict: === PASS
xsim wall time 192 s
=== boot_nofile PASS
```

The exit code is 0 on PASS, 1 otherwise. Each run leaves in
`run_<RUNTAG>/`: `results.txt`, the log `tb_boot_x0_s8_j0.log`
(`tb_boot_nofile_...` for the other), `boot.expect` / `boot.got` /
`boot.diff`, and `boot/` (firmware, `img.txt`, card images). The sha256
prefix changes with the committed ROM; the cycle numbers change with the
RTL, the ROM and the firmware.

The gate (`run.sh`): every `UART:` and `ERRORCODE:` line of the log equals
`boot/expect.txt` (or `boot/expect_nofile.txt`) line for line, `@IMG@`
replaced by `<run>/boot/img.txt`; no `TRAP`/`EXC` on the UART; the SD model
loaded the image; the bench verdict is `=== PASS` (`boot`: DONE = 0, no bench
error; `boot_nofile`: no DONE before the cycle limit, no bench error, last
ErrorCode `00f0`).

### What the log shows

```
ERRORCODE: 0fff
UART: Initializing SD card
UART: 0101cmd_CMD8 response: 1
UART: 01010101010000Hunting for partition
UART: Reading MBR
UART: 00Partitioncount 1
UART: Reading boot sector 2048
UART: 00Read boot sector from first partition
UART: Hunting for filesystem
UART: Reading directory sector 2106
UART: 00file "RV32OSDABIN" found\r000000000000FW OK
UART: PAT 00112233445566778899AABBCCDDEEFF
UART: IMG 00000900 F8431F18
UART: IRQ 20
```

- `ERRORCODE: hhll` is the bench's, not the UART's: printed when the ROM's
  `ErrorCode()` releases the chipset (OSD bytes `08 00` under `sd_cs[5]`);
  `hhll` is the SDRAM halfword at 0x10000A that the 68k boot code would
  show. `0fff` = "booting"; `boot_nofile` adds `00f0` after
  `Can't load firmware` (partition found, file not).
- The pairs of digits are the R1 response of every SD command (the ROM's
  `cmd_write` prints them): `01` CMD0, `01` CMD8; then CMD55/ACMD41 three
  times (`01 01`, `01 01`, `01 00`: the model answers "idle" twice,
  `+SD_INIT_POLLS=2`) and CMD58 `00`; one `00` per sector read (CMD17).
- After `found\r` (the ROM's `printf` ends that line with a carriage return,
  which the bench prints as `\r`): six reads, the five sectors of
  `RV32OSDA.BIN` and one FAT sector (the file starts at cluster 4 behind the
  decoy `832OSDAD.BIN`; clusters are 2 sectors, so the ROM follows the
  chain twice). The Makefile pads the image to 2560 bytes so that this
  count does not move with the code size.
- `Reading directory sector 2106` and the layout depend on `mkfs.fat`
  (dosfstools 4.2 here: 2 reserved sectors, two FATs of 28 sectors, 32 root
  directory sectors). Another version can move these numbers.

What it proves:

- **Load, then execute, on the real bus**: the first proof on the real
  bus of the path dBus write -> hostcache -> SDRAM -> iBus refill. The ROM
  writes the image into SDRAM through the data side, runs `fence.i` and
  jumps; `FW OK` is printed by that code, fetched by I-cache refills. This
  does **not** exercise `fence.i`'s invalidation: the I-cache never held a
  line of the image region before the jump (`=== BOOT` is the first bus
  read of 0x2000 at all, and the ROM reads nothing back), so the run would
  pass without the `fence.i`. The invalidation itself is proven in L1 by
  `sim/rv_l1`'s `fencei` test, whose `-DNO_FENCEI` variant
  (`fencei_nofencei`) must FAIL.
- **`spi.c` `be32()`**: `SPI_PUMP()` assembles 4 card bytes big-endian and
  the ROM stores `be32()` of it, so the bytes land in file order on the
  little-endian CPU. If the order were wrong, the instructions at 0x2000
  would be byte-swapped and nothing would print; explicitly, `PAT` prints
  `fw_pattern[]` byte by byte in file order and the firmware fails with exit
  code 1 if the word view is not little-endian (`0x33221100`, ...).
- **The whole image**: `IMG <len> <sum>` is the word sum of `.text` +
  `.rodata` (0x2000 .. `__init_array_start`, 0x900 bytes over all three
  clusters) as loaded; `img.txt` is the same sum over the file. A run with a
  card that has one bit flipped at file offset 0x880 (third cluster) fails
  with only that line different (`IMG 00000900 F8431F19`), recorded
  2026-10-16. Use `BOOT_CARD=<image>` for such a run; the path may be up to
  1024 characters (the model's `+SD_IMG` buffer; `run.sh` refuses a longer
  one, and the model ends the run with `=== FAIL` if it cannot open the
  file).
- **The file name**: `card.img` has the decoy `832OSDAD.BIN` first in the
  directory; `card_nofile.img` has `832OSDAD.BIN` and the real firmware
  under the near-miss name `RV32OSDB.BIN`. The ROM loads neither.

### Measured (2026-10-17, SLAT=8 SJIT=0, boot ROM with the x1-x31 clear)

| | `boot` | `boot_nofile` |
|---|---|---|
| SD init (`SPI_slow`, SPEED `0xEF`: 7664 `clk_114` per byte; five `spi_spin()` of 200 bytes = 7.7 M) | from cycle 79,255 (`ErrorCode(0xfff)`) to 9,145,941 (`Hunting for partition`): 9.07 M | the same |
| one sector read at `SPI_fast` (SPEED 7) | about 140 k cycles | |
| jump to 0x2000 (first CPU read there) | cycle 12,392,735 (109 ms at 113.44 MHz) | (no jump) |
| `ErrorCode(0x0f0)` | | cycle 26,036,915 (32 root directory sectors read and printed) |
| end | DONE at 13,134,513 | cycle limit 27,000,000 |
| I$ refills (`RV_HOSTCPU_STATS`) | 95 up to the jump, 120 in all | 102 |
| xsim wall time | 92 s | 192 s |

The UART costs about 9,900 `clk_114` per character (115200 baud from
`clk_28`): the boot ROM's 307 characters are about 3.0 M of the 12.4 M. The
bench snoops UART writes at the bridge, and cfide holds a UART write until
the transmitter takes it, so no character is lost and no TX-ready poll is
needed. There is no TX-ready bit to poll: cfide never acks a UART read (its
support state machine serves UART writes only), so a read of `0xFFFFFFF0`
would hang the CPU.

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
  from checkpoint 1, see the test table) and `t_irqctl`.
- **amiga_req**, **i2c_ext_int**, **irq_src[15:4]**: interrupt controller
  sources 2, 3 and 4..15, 0 except in `t_irqctl` (pulses and held levels per
  checkpoint, see [Interrupt controller](#interrupt-controller)). cfide's
  I2C transfer event (source 1) is 0: the bench builds cfide with `havei2c`
  false.
- **SPI slave**: active while `sd_cs[1]` is low. In the boot runs (bench
  compiled with `-d SDCARD`) the SD card model `sim/common/sd_spi_model.v`
  (`IMG_SECTORS = 16384`, the 8 MB card) drives MISO instead; the slave
  still logs the bytes.
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
    `hw_req` (re-armed when `hw_req` rises and when an access completes).
  - **SPI accept**: a write to SPI DATA completed although cfide never
    accepted it. Accepted means a `clk_114` edge with req, wr, SPI DATA and
    `SD_busy = 0`; `SD_busy` is read hierarchically from cfide.
  - **X on the bus**: X in the read data the bridge returns, or in a byte that
    is written (the bytes `sel` enables for SDRAM/BRAM; for a hw access the
    16 bits `q[15:0]` that cfide takes, whatever `sel` says). The core
    treats an X branch condition as not taken, so a CPU check against X data
    would pass.
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
| `+SDRAM_HEX=<file>` | none | preload, `$readmemh` of BE 32-bit words, `@` = word address; first 1 MB (`run.sh` passes `sw/<test>.sdram.hex` if it exists); path up to 1024 characters, a file that cannot be opened ends the run with `=== FAIL` |
| `+TIMEOUT=<n>` | 3000000 | `clk_114` cycles until `=== FAIL timeout` |
| `+VERBOSE=1` / `2` | 0 | log hw accesses and SPI bytes / also every change of the bus address |
| `+SD_IMG=<file>` | none | card image of the SD model (bench compiled with `-d SDCARD`); the model's other plusargs (`+SD_NCR`, `+SD_INIT_POLLS`, `+SD_LOG=1`, ...) are in `sim/common/sd_spi_model.v`. The `=== BOOT` / `=== STATS` counters need `-d RV_HOSTCPU_STATS` on both `rv_hostcpu.v` and the bench (hierarchical `hostcpu.genrv.myrv.st_*`); without it the bench leaves them out. `run.sh boot` sets both. |

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
| `t_irqctl` | Started as `t_irq`. The interrupt controller, tests 1..7 and 9..12 of [Interrupt controller](#interrupt-controller): reset values, the legacy 0xFFFFFFA0 path, one event per edge, masking, "set wins", level sources, LEVEL mode, mode switching, read-back, the ADV7511 INT pin. Exit code 100 * test + check. | The STAMP commands of the table there (pulses, held levels, the interrupt output); test 4 is checked by the bench. |
| `t_irqapi` | Started as `t_irq`. The firmware interrupt-controller API of `fw/ctrl_rv/arch/irq.h` against the real controller: legacy `SetIntHandler` path without the dispatcher, vblank handler (8 pulses), dispatch order (bit 0 first), masked EDGE delivered on `IrqEnable`, NULL handler, LEVEL bits 8 and 3 handled until the handler drops the line (called 2..3 times), `IrqEnable` / `IrqDisable` / `IrqSetMode` read-modify-write, bits >= 16 ignored. Exit code 100 * test + check. | The `t_irqctl` STAMP commands 10, 20, 30, 50, 60/61, 70, 120/121 (pulses and held levels). |
| `t_spibusy` | `SPI_slow()` (SPEED `0xEF`, about 7700 `clk_114` per byte), CS `0x02`, 8 straight-line `sb` to SPI DATA (`01 80 55 AA FF 00 3C C3`), then a DATA read (`0x1C`, the 8th MISO byte), then CS `0x03`. | The slave got the 8 bytes in order. At least 7 DATA writes found `SD_busy` high. No DATA write completed without cfide accepting it. |
| `boot` | The committed boot ROM loads `RV32OSDA.BIN` (`boot/fwtest.c`) from `card.img`; the firmware prints `FW OK`, `PAT`, `IMG`, runs the `t_irq` check, prints `IRQ 20`, writes DONE. Not in `all`; see [Boot](#boot). | STAMP 1/2 as `t_irq`; `ERRORCODE:` lines; `=== BOOT`, `=== STATS`. |
| `boot_nofile` | The same ROM with `card_nofile.img`: `Can't load firmware`, `ErrorCode(0x0f0)`, retry. Not in `all`. | No DONE before the cycle limit; last ErrorCode `00f0`. |

## Interrupt controller

cfide's interrupt controller (`rtl/host/cfide.vhd`, process after the legacy
INTERRUPT register) at `0xFFFFFF30..3C`, 16-bit registers on `clk_28`:

| Address | Register | Read | Write |
|---|---|---|---|
| `0xFFFFFF30` | `IRQ_PENDING` | PENDING and MASK; clears the EDGE-mode bits it returns, once per access | no effect |
| `0xFFFFFF34` | `IRQ_MASK` | MASK | MASK (reset 0) |
| `0xFFFFFF38` | `IRQ_RAW` | the synchronised source levels, no side effect | no effect |
| `0xFFFFFF3C` | `IRQ_MODE` | MODE | MODE (reset 0); per bit 0 = EDGE, 1 = LEVEL |

Sources:

| Bit | cfide signal | What |
|---|---|---|
| 0 | `vbl_int` | vertical blank (pulse) |
| 1 | `i2c_int` | the I2C master's transfer event (`i2c_master_mmio` `r_interrupt`): set by its transfer events, cleared only by an access to the legacy `0xFFFFFFA0` window |
| 2 | `amiga_req` | Akiko request (pulse per request) |
| 3 | `i2c_ext_int` | the ADV7511's INT pin (also I2C status bit 0x400). Active high as the part is set up: `fw/ctrl_832/adv7511.c` writes no polarity register, clearing the part's interrupt flags takes the pin low (ADV7511 Programming Guide), and `i2c_master_mmio` and the 832 firmware use it active high; no inversion. Meant for LEVEL mode |
| 4..15 | `irq_src` | spare, new port (default 0), for IDE / floppy later |

Each bit has a 2-FF synchroniser into `clk_28`.
In EDGE mode a rising edge sets the bit and a read that returns it clears
it; an edge in the clear cycle wins. In LEVEL mode the bit is the
synchronised level, and a read does not clear it. The bit's EDGE latch is
held clear while it is in LEVEL mode: LEVEL -> EDGE with the line high
starts the bit clear (it needs a new rising edge), and EDGE -> LEVEL drops an
unread event. cfide's `interrupt` is the legacy flag OR (PENDING and MASK)
/= 0. With MASK = MODE = 0 (reset) the legacy register `0xFFFFFFA0` behaves
exactly as before. `irq_seen` (req one `clk_28` cycle earlier) marks the
first cycle of an access: the read value is latched there and the bits are
cleared there only. That guard is defensive and untested: with the current
bridge every hw access is seen by exactly one `clk_28` edge.

`t_irqctl` (`sw/t_irqctl.c`, the bench's `t_irqctl` block) runs these tests
in order; the bench acts on the program's STAMPs:

| Test | Program | STAMP: bench action |
|---|---|---|
| 1 | MASK, PENDING, RAW, MODE read 0 after reset; with MASK = 0xFFFF PENDING is still 0. Legacy: `EnableInterrupts()`, one vblank pulse, exactly one interrupt (the handler's PENDING read returns 0, MASK = 0). | 10: one `vbl_int` pulse (one `clk_28` cycle) |
| 2 | Legacy off, MASK = bit 0: 8 pulses give 8 interrupts; each time the handler reads PENDING = 0x0001, then 0. | 20: 8 pulses, 2000 `clk_114` apart |
| 3 | MASK = 0x0025: one interrupt, the read returns 0x0025, the next 0. | 30: `vbl_int` + `irq_src[5]` in one `clk_28` cycle, `amiga_req` high one cycle later for 4 cycles |
| 4 | "Set wins", polled (interrupts off, MASK = bit 6), 25 iterations: STAMP 40, four RAW reads, r1 = PENDING, wait, r2, r3. | 40: an `irq_src[6]` pulse at once (r1 returns it), a second one placed against r1's clear (below); 41: coverage |
| 5 | MASK = bit 0: a bit 7 event raises no interrupt, PENDING reads 0; MASK = 0x0081 raises it, the handler reads 0x0080, then 0. | 50: `irq_src[7]` pulse |
| 6 | MASK = bit 8, line held high: one interrupt, no second one while high, RAW = 0x0100, PENDING = 0; low, then high again: a second interrupt. | 60 / 61: `irq_src[8]` high / low |
| 7 | MASK = bit 9, a bit 9 event, interrupts off: three RAW reads, writes of 0xFFFF to PENDING and RAW; MASK and MODE unchanged; with MASK = 0xFFFF PENDING returns exactly 0x0200, then 0. | 70: `irq_src[9]` pulse |
| 9 | MODE = MASK = bit 9 (LEVEL), line high: PENDING returns 0x0200 on four reads, `mip.MEIP` stays 1; then taken as an interrupt (the handler reads 0x0200 twice and masks it off); line low: PENDING 0, `mip.MEIP` 0. | 90 / 91: `irq_src[9]` high / low; 92 / 93: cfide's `interrupt` must be 1 / 0 |
| 10 | Bit 10, line high: EDGE gives one event; -> LEVEL: PENDING follows the line (0x0400 twice); -> EDGE: 0, also later; low and high: a new event. An unread EDGE event, line low, -> LEVEL: 0; -> EDGE: 0. | 100 / 101: `irq_src[10]` high / low; 102: pulse |
| 11 | MODE 0xA5C3 and 0x5A3C, MASK 0x5A3C and 0 read back. | |
| 12 | Bit 3, the ADV7511 INT pin. EDGE, MASK = bit 3, pin held high: one interrupt (0x0008, then 0), none more, RAW = 0x0008; pin low: RAW 0. LEVEL, interrupts off: PENDING 0x0008 on two reads, `mip.MEIP` 1; pin low: PENDING 0, `mip.MEIP` 0. | 120 / 121: `i2c_ext_int` high / low; 92 / 93 as test 9 |
| | end | 99: every action was taken (10 vblank pulses, 25 test 4 iterations) |

Test 4 in detail: the first pulse sets bit 6 before r1, so r1 returns and
clears it. The bench samples cfide 1 ns after every `clk_28` edge: the edge
where `irq_seen` rises on r1 (the clear) and the edges where bit 6's edge
detector fires (`irq_prev[6]` rises). Iteration 1 places the second pulse
late (STAMP + 300) and measures the distance d from STAMP to the clear;
iterations 2..25 raise it at STAMP + d - 10 + (-6..5) `clk_114`, which moves
the second edge from before the clear, through the clear cycle, to after
it. The bench checks the snooped read data: r1 = 0x0040, r2 = 0x0040 when
the second edge is in or after the clear cycle (else 0, the two events
merged), r3 = 0; at least two iterations must hit the clear cycle and at
least one fall on each side. A run prints one line per iteration and the
summary, e.g. (SLAT=8, EXTRA_WS 0 and 3):

```
t_irqctl test 4 iteration 18: second pulse at STAMP+28, clear at STAMP+40, its edge at STAMP+40 (SAME CYCLE), reads 0040 0040 0000
t_irqctl test 4: 25 iterations, second edge before / in / after the clear cycle: 7 / 8 / 10
```

`run.sh irqmut` (test 8) runs `t_irqctl` (SLAT=8, SJIT=0, EXTRA_WS=0) on
three run copies of `cfide.vhd` and on the real one:

| Run | cfide | Expected |
|---|---|---|
| mutant a | the `-- IRQ SET WINS` line: a PENDING read clears all of PENDING and drops that cycle's edges | FAIL with `BENCH ERROR ... t_irqctl test 4 (set wins)` |
| mutant b | the same line: the read cycle clears the returned bits and drops that cycle's edges (only "set wins" is gone) | FAIL with `BENCH ERROR ... t_irqctl test 4 (set wins)` |
| mutant c | the `-- IRQ MODE MUX` line: PENDING ignores MODE | FAIL with DONE code 9xx (test 9) |
| control | the real `cfide.vhd` | PASS |

Expected output (2026-10-17):

```
ok   gate    cfide mutant a: t_irqctl SLAT=8 SJIT=0 EXTRA_WS=0: === FAIL code 504, bench errors 9 (...)
ok   mutant a fails test 4 in 8 iterations
ok   gate    cfide mutant b: t_irqctl SLAT=8 SJIT=0 EXTRA_WS=0: === FAIL code 0, bench errors 8 (...)
ok   mutant b fails test 4 in 8 iterations
ok   gate    cfide mutant c: t_irqctl SLAT=8 SJIT=0 EXTRA_WS=0: === FAIL code 904, bench errors 1 (...)
ok   mutant c fails in test 9
ok   control real cfide: t_irqctl SLAT=8 SJIT=0 EXTRA_WS=0: === PASS (...)
=== IRQ MUTANTS CAUGHT (3 mutants FAIL where expected, control PASS)
```

Mutant a also loses the masked bit 7 event (DONE code 504); mutant b passes
every CPU check (r2 = 0 is a legal value on its own), only the bench's
per-iteration expectation catches it.

To run the test at the gate settings:

```sh
RUNTAG=irqctl bash sim/host_bridge/run.sh t_irqctl                 # SLAT=8 EXTRA_WS=0
RUNTAG=irqctl3 EXTRA_WS=3 bash sim/host_bridge/run.sh t_irqctl     # EXTRA_WS=3
RUNTAG=irqmut bash sim/host_bridge/run.sh irqmut
```

Firmware rule: put level sources (bit 3 ADV7511 INT, IDE requests; bit 1
the I2C transfer flag, whose handler must access `0xFFFFFFA0` to clear it)
in LEVEL mode. The interrupt then stays asserted until the device is
serviced, so no IRQ_RAW re-check is needed. Pulse sources (vblank, Akiko)
stay EDGE. A debugger that reads IRQ_PENDING consumes pending EDGE bits.

- A LEVEL source that the handler cannot service in interrupt context can be
  masked off until it is serviced (test 9 does this).
- The 2-FF synchroniser delays a LEVEL bit's fall by up to 3 `clk_28` cycles
  after the device drops its line. A handler that returns at once may be
  called one extra time with the bit still set, and must tolerate that.

## Simulation fixes (run copies only)

`run.sh` copies the RTL into `run_*/src` and changes only those copies. These
are the only run-copy patches in force (besides the mutants of `mutant` and
`irqmut`, which are separate files next to the copies); everything else (cfide, the bridge,
`rv_hostcpu`, `VexOsd`, the boot ROM) is simulated as committed:

- `hostcache.v`: `ack <= #1 1'b0` becomes `ack <= 1'b0`, as in
  `host832/run.sh`. With the delay, the ack is a 1 ns glitch that the bridge
  never sees.
- `hostcache.v` and `dpram_inf_generic.v`: a `` `timescale `` line is added,
  to avoid an xelab warning.

Earlier patches that are gone (2026-10-16):

- `cfide.vhd` `timecnt` / `clkgen`: they have no reset, and in simulation
  stayed `'U'` (TIMER never counted, the UART never shifted). The RTL now
  declares both with the initial value 0, the FPGA's power-up value.
- `VexOsd.v` register file (it starts X in simulation): every program clears
  x1-x31 at reset instead: `fw/ctrl_boot_rv/crt0.S` (the committed boot ROM),
  `sw/crt0_rom.S`, `sw/reset_fw.S`, `sw/dhry.S`.
- Port B of the test ROMs: they were built from the `fw/ctrl_boot_832`
  template, whose RAM signal has a driver in each port's process (every
  port-A write resolved to X). They now use the `fw/ctrl_boot_rv` template
  (a shared variable), as the boot ROM does; `run.sh` refuses a ROM built
  from another template.

## Why the mutant needs the fast master

`run.sh mutant` runs `t_b2b` three ways:

| Leg | Bridge | Master | Expected |
|---|---|---|---|
| gate | mutant: the `-- 4PHASE` line becomes `state <= waiting;` (two-phase) | fast master, `EXTRA_WS=0` | every run `=== FAIL` (stale acks, lost writes) |
| control | real (four-phase) | fast master, `EXTRA_WS` 0, 1, 2 and 3 | every run `=== PASS` (24 runs) |
| info | mutant | real `rv_hostcpu` (`EXTRA_WS=0`); fast master with `EXTRA_WS` 1, 2, 3 | printed only, one run each |

`EXTRA_WS` delays every request by 0..3 `clk_114` cycles, so the control leg
starts the next hw request at each of the four `clk_114` phases of `clk_28`:
the four-phase bridge must take no stale ack at any of them. With
`EXTRA_WS` 1..3 even the fast master's request rises at or after the next
`clk_28` edge, so the mutant is expected to survive there; that is why those
runs are info only.

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
