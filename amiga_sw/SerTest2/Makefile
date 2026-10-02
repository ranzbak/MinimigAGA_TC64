AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68020 -Fhunkexe -kick1hunks -nosym

TARGET		:= SerTest2
SOURCE		:= SerTest2.asm

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

clean:
	rm -f $(TARGET)
