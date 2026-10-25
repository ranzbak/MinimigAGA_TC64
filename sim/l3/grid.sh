#!/bin/bash
# The L3 stress grid (plan 7.2 timing-stress mode, findings/osd-riscv/phase4.md
# "Stress grid"): many sim/l3/run.sh runs, at most MAXSIM simulations on the
# machine at once, one Verilator build per build configuration.
#
#   bash sim/l3/grid.sh <tag>            the default grid (below): runs
#                                        run_<tag>_<name>
#   bash sim/l3/grid.sh <tag> <list>     the runs of a list file instead
#   LIST=1 bash sim/l3/grid.sh <tag> [<list>]   print the run list only
#
# A list line (blank lines and "#" lines skipped):
#   <phase> <name> <scenario> [VAR=value ...]
# The VAR=value words go to run.sh's environment (shell
# words, quotes allowed: the rest of the line is eval'd), e.g. EXTRA_WS=16,
# CDCFG=iso, XARGS="+SCKDLY=0.5 +C28DLY=0.2", TIMEOUT=<cycles>,
# PATCH=<script>, FW=<image>.  Every run gets SIM=verilator and FW from
# grid.sh's environment (below) unless its line sets them.  A run of a later phase starts only when every run of the earlier
# phases has started.
#
# Builds: the first run of each build configuration (EXTRA_WS, XRAND,
# PATCH, RDY_MUT, PAULA_TXPOP) builds; the others wait for its
# buildkey_<snapshot> and run with BUILD_FROM=<its RUNTAG> (run.sh compares
# the build keys).  If the builder ends without a build, they build their
# own.
#
# Slots: a run starts only while fewer than MAXSIM (default 6) simulations
# run on the machine: every sim/l3/run.sh process of any lane (a build
# counts: it takes the CPU too) plus every other Verilator simulation (a
# Vtb* process not under sim/l3).  While Vivado runs (pgrep '[v]ivado') the
# cap is VIVADO_CAP (default 2), and this grid's simulators beyond it are
# stopped (SIGSTOP) until it ends (SIGCONT).  Checked every POLL seconds
# (default 60).
#
# Output: run.sh's output of each run in run_<RUNTAG>/run.out (in
# sim/l3/.grid_<RUNTAG>.out while it runs), and sim/l3/grid_<tag>.txt: the
# run list, then one line per run as it ends (verdict, wall time, simulated
# seconds, cycles), then the grid's wall time.  Exit 0 when every run passed.
#
# Environment: FW (a firmware image): the image every run's card gets.
# Unset, grid.sh builds it from this tree at its start, as run.sh does
# (fw/ctrl under run.sh's date shim, L3_DATE), into
# sim/l3/run_<tag>_fw/fwrv.  grid_<tag>.txt names the image, where it came
# from and its sha256.  MAXSIM, VIVADO_CAP, POLL; RUNSH (tests of grid.sh
# only: the run.sh to start, default sim/l3's).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=../common/hostsim.sh
. "$ROOT/sim/common/hostsim.sh"     # hs_fwrv, hs_fwname, hs_die
TAG=${1:-}
LISTFILE=${2:-}
[ -n "$TAG" ] || { sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 2; }
case "$TAG" in *[!a-zA-Z0-9_]*) echo "tag '$TAG': letters, digits and _ only"; exit 2 ;; esac
MAXSIM=${MAXSIM:-6} VIVADO_CAP=${VIVADO_CAP:-2} POLL=${POLL:-60}
export SIM=verilator
FWDIR="$HERE/run_${TAG}_fw"
FW_FROM="given (FW=)"
[ -n "${FW:-}" ] || { FW="$FWDIR/fwrv/$(hs_fwname)"; FW_FROM="built from the tree"; }
export FW

