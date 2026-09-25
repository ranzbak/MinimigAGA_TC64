#!/usr/bin/env bash
# Generate a 68040 cputest corpus with the Linux cputestgen.
#
#   ./gen_corpus.sh [GROUPS] [MODE] [OUTROOT]
#     GROUPS   comma list of the ini's 68020-68060 group names to enable
#              (BASIC, IRQ, EXTSRC, EXTDST, AE, ODDSTK, ODDEXC, ODDIRQ,
#               FBASIC, FINT, FPACK, ...) and/or Default.  Default: BASIC
#     MODE     optional mnemonic list overriding the groups' "mode="
#              (e.g. "move,add,cmp,bcc"); default: keep the ini's mode
#     OUTROOT  directory that receives data040/ and the ini used;
#              default: .. (tests/cputest/)
#
# The ini is the stock cputest/cputestgen.ini of the revision build.sh built (cpu=68040) with four
# edits, all recorded in OUTROOT/cputestgen_used.ini:
#   path=data040/                       output directory
#   test_low_memory_start/end=0/0x8000  so the group gets an lmem.dat, which
#                                       apolkosnik's run_cputest.py requires
#   feature_condition_codes= commented  the stock EMPTY value parses as "no
#                                       condition codes" (not "all"), which
#                                       silently drops every Bcc/DBcc/Scc/TRAPcc
#   enabled=1 (+ mode=) on the requested groups
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GROUPS_="${1:-BASIC}"
MODE="${2:-}"
OUT="$(cd "${3:-$HERE/..}" && pwd)"
GEN="$HERE/cputestgen"
[ -x "$GEN" ] || { echo "build first: $HERE/build.sh" >&2; exit 1; }

python3 - "$HERE/build/src/cputest/cputestgen.ini" "$OUT/cputestgen.ini" "$GROUPS_" "$MODE" <<'EOF'
import re, sys
src, dst, groups, mode = sys.argv[1:5]
want = {g.strip().upper() for g in groups.split(',') if g.strip()}
s = open(src, newline='').read().replace('\r\n', '\n')
parts = re.split(r'(?m)^(?=\[)', s)
out, seen = [], set()
for p in parts:
    m = re.match(r'\[(test=)?([^\]|]*)', p)
    if p.startswith('[cputest]'):
        p = re.sub(r'(?m)^path=.*$', 'path=data040/', p)
        p = re.sub(r'(?m)^;test_low_memory_start=.*$', 'test_low_memory_start=0x0000', p)
        p = re.sub(r'(?m)^;test_low_memory_end=.*$', 'test_low_memory_end=0x8000', p)
        p = re.sub(r'(?m)^feature_condition_codes=$', ';feature_condition_codes=', p)
    elif m and m.group(1):
        name = m.group(2).upper()
        cpu = re.search(r'(?m)^cpu=(.*)$', p)
        applies = cpu is None or '68040' in cpu.group(1) or '68060' in cpu.group(1)
        if applies:
            if name in want:
                p = re.sub(r'(?m)^enabled=.*$', 'enabled=1', p)
                if mode:
                    p = re.sub(r'(?m)^mode=.*$', '', p)
                    p = p.rstrip('\n') + '\nmode=' + mode + '\n\n'
                seen.add(name)
            else:
                p = re.sub(r'(?m)^enabled=.*$', 'enabled=0', p)
    out.append(p)
missing = want - seen
if missing:
    sys.exit('unknown 68040 group(s): ' + ','.join(sorted(missing)))
open(dst, 'w').write(''.join(out))
EOF

cd "$OUT"
mkdir -p data040
echo "== cputestgen in $OUT, groups=$GROUPS_ mode=${MODE:-<ini>}"
start=$(date +%s)
cp cputestgen.ini cputestgen_used.ini
rc=0
"$GEN" > cputestgen.log 2>&1 || rc=$?
rm -f cputestgen.ini
[ "$rc" = 0 ] || echo "!! cputestgen exited with status $rc (see cputestgen.log)" >&2
echo "== done in $(( $(date +%s) - start ))s; log: $OUT/cputestgen.log"
grep -E "total tests generated" cputestgen.log || true
du -sh data040/* 2>/dev/null || true
