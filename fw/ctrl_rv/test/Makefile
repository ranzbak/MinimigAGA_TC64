# Host tests of the RISC-V OSD firmware (fw/ctrl_rv).  Every test is built
# twice, native (LP64) and -m32 (ILP32 like RV32), and run twice.
#   make -C fw/ctrl_rv/test                 build and run everything (exit status = result)
#   make -C fw/ctrl_rv/test run-cue_test    one test, native and -m32  (run64-/run32-: one of them)
#   make -C fw/ctrl_rv/test mutants         every test must go red on a mutated unit
#   make -C fw/ctrl_rv/test clean
# Settings (README.md has the setup of a fresh machine):
#   LIB832=<dir>   the lib832 checkout whose small_printf.c is the 832 reference
#                  (default $(TOP)/EightThirtyTwo/lib832, a submodule); missing = failure
#   ISO=<file>     the ISO of the ISO-backed atapi_test cases (also run once without)
#   CARD=<file>    the card image of mock_selftest (default: built by tools/sim/mkcard.sh)
#   FATIMG=<dir>   the three card images of fat_test and their listings (fatimg.sh;
#                  default $(B)); FATIMG_DEPS= uses them as they are (mutants.sh)
#   CFG832_DIR=<dir>  real 832 config files: config_test round-trips each (optional)
#   DRIVESND=<file>   the drive sounds file of drivesounds_test (default sw/mkdrivesounds/drivesnd.bin)
# Variables that mutants.sh points at a mutated copy of the sources, the tests
# and the gold files: SRC TD GOLD B, and WERROR=-Wno-error.

HOSTCC  = gcc
TOP    := $(abspath $(CURDIR)/../../..)
LIB832 ?= $(TOP)/EightThirtyTwo/lib832
ISO    ?= $(HOME)/work/amiga/AmigaOS3.9.iso
SRC    ?= ..
TD     ?= .
GOLD   ?= gold
B      ?= out
CARD   ?= $(B)/card.img
FATIMG ?= $(B)
FATIMG_DEPS ?= $(TD)/fatimg.sh $(GOLD)/fatdata.py $(GOLD)/fatlist.py $(TOP)/tools/sim/mkcard.sh
WERROR ?= -Werror
PY      = python3 -I

# gnu2x: the firmware's dialect (host gcc 13 spells gnu23 so).  -fno-builtin:
# printf("..\n") must stay printf, not become the firmware's puts (uart.c);
# -U_FORTIFY_SOURCE -D__NO_INLINE__: glibc must not rewrite putchar/printf.
# -funsigned-char: the firmware's char (tools/riscv/toolchain.mk); x86 gcc's
# default is signed.
CFLAGS  = -std=gnu2x -funsigned-char -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter $(WERROR) -O1 -g \
          -fsanitize=address,undefined -fno-sanitize-recover=all \
          -U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin -I$(SRC) -I$(SRC)/arch -I$(TD) -I$(B)