# The default grid (doc/osd-riscv-exec-4.md Task 19, its RV runs).
# Phase 1 is the default point (EXTRA_WS 0, SCKDLY 1.5 / C28DLY 0.3, SLAT 8,
# SJIT 0): every scenario.  Phase 2: EXTRA_WS 4, 16, 64, the five skew
# pairs, FAST_HW and SJIT 8.  Longest runs first within a phase.  TIMEOUT for
# EXTRA_WS n (SJIT 8: n = 8): run.sh's default plus n x the scenario's bus
# accesses at EXTRA_WS 0 (dread + dwrite + 8 x irefill of the merged-tree
# runs p4m2b, p4t14fr, p4t14f, p4m2h, p4m2a: boot 3.46 M, fdd_rd 24.7 M,
# fdd_wr 19.85 M, hdd 4.37 M, cdda 15.87 M), the time if every access
# waited n cycles longer: a bound, not an estimate; at most 2,147,000,000
# (run.sh's limit, tb_l3.v's 32-bit integer: fdd_rd at EXTRA_WS 64 would be
# 2,261 M).  Do not edit grid.sh while a grid runs: bash reads a script as
# it goes, and the running grid would continue at the old byte offsets.
default_list() {
	cat <<'EOF'
1 def_fdd_wr     fdd_wr
1 def_fdd_rd     fdd_rd
1 def_cdda       cdda
1 def_cdda_load  cdda_load
1 def_akiko      akiko
1 def_hdd        hdd
1 def_cd         cd
1 def_cdiso      cd        CDCFG=iso
1 def_keys       keys
1 def_boot       boot
2 ws64_fdd_rd    fdd_rd    EXTRA_WS=64 TIMEOUT=2147000000
2 ws64_fdd_wr    fdd_wr    EXTRA_WS=64 TIMEOUT=1971000000
2 ws64_cdda      cdda      EXTRA_WS=64 TIMEOUT=1536000000
2 ws16_fdd_rd    fdd_rd    EXTRA_WS=16 TIMEOUT=1076000000
2 ws16_fdd_wr    fdd_wr    EXTRA_WS=16 TIMEOUT=1018000000
2 ws4_fdd_rd     fdd_rd    EXTRA_WS=4 TIMEOUT=779000000
2 ws4_fdd_wr     fdd_wr    EXTRA_WS=4 TIMEOUT=780000000
2 ws64_hdd       hdd       EXTRA_WS=64 TIMEOUT=580000000
2 sk0502_fdd_rd  fdd_rd    XARGS="+SCKDLY=0.5 +C28DLY=0.2"
2 sk0205_fdd_rd  fdd_rd    XARGS="+SCKDLY=0.2 +C28DLY=0.5"
2 sk4003_fdd_rd  fdd_rd    XARGS="+SCKDLY=4.0 +C28DLY=0.3"
2 sk0340_fdd_rd  fdd_rd    XARGS="+SCKDLY=0.3 +C28DLY=4.0"
2 sk9503_fdd_rd  fdd_rd    XARGS="+SCKDLY=9.5 +C28DLY=0.3"
2 ws64_boot      boot      EXTRA_WS=64 TIMEOUT=459000000
2 ws16_cdda      cdda      EXTRA_WS=16 TIMEOUT=774000000
2 ws4_cdda       cdda      EXTRA_WS=4 TIMEOUT=584000000
2 sj8_cdda       cdda      SJIT=8 TIMEOUT=647000000
2 ws16_hdd       hdd       EXTRA_WS=16 TIMEOUT=370000000
2 ws4_hdd        hdd       EXTRA_WS=4 TIMEOUT=318000000
2 ws16_boot      boot      EXTRA_WS=16 TIMEOUT=293000000
2 sj8_hdd        hdd       SJIT=8 TIMEOUT=335000000
2 sk0502_hdd     hdd       XARGS="+SCKDLY=0.5 +C28DLY=0.2"
2 sk0205_hdd     hdd       XARGS="+SCKDLY=0.2 +C28DLY=0.5"
2 sk4003_hdd     hdd       XARGS="+SCKDLY=4.0 +C28DLY=0.3"
2 sk0340_hdd     hdd       XARGS="+SCKDLY=0.3 +C28DLY=4.0"
2 sk9503_hdd     hdd       XARGS="+SCKDLY=9.5 +C28DLY=0.3"
2 ws4_boot       boot      EXTRA_WS=4 TIMEOUT=252000000
2 sk0502_keys    keys      XARGS="+SCKDLY=0.5 +C28DLY=0.2"
2 sk0205_keys    keys      XARGS="+SCKDLY=0.2 +C28DLY=0.5"
2 sk4003_keys    keys      XARGS="+SCKDLY=4.0 +C28DLY=0.3"
2 sk0340_keys    keys      XARGS="+SCKDLY=0.3 +C28DLY=4.0"
2 sk9503_keys    keys      XARGS="+SCKDLY=9.5 +C28DLY=0.3"
2 fast_hdd       hdd       XARGS=+FAST_HW=1
2 fast_cd        cd        XARGS=+FAST_HW=1
2 fast_keys      keys      XARGS=+FAST_HW=1
2 fast_boot      boot      XARGS=+FAST_HW=1
EOF
}

