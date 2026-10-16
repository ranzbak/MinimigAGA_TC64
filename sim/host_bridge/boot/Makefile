# L2 boot run (sim/host_bridge/run.sh boot / boot_nofile): the test firmware
# RV32OSDA.BIN and the two SD card images.
#   make -C sim/host_bridge/boot             # into sim/host_bridge/boot/build
#   make -C sim/host_bridge/boot B=<dir>     # run.sh: into its run directory
# Outputs in $(B):
#   RV32OSDA.BIN       fwtest.c + fwfill.S on fw/ctrl_rv/arch (crt0, trap
#                      entry, irq API) with firmware.ld, objcopy -O binary,
#                      padded to $(IMG_BYTES) bytes (5 sectors: the boot ROM
#                      log then has a fixed number of sector reads)
#   img.txt            "IMG <len> <sum>": the line the firmware must print,
#                      from the file: .text + .rodata length and word sum
#   card.img           8 MB FAT16: 832OSDAD.BIN (decoy, first in the
#                      directory), RV32OSDA.BIN
#   card_nofile.img    8 MB FAT16: 832OSDAD.BIN, RV32OSDB.BIN (the firmware
#                      under a near-miss name): the boot ROM must not load
#                      either
#   fw.elf, fw.map, fw.lst
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk
RV_NM      = $(RV_GCC_DIR)/bin/$(RV_PREFIX)nm

B         ?= build
ARCH      := $(TOP)/fw/ctrl_rv/arch
MKCARD    := $(TOP)/tools/sim/mkcard.sh
IMG_BYTES := 2560

CFLAGS  = $(RV_CFLAGS_FW) -g -Wall -Wextra -I../sw -I$(ARCH)
ASFLAGS = $(RV_ARCH) -g
LDFLAGS = $(RV_LDFLAGS_FW) -nostartfiles -T $(ARCH)/firmware.ld -Wl,--no-warn-rwx-segments \
          -Wl,-Map,$(B)/fw.map

OBJS = $(B)/arch/crt0.o $(B)/arch/trap_entry.o $(B)/arch/trap.o $(B)/arch/irq.o \
       $(B)/fwtest.o $(B)/fwfill.o

.PHONY: all clean
.DELETE_ON_ERROR:
all: $(B)/RV32OSDA.BIN $(B)/img.txt $(B)/fw.lst $(B)/card.img $(B)/card_nofile.img

$(B)/arch/crt0.o: $(ARCH)/crt0.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/trap_entry.o: $(ARCH)/trap.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/%.o: $(ARCH)/%.c $(ARCH)/irq.h $(ARCH)/csr.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/fwtest.o: fwtest.c ../sw/hb.h $(ARCH)/irq.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/fwfill.o: fwfill.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/fw.elf: $(OBJS) $(ARCH)/firmware.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(OBJS) $(RV_LIBS_FW)

# pad to IMG_BYTES; fail if the image is already larger
$(B)/RV32OSDA.BIN: $(B)/fw.elf
	$(RV_OBJCOPY) -O binary $< $@.tmp
	@n=$$(stat -c %s $@.tmp); [ $$n -le $(IMG_BYTES) ] || \
	  { echo "RV32OSDA.BIN is $$n bytes, more than IMG_BYTES = $(IMG_BYTES)"; rm -f $@.tmp; exit 1; }
	truncate -s $(IMG_BYTES) $@.tmp
	mv $@.tmp $@

$(B)/img.txt: $(B)/RV32OSDA.BIN $(B)/fw.elf
	n=$$($(RV_NM) $(B)/fw.elf | sed -n 's/^\([0-9a-f]*\) . __init_array_start$$/\1/p'); \
	python3 -c 'import sys, struct; n = int(sys.argv[2], 16) - 0x2000; d = open(sys.argv[1], "rb").read()[:n]; \
	print("IMG %08X %08X" % (n, sum(struct.unpack("<%dI" % (n // 4), d)) & 0xFFFFFFFF))' $(B)/RV32OSDA.BIN $$n > $@

$(B)/fw.lst: $(B)/fw.elf
	$(RV_OBJDUMP) -d -h $< > $@

# decoy: text, an illegal instruction stream if it were ever run
$(B)/832OSDAD.BIN:
	@mkdir -p $(@D)
	yes DECOY832 | head -c 2000 > $@

$(B)/card.img: $(B)/832OSDAD.BIN $(B)/RV32OSDA.BIN $(MKCARD)
	bash $(MKCARD) $@ 8 $(B)/832OSDAD.BIN $(B)/RV32OSDA.BIN

$(B)/card_nofile.img: $(B)/832OSDAD.BIN $(B)/RV32OSDA.BIN $(MKCARD)
	mkdir -p $(B)/nofile
	cp $(B)/RV32OSDA.BIN $(B)/nofile/RV32OSDB.BIN
	bash $(MKCARD) $@ 8 $(B)/832OSDAD.BIN $(B)/nofile/RV32OSDB.BIN

.PRECIOUS: $(B)/%.o $(B)/arch/%.o

clean:
	rm -rf $(B)
