# Host tests for the CD-ROM (findings/cdrom/plan.md): atapi_test, the ATAPI
# command layer (task 0.1); cdrom_test, the board glue against a model of
# the Gayle port and an ATAPI host (task 1.4); phase 3
# (findings/cdrom/phase3-plan.md): cue_test, the CUE parser and disc model;
# cdaudio_test, the CD audio player against a model of the audio ring;
# openhf_test, hdd.c's OpenHardfile on a CD slot (cut out of hdd.c).
#   make -C fw/ctrl_832/test            build and run them all (exit status = result)
#   make -C fw/ctrl_832/test ISO=<path> use another ISO for the ISO-backed cases
# Without the ISO those cases are skipped, not failed.

HOSTCC   = gcc
CFLAGS   = -std=c99 -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g \
           -fsanitize=address,undefined -fno-sanitize-recover=all -I..
ISO     ?= $(HOME)/work/amiga/AmigaOS3.9.iso

all: run

atapi_test: atapi_test.c ../atapi.c ../atapi.h ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c ../cue.c

cue_test: cue_test.c ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ cue_test.c ../cue.c

cdaudio_test: cdaudio_test.c ../cdaudio.c ../cdaudio.h ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ cdaudio_test.c ../cdaudio.c ../cue.c

cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../cdaudio.c ../cdaudio.h ../hdd.h
	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c ../cdaudio.c

# OpenHardfile alone: hdd.c as a whole does not build with gcc
openhf.inc: ../hdd.c
	sed -n '/^unsigned char OpenHardfile(unsigned int unit)/,/^}/p' ../hdd.c > $@
	grep -q '^unsigned char OpenHardfile' $@

openhf_test: openhf_test.c openhf.inc ../hdd.h ../config.h ../cdrom.h
	$(HOSTCC) $(CFLAGS) -Wno-unused-function -o $@ openhf_test.c

run: cue_test cdaudio_test atapi_test cdrom_test openhf_test lib_run hwmap_run
	./cue_test
	./cdaudio_test
	./atapi_test "$(ISO)"
	./cdrom_test
	./openhf_test

clean:
	rm -f cue_test cdaudio_test atapi_test cdrom_test openhf_test openhf.inc
	rm -f hwmap_test hwmap_test_32 lib_test lib_test_32 fmt_glibc_64 fmt_glibc_32 fmt_832 fmt_832.o fmt_host_832.o \
	      fmt_glibc_64.txt fmt_glibc_32.txt fmt_832.txt fmt_diff.txt fmt.ok
	rm -rf mut

.PHONY: all run clean lib_run mutants hwmap_run

# ---- C library (decision 12.12): rvlibc.c and the format-parity check --------
#   make -C fw/ctrl_rv/test lib_test && ./fw/ctrl_rv/test/lib_test
#   make -C fw/ctrl_rv/test mutants        (the full harness's mutants: Task 8)
# LIB832 is the lib832 checkout whose small_printf.c is the 832 reference:
#   git submodule update --init EightThirtyTwo      (default LIB832)
#   make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832
# A missing LIB832 fails the build; it does not skip the check.
TOP     := $(abspath $(CURDIR)/../../..)
LIB832  ?= $(TOP)/EightThirtyTwo/lib832
LIBFLAGS = -std=gnu2x -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g \
           -fsanitize=address,undefined -fno-sanitize-recover=all \
           -U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin
PY      = python3 -I
FMTDEPS = fmt_host.c fmt_run.h fmt_cases.h ../rvlibc.c ../rvlibc.h

# printf of rvlibc.c over glibc's vsnprintf, native and ILP32
fmt_glibc_64: $(FMTDEPS)
	$(HOSTCC) $(LIBFLAGS) -I.. -o $@ fmt_host.c ../rvlibc.c
fmt_glibc_32: $(FMTDEPS)
	$(HOSTCC) -m32 $(LIBFLAGS) -I.. -o $@ fmt_host.c ../rvlibc.c
fmt_glibc_%.txt: fmt_glibc_%
	./$< > $@

# lib832's printf (the 832 reference): small_printf.c unchanged, compiled
# -std=gnu17 -m32 (its %l reads an int) with its names moved aside so that it
# links next to glibc; the shim counts the bytes that reach putchar
$(LIB832)/small_printf.c:
	@echo "LIB832=$(LIB832): no small_printf.c (git submodule update --init EightThirtyTwo, or set LIB832=)"; false
fmt_832.o: $(LIB832)/small_printf.c
	$(HOSTCC) -std=gnu17 -m32 -w -D__weak= -Dprintf=ref832_printf -Dsprintf=ref832_sprintf \
	    -Dsnprintf=ref832_snprintf -Dvprintf=ref832_vprintf -Dvsprintf=ref832_vsprintf \
	    -Dputchar=ref832_putchar -I$(LIB832) -c -o $@ $(LIB832)/small_printf.c
fmt_host_832.o: $(FMTDEPS)
	$(HOSTCC) -m32 -std=gnu2x -O1 -g -fno-builtin -Wall -Wextra -Werror -DFMT_REF832 -c -o $@ fmt_host.c
fmt_832: fmt_host_832.o fmt_832.o
	$(HOSTCC) -m32 -o $@ fmt_host_832.o fmt_832.o
fmt_832.txt: fmt_832
	./$< > $@

# the gates: formats.txt is current, every format has a case, the ILP32 and
# LP64 hosts agree, and the 832-versus-RV differences are exactly the expected list
fmt.ok: fmt_glibc_64.txt fmt_glibc_32.txt fmt_832.txt gold/formats.txt gold/fmt_diff_expected.txt gold/fmtcheck.py $(wildcard ../*.c)
	grep -ho '"[^"]*%[^"]*"' ../*.c | LC_ALL=C sort -u | cmp - gold/formats.txt
	$(PY) gold/fmtcheck.py cover gold/formats.txt fmt_cases.h
	cmp fmt_glibc_64.txt fmt_glibc_32.txt
	$(PY) gold/fmtcheck.py diff fmt_832.txt fmt_glibc_64.txt fmt_cases.h > fmt_diff.txt
	diff gold/fmt_diff_expected.txt fmt_diff.txt
	touch $@

lib_test: lib_test.c ../rvlibc.c ../rvlibc.h fmt.ok
	$(HOSTCC) $(LIBFLAGS) -I.. -o $@ lib_test.c ../rvlibc.c
lib_test_32: lib_test.c ../rvlibc.c ../rvlibc.h fmt.ok
	$(HOSTCC) -m32 $(LIBFLAGS) -I.. -o $@ lib_test.c ../rvlibc.c
lib_run: lib_test lib_test_32
	./lib_test
	./lib_test_32

mutants: fmt.ok
	bash mutants.sh

# ---- I/O register map and uart.c puts (plan 5.3) -------------------------------
#   make -C fw/ctrl_rv/test hwmap_test && ./fw/ctrl_rv/test/hwmap_test
hwmap_test: hwmap_test.c ../hardware.h ../uart.h ../uart.c ../c64keys.h ../akiko.h ../rtc.h ../i2c.h ../arch/irq.h
	$(HOSTCC) $(LIBFLAGS) -I.. -I../arch -o $@ hwmap_test.c
hwmap_test_32: hwmap_test.c ../hardware.h ../uart.h ../uart.c ../c64keys.h ../akiko.h ../rtc.h ../i2c.h ../arch/irq.h
	$(HOSTCC) -m32 $(LIBFLAGS) -I.. -I../arch -o $@ hwmap_test.c
hwmap_run: hwmap_test hwmap_test_32
	./hwmap_test
	./hwmap_test_32
