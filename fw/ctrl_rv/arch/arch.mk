# fw/ctrl_rv/arch/arch.mk: the start-up, trap and interrupt objects of the
# RISC-V firmware, built the same way for every consumer (the firmware, the
# L1/L2 benches, fw/dhrystone_rv).
#
# Include after tools/riscv/toolchain.mk; the includer sets
#   TOP      the repository root
#   ARCH_B   a build directory; the objects go to $(ARCH_B)/arch/
# and gets
#   ARCH          the fw/ctrl_rv/arch directory
#   ARCH_OBJS     crt0.o trap_entry.o trap.o irq.o (trap_entry.o is trap.S)
#   ARCH_LD       the linker script, a prerequisite of every link
#   ARCH_CFLAGS   flags of the C files (the includer's -I paths may follow)
#   ARCH_ASFLAGS  flags of the assembler files
#   ARCH_LDFLAGS  the link flags for the script; add -Wl,-Map,... and
#                 $(RV_LDFLAGS_FW) yourself
# The objects depend on their sources and (-MMD -MP) on every header they
# include, so touching irq.h or csr.h rebuilds them.
ARCH         := $(TOP)/fw/ctrl_rv/arch
ARCH_OBJS    := $(ARCH_B)/arch/crt0.o $(ARCH_B)/arch/trap_entry.o \
                $(ARCH_B)/arch/trap.o $(ARCH_B)/arch/irq.o
ARCH_LD      := $(ARCH)/firmware.ld
ARCH_CFLAGS  := $(RV_CFLAGS_FW) -g -Wall -Wextra -I$(ARCH) -MMD -MP
ARCH_ASFLAGS := $(RV_ARCH) -g -MMD -MP
ARCH_LDFLAGS := -nostartfiles -T $(ARCH)/firmware.ld -Wl,--no-warn-rwx-segments

$(ARCH_B)/arch/crt0.o: $(ARCH)/crt0.S
	@mkdir -p $(@D)
	$(RV_CC) $(ARCH_ASFLAGS) -c -o $@ $<

$(ARCH_B)/arch/trap_entry.o: $(ARCH)/trap.S
	@mkdir -p $(@D)
	$(RV_CC) $(ARCH_ASFLAGS) -c -o $@ $<

$(ARCH_B)/arch/%.o: $(ARCH)/%.c
	@mkdir -p $(@D)
	$(RV_CC) $(ARCH_CFLAGS) -c -o $@ $<

-include $(ARCH_OBJS:.o=.d)
