# OSD / host firmware for the VexRiscv host CPU (RV32IMC): RV32OSDB.BIN
# (the name: fwname.mk), loaded by the boot ROM (fw/ctrl_boot) to 0x2000
# (see README.md).
#
#   make          $(B)/RV32OSDB.BIN (+ .elf, .map, .lst)
#   make size     section sizes and the bytes of the .BIN
#   make check    (a) no lr.w/sc.w/amo*.w, (b) no UART read, (c) I/O offsets
#                 multiple of 4 (both via check_io.awk), (d) no start-up names
#                 of the previous (vbcc) toolchain in the sources,
#                 (e) the C library guard, (f) no #define true/false,
#                 (g) the boot ROM image ends below the stack floor 0x1400,
#                 (h) RV32OSDB.BIN ends with the lock-step trailer (SDC_VERSION),
#                 (i) the committed boot ROM image looks for this file name
#   make stack    the 20 largest stack frames (-fstack-usage, $(B)/*.su)
#   make clean
#
#   B=dir         output directory (default build)
#   CLANG=1       portability check (decision 12.8 gate 1b): compile with
#                 clang/LLVM into build_clang/, link with the xPack gcc
#                 driver; gcc stays the shipping build (README "Clang build")
#   EXTRA_CFLAGS  extra compiler flags for bench variants (empty for the
#                 shipped image)
#   EXTRA_OBJS    extra objects linked after the firmware's (bench variants,
#                 e.g. sim/host_bridge/fwboot/smoke_trap.o; empty for the
#                 shipped image)
TOP := $(abspath ../..)
include $(TOP)/tools/riscv/toolchain.mk

ifeq ($(CLANG),1)
B            ?= build_clang
else
B            ?= build
endif
EXTRA_CFLAGS ?=
EXTRA_OBJS   ?=
ARCH_B       := $(B)
include $(TOP)/fw/ctrl/arch/arch.mk
.DEFAULT_GOAL := all

RV_NM   = $(RV_GCC_DIR)/bin/$(RV_PREFIX)nm

# the file name, shared with the boot ROM and the sims (fwname.mk)
include $(TOP)/fw/ctrl/fwname.mk
PROJECT := $(FW_NAME)

# the firmware's sources (the interrupt API is arch/irq.c, arch.mk), plus
# the C library glue
SRCS := hardware.c config.c fat.c fdd.c fpga.c boot.c hdd.c main.c menu.c \
        mmc.c spi.c osd.c rafile.c swap.c hexdump.c uart.c errors.c \
        c64keys.c akiko.c audio.c drivesounds.c rtc.c i2c.c adv7511.c \
        atapi.c cdrom.c cue.c cdaudio.c rvlibc.c cfgswap.c stackcheck.c \
        diskstat.c sdc.c sdproto.c
OBJS := $(addprefix $(B)/,$(SRCS:.c=.o))

ifeq ($(CLANG),1)
# clang has no nano.specs and no -fstack-usage: newlib-nano's headers by hand
# (nano first: its newlib.h describes the struct _reent of libc_nano.a).
# Compile only: the link stays on the xPack gcc driver (LDFLAGS below), so
# the map is GNU ld's and check (e) reads it unchanged.
CLANG_CC     ?= clang
CLANG_TARGET := --target=riscv32-unknown-elf
NANO_INC     := -isystem $(RV_GCC_DIR)/riscv-none-elf/include/newlib-nano \
                -isystem $(RV_GCC_DIR)/riscv-none-elf/include
# gcc-only spellings in the sources (#pragma GCC diagnostic ignored
# "-Wmaybe-uninitialized" in hdd.c/drivesounds.c, __attribute__((nonstring))
# in menu.c): not defects, clang has no such warning/attribute
CLANG_WNO    := -Wno-unknown-warning-option -Wno-unknown-attributes
CFLAGS  := $(RV_CFLAGS_FW) -std=gnu23 $(NANO_INC) -g -I. -Iarch \
           -I$(B) -Wall -Wextra -Werror $(CLANG_WNO) -MMD -MP $(EXTRA_CFLAGS)
$(ARCH_OBJS) $(OBJS): RV_CC := $(CLANG_CC) $(CLANG_TARGET)
else
CFLAGS  := $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -I. -Iarch \
           -I$(B) -Wall -Wextra -Werror -fstack-usage -MMD -MP $(EXTRA_CFLAGS)
