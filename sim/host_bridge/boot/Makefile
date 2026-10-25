# L2 boot run (sim/host_bridge/run.sh boot / boot_nofile / boot_mismatch /
# boot_both): the test firmware and the four SD card images.
#   make -C sim/host_bridge/boot             # into sim/host_bridge/boot/build
#   make -C sim/host_bridge/boot B=<dir>     # run.sh: into its run directory
# The firmware's name, $(FW_FILE) = RV32OSDB.BIN (the boot ROM looks for
# its 8.3 entry RV32OSDBBIN), comes from fw/ctrl/fwname.mk; $(OLD_FILE) =
# RV32OSDA.BIN is the previous chain's (card on cfide's SPI, no trailer).
# Outputs in $(B):
#   $(FW_FILE)         fwtest.c + fwfill.S on fw/ctrl/arch (crt0, trap
#                      entry, irq API) with firmware.ld, objcopy -O binary,
#                      padded to $(IMG_BYTES) - 8 bytes, then the lock-step
#                      trailer of fw/ctrl (fw/ctrl/sdctrailer.c: 'SDCV', 0,
#                      0, SDC_VERSION of fw/ctrl/sdc.h), $(IMG_BYTES) bytes
#                      in all (5 sectors: the boot ROM log then has a fixed
#                      number of sector reads)
#   plain/$(FW_FILE)   the same without the trailer, padded to $(IMG_BYTES)
#                      (its last 8 bytes are padding): a firmware from
#                      before the trailer
#   img.txt            "IMG <len> <sum>": the line the firmware must print,
#                      from the file: .text + .rodata length and word sum
#   card.img           8 MB FAT16: OSDDECOY.BIN (decoy, first in the
#                      directory), $(FW_FILE)
#   card_nofile.img    8 MB FAT16: OSDDECOY.BIN, $(OLD_FILE) (the test
#                      firmware, trailer included, under the previous
#                      chain's name): the boot ROM must load neither
#   card_mismatch.img  8 MB FAT16: OSDDECOY.BIN, plain/$(FW_FILE) (no
#                      trailer): the boot ROM loads it and must refuse to
#                      run it (ErrorCode 00FF)
#   card_both.img      8 MB FAT16: OSDDECOY.BIN, $(OLD_FILE) = the image
#                      without the trailer (an old firmware, ahead in the
#                      directory), $(FW_FILE): a card for old and new
#                      bitstreams; the boot ROM must boot $(FW_FILE) (taking
#                      the old file would end in the lock-step refusal)
#   fw.elf, fw.map, fw.lst
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk
RV_NM      = $(RV_GCC_DIR)/bin/$(RV_PREFIX)nm
include $(TOP)/fw/ctrl/fwname.mk
OLD_FILE  := RV32OSDA.BIN

B         ?= build
ARCH_B    := $(B)
include $(TOP)/fw/ctrl/arch/arch.mk
.DEFAULT_GOAL := all
MKCARD    := $(TOP)/tools/sim/mkcard.sh
IMG_BYTES := 2560

CFLAGS  = $(RV_CFLAGS_FW) -g -Wall -Wextra -I../sw -I$(ARCH)
ASFLAGS = $(RV_ARCH) -g
LDFLAGS = $(RV_LDFLAGS_FW) $(ARCH_LDFLAGS) \
          -Wl,-Map,$(B)/fw.map

OBJS = $(ARCH_OBJS) $(B)/fwtest.o $(B)/fwfill.o

.PHONY: all clean
.DELETE_ON_ERROR:
all: $(B)/$(FW_FILE) $(B)/img.txt $(B)/fw.lst $(B)/card.img $(B)/card_nofile.img \
     $(B)/card_mismatch.img $(B)/card_both.img

$(B)/fwtest.o: fwtest.c ../sw/hb.h $(ARCH)/irq.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/fwfill.o: fwfill.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/fw.elf: $(OBJS) $(ARCH_LD)
	$(RV_CC) $(LDFLAGS) -o $@ $(OBJS) $(RV_LIBS_FW)

