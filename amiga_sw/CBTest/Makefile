AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68040 -Fhunkexe -kick1hunks -nosym

TARGET		:= CBTest
SOURCE		:= CBTest.asm

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

clean:
	rm -f $(TARGET)