endif
LDFLAGS := $(RV_LDFLAGS_FW) --specs=nano.specs $(ARCH_LDFLAGS) \
           -Wl,-Map,$(B)/$(PROJECT).map
LIBS    := -lc_nano $(RV_LIBS_FW)

all: $(B)/$(FW_FILE)

$(B)/%.o: %.c | $(B)/version.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/$(PROJECT).elf: $(ARCH_OBJS) $(OBJS) $(EXTRA_OBJS) $(ARCH_LD)
	$(RV_CC) $(LDFLAGS) -o $@ $(ARCH_OBJS) $(OBJS) $(EXTRA_OBJS) $(LIBS)
	$(RV_OBJDUMP) -d -S $@ > $(B)/$(PROJECT).lst

# the image, then the lock-step trailer (8 bytes: 'S','D','C','V', 0, 0,
# SDC_VERSION high, low; sdctrailer.c, from sdc.h): the boot ROM boots the
# file only when its last 8 bytes name the peripheral's VERSION register
# (fw/ctrl_boot README "Lock-step check")
$(B)/sdctrailer.bin: sdctrailer.c sdc.h
	@mkdir -p $(@D)
	$(RV_CC) $(RV_ARCH) -c -o $(B)/sdctrailer.o sdctrailer.c
	$(RV_OBJCOPY) -O binary -j .sdctrailer $(B)/sdctrailer.o $@
	@[ `wc -c < $@` = 8 ] || { echo "$@: not 8 bytes"; rm -f $@; exit 1; }

$(B)/$(FW_FILE): $(B)/$(PROJECT).elf $(B)/sdctrailer.bin
	$(RV_OBJCOPY) -O binary $< $@.img
	cat $@.img $(B)/sdctrailer.bin > $@
	rm -f $@.img

