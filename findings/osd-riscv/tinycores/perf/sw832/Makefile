# MINIMIG-DE1
# ctrl boot firmware
# 2012, rok.krajnc@gmail.com
# Ported to EightThirtyTwo by AMR

### tools ###

BASE	= 
832DIR = ../../EightThirtyTwo
CC      = $(832DIR)/vbcc/bin/vbcc832
GCC		= gcc
LD      = $(832DIR)/832a/832l
AS      = $(832DIR)/832a/832a
CP      = objcopy
DUMP    = objdump

LIBDIR = $(832DIR)/lib832
BUILD_DIR = 832obj
COMMON_DIR = $(832DIR)/Lib
INCLUDE_DIR = $(832DIR)/include
STARTUP_DIR = $(832DIR)/Lib

PROJECT=832OSDAB

### flags ###

CFLAGS  = -+ -c99 -O=1343 -unsigned-char -D__geta4= -DNULL=0 -I. -I$(INCLUDE_DIR)/ -I$(COMMON_DIR)/ -I../OSD/
ASFLAGS = -eb
LDFLAGS  = -eb -s_STACKSIZE=0x0 -s_STACKTOP=0x2000 -b 0x2000

### variables ###

# headers
HEADERS=dhry.h

### variables ###
BUILD_USER=\"$(USER)\"
BUILD_T=$$(date +%Y-%m-%d)
BUILD_TIME=\"$(BUILD_T)\"
BUILD_N=$$(cat build_num.txt)
BUILD_NUM=\"$(BUILD_N)\"
BUILD_R=$$(git rev-parse --verify HEAD)
BUILD_REV=\"$(BUILD_R)\"
BUILD_TG=$$(git describe --tags --abbrev=0)
BUILD_TAG=\"$(BUILD_TG)\"

BINDIR=bin
OBJDIR=obj

CFLAGS += -D__BUILD_USER=$(BUILD_USER) -D__BUILD_TAG=$(BUILD_TAG)

### fw specific ###



# common sources
COMMON_SOURCES=$(BUILD_DIR)/dhry_1.o $(BUILD_DIR)/dhry_2.o $(BUILD_DIR)/uart.o


# all sources
ALL_SOURCES = $(LIBDIR)/crt0.a $(COMMON_SOURCES) $(LIBDIR)/lib832.a 


### build rules ###

# all
all: $(PROJECT).bin

$(PROJECT).bin: Makefile $(ALL_SOURCES)
	$(LD) $(LDFLAGS) -M $(PROJECT).map -o $@ $(ALL_SOURCES)

# clean
clean:
	@echo clean
	@rm -rf $(BUILD_DIR)/*.o
	@rm -rf $(PROJECT).bin
	@rm -rf $(PROJECT).map

%.asm: %.c
	$(CC) $(CFLAGS) -o=$@ $<

$(BUILD_DIR)/%.o: %.asm $(BUILD_DIR)
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILD_DIR)/%.o: $(STARTUP_DIR)/%.S $(BUILD_DIR) 
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILD_DIR):
	mkdir $(BUILD_DIR)

