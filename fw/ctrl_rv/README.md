# fw/ctrl_rv - OSD / host firmware for the VexRiscv host CPU

Port of `fw/ctrl_832` (ZPU-class 832 host CPU) to RV32IMC. This commit is the
**verbatim copy**: no copied file has been edited, so every later task's
`diff -ru fw/ctrl_832 fw/ctrl_rv` is exactly the port.

## Copy base

Copied from `fw/ctrl_832` at osd-riscv HEAD `2f5df34c9821fef3d9a4101fe649f9c954a3e482`
(last change to `fw/ctrl_832`: `8f8cf88`).

## What was copied

- The 29 units of the 832 Makefile's `COMMON_SOURCES` (`.c` and `.h`):
  hardware config fat fdd fpga boot hdd main menu mmc spi osd rafile swap
  hexdump uart errors interrupts c64keys akiko audio drivesounds rtc i2c
  adv7511 atapi cdrom cue cdaudio.
- Headers without a unit: `amiga_rawkey.h charrom.h logo.h minimig_cfg.h
  hdd_internal.h firmware.h bootcustominit.h`, and `bootcustominit.s`.
- `test/*.c`, `test/Makefile`, `test/.gitignore` (unchanged for now) and
  `test/emu/*.c` (the three emu programs, used by L1 `units`).

`arch/` is Phase 2 / Task 1 (crt0, trap, irq, `arch.mk`) and is not part of
the copy.

## What was not copied, and why

- `version.h`: generated into `build/` from Task 4 on, never tracked here.
- `Makefile`: vbcc; replaced in Task 4.
- `Makefile.68k`, `startup_m68k-elf.s`, `startup_zpu-elf.s`,
  `osd_m68k-elf.ld`, `osd_zpu-elf.ld`: 68k/ZPU leftovers.
- `small_printf.c`, `small_printf.h`, `printf.c`: not in `COMMON_SOURCES`.
  The 832 links lib832's `printf`; the RV tree uses newlib-nano plus its own
  `printf`/`vprintf` (Task 3, decision 12.12). No lib832 file is copied.
- `test/emu/Makefile`: vbcc832 + 832e, 832-only.

## Check the copy

From the repository root (works in zsh and bash; needs only coreutils and
git, no toolchain):

```sh
(cd fw/ctrl_rv && find . -path ./arch -prune -o -type f ! -name README.md ! -name .gitignore -print) | while read -r f; do cmp "fw/ctrl_832/$f" "fw/ctrl_rv/$f" || echo "DIFF $f"; done
```

No `DIFF` line means every copied file is byte-identical to its 832 original.
(`test/.gitignore` is excluded by the `.gitignore` filter; it is a verbatim copy.)

## Building

Nothing builds yet; the RISC-V Makefile arrives in Task 4. The toolchain
setup it will need, from a fresh Ubuntu 24.04 machine:

```sh
sudo apt install build-essential git python3
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
```
