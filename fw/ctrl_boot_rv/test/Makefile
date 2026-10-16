# Host test of the boot ROM's FAT code (gcc + ASan/UBSan).  `make` builds, makes
# four card images with tools/sim/mkcard.sh and runs minfat_test on each.
# Needs: gcc, mtools, dosfstools, fdisk (see tools/sim/README.md), python3.
TOP     := $(abspath ../../..)
MKCARD  := $(TOP)/tools/sim/mkcard.sh
SRC     := ..
OSDNAME_STR := RV32OSDABIN
OUT     := out

CC      ?= gcc
CFLAGS  := -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare \
           -fsanitize=address,undefined -fno-sanitize-recover=undefined \
           -I$(SRC) -DOSDNAME=\"$(OSDNAME_STR)\"

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

# Card images.  Contents: RV32OSDA.BIN = 3000 deterministic pseudo-random bytes,
# 832OSDAD.BIN = the 832 firmware name (a decoy: the RISC-V ROM must not load it),
# RV32OSDB.BIN = a near-miss name.  The 'nofile' card holds only the decoys.
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
	cp $(OUT)/fw.bin $(OUT)/RV32OSDA.BIN; cp $(OUT)/decoy1.bin $(OUT)/832OSDAD.BIN; cp $(OUT)/decoy2.bin $(OUT)/RV32OSDB.BIN
	$(MKCARD) $@ 8 $(OUT)/832OSDAD.BIN $(OUT)/RV32OSDB.BIN $(OUT)/RV32OSDA.BIN
$(OUT)/mbr_nofile.img: $(OUT)/decoy1.bin $(OUT)/decoy2.bin $(MKCARD)
	cp $(OUT)/decoy1.bin $(OUT)/832OSDAD.BIN; cp $(OUT)/decoy2.bin $(OUT)/RV32OSDB.BIN
	$(MKCARD) $@ 8 $(OUT)/832OSDAD.BIN $(OUT)/RV32OSDB.BIN
# Superfloppy: FAT16 straight at LBA 0, no MBR.
$(OUT)/superfloppy.img: $(OUT)/fw.bin $(OUT)/decoy1.bin
	cp $(OUT)/fw.bin $(OUT)/RV32OSDA.BIN; cp $(OUT)/decoy1.bin $(OUT)/832OSDAD.BIN
	rm -f $@; truncate -s 8M $@
	PATH=$$PATH:/usr/sbin:/sbin mkfs.fat -F 16 -s 2 -n MINIMIG $@ >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -i $@ $(OUT)/832OSDAD.BIN $(OUT)/RV32OSDA.BIN ::
# FAT32 superfloppy with a 40000-byte file (a longer cluster chain).
$(OUT)/fat32.img: $(OUT)/big.bin $(OUT)/decoy1.bin
	cp $(OUT)/big.bin $(OUT)/RV32OSDA.BIN; cp $(OUT)/decoy1.bin $(OUT)/832OSDAD.BIN
	rm -f $@; truncate -s 40M $@
	PATH=$$PATH:/usr/sbin:/sbin mkfs.fat -F 32 -s 1 -n MINIMIG $@ >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -i $@ $(OUT)/832OSDAD.BIN $(OUT)/RV32OSDA.BIN ::

test: $(OUT)/minfat_test $(OUT)/mbr_file.img $(OUT)/mbr_nofile.img $(OUT)/superfloppy.img $(OUT)/fat32.img
	$(OUT)/minfat_test $(OUT)/mbr_file.img $(OUT)/fw.bin
	$(OUT)/minfat_test $(OUT)/mbr_nofile.img -
	$(OUT)/minfat_test $(OUT)/superfloppy.img $(OUT)/fw.bin
	$(OUT)/minfat_test $(OUT)/fat32.img $(OUT)/big.bin
	@echo "minfat host test: ALL PASS"

clean:
	rm -rf $(OUT)

.PHONY: all test clean
