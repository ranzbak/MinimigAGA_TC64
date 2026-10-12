# Host test for the ATAPI CD-ROM layer (findings/cdrom/plan.md, task 0.1).
#   make -C fw/ctrl_832/test            build and run (exit status = result)
#   make -C fw/ctrl_832/test ISO=<path> use another ISO for the ISO-backed cases
# Without the ISO those cases are skipped, not failed.

HOSTCC   = gcc
CFLAGS   = -std=c99 -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g \
           -fsanitize=address,undefined -fno-sanitize-recover=all -I..
ISO     ?= $(HOME)/work/amiga/AmigaOS3.9.iso

all: run

atapi_test: atapi_test.c ../atapi.c ../atapi.h
	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c

run: atapi_test
	./atapi_test "$(ISO)"

clean:
	rm -f atapi_test

.PHONY: all run clean
