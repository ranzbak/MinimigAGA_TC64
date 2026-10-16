# L1 bench test programs -> build/<prog>.hex (one 32-bit BE word per line,
# file byte i in lane i: the romgen order) + .elf + .lst.
#   make -C sim/rv_l1 tests
# A program is tests/<name>.S or tests/<name>.c; add its name to PROGS.
# FWPROGS are linked as firmware: fw/ctrl_rv/arch (crt0, trap entry, irq
# API) with fw/ctrl_rv/arch/firmware.ld (_start at 0x2000), behind
# sw/boot_fw.S padded to 0x2000 (a boot ROM stand-in: zero x1-x31, jump to
# 0x2000).  run.sh keeps its own PROGS/TEETH list: keep the two in sync.
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk

B       := build
ARCH    := $(TOP)/fw/ctrl_rv/arch
PROGS   := lanes refill fencei fencei_nofencei irq dm_smoke
FWPROGS := irq_sig irq_c exc irq_sig_mut

CFLAGS  = $(RV_ARCH) -O2 -g -ffreestanding -fno-builtin -funsigned-char \
          -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections \
          -Wall -Wextra -Isw -I$(ARCH)
ASFLAGS = $(RV_ARCH) -g -Isw
LDFLAGS = $(RV_ARCH) -nostdlib -nostartfiles -T sw/l1.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
          -Wl,-Map,$(@:.elf=.map)
# the arch files are built as the firmware builds them
ARCH_CFLAGS = $(RV_CFLAGS_FW) -g -Wall -Wextra -I$(ARCH)
FWLDFLAGS   = $(RV_LDFLAGS_FW) -nostartfiles -T $(ARCH)/firmware.ld -Wl,--no-warn-rwx-segments \
              -Wl,-Map,$(@:.elf=.map)
ARCH_OBJS   = $(B)/arch/crt0.o $(B)/arch/trap_entry.o $(B)/arch/trap.o $(B)/arch/irq.o
ARCH_DEPS   = $(ARCH)/firmware.ld $(ARCH)/irq.h $(ARCH)/csr.h
FW_LINK     = $(RV_CC) $(FWLDFLAGS) $(FW_EXTRA) -o $@ $(filter %.o,$^) $(RV_LIBS_FW)

.PHONY: tests clean
tests: $(PROGS:%=$(B)/%.hex) $(PROGS:%=$(B)/%.lst) $(FWPROGS:%=$(B)/%.hex) $(FWPROGS:%=$(B)/%.lst)

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

# ---- firmware-linked programs (FWPROGS)
$(B)/arch:
	mkdir -p $@

$(B)/arch/crt0.o: $(ARCH)/crt0.S | $(B)/arch
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/trap_entry.o: $(ARCH)/trap.S | $(B)/arch
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/%.o: $(ARCH)/%.c $(ARCH_DEPS) | $(B)/arch
	$(RV_CC) $(ARCH_CFLAGS) -c -o $@ $<

# teeth: trap.S without the restore of t3 (irq_sig must end "=== FAIL 11c")
$(B)/arch/trap_mut.S: $(ARCH)/trap.S | $(B)/arch
	sed '/^[[:space:]]*lw[[:space:]]*t3,/d' $< > $@
	test $$(diff $< $@ | grep -c '^<') -eq 1

$(B)/arch/trap_mut.o: $(B)/arch/trap_mut.S
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/boot_fw.o: sw/boot_fw.S sw/l1.h | $(B)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/boot_fw.bin: $(B)/boot_fw.o
	$(RV_CC) $(RV_ARCH) -nostdlib -nostartfiles -Wl,-Ttext=0 -Wl,-e,_reset -o $(B)/boot_fw.elf $<
	$(RV_OBJCOPY) -O binary --pad-to=0x2000 $(B)/boot_fw.elf $@
	test $$(stat -c %s $@) -eq 8192

# irq_sig: --no-relax, no gp-relative code (the test fills gp with a pattern)
$(B)/irq_sig.elf $(B)/irq_sig_mut.elf: FW_EXTRA = -Wl,--no-relax
$(B)/irq_sig.elf: $(ARCH_OBJS) $(B)/irq_sig.o $(B)/irq_sig_h.o $(ARCH_DEPS)
	$(FW_LINK)
$(B)/irq_sig_mut.elf: $(B)/arch/crt0.o $(B)/arch/trap_mut.o $(B)/arch/trap.o $(B)/arch/irq.o \
                      $(B)/irq_sig.o $(B)/irq_sig_h.o $(ARCH_DEPS)
	$(FW_LINK)
$(B)/irq_c.elf: $(ARCH_OBJS) $(B)/irq_c.o $(ARCH_DEPS)
	$(FW_LINK)
$(B)/exc.elf: $(ARCH_OBJS) $(B)/exc.o $(ARCH_DEPS)
	$(FW_LINK)

# image = boot_fw padded to 0x2000, then the firmware binary (from 0x2000)
$(FWPROGS:%=$(B)/%.bin): $(B)/%.bin: $(B)/%.elf $(B)/boot_fw.bin
	$(RV_OBJCOPY) -O binary $< $@.fw
	cat $(B)/boot_fw.bin $@.fw > $@
	rm -f $@.fw

.PRECIOUS: $(B)/%.o $(B)/%.elf $(B)/%.bin $(B)/arch/%.o

clean:
	rm -rf $(B)