# the list: arrays per run (index i)
PH=() NAME=() SCEN=() ENVS=() RT=() BKEY=()
n=0
while read -r ph name scen rest; do
	case "$ph" in ''|'#'*) continue ;; esac
	case "$ph" in *[!0-9]*) echo "list: phase '$ph' is not a number"; exit 2 ;; esac
	[ -n "$scen" ] || { echo "list: $name: no scenario"; exit 2; }
	envs=()
	eval "envs=($rest)" || { echo "list: $name: cannot parse '$rest'"; exit 2; }
	ws=0 xr=0 pa= rm=0 tp=0
	for e in "${envs[@]}"; do
		case "$e" in
			*=*) ;;
			*) echo "list: $name: '$e' is not VAR=value"; exit 2 ;;
		esac
		case "$e" in
			EXTRA_WS=*) ws=${e#*=} ;; XRAND=*) xr=${e#*=} ;; PATCH=*) pa=${e#*=} ;;
			RDY_MUT=*) rm=${e#*=} ;; PAULA_TXPOP=*) tp=${e#*=} ;;
			BUILD_FROM=*) echo "list: $name: BUILD_FROM is grid.sh's"; exit 2 ;;
		esac
	done
	rt="${TAG}_${name}"
	for ((j = 0; j < n; j++)); do
		[ "${RT[$j]}" = "$rt" ] && { echo "list: RUNTAG $rt twice"; exit 2; }
	done
	PH[n]=$ph NAME[n]=$name SCEN[n]=$scen ENVS[n]=$rest RT[n]=$rt
	BKEY[n]="ws$ws xr$xr patch=$pa rdymut$rm txpop$tp"
	n=$((n + 1))
done < <(if [ -n "$LISTFILE" ]; then cat "$LISTFILE"; else default_list; fi)
[ "$n" -gt 0 ] || { echo "list: no runs"; exit 2; }

OUT="$HERE/grid_$TAG.txt"
# the image: built from the tree unless given (not for LIST=1)
if [ "${LIST:-0}" != 1 ]; then
	if [ "$FW_FROM" != "given (FW=)" ]; then
		[ -e "$FWDIR" ] && { echo "$FWDIR exists: another tag, or pass FW="; exit 2; }
		mkdir -p "$FWDIR" || exit 2
		echo "building $FW from the tree"
		( run=$FWDIR; hs_fwrv "$run" ) || exit 2
	fi
	[ -f "$FW" ] || { echo "no FW ($FW)"; exit 2; }
fi
sha() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo "(not built yet)"; fi; }
{
	echo "# grid $TAG: $n runs, $(date '+%Y-%m-%d %H:%M:%S'), MAXSIM $MAXSIM"
	echo "# FW $FW, $FW_FROM, sha256 $(sha "$FW")"
	echo "# tree $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- sim rtl fw/ctrl fw/ctrl_boot || echo ' (sim/rtl/fw modified)')"
	for ((i = 0; i < n; i++)); do
		printf 'run %s phase %s %s %s\n' "${RT[$i]}" "${PH[$i]}" "${SCEN[$i]}" "${ENVS[$i]}"
	done
} > "$OUT.list"
if [ "${LIST:-0}" = 1 ]; then cat "$OUT.list"; rm -f "$OUT.list"; exit 0; fi
mv "$OUT.list" "$OUT"
cat "$OUT"

# builder of each run: the first run of its build configuration
BUILDER=()
for ((i = 0; i < n; i++)); do
	BUILDER[i]=-1
	for ((j = 0; j < i; j++)); do
		if [ "${BKEY[$j]}" = "${BKEY[$i]}" ] && [ "${BUILDER[$j]}" = -1 ]; then BUILDER[i]=$j; break; fi
	done
done

# state per run: 0 waiting, 1 running, 2 done; PID, start time
ST=() PID=() T0=()
for ((i = 0; i < n; i++)); do ST[i]=0; done
gstart=$SECONDS

