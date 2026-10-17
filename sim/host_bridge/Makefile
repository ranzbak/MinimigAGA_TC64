# L2 host-bridge bench test ROMs: each test program becomes
# $(B)/<test>/OSDBoot_rv_ROM.vhd (the boot BRAM image, entity OSDBoot_rv_ROM),
# built as fw/ctrl_boot_rv/Makefile builds the boot ROM, from its template:
# romgen between rom_prologue.vhd and rom_epilogue.vhd (the shared-variable
# RAM, which simulates without X), soc_firmware renamed.  The .elf, .bin,
# .lst and .map land next to it.
#   make -C sim/host_bridge                 # into sim/host_bridge/build
#   make -C sim/host_bridge B=<dir>         # run.sh: into its run directory
# A test is sw/<name>.S or sw/<name>.c; add its name to TESTS.
# dhry is a ROM that clears x1-x31 and jumps to 0x2000 (no crt0_rom.S); the
# firmware comes from fw/dhrystone_rv through +SDRAM_HEX (run.sh dhry).
# FWTESTS (C) start through the firmware start-up instead of sw/crt0_rom.S:
# sw/reset_fw.S (reset, trap 0x20, register clear) + fw/ctrl_rv/arch (crt0,
# trap entry, irq API), still linked with sw/rom.ld.
TOP := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk

B       ?= build
TESTS   ?= t_lanes t_hwoff t_b2b t_spibusy t_irq t_irqctl dhry
FWTESTS := t_irq t_irqctl
ARCH    := $(TOP)/fw/ctrl_rv/arch
ROMGEN  := $(TOP)/fw/romgen/romgen
ROMDIR  := $(TOP)/fw/ctrl_boot_rv

CFLAGS  = $(RV_CFLAGS_FW) -g -Wall -Wextra -Isw -I$(ARCH)
ASFLAGS = $(RV_ARCH) -g -Isw
LDFLAGS = $(RV_LDFLAGS_FW) -nostartfiles -T sw/rom.ld -Wl,--no-warn-rwx-segments \
          -Wl,-Map,$(@:.elf=.map)

.PHONY: all clean
all: $(TESTS:%=$(B)/%/OSDBoot_rv_ROM.vhd) $(TESTS:%=$(B)/%/prog.lst)

$(B)/%/OSDBoot_rv_ROM.vhd: $(B)/%/prog.bin $(ROMGEN) $(ROMDIR)/rom_prologue.vhd $(ROMDIR)/rom_epilogue.vhd
	sed 's/soc_firmware/OSDBoot_rv_ROM/' < $(ROMDIR)/rom_prologue.vhd > $@.tmp
	$(ROMGEN) $< >> $@.tmp
	cat $(ROMDIR)/rom_epilogue.vhd >> $@.tmp
	mv $@.tmp $@

$(ROMGEN): $(TOP)/fw/romgen/romgen.c
	$(MAKE) -C $(TOP)/fw/romgen romgen

$(B)/crt0_rom.o: sw/crt0_rom.S sw/hb.h
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%/prog.o: sw/%.S sw/hb.h sw/check.h
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/%/prog.o: sw/%.c sw/hb.h $(ARCH)/irq.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(B)/%/prog.elf: $(B)/crt0_rom.o $(B)/%/prog.o sw/rom.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(B)/crt0_rom.o $(B)/$*/prog.o $(RV_LIBS_FW)

# ---- FWTESTS: firmware start-up and trap entry (fw/ctrl_rv/arch)
ARCH_OBJS = $(B)/arch/crt0.o $(B)/arch/trap_entry.o $(B)/arch/trap.o $(B)/arch/irq.o

$(B)/reset_fw.o: sw/reset_fw.S sw/hb.h
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/crt0.o: $(ARCH)/crt0.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/trap_entry.o: $(ARCH)/trap.S
	@mkdir -p $(@D)
	$(RV_CC) $(ASFLAGS) -c -o $@ $<

$(B)/arch/%.o: $(ARCH)/%.c $(ARCH)/irq.h $(ARCH)/csr.h
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

$(FWTESTS:%=$(B)/%/prog.elf): $(B)/%/prog.elf: $(B)/reset_fw.o $(ARCH_OBJS) $(B)/%/prog.o sw/rom.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(B)/reset_fw.o $(ARCH_OBJS) $(B)/$*/prog.o $(RV_LIBS_FW)

$(B)/dhry/prog.elf: $(B)/dhry/prog.o sw/rom.ld
	$(RV_CC) $(LDFLAGS) -o $@ $(B)/dhry/prog.o $(RV_LIBS_FW)

$(B)/%/prog.bin: $(B)/%/prog.elf
	$(RV_OBJCOPY) -O binary $< $@

$(B)/%/prog.lst: $(B)/%/prog.elf
	$(RV_OBJDUMP) -d -h $< > $@

.PRECIOUS: $(B)/%/prog.o $(B)/%/prog.elf $(B)/%/prog.bin $(B)/arch/%.o

clean:
	rm -rf $(B)
