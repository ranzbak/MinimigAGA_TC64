#!/usr/bin/env bash
# Regenerate VexOsd.v, VexOsd_DMT.v and VexOsd_DMJ.v from GenOsd.scala at the
# pinned VexRiscv commit, then run the gate checks.
#
#   bash rtl/host/vexriscv/regen.sh            # regenerate + check
#   bash rtl/host/vexriscv/regen.sh --check    # check the committed files only
#
# Environment:
#   VEX_SRC   VexRiscv clone (default $HOME/opt/vexriscv-src; cloned if missing)
#   JAVA17    JDK 17 home     (default /usr/lib/jvm/java-17-openjdk-amd64)
#   IVERILOG  iverilog binary (default: iverilog on PATH)
#
# See README.md in this directory.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIN=baf7dc82f855eddaf5b0a20a6802c526f127e38a
REPO=https://github.com/SpinalHDL/VexRiscv
VEX_SRC=${VEX_SRC:-$HOME/opt/vexriscv-src}
JAVA17=${JAVA17:-/usr/lib/jvm/java-17-openjdk-amd64}
IVERILOG=${IVERILOG:-iverilog}
SCALA_REL=src/main/scala/vexriscv/demo/GenOsd.scala
OUTS=(VexOsd VexOsd_DMT VexOsd_DMJ)

die() { echo "regen.sh: $*" >&2; exit 1; }

# Port names of the module header of a generated file, one per line.
ports() {
  awk '/^module /{m=1; next} m && /^\);/{exit}
       m && /^[[:space:]]*(input|output|inout)[[:space:]]/{
         n=$NF; sub(/,$/, "", n); print n }' "$1"
}

