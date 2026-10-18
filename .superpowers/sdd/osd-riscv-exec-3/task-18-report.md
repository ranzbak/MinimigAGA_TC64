# Task 18 report: Clang/LLVM build check

Status: DONE.

## Implemented
- `fw/ctrl_rv/Makefile`: `CLANG=1` -> `B=build_clang`; compile with `clang --target=riscv32-unknown-elf` (target-specific `RV_CC` on `$(ARCH_OBJS) $(OBJS)`, same `RV_CFLAGS_FW`, `-std=gnu23` accepted by clang 18.1.3, `__STDC_VERSION__` 202311L), newlib-nano `-isystem` paths by hand (nano first), no `-fstack-usage` (`make stack` refuses under CLANG). Link through the xPack gcc driver (unchanged line), not ld.lld (ld.lld is installed, unused), so GNU ld map and check (e) work as is. `CLANG_WNO := -Wno-unknown-warning-option -Wno-unknown-attributes` (gcc-only `#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"` in hdd.c/drivesounds.c, `__attribute__((nonstring))` in menu.c; not defects).
- Source fixes (gcc disassembly identical to a gcc build of HEAD saved before the edits; BIN 92,588 B): rafile.c dead `result` in RAReadLine; c64keys.c dead `idx`; stackcheck.c `register ... __asm__("sp")` read uninitialised in clang (real) -> `__asm__("" : "+r"(sp))`.
- `check_io.awk`: clang puts branch-only blocks after a `j`; stale tracked constants gave false (b)/(c) failures (`lw s6,-16(s1)` after `li s1,0`). Now forgets constants after j/jr/ret/mret. gcc counts unchanged (1156 seen, 8 tracked). clang: 1340 seen, all zero-based (never passes on nothing).
- `.gitignore`: `build_clang/`. README section "Clang build (Task 18...)".
- No -Wchar-subscripts hit occurred (no toupper/tolower call with plain char in this tree), so no cast was needed.

## Results
- `make -C fw/ctrl_rv CLANG=1 clean all size check`: zero warnings, links, checks (a)-(g) pass. clang: text 96,712, data 3,480, bss 59,308; RV32OSDA.BIN 100,192 B (gcc 92,588 B).
- `make check` (gcc) passes.
- L2 fwboot clang image (RUNTAG=p3t18): PASS; OSD GAP min 40 (534 bytes); STACK low 0x1980 (1664 B used).
- L2 fwboot gcc image after the source edits (RUNTAG=p3t18g): PASS; OSD GAP min 40; STACK low 0x1950 (1712 B).
- rvlibc.c and format strings untouched, so fmt bench and host suite not re-run.

## Files
fw/ctrl_rv/{Makefile,.gitignore,README.md,check_io.awk,rafile.c,c64keys.c,stackcheck.c}
