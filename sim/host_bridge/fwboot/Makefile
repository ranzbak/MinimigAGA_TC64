# L2 firmware boot (sim/host_bridge/run.sh fwboot / fwboot_trap): the SD
# card images with the real firmware.
#   make -C sim/host_bridge/fwboot                    # card.img, into ./build
#   make -C sim/host_bridge/fwboot trap               # card_trap.img + trap_expect.txt
#   make -C sim/host_bridge/fwboot B=<dir> FW=<bin>   # run.sh: its run directory
# Inputs:
#   FW   an RV32OSDA.BIN, default fw/ctrl_rv/build/RV32OSDA.BIN (make -C
#        fw/ctrl_rv): copied as it is, never rebuilt here
# Outputs in $(B):
#   card.img          16 MB FAT16 (tools/sim/mkcard.sh): 832OSDAD.BIN (decoy,
#                     first in the directory), RV32OSDA.BIN = $(FW).  No
#                     config file, no kickstart.
#   smoke_trap.o      fwboot/smoke_trap.c with the firmware's flags
#   trapfw/           make -C fw/ctrl_rv B=$(B)/trapfw EXTRA_OBJS=smoke_trap.o:
#                     the firmware of the source tree with the trap
#                     constructor linked in (RV32OSDA.BIN, .elf, .map, .lst)
#   card_trap.img     as card.img, with trapfw/RV32OSDA.BIN
#   trap_expect.txt   the EXC line the trap must print, mepc = smoke_trap's
#                     address in trapfw/RV32OSDA.map
TOP := $(abspath $(CURDIR)/../../..)
include $(TOP)/tools/riscv/toolchain.mk

B      ?= build
FW     ?= $(TOP)/fw/ctrl_rv/build/RV32OSDA.BIN
MKCARD := $(TOP)/tools/sim/mkcard.sh
CARDMB := 16
BA     := $(abspath $(B))

CFLAGS = $(RV_CFLAGS_FW) -std=gnu23 --specs=nano.specs -g -Wall -Wextra -Werror

.PHONY: all trap clean
.DELETE_ON_ERROR:
all: $(B)/card.img
trap: $(B)/card_trap.img $(B)/trap_expect.txt

$(B)/fw/RV32OSDA.BIN: $(FW)
	@[ -f "$(FW)" ] || { echo "no firmware $(FW) (make -C fw/ctrl_rv)"; exit 1; }
	@mkdir -p $(@D)
	cp "$(FW)" $@

# decoy: text, an illegal instruction stream if it were ever run
$(B)/832OSDAD.BIN:
	@mkdir -p $(@D)
	yes DECOY832 | head -c 2000 > $@

$(B)/card.img: $(B)/832OSDAD.BIN $(B)/fw/RV32OSDA.BIN $(MKCARD)
	bash $(MKCARD) $@ $(CARDMB) $(B)/832OSDAD.BIN $(B)/fw/RV32OSDA.BIN

$(B)/smoke_trap.o: smoke_trap.c
	@mkdir -p $(@D)
	$(RV_CC) $(CFLAGS) -c -o $@ $<

# the firmware's own Makefile, in its own build directory: every unit is
# compiled as for the shipped image, smoke_trap.o is the one extra object
$(B)/trapfw/RV32OSDA.BIN: $(B)/smoke_trap.o
	$(MAKE) -C $(TOP)/fw/ctrl_rv B=$(BA)/trapfw EXTRA_OBJS=$(BA)/smoke_trap.o

$(B)/card_trap.img: $(B)/832OSDAD.BIN $(B)/trapfw/RV32OSDA.BIN $(MKCARD)
	bash $(MKCARD) $@ $(CARDMB) $(B)/832OSDAD.BIN $(B)/trapfw/RV32OSDA.BIN

$(B)/trap_expect.txt: $(B)/trapfw/RV32OSDA.BIN
	a=$$(sed -n 's/^ *0x\([0-9a-f]*\) *smoke_trap$$/\1/p' $(B)/trapfw/RV32OSDA.map); \
	[ -n "$$a" ] || { echo "smoke_trap not in $(B)/trapfw/RV32OSDA.map"; exit 1; }; \
	printf 'EXC mcause=00000002 mepc=%08X mtval=FFFFFFFF\n' 0x$$a > $@

clean:
	rm -rf $(B)
