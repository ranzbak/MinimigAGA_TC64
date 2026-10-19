#!/bin/sh
# The `date` of the L3 832 firmware build (sim/l3/fw832/Makefile installs it
# as <B>/dateshim/date, first on PATH): every call prints the time
# L3_DATE 00:00:00 UTC (default 2026-01-01) in the caller's format, so the
# version strings fw/ctrl_832/Makefile writes into version.h, and with them
# 832OSDAD.BIN, are the same in every build.
TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"
