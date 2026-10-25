# Firmware-unit programs on the L1 bench: the CD-ROM emu tests of
# <FWDIR>/test/emu built with the RISC-V gcc + newlib-nano.
#   make -C sim/rv_l1/prog [FWDIR=../../../fw/ctrl]
#   bash sim/rv_l1/run.sh units          (runs this make first, FWDIR= passed on)
# FWDIR holds <name>.c/.h and test/emu/<name>_emu.c: fw/ctrl (default), or
# another copy of that tree (e.g. a scratch worktree's).
#
# Per tree (TREE = the last part of FWDIR): objects, .d files, .elf/.map/.bin
# in build/<TREE>/, hexes in ../build/<TREE>/<prog>.hex, so two trees never
# share an object or an image.  -MMD -MP: every header a unit or an emu
# program includes (FWDIR/*.h, FWDIR/test/emu/*.h) is a dependency.
# build/<TREE>/fwdir holds the absolute FWDIR the objects came from: another
# tree with the same last name rebuilds everything.
#
# Flags: as the firmware ($(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs
# -Wall -Wextra -Werror, as fw/ctrl/Makefile); the emu programs add
# -Wno-unused-parameter (as the host tests in fw/ctrl/test: test code,
# main(argc, argv), port stubs).
#
#   make -C sim/rv_l1/prog print-progs     the unit programs (run.sh units reads them)
#   make -C sim/rv_l1/prog print-hexdir    where this FWDIR's hexes go
#
# fmt_rv (bash sim/rv_l1/run.sh fmt) is the other kind of program here: it
# links like the firmware (fw/ctrl/rvlibc.c + newlib-nano's libc_nano.a, no
# syscalls.o, so a call that needs _sbrk/_write fails the link) and takes its
# sources from fw/ctrl by explicit path, not FWDIR.  Not part of PROGS/units.
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk
BIN2HEX := $(TOP)/tools/riscv/bin2hex.sh

FWDIR ?= ../../../fw/ctrl
FWD   := $(patsubst %/,%,$(FWDIR))
TREE  := $(notdir $(FWD))
B     := ../build
S     := ../sw
U     := build
UT    := $(U)/$(TREE)
HT    := $(B)/$(TREE)

PROGS := atapi_emu cue_emu cdaudio_emu

# fmt_rv: the firmware's C flags and library line (fw/ctrl/Makefile, Task 4)
RVFW    := ../../../fw/ctrl
FWCFLAGS = $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -I$(RVFW) -I$(S) -Wall -Wextra -Werror
FWLDFLAGS = $(RV_LDFLAGS_FW) --specs=nano.specs -nostartfiles -T $(S)/l1_newlib.ld \
          -Wl,--no-warn-rwx-segments
FWLIBS   = -lc_nano $(RV_LIBS_FW)

# the bench runtime (syscalls.o), one build for every tree
RTCFLAGS = $(RV_ARCH) -Os -g -funsigned-char -ffunction-sections -fdata-sections \
          --specs=nano.specs -I$(S) -Wall
UCFLAGS = $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -I$(FWD) -I$(S) \
          -Wall -Wextra -Werror -MMD -MP
EMUFLAGS = -Wno-unused-parameter
LDFLAGS = $(RV_ARCH) --specs=nano.specs -nostartfiles -T $(S)/l1_newlib.ld \
          -Wl,--gc-sections -Wl,--no-warn-rwx-segments

atapi_emu_OBJS   = atapi_emu.o atapi.o cue.o
cue_emu_OBJS     = cue_emu.o cue.o
cdaudio_emu_OBJS = cdaudio_emu.o cdaudio.o cue.o

.PHONY: all fmt clean print-progs print-hexdir
all: $(PROGS:%=$(HT)/%.hex)
fmt: $(B)/fmt_rv.hex $(B)/fmt_rv_subset.hex

print-progs:
	@echo $(PROGS)
print-hexdir:
	@echo $(abspath $(HT))

$(U) $(B) $(HT):
	mkdir -p $@

