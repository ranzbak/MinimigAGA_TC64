# Dhrystone 2.1 for the RISC-V host CPU (VexRiscv RV32IMC).  README.md.
#   make                       l1_O2.hex l1_Os.hex l2_O2.hex RV32OSDA.BIN
#   make l1_O2.hex             L1 bench image: boot stand-in (0x0..0x1FFF) + firmware at 0x2000
#   make l2_O2.hex             L2 SDRAM preload (firmware only, "@800" = byte 0x2000)
#   make RV32OSDA.BIN          board image (-O2, 200000 runs), copy to the SD card
#   make build/l1_O2_teeth.hex L1 image with -DDHRY_CHECK_TEETH: one result check
#                              must fail (sim/rv_l1/run.sh dhry)
# Linked with fw/ctrl_rv/arch (crt0, trap entry, irq API) and its firmware.ld.
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk

B       := build
ARCH    := $(TOP)/fw/ctrl_rv/arch
BOOTFW  := $(TOP)/sim/rv_l1/build/boot_fw.bin
BOARD_OPT ?= O2

# the benchmark itself: -O2 / -Os per image, the firmware flags otherwise
DHEXTRA ?=            # e.g. DHEXTRA=-DNUMBER_OF_RUNS=1000
DHFLAGS = $(DHEXTRA) $(RV_ARCH) -ffunction-sections -fdata-sections -fno-builtin -funsigned-char \
          -ffreestanding -std=gnu89 -w -I. -I$(ARCH)
ARCH_CFLAGS = $(RV_CFLAGS_FW) -g -Wall -Wextra -I$(ARCH)
ASFLAGS = $(RV_ARCH) -g
LDFLAGS = $(RV_LDFLAGS_FW) -nostartfiles -T $(ARCH)/firmware.ld -Wl,--no-warn-rwx-segments

ARCH_OBJS = $(B)/arch/crt0.o $(B)/arch/trap_entry.o $(B)/arch/trap.o $(B)/arch/irq.o
SRCS      = dhry_1.c dhry_2.c hw.c

.PHONY: all clean
all: l1_O2.hex l1_Os.hex l2_O2.hex RV32OSDA.BIN

# $(1) = O2 | Os, $(2) = object directory flags (L1 or board)
define IMAGE
$(B)/$(1)_$(3)/%.o: %.c dhry.h hw.h | $(B)/$(1)_$(3)
	$$(RV_CC) $$(DHFLAGS) -$(1) $(2) -c -o $$@ $$<
$(B)/$(1)_$(3):
	mkdir -p $$@
$(B)/$(1)_$(3)/fw.elf: $(ARCH_OBJS) $(SRCS:%.c=$(B)/$(1)_$(3)/%.o) $(ARCH)/firmware.ld
	$$(RV_CC) $$(LDFLAGS) -Wl,-Map,$$(@:.elf=.map) -o $$@ $(ARCH_OBJS) $(SRCS:%.c=$(B)/$(1)_$(3)/%.o) $$(RV_LIBS_FW)
endef
$(eval $(call IMAGE,O2,-DL1,l1))
$(eval $(call IMAGE,Os,-DL1,l1))
$(eval $(call IMAGE,O2,,board))
$(eval $(call IMAGE,Os,,board))
$(eval $(call IMAGE,O2,-DL1 -DDHRY_CHECK_TEETH,teeth))

$(B)/arch:
	mkdir -p $@
$(B)/arch/crt0.o: $(ARCH)/crt0.S | $(B)/arch
	$(RV_CC) $(ASFLAGS) -c -o $@ $<
$(B)/arch/trap_entry.o: $(ARCH)/trap.S | $(B)/arch
	$(RV_CC) $(ASFLAGS) -c -o $@ $<
$(B)/arch/%.o: $(ARCH)/%.c $(ARCH)/irq.h $(ARCH)/csr.h | $(B)/arch
	$(RV_CC) $(ARCH_CFLAGS) -c -o $@ $<

$(B)/%/fw.bin: $(B)/%/fw.elf
	$(RV_OBJCOPY) -O binary $< $@
	$(RV_OBJDUMP) -d -h $< > $(@:.bin=.lst)
	$(RV_SIZE) $<

# one BE 32-bit word per line, file byte i in lane i (the romgen order);
# a short last line is padded with 00 (as sim/rv_l1/Makefile)
HEXCMD = od -An -v -tx1 -w4 $(1) | awk '{ printf "%s%s%s%s\n", $$1, ($$2 == "" ? "00" : $$2), ($$3 == "" ? "00" : $$3), ($$4 == "" ? "00" : $$4) }'

$(BOOTFW):
	$(MAKE) -C $(TOP)/sim/rv_l1 build/boot_fw.bin

l1_O2.hex: $(B)/O2_l1/fw.bin $(BOOTFW)
	cat $(BOOTFW) $< | $(call HEXCMD,-) > $@
l1_Os.hex: $(B)/Os_l1/fw.bin $(BOOTFW)
	cat $(BOOTFW) $< | $(call HEXCMD,-) > $@
$(B)/l1_O2_teeth.hex: $(B)/O2_teeth/fw.bin $(BOOTFW)
	cat $(BOOTFW) $< | $(call HEXCMD,-) > $@
# L2: the SDRAM model preloads +SDRAM_HEX at word address 0x800 (byte 0x2000)
l2_O2.hex: $(B)/O2_l1/fw.bin
	{ echo @800; $(call HEXCMD,$<); } > $@
l2_Os.hex: $(B)/Os_l1/fw.bin
	{ echo @800; $(call HEXCMD,$<); } > $@

RV32OSDA.BIN: $(B)/$(BOARD_OPT)_board/fw.bin
	cp $< $@

.PRECIOUS: $(B)/%.o $(B)/%/fw.elf $(B)/%/fw.bin

clean:
	rm -rf $(B) *.hex RV32OSDA.BIN
