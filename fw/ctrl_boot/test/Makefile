# Host tests of the boot ROM (gcc + ASan/UBSan).  `make` builds, makes four
# card images with tools/sim/mkcard.sh and runs minfat_test on each (the FAT
# code), then lockstep_test (the bitstream / firmware lock-step check,
# ../lockstep.c with the ROM's small_printf; the mismatch message's glyphs
# in the text layer's power-up font), also on fw/ctrl's built
# firmware file when it exists (FWBIN=<file> for another one).  The file
# name (RV32OSDB.BIN, 8.3 entry RV32OSDBBIN) comes from fw/ctrl/fwname.mk,
# as in the ROM's build.
# Needs: gcc, mtools, dosfstools, fdisk (see tools/sim/README.md), python3.
TOP     := $(abspath ../../..)
MKCARD  := $(TOP)/tools/sim/mkcard.sh
SRC     := ..
include $(TOP)/fw/ctrl/fwname.mk
# the previous chain's firmware name (card on cfide's SPI, no trailer):
# the old firmware may sit beside the new one on the same card
OLD_FILE := RV32OSDA.BIN
OUT     := out

CC      ?= gcc
CFLAGS  := -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare \
           -fsanitize=address,undefined -fno-sanitize-recover=undefined \
           -I$(SRC) -DOSDNAME=\"$(FW_83)\"

all: test

$(OUT):
	mkdir -p $(OUT)

# minfat.c is built with puts renamed so the test can supply a quiet one.
$(OUT)/minfat.o: $(SRC)/minfat.c $(SRC)/minfat.h $(SRC)/swap.h $(SRC)/uart.h $(SRC)/spi.h $(SRC)/small_printf.h | $(OUT)
	$(CC) $(CFLAGS) -Dputs=rv_puts -c -o $@ $<
$(OUT)/swap.o: $(SRC)/swap.c $(SRC)/swap.h | $(OUT)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OUT)/minfat_test.o: minfat_test.c $(SRC)/minfat.h | $(OUT)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OUT)/minfat_test: $(OUT)/minfat_test.o $(OUT)/minfat.o $(OUT)/swap.o
	$(CC) $(CFLAGS) -o $@ $^

# lockstep.c and small_printf.c print through putchar: renamed, so the test
# captures the UART text (sdc.h's HOSTTEST register access: SDC_R -> the
# test's hosttest_sdc_rd)
LSFLAGS := -DHOSTTEST -Dputchar=rv_putchar
$(OUT)/lockstep.o: $(SRC)/lockstep.c $(SRC)/lockstep.h $(SRC)/../ctrl/sdc.h $(SRC)/small_printf.h | $(OUT)
	$(CC) $(CFLAGS) $(LSFLAGS) -c -o $@ $<
$(OUT)/small_printf.o: $(SRC)/small_printf.c $(SRC)/small_printf.h $(SRC)/uart.h | $(OUT)
	$(CC) $(CFLAGS) $(LSFLAGS) -c -o $@ $<
$(OUT)/lockstep_test.o: lockstep_test.c $(SRC)/lockstep.h $(SRC)/../ctrl/sdc.h | $(OUT)
	$(CC) $(CFLAGS) $(LSFLAGS) -c -o $@ $<
$(OUT)/lockstep_test: $(OUT)/lockstep_test.o $(OUT)/lockstep.o $(OUT)/small_printf.o
	$(CC) $(CFLAGS) -o $@ $^
FWBIN ?= $(TOP)/fw/ctrl/build/$(FW_FILE)
# the OSD text layer's power-up font (osd_text.v's FONT_FILE): the mismatch
# message needs no font upload, so its glyphs must be there
OSD_FONT := $(TOP)/rtl/openaars/adv7511/osd_font.mem

