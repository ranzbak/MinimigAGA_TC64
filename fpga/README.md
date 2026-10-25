# Board ports

Only `openaars/` (the OpenAARS IO board with the QMTech XC7A100T core board,
Vivado, `project_1`) is built and maintained. See the top-level
[README](../README.md) and [doc/building.md](../doc/building.md).

The Quartus ports in `mist/`, `chameleonv1/`, `chameleonv2/`, `de0_nano/`,
`de10_lite/` and `virtual/` are **unsupported**. They share the RTL and are kept
so that the core stays vendor-neutral (plain VHDL/Verilog; Artix-7-specific
parts sit behind switches that default off), but nobody builds them on this
branch and they may not build as they are:

- **CPU:** they were made for the TG68K CPU (the TG68K.C kernel, submodule
  `rtl/tg68k`, now removed; `rtl/soc/tg68.qip` lists only the wrapper). The
  last commit that builds them with it is tag `d3_stable`; the design's CPU is
  now the AP68040 core.
- **OSD host CPU:** the EightThirtyTwo (832) host CPU and its firmware were
  replaced by the VexRiscv RV32IMC (`rtl/host/`, firmware in `fw/ctrl` and
  `fw/ctrl_boot`, `RV32OSDA.BIN` on the SD card; since the SD card
  peripheral `RV32OSDB.BIN`). The 832 files are gone from
  their file lists; `rtl/host/host.qip` now lists the RISC-V host CPU. The last
  commit with the 832 is tag `osd-832-final` (ad6e6cdc).
