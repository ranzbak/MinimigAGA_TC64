# Boot ROM for the OSD host RISC-V CPU (VexRiscv RV32IMC): loads RV32OSDA.BIN from
# the SD card to 0x2000 and jumps to it (see README.md).
#
#   make            OSDBoot_rv.bin and OSDBoot_rv_ROM.vhd
#   make check      no A-extension opcodes (lr.w/sc.w/amo*) in the disassembly
#   make size       size of the rv32imc image
#   make im         rv32im (no compressed) build in build_im/, size printed
#   make test       host minfat test (test/)
TOP := $(abspath ../..)
include $(TOP)/tools/riscv/toolchain.mk

PROJECT := OSDBoot_rv
ROMGEN  := ../romgen/romgen

DEFS    := -Dprg_start=0x2000 -DOSDNAME=\"RV32OSDABIN\"
BUILD   ?= build
CFLAGS  := $(RV_CFLAGS_FW) -Wall $(DEFS) -I.
LDFLAGS := $(RV_LDFLAGS_FW) -T boot.ld -Wl,--no-warn-rwx-segments -Wl,-Map=$(BUILD)/$(PROJECT).map

SRCS    := boot.c spi.c lockstep.c swap.c minfat.c uart.c checksum.c hexdump.c small_printf.c

OBJS     = $(addprefix $(BUILD)/,$(SRCS:.c=.o)) $(BUILD)/crt0.o
HEADERS  = $(wildcard *.h)

all: $(PROJECT).bin $(PROJECT)_ROM.vhd

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: %.c $(HEADERS) | $(BUILD)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/crt0.o: crt0.S | $(BUILD)
	$(RV_CC) $(RV_ARCH) -c -o $@ $<

$(BUILD)/$(PROJECT).elf: $(OBJS) boot.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(OBJS) $(RV_LIBS_FW)

$(PROJECT).bin: $(BUILD)/$(PROJECT).elf
	$(RV_OBJCOPY) -O binary $< $@

# The ROM VHDL is the template prologue (entity renamed), the romgen word table
# and the epilogue.  romgen is the shared tool in ../romgen.
$(ROMGEN): ../romgen/romgen.c
	$(MAKE) -C ../romgen

%_ROM.vhd: %.bin $(ROMGEN) rom_prologue.vhd rom_epilogue.vhd
	sed 's/soc_firmware/$*_ROM/' <rom_prologue.vhd >$@
	$(ROMGEN) $*.bin >>$@
	cat rom_epilogue.vhd >>$@

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

.PHONY: all check size im test clean
