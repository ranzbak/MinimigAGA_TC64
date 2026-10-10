AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68040 -Fhunkexe -kick1hunks -nosym

TARGET		:= ChipCoh
SOURCE		:= ChipCoh.asm

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

test: $(TARGET)
	./test_chipcoh.sh

clean:
	rm -f $(TARGET)

.PHONY: all test clean