# the trailer as fw/ctrl/Makefile makes it (the same source file)
$(B)/sdctrailer.bin: $(TOP)/fw/ctrl/sdctrailer.c $(TOP)/fw/ctrl/sdc.h
	@mkdir -p $(@D)
	$(RV_CC) $(RV_ARCH) -c -o $(B)/sdctrailer.o $<
	$(RV_OBJCOPY) -O binary -j .sdctrailer $(B)/sdctrailer.o $@
	@[ `wc -c < $@` = 8 ] || { echo "$@: not 8 bytes"; rm -f $@; exit 1; }

# pad to IMG_BYTES - 8, then the trailer; fail if the image is already
# larger.  $(B)/plain/$(FW_FILE): the same without the trailer (padded to
# IMG_BYTES), for card_mismatch.img and card_both.img
$(B)/$(FW_FILE): $(B)/fw.elf $(B)/sdctrailer.bin
	$(RV_OBJCOPY) -O binary $< $@.tmp
	@n=$$(stat -c %s $@.tmp); [ $$n -le $$(($(IMG_BYTES) - 8)) ] || \
	  { echo "$(FW_FILE) is $$n bytes, more than IMG_BYTES - 8 = $$(($(IMG_BYTES) - 8))"; rm -f $@.tmp; exit 1; }
	mkdir -p $(B)/plain
	cp $@.tmp $(B)/plain/$(FW_FILE)
	truncate -s $(IMG_BYTES) $(B)/plain/$(FW_FILE)
	truncate -s $$(($(IMG_BYTES) - 8)) $@.tmp
	cat $(B)/sdctrailer.bin >> $@.tmp
	mv $@.tmp $@

$(B)/img.txt: $(B)/$(FW_FILE) $(B)/fw.elf
	n=$$($(RV_NM) $(B)/fw.elf | sed -n 's/^\([0-9a-f]*\) . __init_array_start$$/\1/p'); \
	python3 -c 'import sys, struct; n = int(sys.argv[2], 16) - 0x2000; d = open(sys.argv[1], "rb").read()[:n]; \
	print("IMG %08X %08X" % (n, sum(struct.unpack("<%dI" % (n // 4), d)) & 0xFFFFFFFF))' $(B)/$(FW_FILE) $$n > $@

$(B)/fw.lst: $(B)/fw.elf
	$(RV_OBJDUMP) -d -h $< > $@

# decoy: text, an illegal instruction stream if it were ever run
$(B)/OSDDECOY.BIN:
	@mkdir -p $(@D)
	yes OSDDECOY | head -c 2000 > $@

$(B)/card.img: $(B)/OSDDECOY.BIN $(B)/$(FW_FILE) $(MKCARD)
	bash $(MKCARD) $@ 8 $(B)/OSDDECOY.BIN $(B)/$(FW_FILE)

$(B)/card_nofile.img: $(B)/OSDDECOY.BIN $(B)/$(FW_FILE) $(MKCARD)
	mkdir -p $(B)/nofile
	cp $(B)/$(FW_FILE) $(B)/nofile/$(OLD_FILE)
	bash $(MKCARD) $@ 8 $(B)/OSDDECOY.BIN $(B)/nofile/$(OLD_FILE)

$(B)/card_mismatch.img: $(B)/OSDDECOY.BIN $(B)/$(FW_FILE) $(MKCARD)
	bash $(MKCARD) $@ 8 $(B)/OSDDECOY.BIN $(B)/plain/$(FW_FILE)

$(B)/card_both.img: $(B)/OSDDECOY.BIN $(B)/$(FW_FILE) $(MKCARD)
	mkdir -p $(B)/both
	cp $(B)/plain/$(FW_FILE) $(B)/both/$(OLD_FILE)
	bash $(MKCARD) $@ 8 $(B)/OSDDECOY.BIN $(B)/both/$(OLD_FILE) $(B)/$(FW_FILE)

.PRECIOUS: $(B)/%.o $(B)/arch/%.o

clean:
	rm -rf $(B)
