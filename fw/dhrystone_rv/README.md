# Dhrystone 2.1 for the RISC-V host CPU (VexRiscv RV32IMC)

The benchmark of `fw/dhrystone_832`, ported to the OSD's RISC-V core:
`dhry.h`, `dhry_1.c`, `dhry_2.c` are copies of `fw/dhrystone_832` at commit
`289a42d` (`git log -1 -- fw/dhrystone_832/dhry_1.c`); `fw/dhrystone_832` itself
is untouched.  Changes to the copies (`dhry_1.c` only; diff it against the 832 file):

- `#include "hw.h"`; `Number_Of_Runs = NUMBER_OF_RUNS` (100 in the L1/L2
  simulation build, 200000 on the board, `-DNUMBER_OF_RUNS=n` overrides);
- `_readMilliseconds()` is `hw_ms()` (cfide TIMER) instead of the 832 TIMER
  trick; `setstack()` (832 stack set-up) removed;
- `hw_stamp(1)` / `hw_stamp(2)` right before / after the timed loop: in the
  simulation build they write the bench's TIME stamp (0xFFFFFF00), so the cycles
  between the two lines `=== TIME 1 cycle n` / `=== TIME 2 cycle m` are the
  result;
- the result checks (`checkparam`, `checksparam`) count what they compare and
  what is wrong ("Result checks: 21 compared, 0 wrong"); a mismatch prints the
  usual `Error <name> is <x> but should be <y>`; `main` returns non-zero and the
  simulation build writes DONE (0xFFFFFF04) with that.

`hw.c` has the cfide UART (0xFFFFFFF0, byte writes without a TX-ready poll:
cfide has no TX-ready bit, it holds the write until the transmitter is free), the TIMER (0xFFFFFFD0; one count = 256 x 643 clk_28 = 5.804 ms),
`printf` (`%d %i %u %x %c %s`) and `strcpy`, `strcmp`, `memcpy`, `memset`
(byte loops, built with the benchmark's -O level, so they are part of the
number).

## Toolchain

xPack `riscv-none-elf-gcc` 15.2.0-1 in `$HOME/opt`: set it up with
`tools/riscv/README.md` (`bash tools/riscv/fetch-xpack.sh`, then
`bash tools/riscv/check-toolchain.sh`).  Ubuntu fallback:
`make RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf-`.

## Build (from the repository root)

    make -C fw/dhrystone_rv          # l1_O2.hex l1_Os.hex l2_O2.hex RV32OSDA.BIN
    make -C fw/dhrystone_rv l1_Os.hex l2_Os.hex     # one target
    make -C fw/dhrystone_rv BOARD_OPT=Os RV32OSDA.BIN

Linked with `fw/ctrl_rv/arch` (`crt0.S`, `trap.S`, `trap.c`, `irq.c`) and its
`firmware.ld` (`_start` at 0x2000, stack top 0x2000).  `l1_*.hex`: the L1
bench image (`sim/rv_l1/build/boot_fw.bin`, the boot ROM stand-in padded to
0x2000, then the firmware; made by `make -C sim/rv_l1 build/boot_fw.bin`,
which this Makefile calls).  `l2_*.hex`: the firmware alone as an SDRAM
preload (`@800` = byte 0x2000).  `RV32OSDA.BIN`: the flat firmware binary the
RISC-V boot ROM loads.

## Run in the simulators

    bash sim/rv_l1/run.sh dhry                  # L1, -O2 and -Os, WS=3 ROMWS=1
    WS=0 RUNTAG=ws0 bash sim/rv_l1/run.sh dhry  # another wait-state setting
    RUNTAG=t13 bash sim/host_bridge/run.sh dhry # L2: real bridge + hostcache + cfide, SLAT 8
    SLAT=20 SJIT=8 DHRY_OPT=Os RUNTAG=t13b bash sim/host_bridge/run.sh dhry

Both print the cycles per 100 runs (between TIME 1 and TIME 2) and fail on any
"should be" line, a nonzero "wrong" count, or a bench failure.
DMIPS/MHz = 1e8 / (cycles per 100 runs x 1757).  Results: `findings/osd-riscv/dhrystone-rv.md`.
The L2 run takes minutes: the UART prints at 115200 baud.

## Run on the board

Needs the RISC-V bitstream (host CPU = VexRiscv, `cpu_riscv`), which does not
exist yet.  Then: `make -C fw/dhrystone_rv RV32OSDA.BIN`, copy `RV32OSDA.BIN` to
the root of the SD card, reset.  The boot ROM loads it and Dhrystone runs 200000
passes (a few seconds) on the serial port; "Dhrystones per Second" and
"VAX MIPS rating * 1000" (= DMIPS x 1000) are printed from the TIMER (5.8 ms
resolution).  `-DNUMBER_OF_RUNS=n` through `make DHEXTRA=...` changes the length.
