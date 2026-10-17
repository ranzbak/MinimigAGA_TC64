# OSD / host firmware for the VexRiscv host CPU (RV32IMC): RV32OSDA.BIN,
# loaded by the boot ROM (fw/ctrl_boot_rv) to 0x2000.  Port of fw/ctrl_832
# (see README.md).
#
#   make          $(B)/RV32OSDA.BIN (+ .elf, .map, .lst)
#   make size     section sizes and the bytes of the .BIN
#   make check    (a) no lr.w/sc.w/amo*.w, (b) no UART read, (c) I/O offsets
#                 multiple of 4, (d) no 832 start-up names in the sources,
#                 (e) the C library guard, (f) no #define true/false
#   make clean
#
#   B=dir         output directory (default build)
#   EXTRA_CFLAGS  extra compiler flags for bench variants (empty for the
#                 shipped image)
TOP := $(abspath ../..)
include $(TOP)/tools/riscv/toolchain.mk

B            ?= build
EXTRA_CFLAGS ?=
ARCH_B       := $(B)
include $(TOP)/fw/ctrl_rv/arch/arch.mk
.DEFAULT_GOAL := all

RV_NM   = $(RV_GCC_DIR)/bin/$(RV_PREFIX)nm

PROJECT := RV32OSDA

# the 832 Makefile's COMMON_SOURCES without interrupts (arch/irq.c), plus
# the C library glue
SRCS := hardware.c config.c fat.c fdd.c fpga.c boot.c hdd.c main.c menu.c \
        mmc.c spi.c osd.c rafile.c swap.c hexdump.c uart.c errors.c \
        c64keys.c akiko.c audio.c drivesounds.c rtc.c i2c.c adv7511.c \
        atapi.c cdrom.c cue.c cdaudio.c rvlibc.c
OBJS := $(addprefix $(B)/,$(SRCS:.c=.o))

CFLAGS  := $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -I. -Iarch \
           -I$(B) -Wall -MMD -MP $(EXTRA_CFLAGS)
LDFLAGS := $(RV_LDFLAGS_FW) --specs=nano.specs $(ARCH_LDFLAGS) \
           -Wl,-Map,$(B)/$(PROJECT).map
LIBS    := -lc_nano $(RV_LIBS_FW)

all: $(B)/$(PROJECT).BIN

$(B)/%.o: %.c | $(B)/version.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/$(PROJECT).elf: $(ARCH_OBJS) $(OBJS) $(ARCH_LD)
	$(RV_CC) $(LDFLAGS) -o $@ $(ARCH_OBJS) $(OBJS) $(LIBS)
	$(RV_OBJDUMP) -d -S $@ > $(B)/$(PROJECT).lst

$(B)/$(PROJECT).BIN: $(B)/$(PROJECT).elf
	$(RV_OBJCOPY) -O binary $< $@

# version.h: the 832 recipe (fw/ctrl_832/Makefile), "-RV" for "-832",
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
# source is newer and vasm exists (as fw/ctrl_boot_rv does for bootdiag.h).
ifneq ($(shell command -v vasmm68k_mot 2>/dev/null),)
bootcustominit.h: bootcustominit.s
	@mkdir -p $(B)
	vasmm68k_mot -quiet -Fbin bootcustominit.s -o $(B)/bootcustominit.bin
	(cd $(B) && xxd -i bootcustominit.bin) > bootcustominit.h
endif

size: $(B)/$(PROJECT).elf $(B)/$(PROJECT).BIN
	$(RV_SIZE) $(B)/$(PROJECT).elf
	@echo "$(PROJECT).BIN: `wc -c < $(B)/$(PROJECT).BIN` bytes"

# ---- check: each part is its own target; all run (-k), any red fails ----
CHECKS := check_a check_b check_c check_d check_e check_f

check: $(B)/$(PROJECT).elf
	@$(MAKE) --no-print-directory -k $(CHECKS)

$(B)/$(PROJECT).dis: $(B)/$(PROJECT).elf
	$(RV_OBJDUMP) -d $< > $@

# (a) the core has no A extension
check_a: $(B)/$(PROJECT).dis
	@if grep -E '\b(lr\.w|sc\.w|amo[a-z]+\.w)\b' $<; then \
	  echo "check (a) FAIL: A-extension opcode in the disassembly"; exit 1; \
	else echo "check (a) pass: no lr.w/sc.w/amo*.w"; fi

# (b) the UART (0xFFFFFFF0) is write only: a read deadlocks the bus
check_b: $(B)/$(PROJECT).dis
	@if grep -E '\bl(b|bu|h|hu|w)[[:space:]]+[a-z0-9]+,-16\(zero\)' $<; then \
	  echo "check (b) FAIL: load from -16(zero) (UART read)"; exit 1; \
	else echo "check (b) pass: no load from -16(zero)"; fi

# (c) every register at offset 0, 4, 8 or 0xC of its 16-byte window:
#     zero-based I/O accesses (offset -256..-1) are word aligned
check_c: $(B)/$(PROJECT).dis
	@grep -E '\b(l(b|bu|h|hu|w)|s(b|h|w))[[:space:]]+[a-z0-9]+,-[0-9]+\(zero\)' $< \
	  | awk '{ for (i = 1; i <= NF; i++) if ($$i ~ /\(zero\)$$/) { o = $$i; sub(/\(zero\)$$/, "", o); \
	           o = substr(o, index(o, ",") + 1); o += 0; \
	           if (o >= -256 && o <= -1 && (-o) % 4 != 0) { print; bad++ } } } \
	         END { if (bad) { printf "check (c) FAIL: %d I/O accesses at an offset not a multiple of 4\n", bad; exit 1 } \
	               else print "check (c) pass: zero-based I/O offsets are multiples of 4" }'

# (d) no 832 start-up names left in the sources
check_d:
	@if grep -nwE '__geta4|__constructor|setstack|c_entry' *.c *.h; then \
	  echo "check (d) FAIL: 832 start-up names in fw/ctrl_rv/*.[ch]"; exit 1; \
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
	@rc=0; syms=`$(RV_NM) $< | awk '{ print $$NF }'`; \
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
	  echo "check (f) FAIL: #define true/false in fw/ctrl_rv/*.[ch]"; exit 1; \
	else echo "check (f) pass: no #define true/false"; fi

clean:
	$(RM) -r $(B)

-include $(OBJS:.o=.d)

.PHONY: all size check $(CHECKS) clean force
