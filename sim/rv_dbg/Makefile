# Debug bench test programs -> build/<prog>.hex (one 32-bit BE word per line,
# file byte i in lane i) + .elf + .lst, linked like the L1 bench programs
# with its start-up code and linker script (sim/rv_l1/sw, used by path).
#   make -C sim/rv_dbg
# A program is tests/<name>.S; add its name to PROGS.
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk
BIN2HEX := $(TOP)/tools/riscv/bin2hex.sh
L1SW    := $(TOP)/sim/rv_l1/sw

B       := build
PROGS   := attach

ASFLAGS = $(RV_ARCH) -g -I$(L1SW)
LDFLAGS = $(RV_ARCH) -nostdlib -nostartfiles -T $(L1SW)/l1.ld -Wl,--gc-sections \
          -Wl,--no-warn-rwx-segments -Wl,-Map,$(@:.elf=.map)

.PHONY: tests clean print-progs
.DEFAULT_GOAL := tests
tests: $(PROGS:%=$(B)/%.hex) $(PROGS:%=$(B)/%.lst)

print-progs:
	@echo $(PROGS)

$(B):
	mkdir -p $@

$(B)/crt0_l1.o: $(L1SW)/crt0_l1.S $(L1SW)/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%.o: tests/%.S $(L1SW)/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

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
