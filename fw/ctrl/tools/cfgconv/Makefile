# cfgconv: Minimig config files between the previous firmware's big-endian
# and the RISC-V byte order
# (README.md).  Host C, no RISC-V toolchain needed.
#   make -C fw/ctrl/tools/cfgconv            -> fw/ctrl/tools/cfgconv/cfgconv
#   make -C fw/ctrl/tools/cfgconv B=<dir>    -> <dir>/cfgconv
#   make -C fw/ctrl/tools/cfgconv clean
# fw/ctrl/test builds its own copies with the sanitizers (config_test).
CC      = gcc
B      ?= .
SRC    := ../..
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu2x -Wall -Wextra -Werror -I$(SRC)

$(B)/cfgconv: cfgconv.c $(SRC)/cfgswap.c $(SRC)/cfgswap.h $(SRC)/swap.h
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ cfgconv.c $(SRC)/cfgswap.c

clean:
	$(RM) $(B)/cfgconv

.PHONY: clean
