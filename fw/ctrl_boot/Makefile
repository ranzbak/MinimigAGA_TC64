# Boot ROM for the OSD host RISC-V CPU (VexRiscv RV32IMC): loads RV32OSDB.BIN
# (the name: fw/ctrl/fwname.mk) from the SD card to 0x2000 and jumps to it
# (see README.md).
#
#   make            OSDBoot_rv.bin and OSDBoot_rv_ROM.vhd
#   make check      no A-extension opcodes (lr.w/sc.w/amo*) in the disassembly
#   make size       size of the rv32imc image
#   make im         rv32im (no compressed) build in build_im/, size printed
#   make test       host minfat test (test/)
#   make romvhd_check ROMVHD_OUT=<file>
#                   the ROM VHDL made from the committed OSDBoot_rv.bin as
#                   it is (not rebuilt) into <file>: fw/ctrl's check (i)
#                   compares it with the committed OSDBoot_rv_ROM.vhd
TOP := $(abspath ../..)
include $(TOP)/tools/riscv/toolchain.mk

PROJECT := OSDBoot_rv
ROMGEN  := ../romgen/romgen

# the firmware's file name, shared with fw/ctrl's build (its check (i)
# checks the committed image against it); OSDNAME = the 8.3 directory entry
include $(TOP)/fw/ctrl/fwname.mk
DEFS    := -Dprg_start=0x2000 -DOSDNAME=\"$(FW_83)\"
BUILD   ?= build
CFLAGS  := $(RV_CFLAGS_FW) -Wall $(DEFS) -I.
LDFLAGS := $(RV_LDFLAGS_FW) -T boot.ld -Wl,--no-warn-rwx-segments -Wl,-Map=$(BUILD)/$(PROJECT).map

SRCS    := boot.c spi.c lockstep.c swap.c minfat.c uart.c checksum.c hexdump.c small_printf.c

OBJS     = $(addprefix $(BUILD)/,$(SRCS:.c=.o)) $(BUILD)/crt0.o
# fw/ctrl/sdc.h too (spi.c and lockstep.c include it: the peripheral's
# registers and SDC_VERSION, which spi_init checks): without it a bumped
# SDC_VERSION left a stale spi.o in the ROM (final review fix wave)
HEADERS  = $(wildcard *.h) $(TOP)/fw/ctrl/sdc.h

all: $(PROJECT).bin $(PROJECT)_ROM.vhd

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: %.c $(HEADERS) $(TOP)/fw/ctrl/fwname.mk | $(BUILD)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/crt0.o: crt0.S | $(BUILD)
	$(RV_CC) $(RV_ARCH) -c -o $@ $<

$(BUILD)/$(PROJECT).elf: $(OBJS) boot.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(OBJS) $(RV_LIBS_FW)

$(PROJECT).bin: $(BUILD)/$(PROJECT).elf
	$(RV_OBJCOPY) -O binary $< $@

# The ROM VHDL is the template prologue (entity renamed), the romgen word table
# and the epilogue.  romgen is the shared tool in ../romgen.
# $(call romvhd,<bin>,<entity>,<out>): the one recipe, for the committed
# file and for romvhd_check
romvhd = sed 's/soc_firmware/$(2)/' <rom_prologue.vhd >$(3) && $(ROMGEN) $(1) >>$(3) && cat rom_epilogue.vhd >>$(3)
$(ROMGEN): ../romgen/romgen.c
	$(MAKE) -C ../romgen

%_ROM.vhd: %.bin $(ROMGEN) rom_prologue.vhd rom_epilogue.vhd
	$(call romvhd,$*.bin,$*_ROM,$@)

# no dependency on $(PROJECT).bin: the committed image as it is
romvhd_check: $(ROMGEN) rom_prologue.vhd rom_epilogue.vhd
	@[ -n "$(ROMVHD_OUT)" ] || { echo "romvhd_check: ROMVHD_OUT=<file> needed"; exit 1; }
	@$(call romvhd,$(PROJECT).bin,$(PROJECT)_ROM,$(ROMVHD_OUT))

# bootdiag.h is the committed 68k byte array; rebuild only if the source is
# newer and vasm exists.
ifneq ($(shell command -v vasmm68k_mot 2>/dev/null),)
bootdiag.h: bootdiag.s
	vasmm68k_mot -Fbin bootdiag.s -o bootdiag.bin
	xxd -i bootdiag.bin > bootdiag.h
endif

check: $(BUILD)/$(PROJECT).elf
	$(RV_OBJDUMP) -d $< > $(BUILD)/$(PROJECT).dis
	@if grep -E '\b(lr\.w|sc\.w|amo[a-z]+\.w)\b' $(BUILD)/$(PROJECT).dis; then \
	  echo "check: A-extension opcode found"; exit 1; \
	else echo "check: no lr.w/sc.w/amo* in the disassembly"; fi

size: $(BUILD)/$(PROJECT).elf
	$(RV_SIZE) $<

# rv32im (no C extension) build, for the size comparison only; not committed.
im:
	$(MAKE) BUILD=build_im RV_ARCH="$(RV_ARCH_IM)" build_im/$(PROJECT).elf
	$(RV_SIZE) build_im/$(PROJECT).elf

test:
	$(MAKE) -C test

clean:
	$(RM) -r build build_im test/out    # the committed OSDBoot_rv.bin / _ROM.vhd stay

.PHONY: all check size im test clean romvhd_check
