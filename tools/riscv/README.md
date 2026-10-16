# RISC-V toolchain for the OSD host CPU (VexRiscv RV32IMC)

Pinned: xPack `riscv-none-elf-gcc` **15.2.0-1** (GCC 15.2.0, binutils 2.45,
newlib 4.5.0), installed outside the repo at
`$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1`.

- tarball: `https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz`
- sha256: `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758`
  (matched on download, 2026-10-16)

All commands run from the repository root.

## 1. Prerequisites

    sudo apt install curl coreutils tar make        # curl, sha256sum, tar, make
    # optional, only for install option B: xpm (xPack package manager, needs node/npm)
    sudo npm install --global xpm

## 2. Install the toolchain

### Option A: fetch-xpack.sh (default, hash-pinned)

    bash tools/riscv/fetch-xpack.sh            # installs to $HOME/opt
    bash tools/riscv/fetch-xpack.sh /some/dir  # or another destination

Downloads about 413 MB, verifies the sha256 (exit 2 and nothing installed on a
mismatch), unpacks, and refuses to overwrite an existing directory. The default
`RV_GCC_DIR` matches this location, so no further setup is needed.

### Option B: xpm global install (alternative)

    xpm install --global @xpack-dev-tools/riscv-none-elf-gcc@15.2.0-1.1
    xpm list --global                          # shows the install path
    export RV_GCC_DIR=$HOME/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/15.2.0-1.1/.content

The `RV_GCC_DIR` path above is the xpm default layout and was not exercised
here; confirm it with `xpm list --global` (the directory holding `bin/`).
This install is not covered by our sha256 pin.

### Option C: Ubuntu fallback (GCC 13.2)

    sudo apt install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf picolibc-riscv64-unknown-elf
    export RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf-

Tested with 13.2.0-11ubuntu1+12 and picolibc 1.8.6. It has no `rv32imc`
multilib, so `check-toolchain.sh` fails check 1a (see Results).

## 3. Verify

    bash tools/riscv/check-toolchain.sh        # exit 0 = OK
    RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf- bash tools/riscv/check-toolchain.sh

Expected output with the xPack toolchain:

    using /home/<you>/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc
    riscv-none-elf-gcc (xPack GNU RISC-V Embedded GCC x86_64) 15.2.0
    OK   1a RV_ARCH -> rv32imc/ilp32
    OK   1b RV_ARCH_IM -> rv32im/ilp32
    OK   2a libgcc has no 16-bit insns (.../rv32im/ilp32/libgcc.a)
    OK   2b libgcc has no lr/sc/amo
    OK   3 compile+link -march=rv32imc_zicsr_zifencei -mabi=ilp32
    OK   3 compile+link -march=rv32im_zicsr_zifencei -mabi=ilp32

## 4. Use from a Makefile

    include $(TOP)/tools/riscv/toolchain.mk

    prog.elf: prog.c
    	$(RV_CC) $(RV_CFLAGS_FW) -o $@ $< $(RV_LDFLAGS_FW) $(RV_LIBS_FW)

Variables: `RV_GCC_DIR`, `RV_PREFIX`, `RV_CC/AS/LD/OBJCOPY/OBJDUMP/SIZE`
(full paths), `RV_ARCH` (`-march=rv32imc_zicsr_zifencei -mabi=ilp32`),
`RV_ARCH_IM` (`-march=rv32im_zicsr_zifencei -mabi=ilp32`), `RV_CFLAGS_FW`,
`RV_LDFLAGS_FW`, `RV_LIBS_FW` (`-lgcc`, last on the link line).
`RV_GCC_DIR` and `RV_PREFIX` use `?=`, so override them in the environment or
on the make command line:

    make RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf-
    RV_GCC_DIR=$HOME/other/gcc make

## Results recorded

- xPack 15.2.0-1: all checks OK. Multilibs include rv32i, rv32im, rv32imc,
  rv32iac, rv32ia, rv32imf, rv32imfd, rv32imafc, rv32imafdc (ilp32/ilp32f/
  ilp32d), the rv32e set and the rv64 set.
- Ubuntu 13.2: fails check 1a only. `RV_ARCH` resolves to the `rv32im/ilp32`
  multilib (no compressed libgcc/libc; the code still runs on an RVC core).
  Checks 1b, 2a, 2b and 3 pass. Fine for tests, not for code-size budgets.

## Do not use the CH32V build in `~/bin`

`~/bin/riscv32-unknown-elf-gcc` (14.2) is a CH32V rv32imac-only build with no
multilibs and may be first on `PATH`. `toolchain.mk` always uses full paths
from `RV_GCC_DIR`, so never call a bare `riscv*-gcc` from a Makefile or script.