HDRS    = $(wildcard $(SRC)/*.h $(SRC)/arch/*.h $(TD)/*.h)

all: run

# ---- the tests -----------------------------------------------------------------
# $(call TEST,name,sources,compiler flags,run arguments)
define TEST
$$(B)/$(1): $$(TD)/$(1).c $(2) $$(HDRS)
	@mkdir -p $$(@D)
	$$(HOSTCC) $$(CFLAGS) $(3) -o $$@ $$(TD)/$(1).c $(2)
$$(B)/$(1)_32: $$(TD)/$(1).c $(2) $$(HDRS)
	@mkdir -p $$(@D)
	$$(HOSTCC) -m32 $$(CFLAGS) $(3) -o $$@ $$(TD)/$(1).c $(2)
run64-$(1):: $$(B)/$(1)
	$$(B)/$(1) $(4)
run32-$(1):: $$(B)/$(1)_32
	$$(B)/$(1)_32 $(4)
run-$(1): run64-$(1) run32-$(1)
.PHONY: run-$(1) run64-$(1) run32-$(1)
endef

$(eval $(call TEST,mock_selftest,$$(TD)/mock_hw.c $$(SRC)/hardware.c $$(SRC)/mmc.c $$(SRC)/uart.c,,$$(CARD)))
$(eval $(call TEST,cue_test,$$(SRC)/cue.c,,))
$(eval $(call TEST,cdaudio_test,$$(SRC)/cdaudio.c $$(SRC)/cue.c,,))
$(eval $(call TEST,atapi_test,$$(SRC)/atapi.c $$(SRC)/cue.c,,$$(ISO)))
$(eval $(call TEST,cdrom_test,$$(SRC)/cdrom.c $$(SRC)/atapi.c $$(SRC)/cue.c $$(SRC)/cdaudio.c,,))
$(eval $(call TEST,openhf_test,,-Wno-unused-function,))
$(eval $(call TEST,lib_test,$$(SRC)/rvlibc.c,,))
$(eval $(call TEST,hwmap_test,,,))
$(eval $(call TEST,swap_test,$$(SRC)/swap.c,,))
# spireply_test: SPI_reply() (hardware.c) waits for HOST_REQ's OSD_RDY, at
# most 2 TIMER counts (Phase 4 Task 11), on the mock's HOST_REQ
$(eval $(call TEST,spireply_test,$$(TD)/mock_hw.c $$(SRC)/hardware.c,,))

# fat_test: the real fat.c + mmc.c on the card model, once per image of
# fatimg.sh (FAT16 with MBR by mkcard.sh, FAT32 with MBR, FAT16 superfloppy);
# fat_check.sh adds the checks by mtools and fsck.fat.  The firmware's printf
# is rvlibc.c's (to the mock UART).
FAT_SRCS = $(TD)/mock_hw.c $(SRC)/hardware.c $(SRC)/mmc.c $(SRC)/uart.c $(SRC)/fat.c $(SRC)/swap.c $(SRC)/rvlibc.c
$(B)/fat_test: $(TD)/fat_test.c $(FAT_SRCS) $(HDRS)
	@mkdir -p $(@D)
	$(HOSTCC) $(CFLAGS) -o $@ $(TD)/fat_test.c $(FAT_SRCS)
$(B)/fat_test_32: $(TD)/fat_test.c $(FAT_SRCS) $(HDRS)
	@mkdir -p $(@D)
	$(HOSTCC) -m32 $(CFLAGS) -o $@ $(TD)/fat_test.c $(FAT_SRCS)
# (re)built when a script changed or one of its outputs is missing
FATIMG_OUT = $(addprefix $(FATIMG)/,fat16.img fat32.img super.img fat16.gold fat32.gold super.gold \
               fatdata/W3.BIN fatdata/lfn_names.txt)
$(FATIMG)/fatimg.ok: $(FATIMG_DEPS) $(if $(filter-out $(wildcard $(FATIMG_OUT)),$(FATIMG_OUT)),FORCE)
	bash $(TD)/fatimg.sh $(FATIMG) $(TOP)/tools/sim/mkcard.sh $(GOLD)
FORCE:
.PHONY: FORCE
run64-fat_test: $(B)/fat_test $(FATIMG)/fatimg.ok
	bash $(TD)/fat_check.sh $(B)/fat_test $(FATIMG) $(B) fat16 64
	bash $(TD)/fat_check.sh $(B)/fat_test $(FATIMG) $(B) fat32 64
	bash $(TD)/fat_check.sh $(B)/fat_test $(FATIMG) $(B) super 64
run32-fat_test: $(B)/fat_test_32 $(FATIMG)/fatimg.ok
	bash $(TD)/fat_check.sh $(B)/fat_test_32 $(FATIMG) $(B) fat16 32
	bash $(TD)/fat_check.sh $(B)/fat_test_32 $(FATIMG) $(B) fat32 32
	bash $(TD)/fat_check.sh $(B)/fat_test_32 $(FATIMG) $(B) super 32
run-fat_test: run64-fat_test run32-fat_test
.PHONY: run-fat_test run64-fat_test run32-fat_test

# mmc_test: the real mmc.c on the card model (SD_TIMEOUT bounds, token delay,
# busy, MMC_Init's command sequence against the L2 boot run's SD log, the
# direct-mode trace gold/dmode.txt, which gold/dmode.py must reproduce)
MMC_SRCS = $(TD)/mock_hw.c $(SRC)/hardware.c $(SRC)/mmc.c $(SRC)/uart.c $(SRC)/rvlibc.c
$(B)/mmc_test: $(TD)/mmc_test.c $(MMC_SRCS) $(HDRS)
	@mkdir -p $(@D)
	$(HOSTCC) $(CFLAGS) -o $@ $(TD)/mmc_test.c $(MMC_SRCS)
$(B)/mmc_test_32: $(TD)/mmc_test.c $(MMC_SRCS) $(HDRS)
	@mkdir -p $(@D)
	$(HOSTCC) -m32 $(CFLAGS) -o $@ $(TD)/mmc_test.c $(MMC_SRCS)
$(B)/dmode.ok: $(GOLD)/dmode.py $(GOLD)/dmode.txt
	@mkdir -p $(@D)
	$(PY) $(GOLD)/dmode.py 513 | cmp - $(GOLD)/dmode.txt
	touch $@
run64-mmc_test: $(B)/mmc_test $(B)/dmode.ok
	$(B)/mmc_test $(GOLD) $(B)/mmc_64
run32-mmc_test: $(B)/mmc_test_32 $(B)/dmode.ok
	$(B)/mmc_test_32 $(GOLD) $(B)/mmc_32
run-mmc_test: run64-mmc_test run32-mmc_test
.PHONY: run-mmc_test run64-mmc_test run32-mmc_test

# config_test: the config file's byte order (Task 11): cfgswap.c, cfgconv
# (built here with the sanitizers, native and -m32), LoadConfiguration of
# the real config.c over fat.c + mmc.c on the card model.  The cases come
# from gold/mkcfg832.py (832 files and the expected fields, cfgcases.h);
# config_check.sh runs cfgconv on them, builds the card images and checks
# the card config_test saved with mtools and fsck.fat.  CFG832_DIR=<dir>:
# the same round trip on real 832 config files.
CFG_SRCS = $(TD)/mock_hw.c $(SRC)/hardware.c $(SRC)/mmc.c $(SRC)/uart.c $(SRC)/fat.c $(SRC)/swap.c \
           $(SRC)/rvlibc.c $(SRC)/errors.c $(SRC)/rafile.c $(SRC)/config.c $(SRC)/cfgswap.c
CFGCONV_SRCS = $(SRC)/tools/cfgconv/cfgconv.c $(SRC)/cfgswap.c
$(B)/cfg/cfgcases.h: $(GOLD)/mkcfg832.py
	@mkdir -p $(@D)
	$(PY) $(GOLD)/mkcfg832.py $(@D)
$(B)/config_test: $(TD)/config_test.c $(CFG_SRCS) $(HDRS) $(B)/cfg/cfgcases.h
	$(HOSTCC) $(CFLAGS) -I$(B)/cfg -o $@ $(TD)/config_test.c $(CFG_SRCS)
$(B)/config_test_32: $(TD)/config_test.c $(CFG_SRCS) $(HDRS) $(B)/cfg/cfgcases.h
	$(HOSTCC) -m32 $(CFLAGS) -I$(B)/cfg -o $@ $(TD)/config_test.c $(CFG_SRCS)
$(B)/cfgconv: $(CFGCONV_SRCS) $(SRC)/cfgswap.h $(SRC)/swap.h
	@mkdir -p $(@D)
	$(HOSTCC) $(CFLAGS) -o $@ $(CFGCONV_SRCS)
$(B)/cfgconv_32: $(CFGCONV_SRCS) $(SRC)/cfgswap.h $(SRC)/swap.h
	@mkdir -p $(@D)
	$(HOSTCC) -m32 $(CFLAGS) -o $@ $(CFGCONV_SRCS)
run64-config_test: $(B)/config_test $(B)/cfgconv
	CFG832_DIR='$(CFG832_DIR)' bash $(TD)/config_check.sh $(B)/config_test $(B)/cfgconv $(B)/cfg $(B) 64 $(TOP)/tools/sim/mkcard.sh
run32-config_test: $(B)/config_test_32 $(B)/cfgconv_32
	CFG832_DIR='$(CFG832_DIR)' bash $(TD)/config_check.sh $(B)/config_test_32 $(B)/cfgconv_32 $(B)/cfg $(B) 32 $(TOP)/tools/sim/mkcard.sh
run-config_test: run64-config_test run32-config_test
.PHONY: run-config_test run64-config_test run32-config_test

# hdd_test: the real hdd.c over fat.c + mmc.c on the card model, driven
# through HandleHDD() by the test's mock Gayle (Task 12): FakeRDB's RDSK and
# PART blocks against gold/rdb.py, IDENTIFY DEVICE against gold/identify.py,
# the RDB patch of an HDF's own RDB, READ/WRITE (MULTIPLE) LBA/CHS, chunks
# and data against the HDF files rdb.py writes (on a mkcard.sh card).
HDD_SRCS = $(TD)/mock_hw.c $(SRC)/hardware.c $(SRC)/mmc.c $(SRC)/uart.c $(SRC)/fat.c $(SRC)/swap.c \
           $(SRC)/rvlibc.c $(SRC)/errors.c $(SRC)/hdd.c
$(B)/hdd/rdb.ok: $(GOLD)/rdb.py
	@mkdir -p $(@D)
	$(PY) $(GOLD)/rdb.py $(@D)
	touch $@
$(B)/hdd/identcases.h: $(GOLD)/identify.py
	@mkdir -p $(@D)
	$(PY) $(GOLD)/identify.py $(@D)
$(B)/hdd/hdd.img: $(B)/hdd/rdb.ok $(TOP)/tools/sim/mkcard.sh
	bash $(TOP)/tools/sim/mkcard.sh $@ 32 $(B)/hdd/hdf/WORK.HDF $(B)/hdd/hdf/SYNTH.HDF $(B)/hdd/hdf/ODD.HDF
$(B)/hdd_test: $(TD)/hdd_test.c $(HDD_SRCS) $(HDRS) $(B)/hdd/rdb.ok $(B)/hdd/identcases.h
	$(HOSTCC) $(CFLAGS) -I$(B)/hdd -o $@ $(TD)/hdd_test.c $(HDD_SRCS)
$(B)/hdd_test_32: $(TD)/hdd_test.c $(HDD_SRCS) $(HDRS) $(B)/hdd/rdb.ok $(B)/hdd/identcases.h
	$(HOSTCC) -m32 $(CFLAGS) -I$(B)/hdd -o $@ $(TD)/hdd_test.c $(HDD_SRCS)
run64-hdd_test: $(B)/hdd_test $(B)/hdd/hdd.img
	$(B)/hdd_test $(B)/hdd
run32-hdd_test: $(B)/hdd_test_32 $(B)/hdd/hdd.img
	$(B)/hdd_test_32 $(B)/hdd
run-hdd_test: run64-hdd_test run32-hdd_test
.PHONY: run-hdd_test run64-hdd_test run32-hdd_test

# fdd_test: the floppy emulation (Task 13): ReadTrack's MFM track streams and
# WriteTrack's decoder (FindSync/GetHeader/GetData) behind a mock paula_floppy,
# against gold/mfm.py (an independent Amiga MFM encoder) and against the 832's
# fdd.c compiled for the host with the same mock.  The 832 source is copied
# unchanged into $(B)/fdd/ (from its own directory "hardware.h" would be the
# 832's, which has no HOSTTEST hooks: the copy takes the RV tree's headers,
# which differ from the 832's in the hooks, the I/O addresses, uint32_t for
# unsigned long, alignment and prototypes, none of which fdd.c's bytes
# depend on), built
# -std=gnu17 -funsigned-char like the 832 firmware, -Wno-parentheses for its
# two unparenthesised `11 - sector >> 1 & 0x55` lines (Task 7 parenthesised
# them in fw/ctrl_rv), and its globals renamed <name>_832 (objcopy, with
# ASan's __odr_asan.<name>) so that both link into one test.  The golden
# streams of tracks 0 and 159 are committed (gold/mfm_c00_s0.hex,
# gold/mfm_c79_s1.hex, Phase 4's L3 data check): mfm.py must reproduce them.
OBJCOPY ?= objcopy
FDD832  := $(TOP)/fw/ctrl_832/fdd.c
FDD832_DATA = DEBUG drives pdfx df
FDD832_FUNCS = SendSector SendGap ReadTrack FindSync GetHeader GetData WriteTrack UpdateDriveStatus HandleFDD
FDD832_RENAME = $(foreach s,$(FDD832_DATA),--redefine-sym $(s)=$(s)_832 --redefine-sym __odr_asan.$(s)=__odr_asan.$(s)_832) \
                $(foreach s,$(FDD832_FUNCS),--redefine-sym $(s)=$(s)_832)
FDD_SRCS = $(TD)/mock_hw.c $(SRC)/uart.c $(SRC)/rvlibc.c $(SRC)/errors.c $(SRC)/fdd.c
$(B)/fdd/fddcases.h: $(GOLD)/mfm.py
	@mkdir -p $(@D)
	$(PY) $(GOLD)/mfm.py $(@D)
$(B)/fdd/gold.ok: $(B)/fdd/fddcases.h $(GOLD)/mfm_c00_s0.hex $(GOLD)/mfm_c79_s1.hex
	cmp $(B)/fdd/track_c00_s0.hex $(GOLD)/mfm_c00_s0.hex
	cmp $(B)/fdd/track_c79_s1.hex $(GOLD)/mfm_c79_s1.hex
	touch $@
$(B)/fdd/fdd832.c: $(FDD832)
	@mkdir -p $(@D)
	cp $(FDD832) $@
$(B)/fdd/fdd832_64.o: $(B)/fdd/fdd832.c $(HDRS)
	$(HOSTCC) $(CFLAGS) -std=gnu17 -funsigned-char -Wno-parentheses -c -o $@ $(B)/fdd/fdd832.c
	$(OBJCOPY) $(FDD832_RENAME) $@
$(B)/fdd/fdd832_32.o: $(B)/fdd/fdd832.c $(HDRS)
	$(HOSTCC) -m32 $(CFLAGS) -std=gnu17 -funsigned-char -Wno-parentheses -c -o $@ $(B)/fdd/fdd832.c
	$(OBJCOPY) $(FDD832_RENAME) $@
$(B)/fdd_test: $(TD)/fdd_test.c $(FDD_SRCS) $(HDRS) $(B)/fdd/fddcases.h $(B)/fdd/fdd832_64.o
	$(HOSTCC) $(CFLAGS) -I$(B)/fdd -o $@ $(TD)/fdd_test.c $(FDD_SRCS) $(B)/fdd/fdd832_64.o
$(B)/fdd_test_32: $(TD)/fdd_test.c $(FDD_SRCS) $(HDRS) $(B)/fdd/fddcases.h $(B)/fdd/fdd832_32.o
	$(HOSTCC) -m32 $(CFLAGS) -I$(B)/fdd -o $@ $(TD)/fdd_test.c $(FDD_SRCS) $(B)/fdd/fdd832_32.o
# the audit's SPIN rule (plan 7.1 item 11): fdd.c's SPINs stay commented, as many as the 832's
$(B)/fdd/spin.ok: $(SRC)/fdd.c $(FDD832)
	@mkdir -p $(@D)
	@if grep -n 'SPIN' $(SRC)/fdd.c | grep -v '^[0-9]*:[[:space:]]*//[[:space:]]*SPIN;[[:space:]]*$$'; then \
	    echo "FAIL fdd.c: a SPIN that is not commented out"; false; fi
	test "$$(grep -c SPIN $(SRC)/fdd.c)" = "$$(grep -c SPIN $(FDD832))"
	touch $@
# the write-FIFO gap (Phase 4 Task 14, README "Write-FIFO gap"): the listed
# exception to "No new count-based delays", exactly its 20 sites in fdd.c
$(B)/fdd/wrfifo.ok: $(SRC)/fdd.c
	@mkdir -p $(@D)
	test "$$(grep -c '^[[:space:]]*WRFIFO_GAP;[[:space:]]*$$' $(SRC)/fdd.c)" = 20
	@if grep -ln 'WRFIFO_GAP' $(SRC)/*.c | grep -v '/fdd\.c$$'; then echo "FAIL WRFIFO_GAP outside fdd.c"; false; fi
	@touch $@

run64-fdd_test: $(B)/fdd_test $(B)/fdd/gold.ok $(B)/fdd/spin.ok $(B)/fdd/wrfifo.ok
	$(B)/fdd_test $(B)/fdd
run32-fdd_test: $(B)/fdd_test_32 $(B)/fdd/gold.ok $(B)/fdd/spin.ok $(B)/fdd/wrfifo.ok
	$(B)/fdd_test_32 $(B)/fdd
run-fdd_test: run64-fdd_test run32-fdd_test
.PHONY: run-fdd_test run64-fdd_test run32-fdd_test

# drivesounds_test: the drive sound ring (Task 14): the real drivesounds.c
# loads sw/mkdrivesounds/drivesnd.bin and gold/drivesounds.py's SYNTH.BIN
# through rafile.c + fat.c + mmc.c on the card model, renders a fixed event
# sequence into the mock's ring; drivesounds.py (the 832's file format and
# render arithmetic) writes the ring after every fill (ring_<case>.bin) and
# the op lists (dscases.h); and five bad files with the RV port's bounded
# load (dscases.h ds_bad).
DRIVESND ?= $(TOP)/sw/mkdrivesounds/drivesnd.bin
DS_SRCS = $(TD)/mock_hw.c $(SRC)/hardware.c $(SRC)/mmc.c $(SRC)/uart.c $(SRC)/fat.c $(SRC)/swap.c \
          $(SRC)/rvlibc.c $(SRC)/errors.c $(SRC)/rafile.c $(SRC)/audio.c $(SRC)/i2c.c $(SRC)/drivesounds.c
$(B)/ds/dscases.h: $(GOLD)/drivesounds.py $(DRIVESND)
	@mkdir -p $(@D)
	$(PY) $(GOLD)/drivesounds.py $(@D) $(DRIVESND)
$(B)/ds/card.img: $(B)/ds/dscases.h $(DRIVESND) $(TOP)/tools/sim/mkcard.sh
	cp $(DRIVESND) $(@D)/DRIVESND.BIN
	bash $(TOP)/tools/sim/mkcard.sh $@ 8 $(@D)/DRIVESND.BIN $(@D)/SYNTH.BIN \
	  $(@D)/TRUNC.BIN $(@D)/ODDLEN.BIN $(@D)/ODDSND.BIN $(@D)/NEGSIZE.BIN $(@D)/NEGID.BIN
$(B)/drivesounds_test: $(TD)/drivesounds_test.c $(DS_SRCS) $(HDRS) $(B)/ds/dscases.h
	$(HOSTCC) $(CFLAGS) -I$(B)/ds -o $@ $(TD)/drivesounds_test.c $(DS_SRCS)
$(B)/drivesounds_test_32: $(TD)/drivesounds_test.c $(DS_SRCS) $(HDRS) $(B)/ds/dscases.h
	$(HOSTCC) -m32 $(CFLAGS) -I$(B)/ds -o $@ $(TD)/drivesounds_test.c $(DS_SRCS)
run64-drivesounds_test: $(B)/drivesounds_test $(B)/ds/card.img
	$(B)/drivesounds_test $(B)/ds
run32-drivesounds_test: $(B)/drivesounds_test_32 $(B)/ds/card.img
	$(B)/drivesounds_test_32 $(B)/ds
run-drivesounds_test: run64-drivesounds_test run32-drivesounds_test
.PHONY: run-drivesounds_test run64-drivesounds_test run32-drivesounds_test

# boot_test: the default copper list (boot.c), CheckSum (main.c, cut out:
# main.c holds main()) and hexdump.c, by their bytes (Task 14).  boot.c's
# (int)adr casts of Amiga addresses are 32-bit casts (exact on RV32 and -m32;
# the LP64 build does not run them): their LP64 warnings are off here.
$(B)/checksum.inc: $(SRC)/main.c
	@mkdir -p $(@D)
	sed -n '/^int CheckSum(char \*adr,int size)/,/^}/p' $(SRC)/main.c > $@
	grep -q '^int CheckSum' $@
$(eval $(call TEST,boot_test,$$(TD)/mock_hw.c $$(SRC)/hardware.c $$(SRC)/uart.c $$(SRC)/boot.c $$(SRC)/hexdump.c,-Wno-pointer-to-int-cast -Wno-int-to-pointer-cast,))
$(B)/boot_test $(B)/boot_test_32: $(B)/checksum.inc

# atapi_test without the ISO: the ISO-backed cases are skipped, not failed
run64-atapi_test::
	$(B)/atapi_test /nonexistent.iso
run32-atapi_test::
	$(B)/atapi_test_32 /nonexistent.iso

# the card image of mock_selftest: tools/sim/mkcard.sh, byte-reproducible
$(B)/card.img: $(TOP)/tools/sim/mkcard.sh
	@mkdir -p $(@D)
	printf 'host test card\n' > $(@D)/HELLO.TXT
	bash $(TOP)/tools/sim/mkcard.sh $@ 8 $(@D)/HELLO.TXT
$(B)/mock_selftest $(B)/mock_selftest_32: | $(CARD)

# OpenHardfile alone, with stubs for the FAT calls (the CD slot case): cut
# out of hdd.c.  hdd.c as a whole builds under HOSTTEST (hdd_test links it);
# openhf_test keeps the cut so that its stubs stay the only FAT it sees.
$(B)/openhf.inc: $(SRC)/hdd.c
	@mkdir -p $(@D)
	sed -n '/^unsigned char OpenHardfile(unsigned int unit)/,/^}/p' $(SRC)/hdd.c > $@
	grep -q '^unsigned char OpenHardfile' $@
$(B)/openhf_test $(B)/openhf_test_32: $(B)/openhf.inc

# check_io: fw/ctrl_rv/check_io.awk (make check (b), (c)) on the fixture
# check_io/*.dis against check_io/expected.txt (check_io.sh)
check_io: $(SRC)/check_io.awk $(TD)/check_io.sh $(wildcard $(TD)/check_io/*)
	@mkdir -p $(B)
	bash $(TD)/check_io.sh $(SRC)/check_io.awk $(TD)/check_io $(B)/check_io.txt
.PHONY: check_io

run: fmt check_io run-mock_selftest run-cue_test run-cdaudio_test run-atapi_test run-cdrom_test \
     run-openhf_test run-lib_test run-hwmap_test run-spireply_test run-swap_test run-fat_test run-mmc_test \
     run-config_test run-hdd_test run-fdd_test run-drivesounds_test run-boot_test

clean:
	$(RM) -r out mut
	$(RM) cue_test cdaudio_test atapi_test cdrom_test openhf_test openhf.inc hwmap_test hwmap_test_32 \
	      lib_test lib_test_32 fmt_glibc_64 fmt_glibc_32 fmt_832 fmt_832.o fmt_host_832.o \
	      fmt_glibc_64.txt fmt_glibc_32.txt fmt_832.txt fmt_diff.txt fmt.ok

mutants:
	LIB832='$(LIB832)' ISO='$(ISO)' HOSTCC='$(HOSTCC)' bash mutants.sh

.PHONY: all run clean mutants fmt

# ---- C library (decision 12.12): rvlibc.c and the format-parity check ----------
# LIB832 is the lib832 checkout whose small_printf.c is the 832 reference:
#   git submodule update --init EightThirtyTwo      (default LIB832)
#   make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832
# A missing LIB832 fails the build; it does not skip the check.
FMTDEPS = $(TD)/fmt_host.c $(TD)/fmt_run.h $(TD)/fmt_cases.h $(SRC)/rvlibc.c $(SRC)/rvlibc.h

# printf of rvlibc.c over glibc's vsnprintf, native and ILP32
$(B)/fmt_glibc_64: $(FMTDEPS)
	@mkdir -p $(@D)
	$(HOSTCC) $(CFLAGS) -o $@ $(TD)/fmt_host.c $(SRC)/rvlibc.c
$(B)/fmt_glibc_32: $(FMTDEPS)
	@mkdir -p $(@D)
	$(HOSTCC) -m32 $(CFLAGS) -o $@ $(TD)/fmt_host.c $(SRC)/rvlibc.c
$(B)/fmt_glibc_%.txt: $(B)/fmt_glibc_%
	$< > $@

# lib832's printf (the 832 reference): small_printf.c unchanged, compiled
# -std=gnu17 -m32 -funsigned-char (the 832 firmware is built unsigned-char)
# with its names moved aside so that it links next to glibc; the shim counts
# the bytes that reach putchar
$(LIB832)/small_printf.c:
	@echo "LIB832=$(LIB832): no small_printf.c (git submodule update --init EightThirtyTwo, or set LIB832=)"; false
$(B)/fmt_832.o: $(LIB832)/small_printf.c
	@mkdir -p $(@D)
	$(HOSTCC) -std=gnu17 -m32 -funsigned-char -w -D__weak= -Dprintf=ref832_printf -Dsprintf=ref832_sprintf \
	    -Dsnprintf=ref832_snprintf -Dvprintf=ref832_vprintf -Dvsprintf=ref832_vsprintf \
	    -Dputchar=ref832_putchar -I$(LIB832) -c -o $@ $(LIB832)/small_printf.c
$(B)/fmt_host_832.o: $(FMTDEPS)
	@mkdir -p $(@D)
	$(HOSTCC) -m32 -std=gnu2x -funsigned-char -O1 -g -fno-builtin -Wall -Wextra $(WERROR) -DFMT_REF832 -c -o $@ $(TD)/fmt_host.c
$(B)/fmt_832: $(B)/fmt_host_832.o $(B)/fmt_832.o
	$(HOSTCC) -m32 -o $@ $^
$(B)/fmt_832.txt: $(B)/fmt_832
	$< > $@

# the gates: formats.txt is current, every format has a case, the ILP32 and
# LP64 hosts agree, and the 832-versus-RV differences are exactly the expected list
$(B)/fmt.ok: $(B)/fmt_glibc_64.txt $(B)/fmt_glibc_32.txt $(B)/fmt_832.txt $(GOLD)/formats.txt \
             $(GOLD)/fmt_diff_expected.txt $(GOLD)/fmtcheck.py $(wildcard $(SRC)/*.c)
	grep -ho '"[^"]*%[^"]*"' $(SRC)/*.c | LC_ALL=C sort -u | cmp - $(GOLD)/formats.txt
	$(PY) $(GOLD)/fmtcheck.py cover $(GOLD)/formats.txt $(TD)/fmt_cases.h
	cmp $(B)/fmt_glibc_64.txt $(B)/fmt_glibc_32.txt
	$(PY) $(GOLD)/fmtcheck.py diff $(B)/fmt_832.txt $(B)/fmt_glibc_64.txt $(TD)/fmt_cases.h > $(B)/fmt_diff.txt
	diff $(GOLD)/fmt_diff_expected.txt $(B)/fmt_diff.txt
	touch $@
fmt: $(B)/fmt.ok
fmt.ok: fmt	# the old name (sim/rv_l1/run.sh)
