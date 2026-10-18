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
CFLAGS  = -std=gnu2x -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter $(WERROR) -O1 -g \
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
$(FATIMG)/fatimg.ok: $(FATIMG_DEPS)
	bash $(TD)/fatimg.sh $(FATIMG) $(TOP)/tools/sim/mkcard.sh $(GOLD)
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

# OpenHardfile alone: hdd.c as a whole does not build with gcc
$(B)/openhf.inc: $(SRC)/hdd.c
	@mkdir -p $(@D)
	sed -n '/^unsigned char OpenHardfile(unsigned int unit)/,/^}/p' $(SRC)/hdd.c > $@
	grep -q '^unsigned char OpenHardfile' $@
$(B)/openhf_test $(B)/openhf_test_32: $(B)/openhf.inc

run: fmt run-mock_selftest run-cue_test run-cdaudio_test run-atapi_test run-cdrom_test \
     run-openhf_test run-lib_test run-hwmap_test run-swap_test run-fat_test

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
