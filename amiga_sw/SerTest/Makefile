AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68020 -Fhunkexe -kick1hunks -nosym

TARGET		:= SerTest
SOURCE		:= SerTest.asm

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

clean:
	rm -f $(TARGET)
