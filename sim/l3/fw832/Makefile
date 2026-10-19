# The 832 firmware for the L3 bench (sim/l3/README.md "832"): 832OSDAD.BIN
# built reproducibly from a copy of fw/ctrl_832 with its own Makefile and
# the EightThirtyTwo tools (vbcc832, 832a / 832l, lib832) of E832DIR.
#
#   make -C sim/l3/fw832 B=<dir> E832DIR=<EightThirtyTwo checkout>
#     -> <dir>/832OSDAD.BIN, <dir>/832OSDAD.map, <dir>/832OSDAD.txt (the
#        sources' git state, L3_DATE, sha256), <dir>/make.log
#
# Variables:
#   B        output directory, default build (relative to this directory)
#   E832DIR  the EightThirtyTwo checkout with the tools built in it (its
#            vbcc/bin/vbcc832, 832a/832a, 832a/832l, lib832/crt0.a,
#            lib832/lib832.a); default $(TOP)/EightThirtyTwo, the submodule
#            (not initialised in a worktree: point it at the main checkout's)
#   L3_DATE  the date every `date` of the build prints (date.sh), default
#            2026-01-01: the version strings in version.h, so the image
#
# fw/ctrl_832 is never built in place (its tracked version.h would change):
# its tracked files are copied to <B>/src, which is built with
# 832DIR=$(E832DIR) and <B>/dateshim (date.sh) first on PATH.  Only the
# targets version.h and 832OSDAD.bin are made: bootcustominit.h is a
# tracked file, so vasmm68k_mot is not needed.  USER, BUILD_TG and BUILD_R
# are fixed (fw/ctrl_832's -D__BUILD_USER / __BUILD_TAG, unused by the
# sources, and its git calls).  Every make rebuilds (about a minute).
TOP     := $(abspath $(CURDIR)/../../..)
B       ?= build
BA      := $(abspath $(B))
E832DIR ?= $(TOP)/EightThirtyTwo
E832A   := $(abspath $(E832DIR))
L3_DATE ?= 2026-01-01
export L3_DATE
TOOLS   := vbcc/bin/vbcc832 832a/832a 832a/832l lib832/crt0.a lib832/lib832.a

.PHONY: all clean FORCE
all: $(BA)/832OSDAD.BIN

$(BA)/832OSDAD.BIN: FORCE
	@for t in $(TOOLS); do [ -f "$(E832A)/$$t" ] || { echo "fw832: no $(E832A)/$$t (E832DIR= the EightThirtyTwo checkout with its tools built)"; exit 1; }; done
	rm -rf "$(BA)/src" "$(BA)/dateshim" "$@"
	mkdir -p "$(BA)/src" "$(BA)/dateshim"
	install -m 755 date.sh "$(BA)/dateshim/date"
	cd "$(TOP)" && git ls-files -z -- fw/ctrl_832 | tar --null -T - -cf - | tar -C "$(BA)/src" --strip-components=2 -xf -
	[ -f "$(BA)/src/Makefile" ] && [ -f "$(BA)/src/main.c" ] || { echo "fw832: copy of fw/ctrl_832 failed"; exit 1; }
	PATH="$(BA)/dateshim:$$PATH" $(MAKE) -C "$(BA)/src" 832DIR="$(E832A)" USER=l3 BUILD_TG=l3 BUILD_R=l3 \
		version.h 832OSDAD.bin > "$(BA)/make.log" 2>&1 || { tail -20 "$(BA)/make.log"; echo "fw832: build failed ($(BA)/make.log)"; exit 1; }
	cp "$(BA)/src/832OSDAD.map" "$(BA)/832OSDAD.map"
	cp "$(BA)/src/832OSDAD.bin" "$@"
	@{ echo "sources: fw/ctrl_832, last change $$(git -C "$(TOP)" log -1 --format=%h -- fw/ctrl_832), $$(git -C "$(TOP)" diff --quiet HEAD -- fw/ctrl_832 && echo unmodified || echo MODIFIED) against git HEAD"; \
	   echo "tools: $(E832A)"; \
	   echo "L3_DATE: $(L3_DATE), version.h: $$(sed -n 's/^#define MM_FIRMWARE_VERSION //p' "$(BA)/src/version.h")"; \
	   echo "832OSDAD.BIN: $$(stat -c %s "$@") bytes, sha256 $$(sha256sum "$@" | cut -c1-16)"; } | tee "$(BA)/832OSDAD.txt"

clean:
	rm -rf "$(BA)/src" "$(BA)/dateshim" "$(BA)/832OSDAD.BIN" "$(BA)/832OSDAD.map" "$(BA)/832OSDAD.txt" "$(BA)/make.log"
