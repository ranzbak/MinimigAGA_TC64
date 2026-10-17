#!/usr/bin/env bash
# Mutants of the C-library tests (make -C fw/ctrl_rv/test mutants).  Each one is
# a sed on a run copy under mut/; the check it targets must turn red.
# Needs the files of `make fmt.ok` (fmt_832.txt, fmt_glibc_64.txt, fmt_cases.h).
set -u
cd "$(dirname "$0")" || exit 1
HOSTCC=${HOSTCC:-gcc}
FLAGS="-std=gnu2x -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g
 -fsanitize=address,undefined -fno-sanitize-recover=all -U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin
 -Wno-error"   # a mutant must be killed by the test, not by an unused-variable warning
bad=0

# mutate <name> <file> <sed expression>: fresh copy of rvlibc.{c,h} in mut/<name>
mutate() {
  mkdir -p "mut/$1"
  cp ../rvlibc.c ../rvlibc.h "mut/$1/"
  sed -i "$3" "mut/$1/$2"
  if cmp -s "../$2" "mut/$1/$2"; then echo "mutant $1: the sed changed nothing"; bad=1; return 1; fi
}

killed() { echo "mutant $1: killed ($2)"; }
survived() { echo "mutant $1: SURVIVED ($2)"; bad=1; }

# 1 the print buffer is 16 bytes: the format-parity check is red
if mutate buf16 rvlibc.h 's/^#define RV_PRINTF_BUF .*/#define RV_PRINTF_BUF 16/'; then
  # shellcheck disable=SC2086
  $HOSTCC $FLAGS -Imut/buf16 -o mut/buf16/fmt_glibc fmt_host.c mut/buf16/rvlibc.c &&
    ./mut/buf16/fmt_glibc > mut/buf16/fmt_glibc.txt
  if python3 -I gold/fmtcheck.py diff fmt_832.txt mut/buf16/fmt_glibc.txt fmt_cases.h > mut/buf16/diff.txt 2> /dev/null; then
    survived buf16 "fmtcheck diff passed"
  else killed buf16 "fmtcheck diff fails"; fi
fi

# 2 one line of the expected difference list is gone
mkdir -p mut/expected
sed '7d' gold/fmt_diff_expected.txt > mut/expected/fmt_diff_expected.txt
if python3 -I gold/fmtcheck.py diff fmt_832.txt fmt_glibc_64.txt fmt_cases.h 2> /dev/null | diff -q mut/expected/fmt_diff_expected.txt - > /dev/null; then
  survived expected "list with a line deleted still equal"
else killed expected "diff against the list fails"; fi

# 3 a format string without a case: the cover step is red
mkdir -p mut/cover
{ cat gold/formats.txt; echo '"a format nobody tests %d"'; } > mut/cover/formats.txt
if python3 -I gold/fmtcheck.py cover mut/cover/formats.txt fmt_cases.h > /dev/null 2>&1; then
  survived cover "cover passed with an extra format"
else killed cover "fmtcheck cover fails"; fi

# 4.. lib_test mutants: a change in rvlibc.c must turn lib_test red
libtest_mutant() {  # <name> <sed>
  if mutate "$1" rvlibc.c "$2"; then
    # shellcheck disable=SC2086
    if ! $HOSTCC $FLAGS -Imut/"$1" -o mut/"$1"/lib_test lib_test.c mut/"$1"/rvlibc.c 2> mut/"$1"/build.log; then
      survived "$1" "the mutant does not build: mut/$1/build.log"
    elif ./mut/"$1"/lib_test > mut/"$1"/run.log 2>&1; then
      survived "$1" "lib_test passed"
    else killed "$1" "lib_test red"; fi
  fi
}
libtest_mutant notrunc 's/rv_printf_truncations++;/;/'
libtest_mutant sendfull 's/send = size - 1;/send = size;/'
libtest_mutant nonest 's/char \*buf = depth ? printf_irq_buf : printf_buf;/char *buf = printf_buf;/; s/size_t size = depth ? sizeof printf_irq_buf : sizeof printf_buf;/size_t size = sizeof printf_buf;/'
libtest_mutant nodepthrestore 's/printf_depth = depth;/;/'
libtest_mutant heapcount 's/rv_libc_heap_calls++;/;/'
libtest_mutant retval 's/return n;/return 0;/'

# hwmap_test mutants: a change in the register map or in uart.c must turn it red
hwmap_mutant() {  # <name> <file> <sed>
  mkdir -p "mut/$1/arch"
  cp ../*.h ../uart.c "mut/$1/"; cp ../arch/*.h "mut/$1/arch/"
  sed -i "$3" "mut/$1/$2"
  if cmp -s "../$2" "mut/$1/$2"; then echo "mutant $1: the sed changed nothing"; bad=1; return; fi
  # shellcheck disable=SC2086
  if ! $HOSTCC $FLAGS -Imut/"$1" -Imut/"$1"/arch -o mut/"$1"/hwmap_test hwmap_test.c 2> mut/"$1"/build.log; then
    killed "$1" "does not build: the test is red"
  elif ./mut/"$1"/hwmap_test > mut/"$1"/run.log 2>&1; then
    survived "$1" "hwmap_test passed"
  else killed "$1" "hwmap_test red"; fi
}
hwmap_mutant hw_timer hardware.h 's/0xFFFFFFD0/0xFFFFFFD2/'
hwmap_mutant hw_spidata hardware.h 's/define HW_SPI_DATA 0/define HW_SPI_DATA 3/'
hwmap_mutant hw_uart hardware.h 's/(\*(volatile unsigned char \*)0xFFFFFFF0)/(*(volatile unsigned char *)0xFFFFFFF3)/'
hwmap_mutant hw_kbd c64keys.h 's/WORD1 4/WORD1 6/'
hwmap_mutant hw_akiko akiko.h 's/ADDR 0/ADDR 2/'
hwmap_mutant hw_width hardware.h 's/volatile unsigned short \*)0xFFFFFFC0/volatile unsigned int *)0xFFFFFFC0/'
hwmap_mutant puts_nl uart.c 's/++result;/++result; if (!*msg) putchar(10);/'
hwmap_mutant puts_words uart.c 's/(c=(unsigned char)\*msg++)/(c=(unsigned char)*msg++) \&\& result < 1/'

if [ $bad -eq 0 ]; then echo "=== MUTANTS PASS"; else echo "=== MUTANTS FAILED"; fi
exit $bad
