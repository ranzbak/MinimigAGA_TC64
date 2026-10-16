# Host tests for the CD-ROM (findings/cdrom/plan.md): atapi_test, the ATAPI
# command layer (task 0.1); cdrom_test, the board glue against a model of
# the Gayle port and an ATAPI host (task 1.4); phase 3
# (findings/cdrom/phase3-plan.md): cue_test, the CUE parser and disc model;
# cdaudio_test, the CD audio player against a model of the audio ring.
#   make -C fw/ctrl_832/test            build and run them all (exit status = result)
#   make -C fw/ctrl_832/test ISO=<path> use another ISO for the ISO-backed cases
# Without the ISO those cases are skipped, not failed.

HOSTCC   = gcc
CFLAGS   = -std=c99 -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g \
           -fsanitize=address,undefined -fno-sanitize-recover=all -I..
ISO     ?= $(HOME)/work/amiga/AmigaOS3.9.iso

all: run

atapi_test: atapi_test.c ../atapi.c ../atapi.h ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c ../cue.c

cue_test: cue_test.c ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ cue_test.c ../cue.c

cdaudio_test: cdaudio_test.c ../cdaudio.c ../cdaudio.h ../cue.c ../cue.h
	$(HOSTCC) $(CFLAGS) -o $@ cdaudio_test.c ../cdaudio.c ../cue.c

cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../hdd.h
	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c

run: cue_test cdaudio_test atapi_test cdrom_test
	./cue_test
	./cdaudio_test
	./atapi_test "$(ISO)"
	./cdrom_test

clean:
	rm -f cue_test cdaudio_test atapi_test cdrom_test

.PHONY: all run clean
