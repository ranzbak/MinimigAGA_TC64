# L1 bench test programs -> build/<prog>.hex (one 32-bit BE word per line,
# file byte i in lane i: the romgen order) + .elf + .lst.
#   make -C sim/rv_l1 tests
# A program is tests/<name>.S or tests/<name>.c; add its name to PROGS.
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk

B     := build
PROGS := lanes refill fencei fencei_nofencei irq

CFLAGS  = $(RV_ARCH) -O2 -g -ffreestanding -fno-builtin -funsigned-char \
          -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections \
          -Wall -Wextra -Isw
ASFLAGS = $(RV_ARCH) -g -Isw
LDFLAGS = $(RV_ARCH) -nostdlib -nostartfiles -T sw/l1.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
          -Wl,-Map,$(@:.elf=.map)

.PHONY: tests clean
tests: $(PROGS:%=$(B)/%.hex) $(PROGS:%=$(B)/%.lst)

$(B):
	mkdir -p $@

$(B)/crt0_l1.o: sw/crt0_l1.S sw/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%.o: tests/%.S sw/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%.o: tests/%.c sw/l1.h | $(B)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

# teeth variant: fencei without the fence.i (must end with "=== FAIL 1")
$(B)/fencei_nofencei.o: tests/fencei.S sw/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -DNO_FENCEI -c -o $@ $<

$(B)/%.elf: $(B)/crt0_l1.o $(B)/%.o sw/l1.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(B)/crt0_l1.o $(B)/$*.o $(RV_LIBS_FW)

$(B)/%.bin: $(B)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

# od prints the bytes in file order, four per line = one BE word per line;
# a short last line is padded with 00 so every byte keeps its lane.
$(B)/%.hex: $(B)/%.bin
	od -An -v -tx1 -w4 $< | awk '{ printf "%s%s%s%s\n", $$1, ($$2 == "" ? "00" : $$2), ($$3 == "" ? "00" : $$3), ($$4 == "" ? "00" : $$4) }' > $@

$(B)/%.lst: $(B)/%.elf
	$(RV_OBJDUMP) -d -h $< > $@

.PRECIOUS: $(B)/%.o $(B)/%.elf $(B)/%.bin

clean:
	rm -rf $(B)