# ---------------------------------------------------------------- gate checks
check() {
  local fail=0 f m p
  err() { echo "FAIL: $*" >&2; fail=1; }
  command -v "$IVERILOG" >/dev/null || die "iverilog not found (set IVERILOG=)"

  local common=(clk reset timerInterrupt externalInterrupt softwareInterrupt
    iBus_cmd_valid iBus_cmd_ready iBus_cmd_payload_address iBus_cmd_payload_size
    iBus_rsp_valid iBus_rsp_payload_data iBus_rsp_payload_error
    dBus_cmd_valid dBus_cmd_ready dBus_cmd_payload_wr dBus_cmd_payload_mask
    dBus_cmd_payload_address dBus_cmd_payload_data dBus_cmd_payload_size
    dBus_rsp_ready dBus_rsp_error dBus_rsp_data)
  local jtag_ins=(jtagInstruction_tdi jtagInstruction_enable jtagInstruction_capture
    jtagInstruction_shift jtagInstruction_update jtagInstruction_reset
    jtagInstruction_tdo)
  local tap=(jtag_tck jtag_tms jtag_tdi jtag_tdo)

  for m in "${OUTS[@]}"; do
    f=$HERE/$m.v
    if [[ ! -f $f ]]; then err "$m.v missing"; continue; fi

    # (a) parses
    "$IVERILOG" -g2012 -o /dev/null "$f" || err "$m.v: iverilog -g2012 does not parse it"
    grep -q "^module $m (" "$f" || err "$m.v: no 'module $m ('"

    # (b) no vendor primitives (prefix match: RAMB36E1, BUFGCE, altera_mf...).
    # Synthesis attributes (* ... *) are stripped first: the debug variants
    # carry async_reg / altera_attribute / ram_style hints, which are not
    # primitives and which other tools ignore.
    if sed -E 's/\(\*[^*]*\*\)//g' "$f" | grep -n -E \
        '\b(BSCANE2|BUFG\w*|RAMB\w*|DSP48\w*|IBUF\w*|OBUF\w*|altsyncram|altera_\w*)\b'; then
      err "$m.v: vendor primitive found (lines above)"
    fi

    # RAM init files referenced by the Verilog must sit next to it
    while read -r p; do
      [[ -f $HERE/$p ]] || err "$m.v: \$readmem file $p missing"
    done < <(grep -o -E '\$readmem[bh]\("[^"]+"' "$f" | sed -E 's/.*\("//; s/"$//')

    # (c)+(d) ports
    local have; have=$(ports "$f")
    has() { grep -qx "$1" <<<"$have"; }
    for p in "${common[@]}"; do has "$p" || err "$m.v: port $p missing"; done
    case $m in
      VexOsd)
        if grep -E '^(jtag|debugReset$|ndmreset$)' <<<"$have"; then
          err "$m.v: has debug ports (above)"
        fi ;;
      VexOsd_DMT)
        for p in "${jtag_ins[@]}" jtag_tck debugReset ndmreset; do
          has "$p" || err "$m.v: port $p missing"; done
        for p in jtag_tms jtag_tdi jtag_tdo; do
          has "$p" && err "$m.v: unexpected TAP port $p"; done ;;
      VexOsd_DMJ)
        for p in "${tap[@]}" debugReset ndmreset; do
          has "$p" || err "$m.v: port $p missing"; done
        if grep -E '^jtagInstruction_' <<<"$have"; then
          err "$m.v: unexpected jtagInstruction ports (above)"
        fi ;;
    esac
  done
  # (e) the three files can sit in one source list: every module in X.v is
  # named X or X_* (privateNamespace), and iverilog takes all three at once.
  local all=()
  for m in "${OUTS[@]}"; do
    f=$HERE/$m.v; [[ -f $f ]] || continue; all+=("$f")
    if grep -E '^module ' "$f" | awk '{print $2}' | grep -v -x -E "${m}(_.*)?"; then
      err "$m.v: module names above are not in the ${m}_ namespace"
    fi
  done
  if (( ${#all[@]} == ${#OUTS[@]} )); then
    "$IVERILOG" -g2012 -o /dev/null "${all[@]}" ||
      err "the three files do not compile together (duplicate modules?)"
  fi

  # (f) VERSION matches: the pin of this script and the hash of each output
  # (regeneration rewrites the hashes; a hand-edited .v fails here).
  local v=$HERE/VERSION
  if [[ ! -f $v ]]; then err "VERSION missing"; else
    grep -qx "vexriscv_commit=$PIN" "$v" || err "VERSION: vexriscv_commit is not $PIN"
    for m in "${OUTS[@]}"; do
      [[ -f $HERE/$m.v ]] || continue
      grep -qx "sha256_$m.v=$(sha256sum < "$HERE/$m.v" | cut -d' ' -f1)" "$v" ||
        err "VERSION: sha256_$m.v does not match $m.v (run regen.sh, commit both)"
    done
  fi

  if (( fail )); then echo "regen.sh --check: FAILED" >&2; return 1; fi
  for m in "${OUTS[@]}"; do sha256sum "$HERE/$m.v"; done
  echo "regen.sh --check: PASS"
}

if [[ ${1:-} == --check ]]; then check; exit $?; fi
[[ $# -eq 0 ]] || die "usage: regen.sh [--check]"

# ---------------------------------------------------------------- regenerate
command -v sbt >/dev/null || die "sbt not found (see README.md)"
[[ -x $JAVA17/bin/java ]] || die "JDK 17 not at $JAVA17 (apt install openjdk-17-jdk-headless, or set JAVA17=)"

if [[ ! -d $VEX_SRC/.git ]]; then
  mkdir -p "$(dirname "$VEX_SRC")"
  git clone "$REPO" "$VEX_SRC"
fi
git -C "$VEX_SRC" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$VEX_SRC" fetch origin
git -C "$VEX_SRC" cat-file -e "$PIN^{commit}" 2>/dev/null || die "commit $PIN not in $VEX_SRC"

# Refuse a dirty tree: only our copied Scala file and our output dir may differ.
dirty=$(git -C "$VEX_SRC" status --porcelain --untracked-files=all |
  grep -v -E "^(\?\?| M) ($SCALA_REL|gen_osd/.*)\$" || true)
[[ -z $dirty ]] || die "$VEX_SRC is dirty:
$dirty"

git -C "$VEX_SRC" -c advice.detachedHead=false checkout --detach "$PIN"
cp "$HERE/GenOsd.scala" "$VEX_SRC/$SCALA_REL"
rm -rf "$VEX_SRC/gen_osd"

(cd "$VEX_SRC" && sbt -java-home "$JAVA17" -batch "runMain vexriscv.demo.GenOsd")

for m in "${OUTS[@]}"; do
  [[ -f $VEX_SRC/gen_osd/$m.v ]] || die "sbt did not produce gen_osd/$m.v"
  cp "$VEX_SRC/gen_osd/$m.v" "$HERE/$m.v"
done
# RAM init files: copied only if the Verilog loads them ($readmem).
for b in "$VEX_SRC"/gen_osd/*.bin; do
  [[ -e $b ]] || continue
  if grep -q -F "$(basename "$b")" "$HERE"/VexOsd*.v; then
    cp "$b" "$HERE/"
  else
    echo "regen.sh: ignoring unreferenced $(basename "$b")"
  fi
done

for m in "${OUTS[@]}"; do
  sed -i -E "s/^sha256_$m\.v=.*/sha256_$m.v=$(sha256sum < "$HERE/$m.v" | cut -d' ' -f1)/" "$HERE/VERSION"
done

check   # prints the sha256 of each output
