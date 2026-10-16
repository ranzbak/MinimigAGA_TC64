# RISC-V toolchain pin for the OSD host CPU (VexRiscv RV32IMC).
# Include from every Makefile.  Override on the command line or environment:
#   RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf-   (Ubuntu fallback)
# Always use full paths: a CH32V rv32imac-only gcc may be first on PATH.
RV_GCC_DIR ?= $(HOME)/opt/xpack-riscv-none-elf-gcc-15.2.0-1
RV_PREFIX  ?= riscv-none-elf-

RV_CC      = $(RV_GCC_DIR)/bin/$(RV_PREFIX)gcc
RV_AS      = $(RV_GCC_DIR)/bin/$(RV_PREFIX)as
RV_LD      = $(RV_GCC_DIR)/bin/$(RV_PREFIX)ld
RV_OBJCOPY = $(RV_GCC_DIR)/bin/$(RV_PREFIX)objcopy
RV_OBJDUMP = $(RV_GCC_DIR)/bin/$(RV_PREFIX)objdump
RV_SIZE    = $(RV_GCC_DIR)/bin/$(RV_PREFIX)size

# Target core: RV32IMC.  RV_ARCH_IM is the no-compressed variant (multilib
# rv32im/ilp32) used for libgcc checks and non-C code.
RV_ARCH    = -march=rv32imc_zicsr_zifencei -mabi=ilp32
RV_ARCH_IM = -march=rv32im_zicsr_zifencei -mabi=ilp32

# Firmware / boot ROM flags (freestanding, link with $(RV_LIBS_FW) last).
RV_CFLAGS_FW  = $(RV_ARCH) -Os -ffunction-sections -fdata-sections \
                -fno-builtin -funsigned-char -ffreestanding
RV_LDFLAGS_FW = $(RV_ARCH) -nostdlib -Wl,--gc-sections
RV_LIBS_FW    = -lgcc