# Card images.  Contents: $(FW_FILE) = 3000 deterministic pseudo-random bytes,
# OLDOSDAD.BIN = another firmware-like name ahead of it on the card (a decoy, as
# the previous firmware's 832OSDAD.BIN may be: the ROM must not load it),
# $(OLD_FILE) = the previous chain's firmware, also ahead of it (a card for old
# and new bitstreams holds both; the ROM must load its own).  The 'nofile'
# card holds only the decoys.
RANDGEN = python3 -I -c 'import random,sys; r=random.Random(sys.argv[1]); open(sys.argv[2],"wb").write(bytes(r.getrandbits(8) for _ in range(int(sys.argv[3]))))'
$(OUT)/fw.bin: | $(OUT)
	$(RANDGEN) fw $@ 3000
$(OUT)/big.bin: | $(OUT)
	$(RANDGEN) big $@ 40000
$(OUT)/decoy1.bin: | $(OUT)
	$(RANDGEN) d1 $@ 1500
$(OUT)/decoy2.bin: | $(OUT)
	$(RANDGEN) d2 $@ 1500

$(OUT)/mbr_file.img: $(OUT)/fw.bin $(OUT)/decoy1.bin $(OUT)/decoy2.bin $(MKCARD)
	cp $(OUT)/fw.bin $(OUT)/$(FW_FILE); cp $(OUT)/decoy1.bin $(OUT)/OLDOSDAD.BIN; cp $(OUT)/decoy2.bin $(OUT)/$(OLD_FILE)
	$(MKCARD) $@ 8 $(OUT)/OLDOSDAD.BIN $(OUT)/$(OLD_FILE) $(OUT)/$(FW_FILE)
$(OUT)/mbr_nofile.img: $(OUT)/decoy1.bin $(OUT)/decoy2.bin $(MKCARD)
	cp $(OUT)/decoy1.bin $(OUT)/OLDOSDAD.BIN; cp $(OUT)/decoy2.bin $(OUT)/$(OLD_FILE)
	$(MKCARD) $@ 8 $(OUT)/OLDOSDAD.BIN $(OUT)/$(OLD_FILE)
# Superfloppy: FAT16 straight at LBA 0, no MBR.
$(OUT)/superfloppy.img: $(OUT)/fw.bin $(OUT)/decoy1.bin
	cp $(OUT)/fw.bin $(OUT)/$(FW_FILE); cp $(OUT)/decoy1.bin $(OUT)/OLDOSDAD.BIN
	rm -f $@; truncate -s 8M $@
	PATH=$$PATH:/usr/sbin:/sbin mkfs.fat -F 16 -s 2 -n MINIMIG $@ >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -i $@ $(OUT)/OLDOSDAD.BIN $(OUT)/$(FW_FILE) ::
# FAT32 superfloppy with a 40000-byte file (a longer cluster chain).
$(OUT)/fat32.img: $(OUT)/big.bin $(OUT)/decoy1.bin
	cp $(OUT)/big.bin $(OUT)/$(FW_FILE); cp $(OUT)/decoy1.bin $(OUT)/OLDOSDAD.BIN
	rm -f $@; truncate -s 40M $@
	PATH=$$PATH:/usr/sbin:/sbin mkfs.fat -F 32 -s 1 -n MINIMIG $@ >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -i $@ $(OUT)/OLDOSDAD.BIN $(OUT)/$(FW_FILE) ::

test: $(OUT)/minfat_test $(OUT)/mbr_file.img $(OUT)/mbr_nofile.img $(OUT)/superfloppy.img $(OUT)/fat32.img $(OUT)/lockstep_test
	$(OUT)/minfat_test $(OUT)/mbr_file.img $(OUT)/fw.bin
	$(OUT)/minfat_test $(OUT)/mbr_nofile.img -
	$(OUT)/minfat_test $(OUT)/superfloppy.img $(OUT)/fw.bin
	$(OUT)/minfat_test $(OUT)/fat32.img $(OUT)/big.bin
	@echo "minfat host test: ALL PASS"
	$(OUT)/lockstep_test $(OSD_FONT) $(wildcard $(FWBIN))
	@[ -f "$(FWBIN)" ] || echo "lockstep host test: $(FWBIN) not built, its two cases skipped (make -C fw/ctrl)"

clean:
	rm -rf $(OUT)

.PHONY: all test clean