# version.h: the build date and the version string (suffix "-RV"),
# written into $(B), never into the source directory.  Regenerated on every
# make; replaced only when the text changed (the minute), so the units that
# include it (fpga.c main.c rtc.c, via the -MMD dependencies) rebuild then.
force:
$(B)/version.h: force
	@mkdir -p $(@D)
	@{ echo \#define MM_FIRMWARE_VERSION \"`date +%Y-%-m-%-d-%-H-%-M`\"; \
	   echo \#define MM_VERSTRING \"\$$VER:AMR`date +%y%-m%-d`-RV\"; \
	   echo \#define MM_YEAR `date +%Y`; \
	   echo \#define MM_MONTH `date +%m`; \
	   echo \#define MM_DAY `date +%d`; \
	   echo \#define MM_WEEKDAY `date +%w`; } > $@.tmp
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv -f $@.tmp $@; echo "version.h: `sed -n 2p $@`"; fi

# bootcustominit.h is the committed 68k byte array; rebuild only if the
# source is newer and vasm exists (as fw/ctrl_boot does for bootdiag.h).
ifneq ($(shell command -v vasmm68k_mot 2>/dev/null),)
bootcustominit.h: bootcustominit.s
	@mkdir -p $(B)
	vasmm68k_mot -quiet -Fbin bootcustominit.s -o $(B)/bootcustominit.bin
	(cd $(B) && xxd -i bootcustominit.bin) > bootcustominit.h
endif

size: $(B)/$(PROJECT).elf $(B)/$(FW_FILE)
	$(RV_SIZE) $(B)/$(PROJECT).elf
	@echo "$(FW_FILE): `wc -c < $(B)/$(FW_FILE)` bytes"

# ---- check: each part is its own target; all run (-k), any red fails ----
CHECKS := check_a check_b check_c check_d check_e check_f check_g check_h check_i

check: $(B)/$(PROJECT).elf
	@$(MAKE) --no-print-directory -k $(CHECKS)

# a failed objdump must not leave an empty .dis for the greps to "pass" on
.DELETE_ON_ERROR:

$(B)/$(PROJECT).dis: $(B)/$(PROJECT).elf
	$(RV_OBJDUMP) -d $< > $@

# (a) the core has no A extension
check_a: $(B)/$(PROJECT).dis
	@if grep -E '\b(lr\.w|sc\.w|amo[a-z]+\.w)\b' $<; then \
	  echo "check (a) FAIL: A-extension opcode in the disassembly"; exit 1; \
	else echo "check (a) pass: no lr.w/sc.w/amo*.w"; fi

# (b) the UART (0xFFFFFFF0) is write only: a read deadlocks the bus
# (c) every register at offset 0, 4, 8 or 0xC of its 16-byte window: I/O
#     accesses (address 0xFFFFFF00..0xFFFFFFFF) are word aligned
# Both read the disassembly through check_io.awk, which sees a base register
# only when it holds a constant set by li/lui/addi/mv in the same function
# (straight-line); it fails when it finds no I/O access at all.
check_b: $(B)/$(PROJECT).dis check_io.awk
	@awk -v mode=b -f check_io.awk $<

check_c: $(B)/$(PROJECT).dis check_io.awk
	@awk -v mode=c -f check_io.awk $<

# (d) no start-up names of the previous firmware's vbcc toolchain: the
#     start-up is arch/crt0.S, the interrupt set-up arch/irq.c
check_d:
	@if grep -nwE '__geta4|__constructor|setstack|c_entry' *.c *.h; then \
	  echo "check (d) FAIL: old start-up names in fw/ctrl/*.[ch]"; exit 1; \
	else echo "check (d) pass: no __geta4/__constructor/setstack/c_entry"; fi

# (e) the C library guard (README "C library"): nothing of the stdio FILE
#     layer, the heap or the syscalls linked; the stubs and the output
#     functions come from the firmware's own objects
LIBC_BANNED := _sbrk _sbrk_r malloc free realloc calloc _write _write_r \
               _read _read_r _fstat _fstat_r _isatty _isatty_r _lseek \
               _lseek_r _close _close_r __sinit __sfp _printf_float \
               _scanf_float asprintf vasprintf open_memstream fprintf fputc \
               fputs fflush
LIBC_OWN    := _malloc_r:rvlibc.o _realloc_r:rvlibc.o _free_r:rvlibc.o \
               printf:rvlibc.o vprintf:rvlibc.o putchar:uart.o puts:uart.o
check_e: $(B)/$(PROJECT).elf
	@rc=0; syms=`$(RV_NM) $<` || { echo "check (e) FAIL: nm failed"; exit 1; }; \
	syms=`printf '%s\n' "$$syms" | awk '{ print $$NF }'`; \
	for s in $(LIBC_BANNED); do \
	  if printf '%s\n' "$$syms" | grep -qxF "$$s"; then echo "check (e) FAIL: $$s linked"; rc=1; fi; \
	done; \
	for p in $(LIBC_OWN); do \
	  s=$${p%%:*}; o=$${p#*:}; \
	  from=`grep -B1 -E "^[[:space:]]+0x[0-9a-f]+[[:space:]]+$$s\$$" $(B)/$(PROJECT).map | head -1`; \
	  case "$$from" in \
	    */$$o) ;; \
	    *) echo "check (e) FAIL: $$s does not come from $$o ($$from)"; rc=1 ;; \
	  esac; \
	done; \
	if [ $$rc = 0 ]; then echo "check (e) pass: C library guard"; fi; exit $$rc

# (f) true/false are the C23 keywords (gcc 15 lets a #define replace them
#     without a word)
check_f:
	@if grep -nE '^[[:space:]]*#[[:space:]]*define[[:space:]]+(true|false)\b' *.c *.h; then \
	  echo "check (f) FAIL: #define true/false in fw/ctrl/*.[ch]"; exit 1; \
	else echo "check (f) pass: no #define true/false"; fi

# (g) the stack grows into the boot BRAM down to STACK_FLOOR (stackcheck.h);
#     the boot ROM image must end below it, so a soft re-run of the boot ROM
#     stays possible.  _end of the boot ROM's map (build it with
#     make -C fw/ctrl_boot).
BOOT_MAP := $(TOP)/fw/ctrl_boot/build/OSDBoot_rv.map
check_g:
	@end=`sed -n 's/^[[:space:]]*0x\([0-9a-f]*\)[[:space:]]*_end = \..*/0x\1/p' $(BOOT_MAP) | head -1`; \
	if [ -z "$$end" ]; then echo "check (g) FAIL: no _end in $(BOOT_MAP) (make -C fw/ctrl_boot)"; exit 1; fi; \
	if [ $$(($$end)) -lt $$((0x1400)) ]; then echo "check (g) pass: boot ROM _end $$end < 0x1400"; \
	else echo "check (g) FAIL: boot ROM _end $$end is not below 0x1400"; exit 1; fi

