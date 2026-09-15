#!/usr/bin/env bash
# One Markdown row of the Stage E complexity budget
# (findings/ap68040/stage-e/2026-09-15-stage-e-design.md §3, decision 3).
#
#   tools/complexity_report.sh <label>      (run from any directory in a checkout)
#
# Columns: label | wrapper lines | wrapper code lines | cpu_cache_new code lines |
#          sdram_ctrl code lines | posted-write paths | longword_pair uses |
#          g_tg68k uses | gate/data switch uses | debug probes
# "Code lines" exclude blank lines and full-line comments (-- or //).
set -e
cd "$(dirname "$0")/.."
code() { grep -vcE '^\s*(--|//|$)' "$1"; }
W=rtl/soc/TG68K.vhd
posted=1                                                        # ap040_cache POST_STORES
grep -q 'CPU_SM_WSYNC' rtl/sdram/cpu_cache_new.v && posted="$posted+wsync-option"
lw=$(grep -c 'longword_pair' $W || true)
tg=$(grep -c 'g_tg68k' $W || true)
sw=$(grep -cE 'cpu_phase_gate_en|cpu_data_reg_en|cpu_phase_gate_req|cpu_phase_gate_dly' $W || true)
dbg=$(grep -oE 'dbg_(snoop|phist|rtg)' $W | sort -u | tr '\n' ' ')
printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "${1:-now}" \
  "$(wc -l < $W)" "$(code $W)" "$(code rtl/sdram/cpu_cache_new.v)" "$(code rtl/sdram/sdram_ctrl.v)" \
  "$posted" "$lw" "$tg" "$sw" "$dbg"