# the tree the objects in $(UT) came from; rewritten only when it changes,
# so its date is the last switch of trees (every object depends on it)
FWABS := $(abspath $(FWD))
ifeq ($(filter clean print-progs print-hexdir,$(MAKECMDGOALS)),)
$(shell mkdir -p $(UT) && { [ "$$(cat $(UT)/fwdir 2>/dev/null)" = "$(FWABS)" ] || echo "$(FWABS)" > $(UT)/fwdir; })
endif

$(U)/crt0_l1.o: $(S)/crt0_l1.S $(S)/l1.h | $(U)
	$(RV_CC) $(RV_ARCH) -g -I$(S) -c -o $@ $<

$(U)/syscalls.o: $(S)/syscalls.c $(S)/l1.h | $(U)
	$(RV_CC) $(RTCFLAGS) -c -o $@ $<

$(UT)/%_emu.o: $(FWD)/test/emu/%_emu.c $(UT)/fwdir
	$(RV_CC) $(UCFLAGS) $(EMUFLAGS) -c -o $@ $<

$(UT)/%.o: $(FWD)/%.c $(UT)/fwdir
	$(RV_CC) $(UCFLAGS) -c -o $@ $<

-include $(wildcard $(UT)/*.d)

# fmt_rv, linked as the firmware is (crt0_l1.o + l1_newlib.ld for the L1 memory map)
$(U)/fmt_rv.o: $(RVFW)/test/rv/fmt_rv.c $(RVFW)/test/fmt_run.h $(RVFW)/test/fmt_cases.h $(RVFW)/rvlibc.h $(S)/l1.h | $(U)
	$(RV_CC) $(FWCFLAGS) -c -o $@ $<

$(U)/fmt_rv_subset.o: $(RVFW)/test/rv/fmt_rv.c $(RVFW)/test/fmt_run.h $(RVFW)/test/fmt_cases.h $(RVFW)/rvlibc.h $(S)/l1.h | $(U)
	$(RV_CC) $(FWCFLAGS) -DFMT_SUBSET=1 -c -o $@ $<

$(U)/rvlibc.o: $(RVFW)/rvlibc.c $(RVFW)/rvlibc.h | $(U)
	$(RV_CC) $(FWCFLAGS) -c -o $@ $<

$(U)/fmt_rv.elf: $(U)/crt0_l1.o $(U)/fmt_rv.o $(U)/rvlibc.o $(S)/l1_newlib.ld
	$(RV_CC) $(FWLDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(U)/fmt_rv.o $(U)/rvlibc.o $(FWLIBS)

$(U)/fmt_rv_subset.elf: $(U)/crt0_l1.o $(U)/fmt_rv_subset.o $(U)/rvlibc.o $(S)/l1_newlib.ld
	$(RV_CC) $(FWLDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(U)/fmt_rv_subset.o $(U)/rvlibc.o $(FWLIBS)

.SECONDEXPANSION:
$(UT)/%.elf: $$(addprefix $(UT)/,$$($$*_OBJS)) $(U)/crt0_l1.o $(U)/syscalls.o $(S)/l1_newlib.ld
	$(RV_CC) $(LDFLAGS) -Wl,-Map,$(@:.elf=.map) -o $@ $(U)/crt0_l1.o $(addprefix $(UT)/,$($*_OBJS)) $(U)/syscalls.o $(RV_LIBS_FW)

# build/<x>.bin and build/<TREE>/<x>.bin
$(U)/%.bin: $(U)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

# one BE word per line, file byte i in lane i (tools/riscv/bin2hex.sh)
$(HT)/%.hex: $(UT)/%.bin $(BIN2HEX) | $(HT)
	bash $(BIN2HEX) $< $@

$(B)/%.hex: $(U)/%.bin $(BIN2HEX) | $(B)
	bash $(BIN2HEX) $< $@

.SECONDARY:

clean:
	$(RM) -r $(U) $(PROGS:%=$(B)/*/%.hex) $(B)/fmt_rv.hex $(B)/fmt_rv_subset.hex
