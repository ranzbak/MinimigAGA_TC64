# atapi_emu: atapi.c built by vbcc832 and run in 832e, the EightThirtyTwo
# emulator (see atapi_emu.c).  Little-endian: 832e's big-endian mode mixes
# swapped (stmpdec) and raw (stbinc) byte writes; the size bug this test is
# for shows either way (a 32-bit store clobbers the bytes after a uint8_t).
# Exit status 0 = PASS.

832DIR ?= ../../../../EightThirtyTwo
CC      = $(832DIR)/vbcc/bin/vbcc832
AS      = $(832DIR)/832a/832a
LD      = $(832DIR)/832a/832l
# 832e as of EightThirtyTwo d1cd671 does not set the Z/C flags on ldt, which
# every other load and the CPU (RTL/eightthirtytwo_cpu.vhd: any load sets Z
# and C) do; vbcc832 tests "if (u->ua_asc)" with byt ldt + cond.  The test
# builds its own copy with that one line added (832e_ldt).
EMU     = ./832e_ldt
EMUSRC  = $(832DIR)/832emu
LIBDIR  = $(832DIR)/lib832
# the firmware's code generator options (fw/ctrl_832/Makefile)
CFLAGS  = -+ -c99 -O=1343 -unsigned-char -D__geta4= -DNULL=0 -I../.. -I$(832DIR)/include/ -I$(LIBDIR)

all: run

atapi.asm: ../../atapi.c ../../atapi.h
	$(CC) $(CFLAGS) -o=$@ ../../atapi.c

atapi_emu.asm: atapi_emu.c ../../atapi.h
	$(CC) $(CFLAGS) -o=$@ atapi_emu.c

%.o: %.asm
	$(AS) -o $@ $<

832e_ldt: $(EMUSRC)/832e.cpp
	rm -rf emusrc && cp -r $(EMUSRC) emusrc && rm -rf emusrc/.obj emusrc/832e
	sed -i 's|^\(\t*\)temp=prg.Read(temp,endian,sizemod);$$|&\n\1zero=(temp==0);\n\1carry=(temp\&0x80000000)!=0;|' emusrc/832e.cpp
	grep -A2 'temp=prg.Read(temp,endian,sizemod);' emusrc/832e.cpp | grep -q 'zero=(temp==0);'
	$(MAKE) -C emusrc
	cp emusrc/832e $@

atapi_emu: atapi_emu.o atapi.o
	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a atapi_emu.o atapi.o

run: atapi_emu 832e_ldt
	$(EMU) atapi_emu | tee atapi_emu.log; ! grep -q "^FAIL" atapi_emu.log && grep -qx PASS atapi_emu.log

clean:
	rm -rf *.asm *.o atapi_emu atapi_emu.log 832e_ldt emusrc

.PHONY: all run clean
