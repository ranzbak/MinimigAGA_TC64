# Debug bench test programs -> build/<prog>.hex (one 32-bit BE word per line,
# file byte i in lane i) + .elf + .lst, linked like the L1 bench programs
# with its start-up code and linker script (sim/rv_l1/sw, used by path).
#   make -C sim/rv_dbg
# A program is tests/<name>.S; add its name to PROGS.
# The GDB session's program sw/dbgtest.c is built twice, -DIMG_A and
# -DIMG_B (build/dbgtest_a.*, build/dbgtest_b.*); build/dbgtest.layout
# exists only when the two have identical nm output (same addresses for
# every symbol) and different binaries (work()'s constant).
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk
BIN2HEX := $(TOP)/tools/riscv/bin2hex.sh
L1SW    := $(TOP)/sim/rv_l1/sw

B       := build
PROGS   := attach
IMGS    := dbgtest_a dbgtest_b
RV_NM    = $(RV_GCC_DIR)/bin/$(RV_PREFIX)nm

ASFLAGS = $(RV_ARCH) -g -I$(L1SW)
CFLAGS  = $(RV_ARCH) -g -O1 -ffreestanding -fno-builtin -Wall -Wextra -Werror -I$(L1SW)
LDFLAGS = $(RV_ARCH) -nostdlib -nostartfiles -T $(L1SW)/l1.ld -Wl,--gc-sections \
          -Wl,--no-warn-rwx-segments -Wl,-Map,$(@:.elf=.map)

.PHONY: tests clean print-progs
.DEFAULT_GOAL := tests
tests: $(PROGS:%=$(B)/%.hex) $(PROGS:%=$(B)/%.lst) \
       $(IMGS:%=$(B)/%.hex) $(IMGS:%=$(B)/%.lst) $(B)/dbgtest.layout

print-progs:
	@echo $(PROGS)

$(B):
	mkdir -p $@

$(B)/crt0_l1.o: $(L1SW)/crt0_l1.S $(L1SW)/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%.o: tests/%.S $(L1SW)/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/dbgtest_a.o: sw/dbgtest.c | $(B)
	$(RV_CC) $(CFLAGS) -DIMG_A -c -o $@ $<

$(B)/dbgtest_b.o: sw/dbgtest.c | $(B)
	$(RV_CC) $(CFLAGS) -DIMG_B -c -o $@ $<

$(B)/dbgtest.layout: $(B)/dbgtest_a.elf $(B)/dbgtest_b.elf $(B)/dbgtest_a.bin $(B)/dbgtest_b.bin
	$(RV_NM) -n $(B)/dbgtest_a.elf > $(B)/dbgtest_a.nm
	$(RV_NM) -n $(B)/dbgtest_b.elf > $(B)/dbgtest_b.nm
	cmp $(B)/dbgtest_a.nm $(B)/dbgtest_b.nm
	! cmp -s $(B)/dbgtest_a.bin $(B)/dbgtest_b.bin
	cp $(B)/dbgtest_a.nm $@

$(B)/%.elf: $(B)/crt0_l1.o $(B)/%.o $(L1SW)/l1.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(B)/crt0_l1.o $(B)/$*.o $(RV_LIBS_FW)

$(B)/%.bin: $(B)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

$(B)/%.hex: $(B)/%.bin $(BIN2HEX)
	bash $(BIN2HEX) $< $@

$(B)/%.lst: $(B)/%.elf
	$(RV_OBJDUMP) -d -h $< > $@

.PRECIOUS: $(B)/%.o $(B)/%.elf $(B)/%.bin

clean:
	rm -rf $(B)