# (h) the image ends with the lock-step trailer naming SDC_VERSION of sdc.h
#     (read here with sed: a second derivation next to sdctrailer.c's)
check_h: $(B)/$(FW_FILE)
	@v=`sed -n 's/^#define[[:space:]]*SDC_VERSION[[:space:]]*0x\([0-9A-Fa-f]\{4\}\).*/\1/p' sdc.h | tr A-F a-f`; \
	want="53 44 43 56 00 00 `echo $$v | cut -c1-2` `echo $$v | cut -c3-4`"; \
	got=`tail -c 8 $< | od -An -tx1 | sed 's/^ *//; s/ *$$//'`; \
	if [ -n "$$v" ] && [ "$$got" = "$$want" ]; then echo "check (h) pass: trailer SDCV $$v at the end of $(FW_FILE)"; \
	else echo "check (h) FAIL: last 8 bytes of $< are '$$got', want '$$want'"; exit 1; fi

# (i) the boot ROM and this build agree on the file: the 8.3 directory name
#     made from the build output's own name ($(notdir) of the file the
#     image went to, the dot taken out) has 8 + 3 characters and is in the
#     committed boot ROM image (the .bin the ROM VHDL is generated from,
#     i.e. what the bitstream gets); .clangd's -DOSDNAME (the editor's copy
#     of fw/ctrl_boot's DEFS) names it too.  A changed fwname.mk without a
#     regenerated, committed boot ROM fails here.  And the committed
#     OSDBoot_rv_ROM.vhd (what the bitstream build compiles) must be the one
#     made from that .bin: fw/ctrl_boot's own recipe (make romvhd_check)
#     writes it into $(B) and cmp compares.
BOOT_BIN := $(TOP)/fw/ctrl_boot/OSDBoot_rv.bin
BOOT_VHD := $(TOP)/fw/ctrl_boot/OSDBoot_rv_ROM.vhd
check_i: $(B)/$(FW_FILE)
	@f=$(notdir $<); n=`echo $$f | tr -d .`; rc=0; \
	case $$f in ????????.???) ;; *) echo "check (i) FAIL: $$f is not an 8.3 name of 8 + 3 characters"; exit 1 ;; esac; \
	if ! LC_ALL=C grep -qaF "$$n" $(BOOT_BIN); then \
	  echo "check (i) FAIL: the boot ROM image $(BOOT_BIN) does not look for $$n (its RV32*BIN names: `LC_ALL=C grep -aoE 'RV32[A-Z0-9]{4}BIN' $(BOOT_BIN) | tr '\n' ' '`; make -C fw/ctrl_boot, commit both outputs)"; rc=1; fi; \
	if ! grep -qF -- "-DOSDNAME=\"$$n\"" $(TOP)/.clangd; then echo "check (i) FAIL: .clangd's -DOSDNAME is not \"$$n\""; rc=1; fi; \
	v=$(abspath $(B))/OSDBoot_rv_ROM.vhd.check; rm -f $$v; \
	if ! $(MAKE) -s --no-print-directory -C $(TOP)/fw/ctrl_boot romvhd_check ROMVHD_OUT=$$v >/dev/null || [ ! -s $$v ]; then \
	  echo "check (i) FAIL: could not make the ROM VHDL from $(BOOT_BIN) (make -C fw/ctrl_boot romvhd_check)"; rc=1; \
	elif ! cmp -s $$v $(BOOT_VHD); then \
	  echo "check (i) FAIL: the committed $(BOOT_VHD) is not the one made from OSDBoot_rv.bin ($$v; make -C fw/ctrl_boot, commit both outputs)"; rc=1; fi; \
	if [ $$rc = 0 ]; then echo "check (i) pass: the boot ROM image and .clangd look for $$n = $$f, OSDBoot_rv_ROM.vhd = the VHDL of OSDBoot_rv.bin"; fi; exit $$rc

# the 20 largest stack frames of the firmware (-fstack-usage: bytes, kind)
stack: $(OBJS)
	@if [ "$(CLANG)" = 1 ]; then echo "make stack: no -fstack-usage in clang"; exit 1; fi
	@cat $(B)/*.su | awk -F'\t' '{ print $$2 "\t" $$3 "\t" $$1 }' | sort -rn | head -20

clean:
	$(RM) -r $(B)

-include $(OBJS:.o=.d)

.PHONY: all size check stack $(CHECKS) clean force
