# Firmware units built by vbcc832 and run in 832e, the EightThirtyTwo
# emulator: atapi_emu (atapi.c), cue_emu (cue.c).  Little-endian: 832e's
# big-endian mode mixes swapped (stmpdec) and raw (stbinc) byte writes; the
# size bug these tests are for shows either way (a 32-bit store clobbers
# the bytes after a uint8_t).  Exit status 0 = every program printed PASS.

832DIR ?= ../../../../EightThirtyTwo
CC      = $(832DIR)/vbcc/bin/vbcc832
AS      = $(832DIR)/832a/832a
LD      = $(832DIR)/832a/832l
# 832e as of EightThirtyTwo d1cd671 differs from the CPU in two places the
# tests reach, and the tests build their own copy with both fixed (832e_fix):
#  - it does not set the Z/C flags on ldt, which every other load and the CPU
#    (RTL/eightthirtytwo_cpu.vhd: any load sets Z and C) do; vbcc832 tests
#    "if (u->ua_asc)" with byt ldt + cond.
#  - it has no mul at all (opc_mul 0x90 is decoded as nothing, so "n * 10"
#    leaves n unchanged); README.md: mul r<n> = 32x32 -> 64, low half to
#    r<n>, high half to tmp, signed when sgn is set.
EMU     = ./832e_fix
EMUSRC  = $(832DIR)/832emu
LIBDIR  = $(832DIR)/lib832
# the firmware's code generator options (fw/ctrl_832/Makefile)
CFLAGS  = -+ -c99 -O=1343 -unsigned-char -D__geta4= -DNULL=0 -I../.. -I$(832DIR)/include/ -I$(LIBDIR)

PROGS    = atapi_emu cue_emu
UNIT_ASM = atapi.asm cue.asm
TEST_ASM = $(PROGS:=.asm)

all: run

$(UNIT_ASM): %.asm: ../../%.c
	$(CC) $(CFLAGS) -o=$@ $<

$(TEST_ASM): %.asm: %.c
	$(CC) $(CFLAGS) -o=$@ $<

atapi.asm: ../../atapi.h
cue.asm: ../../cue.h
atapi_emu.asm: ../../atapi.h
cue_emu.asm: ../../cue.h

%.o: %.asm
	$(AS) -o $@ $<

832e_fix: $(EMUSRC)/832e.cpp
	rm -rf emusrc && cp -r $(EMUSRC) emusrc && rm -rf emusrc/.obj emusrc/832e
	sed -i 's|^\(\t*\)temp=prg.Read(temp,endian,sizemod);$$|&\n\1zero=(temp==0);\n\1carry=(temp\&0x80000000)!=0;|' emusrc/832e.cpp
	grep -A2 'temp=prg.Read(temp,endian,sizemod);' emusrc/832e.cpp | grep -q 'zero=(temp==0);'
	sed -i '0,/^\(\t*\)case opc_add: \/\/ add$$/s//\1case opc_mul: \/\/ mul\n\1\tif(sign_mod) t2=(long long)(int)regfile[operand]*(long long)(int)temp;\n\1\telse t2=(long long)((unsigned long long)regfile[operand]*(unsigned long long)temp);\n\1\tregfile[operand]=(unsigned int)t2;\n\1\ttemp=(unsigned int)((unsigned long long)t2>>32);\n\1\tzero=regfile[operand]==0;\n\1\tcarry=0;\n\1\tsign_mod=false;\n\1\tmnem << ("mul ") << operand;\n\1\tbreak;\n\n&/' emusrc/832e.cpp
	grep -q 'case opc_mul: // mul' emusrc/832e.cpp
	$(MAKE) -C emusrc
	cp emusrc/832e $@

atapi_emu: atapi_emu.o atapi.o
	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^

cue_emu: cue_emu.o cue.o
	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^

run: $(PROGS) 832e_fix
	timeout 60 $(EMU) atapi_emu | tee atapi_emu.log; ! grep -q "^FAIL" atapi_emu.log && grep -qx PASS atapi_emu.log
	timeout 60 $(EMU) cue_emu | tee cue_emu.log; ! grep -q "^FAIL" cue_emu.log && grep -qx PASS cue_emu.log

clean:
	rm -rf *.asm *.o $(PROGS) *.log 832e_fix emusrc

.PHONY: all run clean
