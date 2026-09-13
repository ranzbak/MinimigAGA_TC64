#!/usr/bin/env bash
# Run a long job (simulation, synthesis) so that it CANNOT be silently missed.
#
# Three rules, each fixing a way jobs were lost during 2026-09-08..13:
#   1. always exit 0, and print a self-contained verdict -- a waiter ending in
#      `grep -c` exits 1 on zero matches, which reported clean builds as failed
#   2. write the raw log to a file and grep the FILE, never pipe through
#      tee/grep (buffering left notification output empty)
#   3. append to a LEDGER, so outstanding jobs can be reconciled at any time
#      even after the conversation has moved on -- which is how a nine-leg
#      regression sat half-finished for a day
#
#   tools/jobs/job.sh <name> <logfile> <done-pattern> -- <command...>
#   tools/jobs/job.sh status          # what is outstanding
set -u
LEDGER="${JOB_LEDGER:-/tmp/claude-1000/joblog.tsv}"
mkdir -p "$(dirname "$LEDGER")"; touch "$LEDGER"

if [ "${1:-}" = "status" ]; then
    printf '%-28s %-9s %s\n' NAME STATE LOG
    while IFS=$'\t' read -r name state log verdict; do
        printf '%-28s %-9s %s\n' "$name" "$state" "${verdict:-$log}"
    done < "$LEDGER"
    exit 0
fi

NAME=$1; LOG=$2; DONE_PAT=$3; shift 4   # the 4th is the literal --
printf '%s\t%s\t%s\t\n' "$NAME" RUNNING "$LOG" >> "$LEDGER"

( "$@" > "$LOG" 2>&1
  if grep -qE "$DONE_PAT" "$LOG"; then V="completed"; else V="ENDED WITHOUT THE DONE MARKER"; fi
  ERRS=$(grep -cE '^ERROR|FAIL|failed' "$LOG" || true)
  V="$V, ${ERRS} error/fail lines"
  tmp=$(mktemp); awk -F'\t' -v n="$NAME" -v v="$V" 'BEGIN{OFS="\t"}
      $1==n && $2=="RUNNING" {$2="DONE"; $4=v} {print}' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
  echo "=== JOB $NAME $V ==="
) &
echo "job '$NAME' started -> $LOG  (tools/jobs/job.sh status to reconcile)"
exit 0
