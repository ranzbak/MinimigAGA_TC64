# Firmware-unit programs on the L1 bench: the CD-ROM emu tests of
# fw/ctrl_832/test/emu built with the RISC-V gcc + newlib-nano.
#   make -C sim/rv_l1/prog [FWDIR=../../../fw/ctrl_832]
#   bash sim/rv_l1/run.sh units
# FWDIR holds <name>.c/.h and test/emu/<name>_emu.c (fw/ctrl_rv in Phase 3).
# Link sets as fw/ctrl_832/test/emu/Makefile.  Output: ../build/<prog>.hex.
#
# fmt_rv (bash sim/rv_l1/run.sh fmt) is the other kind of program here: it
# links like the firmware (fw/ctrl_rv/rvlibc.c + newlib-nano's libc_nano.a, no
# syscalls.o, so a call that needs _sbrk/_write fails the link) and takes its
# sources from fw/ctrl_rv by explicit path, not FWDIR.  Not part of PROGS/units.
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk
BIN2HEX := $(TOP)/tools/riscv/bin2hex.sh

FWDIR ?= ../../../fw/ctrl_832
B     := ../build
S     := ../sw
U     := build

PROGS := atapi_emu cue_emu cdaudio_emu

# fmt_rv: the firmware's C flags and library line (fw/ctrl_rv/Makefile, Task 4)
RVFW    := ../../../fw/ctrl_rv
FWCFLAGS = $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -I$(RVFW) -I$(S) -Wall -Wextra -Werror
FWLDFLAGS = $(RV_LDFLAGS_FW) --specs=nano.specs -nostartfiles -T $(S)/l1_newlib.ld \
          -Wl,--no-warn-rwx-segments
FWLIBS   = -lc_nano $(RV_LIBS_FW)

CFLAGS  = $(RV_ARCH) -Os -g -funsigned-char -ffunction-sections -fdata-sections \
          --specs=nano.specs -I$(FWDIR) -I$(S) -Wall
LDFLAGS = $(RV_ARCH) --specs=nano.specs -nostartfiles -T $(S)/l1_newlib.ld \
          -Wl,--gc-sections -Wl,--no-warn-rwx-segments

atapi_emu_OBJS   = atapi_emu.o atapi.o cue.o
cue_emu_OBJS     = cue_emu.o cue.o
cdaudio_emu_OBJS = cdaudio_emu.o cdaudio.o cue.o

.PHONY: all fmt clean
all: $(PROGS:%=$(B)/%.hex)
fmt: $(B)/fmt_rv.hex

$(U) $(B):
	mkdir -p $@

$(U)/crt0_l1.o: $(S)/crt0_l1.S $(S)/l1.h | $(U)
	$(RV_CC) $(RV_ARCH) -g -I$(S) -c -o $@ $<

$(U)/syscalls.o: $(S)/syscalls.c $(S)/l1.h | $(U)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(U)/%_emu.o: $(FWDIR)/test/emu/%_emu.c $(wildcard $(FWDIR)/*.h) | $(U)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(U)/%.o: $(FWDIR)/%.c $(wildcard $(FWDIR)/*.h) | $(U)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

# fmt_rv, linked as the firmware is (crt0_l1.o + l1_newlib.ld for the L1 memory map)
$(U)/fmt_rv.o: $(RVFW)/test/rv/fmt_rv.c $(RVFW)/test/fmt_run.h $(RVFW)/test/fmt_cases.h $(RVFW)/rvlibc.h $(S)/l1.h | $(U)
	$(RV_CC) $(FWCFLAGS) -c -o $@ $<

$(U)/rvlibc.o: $(RVFW)/rvlibc.c $(RVFW)/rvlibc.h | $(U)
	$(RV_CC) $(FWCFLAGS) -c -o $@ $<

$(U)/fmt_rv.elf: $(U)/crt0_l1.o $(U)/fmt_rv.o $(U)/rvlibc.o $(S)/l1_newlib.ld
	$(RV_CC) $(FWLDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(U)/fmt_rv.o $(U)/rvlibc.o $(FWLIBS)

.SECONDEXPANSION:
$(U)/%.elf: $$(addprefix $(U)/,$$($$*_OBJS)) $(U)/crt0_l1.o $(U)/syscalls.o $(S)/l1_newlib.ld
	$(RV_CC) $(LDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(addprefix $(U)/,$($*_OBJS)) $(U)/syscalls.o $(RV_LIBS_FW)

$(U)/%.bin: $(U)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

# one BE word per line, file byte i in lane i (tools/riscv/bin2hex.sh)
$(B)/%.hex: $(U)/%.bin $(BIN2HEX) | $(B)
	bash $(BIN2HEX) $< $@

.SECONDARY:

clean:
	$(RM) -r $(U) $(PROGS:%=$(B)/%.hex) $(B)/fmt_rv.hex