snap_of() { local ws=0 e; eval "local a=(${ENVS[$1]})"; for e in "${a[@]}"; do case "$e" in EXTRA_WS=*) ws=${e#*=} ;; esac; done; echo "tb_l3_x$ws"; }

# the builder's build is there (and newer than its start), or it ended without one
build_ready() {
	local b=${BUILDER[$1]} f
	[ "$b" = -1 ] && { echo own; return; }
	f="$HERE/run_${RT[$b]}/buildkey_$(snap_of "$b")"
	if [ "${ST[$b]}" != 0 ] && [ -f "$f" ] && [ "$(stat -c %Y "$f")" -ge "${T0[$b]}" ]; then echo from; return; fi
	[ "${ST[$b]}" = 2 ] && { echo own; return; }
	echo wait
}

sims_used() {
	local a b c
	a=$(pgrep -fc 'bash .*sim/l3/run\.sh ' 2>/dev/null) || a=0
	b=$(pgrep -c '[V]tb' 2>/dev/null) || b=0
	c=$(pgrep -fc '[s]im/l3/run_[^ ]*/vl_[^ ]*/Vtb' 2>/dev/null) || c=0
	echo $((a + b - c))
}

# while Vivado runs: this grid's simulators beyond the cap (less the other
# simulators that are not stopped) stopped, the oldest kept; otherwise all
# of them continued
own_vtb() { pgrep -f "[/]run_${TAG}_[^ ]*/vl_[^ ]*/Vtb" 2>/dev/null | sort -n; }
throttle() {
	local vivado=$1 own p k=0 foreign=0 allowed
	own=" $(own_vtb | tr '\n' ' ') "
	if [ "$vivado" = 0 ]; then
		for p in $own; do kill -CONT "$p" 2>/dev/null; done
		return 0
	fi
	for p in $(pgrep '[V]tb' 2>/dev/null); do
		case "$own" in *" $p "*) continue ;; esac
		case "$(ps -o stat= -p "$p" 2>/dev/null)" in T*) ;; ?*) foreign=$((foreign + 1)) ;; esac
	done
	allowed=$((VIVADO_CAP - foreign)); [ "$allowed" -lt 0 ] && allowed=0
	for p in $own; do
		k=$((k + 1))
		if [ "$k" -le "$allowed" ]; then kill -CONT "$p" 2>/dev/null; else kill -STOP "$p" 2>/dev/null; fi
	done
}

launch() {
	local i=$1 how=$2 o="$HERE/.grid_${RT[$1]}.out"
	(
		[ -n "${ENVS[$i]}" ] && eval "export ${ENVS[$i]}"
		export RUNTAG=${RT[$i]}
		[ "$how" = from ] && export BUILD_FROM=${RT[${BUILDER[$i]}]}
		exec bash "${RUNSH:-$HERE/run.sh}" "${SCEN[$i]}"
	) > "$o" 2>&1 &
	PID[i]=$! ST[i]=1 T0[i]=$(date +%s)
	echo "$(date '+%H:%M:%S') start ${RT[$i]} ($how build)"
}

finish() {
	local i=$1 rc=$2 o="$HERE/.grid_${RT[$1]}.out" d="$HERE/run_${RT[$1]}" v w sim cyc
	ST[i]=2
	w=$(( $(date +%s) - T0[i] ))
	if [ -d "$d" ]; then mv "$o" "$d/run.out"; o="$d/run.out"; fi
	v=$(grep -E "^=== ${SCEN[$i]} (PASS|FAILED)" "$o" | tail -1)
	[ "$rc" = 0 ] && [ -n "$v" ] || v="${v:-no verdict} (exit $rc)"
	sim=$(sed -n 's/^verilator wall time \([0-9]*\) s, .*/\1/p' "$o" | tail -1)
	cyc=$(sed -n 's/^verilator wall time [0-9]* s, \([0-9]*\) cycles/\1/p' "$o" | tail -1)
	printf '%s %-34s %-22s wall %6d s, sim %6s s, %s cycles\n' "$(date '+%H:%M:%S')" "${RT[$i]}" "$v" "$w" "${sim:--}" "${cyc:--}" \
		| tee -a "$OUT"
}

while :; do
	# reap
	left=0
	for ((i = 0; i < n; i++)); do
		if [ "${ST[$i]}" = 1 ] && ! kill -0 "${PID[$i]}" 2>/dev/null; then
			wait "${PID[$i]}"; finish "$i" "$?"
		fi
		[ "${ST[$i]}" != 2 ] && left=$((left + 1))
	done
	[ "$left" = 0 ] && break
	cap=$MAXSIM viv=0
	if pgrep '[v]ivado' > /dev/null 2>&1; then cap=$VIVADO_CAP viv=1; fi
	throttle "$viv"
	# the earliest phase with a run not yet started
	minph=
	for ((i = 0; i < n; i++)); do
		[ "${ST[$i]}" = 0 ] && { [ -z "$minph" ] || [ "${PH[$i]}" -lt "$minph" ]; } && minph=${PH[$i]}
	done
	if [ -n "$minph" ]; then
		for ((i = 0; i < n; i++)); do
			[ "${ST[$i]}" = 0 ] && [ "${PH[$i]}" = "$minph" ] || continue
			[ "$(sims_used)" -lt "$cap" ] || break
			how=$(build_ready "$i")
			[ "$how" = wait ] && continue
			launch "$i" "$how"
			sleep 2
		done
	fi
	sleep "$POLL"
done
npass=$(grep -cE " === [a-z_]+ PASS " "$OUT")
echo "# grid $TAG done: $npass of $n PASS, wall $((SECONDS - gstart)) s ($(date '+%Y-%m-%d %H:%M:%S'))" | tee -a "$OUT"
[ "$npass" = "$n" ]
