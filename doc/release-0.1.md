# Release 0.1 (QMTech XC7A100T, AP68040-pipelined)

Release 0.1: the first release of the pipelined 68040 core (MMU and FPU) on the QMTech
XC7A100T board (fpga/openaars). Only this board is built from this tree.

## What is in it

- CPU: lib/AP68040-pipelined at 3ec6ad1, built with the store buffer,
  store-to-load forwarding, the return-address stack, address-precise fast
  reads, posted stores with the MMU on (SB_MMU) and **BTFN** (forward
  conditional branches guessed not taken). The copyback data cache is **not**
  built in (COPYBACK=0; see Known issues).
- Since the previous stable image (stage_cu9):
  - six core fixes found by WinUAE cputest on the board
    (findings/ap040-pipelined/tests/cputest/board/README.md);
  - BTFN: +8 % with write-through, measured on the board;
  - the chipset snoop is registered on the CPU clock (timing of the snoop
    crossing; no functional change);
  - the boot firmware ROM matches its committed sources, and the committed
    rom_prologue.vhd parses again;
  - one version header (fpga/openaars/minimig_version.vh): the OSD shows
    26.10.02, the build date of this release;
  - rebuild.tcl recreates project_1 from a fresh clone.

## Performance

xSysInfo on the board, same core with the copyback hardware off: **1.10,
36,256 Dhrystones** (stage_cu9: 1.00-1.03, about 33,300). The 68040 at
25 MHz is 1.00; this core runs at 37.8 MHz. Where the remaining clocks go
per instruction: findings/loadstore/plan.md section 11.

## Building

Vivado 2023.2. From a fresh clone with submodules:

```
git clone --recurse-submodules https://github.com/ranzbak/MinimigAGA_TC64.git
cd MinimigAGA_TC64
vivado -mode batch -source rebuild.tcl
STORE_BUF=1 FWD=1 RAS=1 PRECISE=1 SB_MMU=1 COPYBACK=0 BTB=0 LDX=0 BTFN=1 \
MISPLIT=0 IMPL_EFFORT=high AP040_PIPE_MMU=1 AP040_PIPE_FPU=1 \
vivado -mode batch -source tools/vivado/build_ap040.tcl -tclargs build/release_26.10.02 0
```

This exact sequence, run on a clean clone of this tree, produced the
release bitstream (md5 dabd362b66d669bff3bed3f5fd165e8a). Timing: clk_38
+0.444 ns, clk_114 +0.205 ns, clk_114 -> clk_38 +0.292 ns; the one failing
path is the SDRAM input path (clk_gen_sdram -> clk_114, -0.448 ns), present
in every build since stage_cu9.

## Known issues

There are still issues to address, hence 0.1. Written down with what is known and the first step in doc/backlog.md:

- HDMI: some RTG modes do not sync; demos that flash a lot can make the
  monitor lose sync (from the HDMI work of 2026-09-25..27).
- Static artifacts in the border after a resolution change.
- A corrupted 832 firmware survives the reset button (power cycle needed);
  the SD card can disappear after Ctrl-Amiga-Amiga (an OSD menu reboot
  brings it back).
- Copyback (CopyBack via MuSetCacheMode) is not supported: it was unstable
  under disk load and is not built into this release.
- The serial port runs at about 112 baud.
- With only the DDR3 board configured, AmigaOS sees 10 MB.
- A rare interrupt-timing deviation found by the fuzzer (an interrupt taken
  one instruction late).
