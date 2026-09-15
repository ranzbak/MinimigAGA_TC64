#!/usr/bin/env bash
# One Markdown row of the Stage E complexity budget
# (findings/ap68040/stage-e/2026-09-15-stage-e-design.md §3, decision 3).
#
#   tools/complexity_report.sh <label>      (run from any directory in a checkout)
#
# Columns: label | wrapper lines | wrapper code lines | cpu_cache_new code lines |
#          sdram_ctrl code lines | posted-write paths | longword_pair uses |
#          g_tg68k uses | gate/data switch uses | debug probes |
#          RAM width conversions | handshake signals
# "Code lines" exclude blank lines and full-line comments (-- or //).
#
# Posted-write paths: the 040's POST_STORES, plus cpu_cache_new's write buffer
# unless it is synchronous (CPU_WRITE_SYNC, Stage E2 Task 5).  The buffer
# acknowledges a write before the SDRAM write is issued, so it is a posted path
# too; E4a's rows printed 1 and undercounted it.
# RAM width conversions: "32-16-32" while sdram_ctrl still has the 16-bit CPU
# port the bus16 adapter feeds, 0 once it takes the unit port (Stage E2).
# Handshake signals: how many of the spec §2 CPU<->memory enable/handshake
# signals are still in the wrapper (clkena itself, the core's enable, is not
# counted).
set -e
cd "$(dirname "$0")/.."
code() { grep -vcE '^\s*(--|//|$)' "$1"; }
W=rtl/soc/TG68K.vhd
posted=1                                                        # ap040_cache POST_STORES
grep -q 'CPU_WRITE_SYNC' rtl/sdram/cpu_cache_new.v || posted=2  # + cpu_cache_new write buffer
lw=$(grep -c 'longword_pair' $W || true)
tg=$(grep -c 'g_tg68k' $W || true)
sw=$(grep -cE 'cpu_phase_gate_en|cpu_data_reg_en|cpu_phase_gate_req|cpu_phase_gate_dly' $W || true)
dbg=$(grep -oE 'dbg_(snoop|phist|rtg)' $W | sort -u | tr '\n' ' ')
if grep -qE 'input +wire +\[ *16-1:0\] +cpuWR' rtl/sdram/sdram_ctrl.v; then conv='32-16-32'; else conv=0; fi
hs=$(grep -oE '\b(clkena_r|slower|bus_step|bus_fresh|cpu_phase_ok|datatg68_r|mem_ready|cpu_bus_settled)\b' $W | sort -u | wc -l)
printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "${1:-now}" \
  "$(wc -l < $W)" "$(code $W)" "$(code rtl/sdram/cpu_cache_new.v)" "$(code rtl/sdram/sdram_ctrl.v)" \
  "$posted" "$lw" "$tg" "$sw" "$dbg" "$conv" "$hs"
