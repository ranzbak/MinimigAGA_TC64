# WinUAE cputest corpus for the 68040 (M0.2, generator side)

This directory has a native Linux build of WinUAE's CPU tester **generator**
(`cputestgen`) and a 68040 integer corpus generated with it. The Amiga-side
runtime (`cputest/main.c` etc.) is not built here.

    gen/build.sh          reproduces gen/cputestgen from ~/work/amiga/WinUAE (read-only)
    gen/gen_corpus.sh     writes the ini and runs the generator -> data040/
    gen/Makefile          build68k -> cpudefs.cpp, gencpu (CPU_TESTER=1) -> test cores, cputestgen
    gen/shim/             Linux sysconfig.h / target.h / tchar.h (TCHAR = char)
    gen/linux_support.cpp stands in for od-win32/unicode.cpp
    data040/              the corpus (4_<GROUP>/<INSN>/0000.daz + lmem.dat/tmem.dat per group)
    cputestgen_used.ini   the exact ini that produced data040/
    cputestgen.log        the generator's output for that run

## Build

    cd gen && ./build.sh                 # ~1 min with 8 jobs; result: gen/cputestgen
    WINUAE=/other/checkout ./build.sh
    WINUAE_REV=HEAD ./build.sh           # build the tip instead (see "Revision" below)

`build.sh` runs `git archive` on the chosen revision into `gen/build/src`, so it
only reads from the checkout and does not touch it. It applies the patches
listed below to that copy, then runs make. You need g++ and zlib (`-lz`).

## Generate

    cd gen
    ./gen_corpus.sh                                   # BASIC only
    ./gen_corpus.sh BASIC "move,add,cmp,bcc"          # subset by mnemonic
    ./gen_corpus.sh Default,BASIC,IRQ,EXTSRC,EXTDST,AE,ODDSTK,ODDEXC,ODDIRQ   # what is in data040/
    ./gen_corpus.sh FBASIC,FINT,FPACK "" /some/dir    # FPU groups, other output root

The generator writes into the output root (default: this directory):
`data040/`, `cputestgen_used.ini` and `cputestgen.log`. It overwrites
instructions that already exist but does not delete other groups.

The ini is the revision's stock `cputest/cputestgen.ini` (cpu=68040,
cpu_address_space=68020, test memory 0x460000+0xa0000, feature_flags_mode=1,
test_rounds=1, gzip on, no split) with these edits:

| edit | why |
|---|---|
| `path=data040/` | gives the layout apolkosnik's `run_cputest.py` looks for |
| `test_low_memory_start=0`, `_end=0x8000` | produces `lmem.dat`, which `run_cputest.py` requires (stock ini: disabled) |
| `feature_condition_codes=` commented out | the stock **empty** value parses as "no condition codes" rather than "all", so every Bcc/DBcc/Scc/TRAPcc gets 0 tests without any warning |
| `enabled=1` on the requested groups (+ `mode=` if given) | the stock ini has every 68020+ group disabled |

## What is in data040/ now

Revision d2838c08, DATA_VERSION 24. Takes 6 min on one core. Total
27,014,475 tests, 54 MB, 439 instruction containers, 6,792 slices.

| dir | run_cputest.py name | instructions | slices | tests | size |
|---|---|---|---|---|---|
| 4_Default | Default | 181 | 532 | 3,661,164 | 16 MB |
| 4_BASIC | Basic | 181 | 670 | 20,898,336 | 30 MB |
| 4_IRQ | IRQ | 29 | 117 | 293,881 | 1.2 MB |
| 4_EXTSRC | FFEXT_SRC | 6 | 4,632 | 30,126 | 2.1 MB |
| 4_EXTDST | FFEXT_DST | 6 | 756 | 30,272 | 1.5 MB |
| 4_AE | AE | 12 | 38 | 1,428,424 | 1.5 MB |
| 4_ODDSTK | ODD_STK | 4 | 6 | 15,328 | 0.7 MB |
| 4_ODDEXC | ODD_EXC | 16 | 33 | 655,920 | 1.4 MB |
| 4_ODDIRQ | ODD_IRQ | 4 | 8 | 1,024 | 0.7 MB |

BASIC by itself takes 140 s and makes 30 MB. The FPU groups (FBASIC, FINT, FPACK)
are not included: in a 25-minute trial (killed by timeout) FBASIC finished only
18 instruction containers (1.2 MB), because it uses `min_opcode_test_rounds=5000`
and runs at `verbose=1`. Expect hours for the full FPU set; run it separately
with `gen_corpus.sh FBASIC,FINT,FPACK "" <dir>`.

Each group directory holds `lmem.dat`, `tmem.dat` (uncompressed, identical across
groups) and one `<INSN>/0000.daz` per instruction. The `.daz` file is a
sequence of `"\xafMRG" + u32 length + gzip member` records: member 0 is the
header (DATA_VERSION 24, instruction name at +92), the rest are the slices.

## Compatibility with apolkosnik's tooling

`~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer/tests/ap040/`:

* `diff/dat_parser.py` accepts `SUPPORTED_VERSIONS = (20, 24)`. v24 has three
  extra header longs and the `$FF` escape in `restore_bytes`, and the parser
  handles both. `decode_cputest_dat.py` and `replay_cputest_dat.py` still
  hard-code DATA_VERSION 20, so they will not read this corpus as they are.
