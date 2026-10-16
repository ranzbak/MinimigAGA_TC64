#!/bin/bash
# Check the RISC-V toolchain selected by RV_GCC_DIR / RV_PREFIX (defaults from
# toolchain.mk).  Exit 0 = all checks OK.
here=$(cd "$(dirname "$0")" && pwd)
q() { make -s -f - <<MK
include $here/toolchain.mk
p: ; @echo \$($1)
MK
}
CC=$(q RV_CC); OBJDUMP=$(q RV_OBJDUMP)
ARCH=$(q RV_ARCH); ARCH_IM=$(q RV_ARCH_IM)
fail=0
ok()  { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }
echo "using $CC"
"$CC" --version | head -1

# 1. multilib selection
m=$($CC $ARCH -print-multi-directory 2>&1)
[ "$m" = rv32imc/ilp32 ] && ok "1a RV_ARCH -> $m" || bad "1a RV_ARCH -> '$m' (want rv32imc/ilp32)"
m=$($CC $ARCH_IM -print-multi-directory 2>&1)
[ "$m" = rv32im/ilp32 ] && ok "1b RV_ARCH_IM -> $m" || bad "1b RV_ARCH_IM -> '$m' (want rv32im/ilp32)"

# 2. rv32im libgcc: no compressed, no atomics
lib=$($CC $ARCH_IM -print-libgcc-file-name 2>&1)
if [ -f "$lib" ]; then
  dis=$("$OBJDUMP" -d "$lib" 2>&1)
  n=$(printf '%s\n' "$dis" | grep -cE '^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]{4}[[:space:]]')
  [ "$n" -eq 0 ] && ok "2a libgcc has no 16-bit insns ($lib)" || bad "2a libgcc has $n 16-bit insns ($lib)"
  n=$(printf '%s\n' "$dis" | grep -cE '[[:space:]](lr\.w|sc\.w|amo[a-z]+\.w)')
  [ "$n" -eq 0 ] && ok "2b libgcc has no lr/sc/amo" || bad "2b libgcc has $n atomic insns"
else
  bad "2 libgcc not found: $lib"
fi

# 3. inline asm compiles and links for both arch strings
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/t.c" <<'C'
static inline unsigned rdcycle(void) { unsigned v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
unsigned f(unsigned a, unsigned b) { return a / (b | 1); }
void _start(void)
{
    volatile unsigned *p = (volatile unsigned *)0x2000;
    *p = rdcycle() + f(*p, 3);
    __asm__ volatile("fence.i");
    for (;;) ;
}
C
for a in "$ARCH" "$ARCH_IM"; do
  if $CC $a -Os -ffreestanding -nostdlib -o "$t/t.elf" "$t/t.c" -lgcc >"$t/log" 2>&1; then
    ok "3 compile+link $a"
  else
    bad "3 compile+link $a"; sed 's/^/     /' "$t/log"
  fi
done
exit $fail
