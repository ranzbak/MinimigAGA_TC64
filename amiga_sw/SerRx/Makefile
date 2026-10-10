AS=vasmm68k_mot
VASM_FLAGS	:= -quiet -m68020 -Fhunkexe -kick1hunks -nosym

TARGET		:= SerRx
SOURCE		:= SerRx.s

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(AS) $< -o $@ $(VASM_FLAGS)

test: $(TARGET)
	./test_serrx.sh

clean:
	rm -f $(TARGET)

.PHONY: all test clean