* `run_cputest.py` takes a zip, a `data/` directory or an extraction root.
  It looks for `68040_*/*/0000.dat` (the v20 layout) and `4_*/*/0000.daz` (the
  v24 layout, also under a `data040/` wrapper) and maps `4_BASIC` to `Basic` and so on.
  This corpus is v24 in exactly that layout. Pass this directory:

      cd ~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer/tests/ap040
      ./run_cputest.py <this dir> --audit --work /tmp/somewhere
      # 6792/6792 slices pass the structural audit (136 s)
      ./run_cputest.py <this dir> --audit --semantic-audit --group Basic \
          --instruction 'MOVE.*' --instruction 'Bcc.*' --instruction 'CMP.*' \
          --instruction 'ADD.*' --instruction NOP --work /tmp/somewhere
      # 112/112 pass the semantic audit

  Always pass `--work`, because the default writes into that repo's `build/`.
* apolkosnik's baselines (1,911 slices, 1875 pass) come from the **v20**
  `data040.zip` (68040_* names, 587 headers). A corpus freshly generated at v24
  is different data, so slice numbers and pass counts do not carry over.
* WinUAE history: DATA_VERSION 20 lasted from f68c3400 (2020-05-31) to f0cf9536
  (2020-07-03, bumped to 21). It became 24 at 81959513 (2023-03-12) and is
  still 24 at HEAD. To regenerate a v20-format corpus you would build the
  generator from `f0cf9536~1`. That was not attempted: the old tree predates
  several of the fixes below and would need its own porting pass.

## Revision, and the patches build.sh applies

The default revision is **d2838c08** (`e58f45d5~1`, 2023-09-16), because HEAD's
generator has a data-destroying bug:

1. **e58f45d5 (HEAD too): `fill_memory_buffer()` does nothing.** It computes
   `pend = p - 64` instead of `p + size - 64`, so `tmem.dat`/`lmem.dat` come out
   all zero, and the EA search in `analyze_address()` (which looks for zero,
   negative and positive operands) spins almost forever. With HEAD, "BASIC all"
   did not get past OR in 35 minutes. `WINUAE_REV=HEAD` patches this, and was
   tested only on or/nop/bcc.

Patches for building on Linux or a 64-bit host (each one is checked, so the
build stops if the source line it expects has changed):

2. gencpu hard-codes `#define CPU_TESTER 0`. The author flips it by hand to get
   `cpuemu_9x_test.cpp`/`cpustbl_test.cpp`/`cputbl_test.h`, so build.sh sets it to 1.
3. build68k's `#define TCHAR char` clashes with the typedef and is removed.
4. `static inline float_raise` (softfloat-specialize.h) and cputest.cpp's private
   `static my_trim` both follow extern declarations. MSVC keeps them static;
   g++ `-fpermissive` makes them extern, so they give duplicate symbols. float_raise
   becomes plain `inline`, and the copy of my_trim is renamed (it is identical
   to the one in cputest_support.cpp).
5. **64-bit bug:** `memcpy(test_memory + (regs.isp - test_memory_start),
   test_memory + (regs.usp - test_memory_start), 0x20)` uses uae_u32 arithmetic.
   EXTSRC/EXTDST give USP = test_memory_start - 2, so the pointer ends up about
   4 GB away and the program segfaults. The 32-bit Windows build wraps around and
   silently copies 2 bytes from before the buffer; WinUAE's own x64 build would
   crash too. The copy now only happens when the stack image lies inside test
   memory.
6. **Header over-read:** `save_data()` writes the three spare header longs as
   `fwrite(&data[1],1,4)` and `fwrite(&data[2],1,4)` from a 4-byte stack array,
   which pulls stack garbage into the spare words (ASan: stack-buffer-overflow).
   The array is now `data[8] = {0}`: same layout, and the output is deterministic.
7. HEAD only: 905f7998 added a `vector_nr` argument to
   `Exception_build_stack_frame_common` without updating cputest.cpp's three
   calls, so HEAD's generator does not compile even on Windows. build.sh passes
   `test_exception` for it, but only when the header has the new signature.

Checks done: an ASan build (`-fsanitize=address`, after patches 5 and 6)
generated the whole integer set with no reports. Its output matches the
`-O2` build exactly once the start-time word is ignored.

## Things to know

* `mode=moveq` fails with "Couldn't find": in table68k MOVEQ is part of MOVE.
  Use `move`.
* Every normally completing test is recorded as "exception 4 at the end PC": the
  generator runs until the `ILLEGAL` placed after the test instruction. So the
  log's `OK=0 ... E4=n` is normal and does not indicate a failure.
* The header's start-time word (`time(0)`) differs between runs. Apart from that
  the output is deterministic for a given ini and revision. `tmem.dat` is
  seeded, not random per run.
* The corpus is not packed as `data040.zip` or an ADF/HDF image. `run_cputest.py`
  reads the directory directly. For the Amiga runtime, copy `data040/` next to
  the `cputest` executable.
* FPU groups: generation works but is slow (see above) and has not been run
  to completion or audited.
