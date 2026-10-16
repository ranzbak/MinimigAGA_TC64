# Firmware-unit programs on the L1 bench: the CD-ROM emu tests of
# fw/ctrl_832/test/emu built with the RISC-V gcc + newlib-nano.
#   make -C sim/rv_l1/prog [FWDIR=../../../fw/ctrl_832]
#   bash sim/rv_l1/run.sh units
# FWDIR holds <name>.c/.h and test/emu/<name>_emu.c (fw/ctrl_rv in Phase 3).
# Link sets as fw/ctrl_832/test/emu/Makefile.  Output: ../build/<prog>.hex.
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk

FWDIR ?= ../../../fw/ctrl_832
B     := ../build
S     := ../sw
U     := build

PROGS := atapi_emu cue_emu cdaudio_emu

CFLAGS  = $(RV_ARCH) -Os -g -funsigned-char -ffunction-sections -fdata-sections \
          --specs=nano.specs -I$(FWDIR) -I$(S) -Wall
LDFLAGS = $(RV_ARCH) --specs=nano.specs -nostartfiles -T $(S)/l1_newlib.ld \
          -Wl,--gc-sections -Wl,--no-warn-rwx-segments

atapi_emu_OBJS   = atapi_emu.o atapi.o cue.o
cue_emu_OBJS     = cue_emu.o cue.o
cdaudio_emu_OBJS = cdaudio_emu.o cdaudio.o cue.o

.PHONY: all clean
all: $(PROGS:%=$(B)/%.hex)

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

.SECONDEXPANSION:
$(U)/%.elf: $$(addprefix $(U)/,$$($$*_OBJS)) $(U)/crt0_l1.o $(U)/syscalls.o $(S)/l1_newlib.ld
	$(RV_CC) $(LDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(addprefix $(U)/,$($*_OBJS)) $(U)/syscalls.o $(RV_LIBS_FW)

$(U)/%.bin: $(U)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

# one BE word per line, file byte i in lane i (as ../Makefile)
$(B)/%.hex: $(U)/%.bin | $(B)
	od -An -v -tx1 -w4 $< | awk '{ printf "%s%s%s%s\n", $$1, ($$2 == "" ? "00" : $$2), ($$3 == "" ? "00" : $$3), ($$4 == "" ? "00" : $$4) }' > $@

.SECONDARY:

clean:
	$(RM) -r $(U) $(PROGS:%=$(B)/%.hex)
