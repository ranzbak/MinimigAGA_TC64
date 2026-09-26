AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68000 -Fhunkexe -kick1hunks -nosym

TARGET		:= DDR3First
SOURCE		:= DDR3First.asm

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

clean:
	rm -f $(TARGET)
