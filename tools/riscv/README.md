# RISC-V toolchain (OSD host CPU, VexRiscv RV32IMC)

Pinned: xPack `riscv-none-elf-gcc` **15.2.0-1** (GCC 15.2.0, binutils 2.45,
newlib 4.5.0), installed outside the repo at
`$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1`.

- tarball: `https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz`
- sha256: `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758` (verified on download, 2026-10-16)

## Files

- `toolchain.mk` - include from every Makefile. Variables: `RV_GCC_DIR`,
  `RV_PREFIX`, `RV_CC/AS/LD/OBJCOPY/OBJDUMP/SIZE` (full paths),
  `RV_ARCH` (`-march=rv32imc_zicsr_zifencei -mabi=ilp32`), `RV_ARCH_IM`
  (`-march=rv32im_zicsr_zifencei -mabi=ilp32`), `RV_CFLAGS_FW`,
  `RV_LDFLAGS_FW`, `RV_LIBS_FW` (`-lgcc`, put last on the link line).
- `fetch-xpack.sh [dest]` - download (default `$HOME/opt`), verify sha256,
  unpack; refuses to overwrite an existing directory.
- `check-toolchain.sh` - exit 0 = OK. Checks multilib selection
  (`rv32imc/ilp32`, `rv32im/ilp32`), that the rv32im `libgcc.a` has no 16-bit
  or lr/sc/amo instructions, and that csrr/fence.i inline asm compiles and
  links for both arch strings.

## Use

    bash tools/riscv/fetch-xpack.sh && bash tools/riscv/check-toolchain.sh

Multilibs of the xPack build include `rv32i`, `rv32im`, `rv32imc`, `rv32iac`,
`rv32ia`, `rv32imf`, `rv32imfd`, `rv32imafc`, `rv32imafdc` (ilp32/ilp32f/ilp32d),
the `rv32e*` set and the rv64 set.

## Overrides

    # Ubuntu fallback (gcc 13.2, picolibc)
    RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf- make ...

    # xpm install (alternative to fetch-xpack.sh; default path and pin unchanged)
    xpm install --global @xpack-dev-tools/riscv-none-elf-gcc@15.2.0-1.1
    RV_GCC_DIR=$HOME/.local/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/15.2.0-1.1/.content make ...
    # (verify the exact xPacks path with: xpm list --global; the xpm build is
    #  not hash-pinned by us - rerun check-toolchain.sh with that RV_GCC_DIR)

## Results recorded

- xPack 15.2.0-1: all checks OK (1a, 1b, 2a, 2b, 3 for both arch strings).
- Ubuntu fallback (riscv64-unknown-elf-gcc 13.2.0): FAILS check 1a only.
  It has no `rv32imc` multilib, so `RV_ARCH` falls back to `rv32im/ilp32`
  (libgcc without compressed code; still links and runs on an RVC core).
  Checks 1b, 2a, 2b and 3 pass. Acceptable for tests that do not need
  size-optimal RVC libgcc; do not use it for the boot ROM size budget.

## Do not use

`~/bin/riscv32-unknown-elf-gcc` (14.2) is a CH32V rv32imac-only build with no
multilibs. It may be first on `PATH`; the makefiles use full paths from
`RV_GCC_DIR`, so it is never picked up by accident.
