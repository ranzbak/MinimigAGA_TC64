#!/bin/bash
# L3 bench: the host CPU (bridge, cfide) with the real Minimig SPI slaves
# (userio_osd, paula_floppy, gayle) boots the real boot ROM and firmware from
# an SD card image.  See tb_l3.v, scenarios.vh, README.md.
#
#   bash sim/l3/run.sh <scenario>        boot, boot_short, keys, fdd_rd, fdd_wr, hdd,
#                                        cd, cdda, cdda_load, akiko
#   bash sim/l3/run.sh xpair <scenario>  the scenario and its XRAND twin
#                                        (run_$RUNTAG, run_${RUNTAG}_xr; in
#                                        parallel), then compare: both PASS
#                                        and SAME
#   bash sim/l3/run.sh compare <RUNTAG a> <RUNTAG b>
#                                        every tb_*.log and spi.txt of both
#                                        run directories (sim/common/hostsim.sh
#                                        hs_compare; exit 1 unless all SAME)
#   bash sim/l3/run.sh diff [--unused-rules] <RUNTAG rv> <RUNTAG 832>
#                                        the differential (README
#                                        "Differential"): each run's spi.txt,
#                                        hw.txt and uart.txt normalised with
#                                        expected_diff.txt (spitrace.py norm,
#                                        <run>/norm.txt), then spitrace.py diff:
#                                        exit 0 only when empty; with
#                                        --unused-rules also the rules neither
#                                        run used (exit 1 when there is one)
#
# Environment:
#   CPU      rv (default: rv_hostcpu, fw/ctrl_boot_rv, RV32OSDA.BIN) or 832
#            (the EightThirtyTwo, fw/ctrl_boot_832, 832OSDAD.BIN): the same
#            scenarios and checks; the logs say "=== CPU <cpu>"
#   E832     CPU=832: the EightThirtyTwo VHDL (default $ROOT/EightThirtyTwo/RTL)
#   E832DIR  CPU=832: the EightThirtyTwo checkout whose tools build
#            832OSDAD.BIN (sim/l3/fw832; default $ROOT/EightThirtyTwo).  The
#            submodule of a worktree is not initialised: set both to the
#            main checkout's
#   SIM      xsim (default, 4-state, the X-checking reference) or verilator
#            (GHDL --synth converts the VHDL, as sim/host_bridge)
#   RUNTAG   run directory sim/l3/run_${RUNTAG:-wt}; a new one per code change
#   FW       an RV32OSDA.BIN to put on the card; default: built from
#            fw/ctrl_rv into <run>/fwrv under a date shim (hs_fwrv, L3_DATE)
#   FW832    an 832OSDAD.BIN to put on the card; default with CPU=832:
#            built from a copy of fw/ctrl_832 into <run>/fw832 (sim/l3/fw832,
#            the same L3_DATE); with CPU=rv: the card's stand-in
#   L3_DATE  the date of both firmware builds (default 2026-01-01)
#   EXTRA_WS the bridge's rv_extra_ws (0; CPU=rv only)
#   SLAT, SJIT, SEED   the SDRAM model (8, 0, 1)
#   XARGS    extra plusargs ("+FAST_HW=1 +OSD_EARLY_OK=1 +TICKDIV=643 ...");
#            +FAST_HW=1 also puts the models' fast plusargs first (below)
#   CDCFG    cd: the disc in the drive, cue (default: TEST.CUE + TEST.BIN)
#            or iso (TEST.ISO); the card's configs name it (sim/l3/card).
#            cdda and cdda_load play TEST.CUE's track 2: cue only
#   KEYS     keys, fdd_rd, fdd_wr: the key script (default keys:
#            sim/l3/keys/menu_tour.txt; l3check.py keys checks the pages
#            against osdtext_expect/keys.txt, which is that script's;
#            fdd_rd and fdd_wr: sim/l3/keys/insert_df0.txt)
#   NOKICK=1 boot only: the boot card without KICK.ROM.  The run must FAIL
#            at the main-loop milestone (the fatal-error loop); the exit
#            status is 0 when it does
#   RDY_MUT=1 the run copy of cfide answers OSD_RDY = 1 (the handshake's
#            tooth, README "keys"); the run must FAIL with OSD EARLY > 0
#   PAULA_TXPOP=1 the run copy of paula_floppy.v pops the write FIFO when a
#            word starts going out (tx_flag, tx_cnt 3, as Gayle's hdd_data_rd)
#            instead of after it came in (spidat): the evidence fix of the
#            write-FIFO finding (README "fdd_wr", findings/osd-riscv/phase4.md
#            Task 14); rtl/ is never edited
#   XRAND=1  (verilator) the X-sensitivity build, XSEED=<n> its seed
#   PATCH=<script>  teeth only: "bash <script> <run>/src <repository root>"
#            runs on the run copies of the RTL (rtl/host's and the Minimig
#            slaves', before the timescale lines and the pins), e.g. one
#            reverted file or a mutant line (sim/l3/teeth); rtl/ is never
#            edited; results.txt names the script
#   BUILD_FROM=<RUNTAG>  (verilator) the simulator of run_<RUNTAG> instead
#            of a build of its own, when that run's build key (a sha256 of
#            every build input: the run copies in src/, the bench, the
#            include files, the ROM, the tools' versions, CPU, EXTRA_WS,
#            XRAND; <run>/buildkey_<snapshot>, written by every Verilator
#            build) equals this run's; else it builds its own (results.txt
#            says so).  Plusargs (the
#            scenario, the card, skew, FAST_HW, SLAT, SJIT) are not build
#            inputs (sim/l3/grid.sh)
#   TIMEOUT  clk_114 cycles (default per scenario below), at most
#            2147483647 (tb_l3.v's integer)
#   L3CHECK  tests of run.sh only: the l3check.py to run (default sim/l3's)
#   VIVADO_PATH, GHDL, VERILATOR, JOBS, OBJCACHE as sim/host_bridge/run.sh
#
# Scenarios (scenarios.vh), card, checks:
#   boot        boot card (sim/l3/card), +SCENARIO=boot +SD_LOG=1, TICKDIV 1;
#               checks: milestones_boot.txt (spitrace.py check: UART lines and
#               SPI frames in order; "NOT UART <text>" lines here: no UART
#               line contains <text>), no EXC / TRAP on the UART, l3check.py
#               kick (the uploaded kickstart = KICK.ROM, from the SDRAM
#               dump), order (plan 7.1 item 14: the last kickstart write
#               before the CPU release) and mmc (MMC_Init's card commands =
#               gold/mmc_init_rv.txt), every "=== MARGIN" line of MARGINS
#               below present and none LOW, bench "=== PASS" (no bench
#               error: OSD GAP >= 40, OSD EARLY 0, no X, no stale ack, no
#               MARGIN LOW)
#   boot_short  boot cut at its end event (scenarios.vh); milestones_boot.txt
#               up to the line "#@ boot_short end"; the MARGIN lines; no
#               kick, order or mmc check
#   keys        boot card, +SCENARIO=keys +KEYS=sim/l3/keys/menu_tour.txt,
#               TICKDIV 643 from the script's start (+TICKDIV_AT=scenario):
#               the OSD key script (bfm_keys.v) after the main-loop
#               milestone; checks: boot's milestones, no EXC / TRAP, kick,
#               order, the MARGIN lines, l3check.py keys (the KEYQ replies =
#               the events the script made, the OSD pages =
#               osdtext_expect/keys.txt), bench "=== PASS"
#   fdd_rd      fdd card (boot + TEST.ADF + DRIVESND.BIN), +SCENARIO=fdd_rd
#               +KEYS=sim/l3/keys/insert_df0.txt +FDD_DUMP=<run>/fdd_rd,
#               TICKDIV 643 from the script's start (+TICKDIV_AT=scenario):
#               the key script (drive sounds on, TEST.ADF into df0), then
#               bfm_floppy's 10 track reads; checks: boot's milestones, no
#               EXC / TRAP, kick, order, the MARGIN lines (item 6 required),
#               l3check.py fdd_rd (the dumps decode and equal TEST.ADF, the
#               golden streams, the OSD), bench "=== PASS"
#   fdd_wr      fdd card, +SCENARIO=fdd_wr, the key script of fdd_rd,
#               +FDD_WFILE=<run>/fdd_wr (the write streams, made here by
#               sim/l3/gen/mkwrtrack.py from the card's TEST.ADF for the
#               tracks of FDD_WR_PLAN below), +SD_SAVE=<run>/card_saved.img,
#               TICKDIV as fdd_rd: the key script, then bfm_floppy's 10 track
#               writes, the last with a bad header checksum in sector 3;
#               checks: boot's milestones, no EXC / TRAP, kick, order, the
#               MARGIN lines (item 7 required), l3check.py fdd_wr (TEST.ADF
#               from the saved card = the original with the written
#               sectors' new data; the bad-header sector's fate and the error
#               page recorded; the OSD), bench "=== PASS"
#   hdd         hdd card (boot + SYNTH.HDF + RDB.HDF), +SCENARIO=hdd
#               +IDE_DUMP=<run>/hdd +SD_SAVE=<run>/card_saved.img, TICKDIV 1:
#               bfm_ide's ATA commands from the main-loop milestone on;
#               checks: boot's milestones (the hdd card's lines), no EXC /
#               TRAP, kick, order, the MARGIN lines (item 3 required: the
#               firmware reads the HDFs in direct mode), l3check.py hdd (the
#               reads = the HDFs and the goldens, the writes on the saved
#               card and nowhere else), bench "=== PASS"
#   cd          cd card (boot + TEST.CUE / TEST.BIN + TEST.ISO, the configs'
#               CD drive on IDE port 2 holding TEST.CUE or, CDCFG=iso,
#               TEST.ISO), +SCENARIO=cd +CDCFG=<cfg> +IDE_DUMP=<run>/cd,
#               TICKDIV 643 from the scenario's start (+TICKDIV_AT=scenario):
#               bfm_ide's ATAPI commands from the main-loop milestone on;
#               checks: boot's milestones (the cd card's lines, per CDCFG),
#               no EXC / TRAP, kick, order, the MARGIN lines (item 9
#               required, item 3 too for iso: its sectors come in direct
#               mode), l3check.py cd (every answer = what atapi.c / cdrom.c
#               build for the disc, the sectors = TEST.ISO / TEST.BIN's data
#               track, the TOC = TEST.CUE), bench "=== PASS"
#   cdda        cd card with CDCFG=cue, +SCENARIO=cdda +IDE_DUMP=<run>/cdda
#               +CDDA_DUMP=<run>/cdda_half, TICKDIV 643 from the scenario's
#               start: bfm_ide's PLAY AUDIO MSF / PAUSE / READ SUB-CHANNEL /
#               RESUME / STOP on IDE port 2, bfm_audio's copy of every half
#               the player starts, mon_l3.vh's refill timing; checks: boot's
#               milestones (cd_cue's lines), no EXC / TRAP, kick, order, the
#               MARGIN lines (item 9 required), l3check.py cdda (every half =
#               TEST.BIN at the firmware's position, no underrun, READ
#               SUB-CHANNEL), bench "=== PASS"
#   cdda_load   cdhdd card (boot + SYNTH.HDF + RDB.HDF + TEST.CUE / TEST.BIN),
#               +SCENARIO=cdda_load, the same plusargs: cdda plus a READ
#               MULTIPLE of 256 SYNTH.HDF sectors from the player's second
#               flip; checks as cdda (item 3 required too: the HDF sectors
#               come in direct mode; the cdhdd card's milestones), l3check.py
#               cdda counts the underruns and checks the HDF sectors
#   akiko       fdd card, +SCENARIO=akiko +KEYS=sim/l3/keys/insert_df0.txt
#               +FDD_DUMP=<run>/akiko, TICKDIV 643 from the scenario start:
#               bfm_akiko block 0 (32 write + 32 read requests on cfide's
#               amiga_* window) in the idle main loop, the key script, two
#               track reads and block 1 from the first track DMA's start;
#               checks as fdd_rd's (milestones, kick, order, MARGIN lines with
#               item 6 required) and l3check.py akiko (every request's UART
#               line = the pattern, every read 0, every request acked once,
#               the DATA writes in hw.txt, the latency table, the track read)
# Logs in the run directory: tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log,
# spi.txt, spi_t.txt (frames with cycles, not compared), hw.txt and uart.txt
# (sim/common/hostmon.vh +HW_LOG / +UART_LOG, for diff; hw.txt's MEM lines
# hashed from sdram.bin by l3check.py memhash), sdram.bin, milestones.txt,
# results.txt (with the wall time); fdd_wr also fdd_wr_<cyl>_<head>.hex (the
# write streams) and card_saved.img (the card as the run left it).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
L2="$ROOT/sim/host_bridge"
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
SIM=${SIM:-xsim}
CPU=${CPU:-rv}
GHDL=${GHDL:-ghdl}
VERILATOR=${VERILATOR:-verilator}
JOBS=${JOBS:-$(nproc)}
case "$SIM" in
	xsim|verilator) ;;
	*) echo "SIM=$SIM: must be xsim or verilator"; exit 2 ;;
esac
case "$CPU" in
	rv|832) ;;
	*) echo "CPU=$CPU: must be rv or 832"; exit 2 ;;
esac
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
GHDLFLAGS="--std=93c --ieee=synopsys -fexplicit"
I2C_V="$ROOT/rtl/host/i2c_master_mmio.sv $ROOT/rtl/openaars/adv7511/i2c_master.v"
XW=${EXTRA_WS:-0}
SL=${SLAT:-8} SJ=${SJIT:-0}
run="$HERE/run_${RUNTAG:-wt}"
# the committed boot ROM (ROM, checked against git HEAD) and the file the
# simulators read (ROM_SIM: the 832's is the run copy of hs_rom832)
E832=${E832:-$ROOT/EightThirtyTwo/RTL}
E832DIR=${E832DIR:-$ROOT/EightThirtyTwo}
if [ "$CPU" = 832 ]; then
	ROM="$ROOT/fw/ctrl_boot_832/OSDBoot_832_ROM.vhd" ROM_SIM="$run/src/OSDBoot_832_ROM.vhd"
	[ "$XW" = 0 ] || { echo "EXTRA_WS=$XW: the bridge's rv_extra_ws is the RV's (CPU=832: 0)"; exit 2; }
else
	ROM="$ROOT/fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd" ROM_SIM=$ROM
fi

# the Minimig RTL the bench simulates (copied into <run>/src), after the
# board's global include (rtl/soc/openaars_defines.vh)
MM_FILES="rtl/soc/openaars_defines.vh rtl/minimig/userio_osd.v rtl/minimig/userio_osd_spi.v
          rtl/minimig/paula_floppy.v rtl/minimig/paula_floppy_fifo.v rtl/minimig/gayle.v
          rtl/minimig/gayle_port.v rtl/minimig/gayle_fifo.v rtl/minimig/minimig_syscontrol.v"
MM_INC="$ROOT/fpga/openaars"     # minimig_version.vh (the board's)

# the "=== MARGIN <item> <name>" lines every run must print (mon_l3.vh),
# and per scenario the ones that must have seen events: their verdict must
# be ok (n/a fails the scenario).  boot has no direct transfer and one RTC
# transfer (items 3 and 12: n/a); boot_short has no paula frame yet and its
# only cpurst fall is fpga_init's reset pulse, before any kickstart
MARGINS="1:stale_acks 3:dmode_release 3:dmode_L 4:paula_cs_release 4:userio_cs_release
         4:paula_word_spacing 4:userio_byte_spacing 5:spi_write_busy 6:fdd_fifo_empty_dma
         7:fdd_fifo_full_write 8:ide_wait 9:cd_timeout_left 12:rtc_cs_high 14:kick_order"
MARGIN_REQ_boot="1:stale_acks 4:paula_cs_release 4:userio_cs_release 4:paula_word_spacing
                 4:userio_byte_spacing 5:spi_write_busy 14:kick_order"
MARGIN_REQ_boot_short="1:stale_acks 4:userio_cs_release 4:userio_byte_spacing 5:spi_write_busy"
MARGIN_REQ_keys=$MARGIN_REQ_boot
MARGIN_REQ_fdd_rd="$MARGIN_REQ_boot 6:fdd_fifo_empty_dma"
MARGIN_REQ_fdd_wr="$MARGIN_REQ_boot 7:fdd_fifo_full_write"
# hdd: the HDF sectors come in direct mode (item 3); item 8 is rec (no
# bound), l3check.py hdd requires its per-command lines
MARGIN_REQ_hdd="$MARGIN_REQ_boot 3:dmode_release"
# cd: item 9 (the CD phase windows against CD_TIMEOUT); an ISO's sectors
# come in direct mode (cdrom.c cd_send_sectors: FileReadEx), a CUE's
# MODE1/2352 sectors through the CPU (cd_send_raw): item 3 only for iso
CDCFG=${CDCFG:-cue}
case "$CDCFG" in
	cue) MARGIN_REQ_cd="$MARGIN_REQ_boot 9:cd_timeout_left" ;;
	iso) MARGIN_REQ_cd="$MARGIN_REQ_boot 9:cd_timeout_left 3:dmode_release" ;;
	*) echo "CDCFG=$CDCFG: must be cue or iso"; exit 2 ;;
esac
# cdda: item 9 (each packet's command phase); cdda_load also item 3 (the
# HDF sectors in direct mode)
MARGIN_REQ_cdda="$MARGIN_REQ_boot 9:cd_timeout_left"
MARGIN_REQ_cdda_load="$MARGIN_REQ_cdda 3:dmode_release"
MARGIN_REQ_akiko=$MARGIN_REQ_fdd_rd

# fdd_wr's tracks, in order (= scenarios.vh FDD_WPLAN, l3check.py
# FDD_WR_TRACKS): "<cylinder>:<head>[:<sector with a bad header checksum>]"
FDD_WR_PLAN="0:0 1:0 2:0 39:0 41:0 77:0 78:0 79:0 79:1 40:0:3"

# cycles per scenario (clk_114): 1.5 x the measured end event (README "boot",
# Verilator 2026-10-19: RV boot 158,155,012, boot_short 57,659,090; 832
# boot 202,841,132, boot_short 74,525,542; README "keys": RV keys
# 164,959,781, 832 214,187,801); fdd_rd: 1.5 x the estimate of README
# "fdd_rd" (Task 13's measured ends, RV 393,222,555 and 832 442,065,819,
# plus bfm_floppy's drive-ready waits of Task 14: 500 ms after motor on and
# 15 ms per head change, 59 M: RV 452 M, 832 501 M); fdd_wr: 1.5 x the
# estimate of README "fdd_wr" (RV 470 M, 832 520 M);
# hdd: 832 1.5 x its measured end (p4t15c3: 233,511,245), RV 1.5 x the
# estimate 200 M (README "hdd"); cd: 1.5 x the estimates RV 210 M, 832
# 300 M (measured, README "cd": RV 185,153,365, 832 233,680,101); cdda,
# cdda_load: 1.5 x the estimates RV 345 M, 832 390 M (the plan start as
# cd, then 7 halves of the board's 21.1 M and the refills; measured, README
# "cdda": RV 337,017,061, 832 407,912,613)
if [ "$CPU" = 832 ]; then
	L3_BOOT_TO=${L3_BOOT_TO:-304300000}
	L3_SHORT_TO=${L3_SHORT_TO:-111800000}
	L3_KEYS_TO=${L3_KEYS_TO:-321300000}
	L3_FDD_TO=${L3_FDD_TO:-750000000}
	L3_FDDW_TO=${L3_FDDW_TO:-780000000}
	L3_HDD_TO=${L3_HDD_TO:-350000000}
	L3_CD_TO=${L3_CD_TO:-450000000}
	L3_CDDA_TO=${L3_CDDA_TO:-585000000}
	L3_AKIKO_TO=${L3_AKIKO_TO:-700000000}
else
	L3_BOOT_TO=${L3_BOOT_TO:-237300000}
	L3_SHORT_TO=${L3_SHORT_TO:-86500000}
	L3_KEYS_TO=${L3_KEYS_TO:-247400000}
	L3_FDD_TO=${L3_FDD_TO:-680000000}
	L3_FDDW_TO=${L3_FDDW_TO:-700000000}
	L3_HDD_TO=${L3_HDD_TO:-300000000}
	L3_CD_TO=${L3_CD_TO:-315000000}
	L3_CDDA_TO=${L3_CDDA_TO:-520000000}
	L3_AKIKO_TO=${L3_AKIKO_TO:-520000000}
fi

# shellcheck source=../common/hostsim.sh
. "$ROOT/sim/common/hostsim.sh"
# every fatal step, hostsim.sh's hs_* included (they call hs_die), ends the
# run with the scenario's verdict line: no step failure is silent
hs_die() { echo "FAILED: $*"; echo "=== ${SCEN:-run.sh} FAILED"; exit 1; }
die() { hs_die "$@"; }
L3CHECK=${L3CHECK:-$HERE/l3check.py}   # tests of run.sh only: another l3check.py

# l3_check <name> <out file> <pass regex> <command...>: one offline check
# (spitrace.py, l3check.py), its output in <out file>.  "ok   <the first line
# matching <pass regex>>" only when the command exits 0 AND printed such a
# line; otherwise its BAD lines and "BAD  <name>: exit <rc>, ..." (a crash
# prints no PASS line and exits non-zero: it fails the scenario either way)
l3_check() {
	local name=$1 out=$2 re=$3 rc line; shift 3
	"$@" > "$out" 2>&1; rc=$?
	line=$(grep -m1 -E -- "$re" "$out")
	if [ "$rc" -eq 0 ] && [ -n "$line" ]; then echo "ok   $line ($out)"; return 0; fi
	grep '^BAD' "$out"
	echo "BAD  $name: exit $rc, ${line:-no line matching '$re'}; last line: $(tail -1 "$out") ($out)"
	return 1
}
X() { hs_X "$run" "$@"; }

# cfide_generics: -g<name>=true|false from tb_l3.v's "cfide #( ... ) mycfide ("
# block, one per boolean generic of the cfide entity (dies otherwise)
cfide_generics() {
	local names tbg n
	names=$(sed -n '/^entity cfide is$/,/^ *port($/s/^ *\([a-z0-9_]*\) *: *in boolean.*/\1/p' "$ROOT/rtl/host/cfide.vhd")
	tbg=$(sed -n '/^  cfide #($/,/^  ) mycfide ($/p' "$HERE/tb_l3.v" | grep -o "\.[a-z0-9_]*(1'b[01])" \
		| sed "s/^\.\([a-z0-9_]*\)(1'b0)$/-g\1=false/; s/^\.\([a-z0-9_]*\)(1'b1)$/-g\1=true/")
	[ -n "$names" ] || die "no boolean generics found in rtl/host/cfide.vhd's entity"
	for n in $names; do
		echo "$tbg" | grep -qx -- "-g$n=\(true\|false\)" || die "tb_l3.v: the cfide instance does not set generic $n"
	done
	[ "$(echo "$tbg" | wc -l)" = "$(echo "$names" | wc -w)" ] || die "tb_l3.v: the cfide instance sets other generics than cfide.vhd has"
	CFIDE_GENERICS=$(echo $tbg)
}

# l3_pin_minimig (XRAND=1 only): reset-less state of the Minimig slaves
# that the FPGA's configuration starts at 0, pinned to 0 at time 0 in the
# run copy, as hostsim.sh pins the bridge's and hostcache's flops (README
# "boot", XRAND): paula_floppy.v dsktrack[0..3] (the drives' head
# positions, never reset: HandleFpga's track byte; found by the first XRAND
# twin, findings/osd-riscv/phase4.md); gayle_port.v's task file tfr[0..7]
# and gayle_fifo.v's sector buffer mem[0..4095] (no reset: the firmware's
# CMD_IDE_REGS_RD of the first IDE command reads the FIFO's head word and
# the features register before the 68k wrote them; found by the hdd twin
# p4t15_xr; 8 + 4,096 per port, two ports).  The count joins hostsim.sh's
# "=== XRAND pinned <n> regs" (it sums the lines of src/pinned_hostcache).
l3_pin_minimig() {
	local v="$run/src/paula_floppy.v" decl='	reg		[6:0] dsktrack[3:0]; //track select'
	[ "${XRAND:-0}" = 1 ] || return 0
	[ "$(grep -cxF -- "$decl" "$v")" = 1 ] || die "XRAND pin: paula_floppy.v dsktrack declaration not found"
	sed -i "/^$(printf '%s' "$decl" | sed 's/[][\/.*^$]/\\&/g')\$/a\\	initial begin dsktrack[0] = 7'd0; dsktrack[1] = 7'd0; dsktrack[2] = 7'd0; dsktrack[3] = 7'd0; end // XRAND pin" "$v"
	[ "$(grep -c '// XRAND pin$' "$v")" = 1 ] || die "XRAND pin: dsktrack initialiser not inserted"
	echo 4 >> "$run/src/pinned_hostcache"
	python3 - "$run/src/gayle_port.v" "$run/src/gayle_fifo.v" <<'EOP' || die "XRAND pin: gayle_port.v tfr / gayle_fifo.v mem declaration not found"
import sys
for path, decl, init in (
        (sys.argv[1], "reg\t\t[7:0] tfr [7:0];",
         "initial begin : xrand_pin_tfr integer i; for (i = 0; i < 8; i = i + 1) tfr[i] = 8'd0; end // XRAND pin"),
        (sys.argv[2], "reg \t[15:0] mem [4095:0];\t\t// 16 bit wide fifo memory",
         "initial begin : xrand_pin_mem integer i; for (i = 0; i < 4096; i = i + 1) mem[i] = 16'd0; end // XRAND pin")):
    s = open(path).read()
    assert s.count(decl + "\n") == 1, decl
    s = s.replace(decl + "\n", decl + "\n" + init + "\n")
    open(path, "w").write(s)
EOP
	[ "$(grep -c '// XRAND pin$' "$run/src/gayle_port.v")" = 1 ] && [ "$(grep -c '// XRAND pin$' "$run/src/gayle_fifo.v")" = 1 ] \
		|| die "XRAND pin: gayle initialisers not inserted"
	echo 8208 >> "$run/src/pinned_hostcache"
}

# l3_pin_async (every run, both simulators): the slaves' SPI registers with
# an edge-triggered asynchronous set / clear ("always @(posedge sck or
# posedge _scs) if (_scs) ...") start in the state that set / clear holds.
# Synthesis makes these level-sensitive preset / clear flops, and the
# selects are high from configuration on (cfide's sd_cs = NOT scs, scs
# cleared by its reset), so on the board they are held there from the
# start.  A simulator applies them only on an edge of the select: xsim sees
# X -> 1 at time 0 as one, Verilator's two-state build does not (probed:
# first_byte 0 at 50 ns, so its first OSD frame's command byte was taken as
# data), and XRAND starts them random (twin p4t5c_xr: bit_cnt shifted a
# random sdo_reg into the first OSD frame's MISO).  Initialisers in the run
# copies:  userio_osd_spi.v bit_cnt 0, first_byte 1; paula_floppy.v
# spi_bit_cnt 0, spi_tx_cnt 0 (clear on ~scs), spi_rx_cnt_rst 1 (set on
# ~scs1).  A model of the RTL as built, not a change to it.
l3_pin_async() {
	local u="$run/src/userio_osd_spi.v" p="$run/src/paula_floppy.v"
	python3 - "$u" "$p" <<'EOP' || die "async pin: a declaration was not found (run.sh l3_pin_async)"
import sys
u, p = sys.argv[1], sys.argv[2]
def pin(path, pairs):
    s = open(path).read()
    for decl, init in pairs:
        assert s.count(decl + "\n") == 1, decl
        ind = decl[:len(decl) - len(decl.lstrip())]
        s = s.replace(decl + "\n", decl + "\n" + ind + init + " // ASYNC pin\n")
    open(path, "w").write(s)
pin(u, [("reg [2:0] bit_cnt;\t\t//bit counter", "initial bit_cnt = 3'd0;"),
        ("reg first_byte;\t\t//first byte is going to be received", "initial first_byte = 1'b1;")])
pin(p, [("\treg [3:0] spi_bit_cnt; //received bit counter - incremented on rising edge of SCK",
         "initial spi_bit_cnt = 4'd0;"),
        ("\treg [1:0] spi_tx_cnt; //transmitted SPI words counter", "initial spi_tx_cnt = 2'd0;"),
        ("\treg\tspi_rx_cnt_rst; //indicates reception of the first spi word after activation of the chip select",
         "initial spi_rx_cnt_rst = 1'b1;")])
EOP
	[ "$(grep -c '// ASYNC pin$' "$u")" = 2 ] && [ "$(grep -c '// ASYNC pin$' "$p")" = 3 ] \
		|| die "async pin: initialisers not inserted"
}

# l3_retire_tap (CPU=rv): the run copy of rv_hostcpu.v gets a wire
# l3_retire = the VexOsd core's writeBack_arbitration_isFiring (one retired
# instruction), driven inside the DEBUG = 0 generate branch, for tb_l3.v's
# "=== RETIRED" count.  A reference from the bench into the branch does not
# resolve under Verilator 5.020 (every branch is labelled g_core, and the
# lookup does not pick the elaborated one); the wire is read from outside
# instead.  It drives nothing in the design; rtl/ is never edited
l3_retire_tap() {
	local v="$run/src/rv_hostcpu.v"
	[ "$CPU" = rv ] || return 0
	python3 - "$v" <<'EOP' || die "RETIRED tap: rv_hostcpu.v's generate / DEBUG = 0 branch not found"
import sys
p = sys.argv[1]
s = open(p).read()
g = "\n  generate\n    if (DEBUG == 0) begin : g_core\n"
assert s.count(g) == 1
s = s.replace(g, "\n  wire l3_retire; // L3 RETIRED tap (sim/l3/run.sh)" + g +
              "      assign l3_retire = u_core.writeBack_arbitration_isFiring; // L3 RETIRED tap\n")
open(p, "w").write(s)
EOP
	[ "$(grep -c '// L3 RETIRED tap' "$v")" = 2 ] || die "RETIRED tap: not inserted"
}

# l3_rdy_mut (RDY_MUT=1 only): the run copy of cfide answers OSD_RDY = 1
# whatever the counts say (the mutant of sim/spi_cdc/run.sh's RDY_MUT): the
# handshake's tooth.  The tree's rtl/ is never edited.
l3_rdy_mut() {
	local c="$run/src/cfide.vhd"
	[ "${RDY_MUT:-0}" = 1 ] || return 0
	[ "$(grep -c -- '-- OSD RDY$' "$c")" = 1 ] || die "RDY_MUT: not exactly one '-- OSD RDY' line in cfide.vhd"
	sed -i "s/^\( *\)osd_rdy <= .*-- OSD RDY\$/\1osd_rdy <= '1'; -- OSD RDY MUTANT/" "$c"
	[ "$(grep -c -- "osd_rdy <= '1'; -- OSD RDY MUTANT\$" "$c")" = 1 ] || die "RDY_MUT: mutation not applied"
	echo "RDY_MUT: $(grep -- '-- OSD RDY MUTANT' "$c" | sed 's/^ *//')" >> "$run/compile.log"
}

# l3_paula_txpop (PAULA_TXPOP=1 only): the run copy of paula_floppy.v takes
# the evidence fix of Task 14's write-FIFO finding: a track write's FIFO word
# is popped at tx_flag of word 3+ (its transmission has started, the word is
# in spi_sdo_reg) instead of at spidat (received), so the next word's load,
# a whole word later, sees the next FIFO entry
l3_paula_txpop() {
	local p="$run/src/paula_floppy.v"
	local old='	assign fifo_rd = (busrd & dmaon) | (trackwr & spidat);'
	[ "${PAULA_TXPOP:-0}" = 1 ] || return 0
	[ "$(grep -cxF -- "$old" "$p")" = 1 ] || die "PAULA_TXPOP: the fifo_rd line not found in paula_floppy.v"
	sed -i "s/^	assign fifo_rd = (busrd & dmaon) | (trackwr & spidat);\$/	assign fifo_rd = (busrd \& dmaon) | (trackwr \& cmd_fdd \& tx_flag \& tx_cnt==2'd3); \/\/ PAULA_TXPOP/" "$p"
	[ "$(grep -c '// PAULA_TXPOP$' "$p")" = 1 ] || die "PAULA_TXPOP: patch not applied"
	echo "PAULA_TXPOP: $(grep -- '// PAULA_TXPOP' "$p" | sed 's/^[[:space:]]*//')" >> "$run/compile.log"
}

# l3_e832_xsim (CPU=832, xsim): copies of the EightThirtyTwo VHDL in
# <run>/src/e832 for xsim, with the register file's data registers
# (eightthirtytwo_cpu.vhd regfile: tmp, gpr0..gpr6, which its reset leaves
# alone) starting at 0 as the FPGA's configuration starts them: the 4-state
# simulator otherwise has them X, and the boot ROM's first function
# prologue saves them to the stack, an "X on the bus" bench error (probe
# p4t6xb: a write of xxxxxxxx to 0x158c at cycle 2627).  The other fields
# get 0 as well (the reset or a concurrent assignment sets them before
# use).  Verilator's two-state build starts them at 0 anyway; the XRAND
# twin randomises them (any effect on the run would show as a difference).
# Sets E832_XSIM to the copies, in analysis order
l3_e832_xsim() {
	local f
	E832_XSIM=()
	mkdir -p "$run/src/e832" || die "mkdir $run/src/e832"
	for f in $HS_E832_FILES; do
		[ -f "$E832/$f" ] || die "no $E832/$f (E832= the EightThirtyTwo RTL directory)"
		cp "$E832/$f" "$run/src/e832/" || die "copy $E832/$f"
		E832_XSIM+=("$run/src/e832/$f")
	done
	python3 - "$run/src/e832/eightthirtytwo_cpu.vhd" <<'EOP' || die "l3_e832_xsim: eightthirtytwo_cpu.vhd's regfile declaration not found"
import sys
p = sys.argv[1]
s = open(p).read()
old = "\nsignal regfile : e32_regfile;\n"
z = "(others => '0')"
init = ", ".join(["tmp => " + z, "gpr_a => " + z, "gpr_q => " + z] +
                 ["gpr%d => %s" % (i, z) for i in range(8)] +
                 ["gpr7_flags => " + z, "gpr7_readflags => '0'"] +
                 ["flag_%s => '0'" % f for f in ("z", "c", "cond", "sgn", "interrupting", "halfword", "byte")])
assert s.count(old) == 1
s = s.replace(old, "\nsignal regfile : e32_regfile := (" + init + "); -- L3 pin (run.sh l3_e832_xsim)\n")
open(p, "w").write(s)
EOP
}

# setup: run directory, RTL copies, firmware, card
setup() {
	local f mk=()
	rm -rf "$run"; mkdir -p "$run/src" || die "mkdir $run"
	cd "$run" || die "cd $run"
	: > compile.log
	hs_copy_rtl "$run" "$ROOT"
	for f in $MM_FILES; do cp "$ROOT/$f" "$run/src/" || die "copy $f"; done
	if [ -n "${PATCH:-}" ]; then
		PATCHF=$(realpath -m -- "$PATCH")
		[ -f "$PATCHF" ] || die "no PATCH script $PATCHF"
		echo "PATCH: $PATCHF" >> "$run/compile.log"
		bash "$PATCHF" "$run/src" "$ROOT" >> "$run/compile.log" 2>&1 \
			|| { tail -20 "$run/compile.log"; die "PATCH $PATCHF ($run/compile.log)"; }
	fi
	# the slaves have no `timescale (xelab refuses a design that mixes);
	# their #1 delays are 1 ns, as in a build after any 1ns/1ps file
	for f in $MM_FILES; do
		case "$f" in *.v) sed -i '1i `timescale 1ns/1ps' "$run/src/$(basename "$f")" ;; esac
	done
	l3_pin_minimig
	l3_pin_async
	l3_retire_tap
	l3_rdy_mut
	l3_paula_txpop
	[ "$CPU" = 832 ] && hs_rom832 "$run"
	if [ -n "${FW:-}" ]; then
		FWBIN=$(realpath -m -- "$FW")
		[ -f "$FWBIN" ] || die "no firmware $FWBIN (FW=)"
	else
		hs_fwrv "$run"
		FWBIN="$run/fwrv/RV32OSDA.BIN"
	fi
	# the 832 firmware: FW832, else (CPU=832) built here, else the stand-in
	FW832BIN=
	if [ -n "${FW832:-}" ]; then
		FW832BIN=$(realpath -m -- "$FW832")
		[ -f "$FW832BIN" ] || die "no firmware $FW832BIN (FW832=)"
	elif [ "$CPU" = 832 ]; then
		make -C "$HERE/fw832" B="$run/fw832" E832DIR="$E832DIR" > "$run/make_fw832.log" 2>&1 \
			|| { tail -20 "$run/make_fw832.log"; die "make sim/l3/fw832 ($run/make_fw832.log)"; }
		FW832BIN="$run/fw832/832OSDAD.BIN"
	fi
	[ -n "$FW832BIN" ] && mk+=(FW832="$FW832BIN")
	[ "${NOKICK:-0}" = 1 ] && mk+=(NOKICK=1)
	# the card of the scenario (sim/l3/card): fdd_rd, fdd_wr and akiko the
	# fdd card, hdd the hdd card, cd the cd card with CDCFG's configs (image
	# cd.img or cd_iso.img), cdda the cd card (cue), cdda_load the cdhdd
	# card, the others boot.  MSCARD: milestones()'s "CARD=<card>" lines (cd:
	# cd_cue or cd_iso, the disc's files differ)
	CARDNAME=boot
	case "${SCEN:-}" in fdd_rd|fdd_wr|akiko) CARDNAME=fdd ;; esac
	[ "${SCEN:-}" = hdd ] && CARDNAME=hdd
	[ "${SCEN:-}" = cd ] && CARDNAME=cd
	[ "${SCEN:-}" = cdda ] && CARDNAME=cd
	[ "${SCEN:-}" = cdda_load ] && CARDNAME=cdhdd
	case "${SCEN:-}" in
		cdda|cdda_load) [ "$CDCFG" = cue ] || die "CDCFG=$CDCFG: ${SCEN} plays TEST.CUE's track 2 (cue only)" ;;
	esac
	MSCARD=$CARDNAME IMG=$CARDNAME
	if [ "$CARDNAME" = cd ]; then
		MSCARD=cd_$CDCFG
		[ "$CDCFG" = iso ] && IMG=cd_iso
		mk+=(CDCFG="$CDCFG")
	fi
	make -s -C "$HERE/card" "$CARDNAME" B="$run/card" FWRV="$FWBIN" "${mk[@]}" > "$run/make_card.log" 2>&1 \
		|| { tail -20 "$run/make_card.log"; die "make the $CARDNAME card ($run/make_card.log)"; }
	CARD="$run/card/$IMG.img"
	[ ${#CARD} -le 1024 ] || die "card image path longer than 1024 characters (+SD_IMG): $CARD"
	# fdd_wr: the write stream of each track, from the card's TEST.ADF
	if [ "${SCEN:-}" = fdd_wr ]; then
		local e c h b
		for e in $FDD_WR_PLAN; do
			c=${e%%:*} h=${e#*:} h=${h%%:*} b=
			case "$e" in *:*:*) b=${e##*:} ;; esac
			python3 -I "$HERE/gen/mkwrtrack.py" "$run/card/content/TEST.ADF" "$c" "$h" "$run/fdd_wr_${c}_${h}.hex" \
				${b:+--bad-header "$b"} >> "$run/mkwrtrack.log" 2>&1 \
				|| { tail -5 "$run/mkwrtrack.log"; die "mkwrtrack.py $c $h ($run/mkwrtrack.log)"; }
		done
	fi
}

# l3_build_key: sha256 of every input of a Verilator build (BUILD_FROM)
l3_build_key() {
	local f files=()
	while IFS= read -r f; do files+=("$f"); done < <(find "$run/src" -maxdepth 1 -type f | LC_ALL=C sort)
	files+=("$HERE"/*.v "$HERE"/*.vh "$HERE/l3.vlt" "$ROOT"/sim/common/*.v "$ROOT"/sim/common/*.vh
	        "$ROOT/sim/common/hostsim.sh" "$L2/sdram_host_model.v" "$L2/verilator/blackbox.vhd"
	        "$L2/verilator/romcheck.py" "$ROM_SIM" $I2C_V "$MM_INC"/*.vh "$ROOT"/rtl/minimig/*.vh "$HERE/run.sh")
	if [ "$CPU" = 832 ]; then
		for f in $HS_E832_FILES; do files+=("$E832/$f"); done
		files+=("$ROOT/$HS_E832_STUB")
	fi
	{
		echo "SIM=$SIM CPU=$CPU EXTRA_WS=$XW XRAND=${XRAND:-0} generics=$CFIDE_GENERICS"
		"$GHDL" --version | head -1
		"$VERILATOR" --version
		sha256sum "${files[@]}" | sed 's|  .*/|  |'
	} | sha256sum | cut -c1-64
}

# build: the snapshot tb_l3_x<XW> (Verilator: GHDL conversion + verilate)
build() {
	local snap=$1 d="$run/ghdl_$1" i2c="" mm=() f key from
	for f in $MM_FILES; do mm+=("$run/src/$(basename "$f")"); done
	cfide_generics
	if [ "$SIM" = verilator ]; then
		key=$(l3_build_key)
		[ ${#key} = 64 ] || die "build key not computed"
	fi
	from=
	if [ -n "${BUILD_FROM:-}" ]; then
		from="$HERE/run_$BUILD_FROM"
		[ "$SIM" = verilator ] || die "BUILD_FROM needs SIM=verilator"
		if [ ! -f "$from/buildkey_$snap" ] || [ ! -x "$from/vl_$snap/Vtb_l3" ] \
			|| [ "$(cat "$from/buildkey_$snap")" != "$key" ]; then
			echo "BUILD_FROM=$BUILD_FROM: no finished build there with this run's build key: building" \
				| tee -a "$run/compile.log" >> "$run/results.txt"
			from=
		fi
	fi
	if [ -n "$from" ]; then
		mkdir -p "$run/vl_$snap" "$d" || die "mkdir $run/vl_$snap"
		cp "$from/vl_$snap/Vtb_l3" "$run/vl_$snap/" || die "copy $from/vl_$snap/Vtb_l3"
		if [ -f "$from/ghdl_$snap/pinned.txt" ]; then cp "$from/ghdl_$snap/pinned.txt" "$d/" || die "copy pinned.txt"; fi
		echo "$key" > "$run/buildkey_$snap"
		echo "BUILD_FROM: run_$BUILD_FROM's simulator, build key $key" | tee -a "$run/compile.log" >> "$run/results.txt"
		return 0
	fi
	# per CPU: the core's files, the defines (CPU=rv: rv_hostcpu's counters;
	# CPU=832: L3_CPU832, no counters), the bridge's cpu_riscv
	local cpuv=() def riscv
	if [ "$CPU" = 832 ]; then
		def=L3_CPU832 riscv=false
	else
		def=RV_HOSTCPU_STATS riscv=true cpuv=(src/rv_hostcpu.v src/VexOsd.v)
	fi
	if [ "$SIM" = verilator ]; then
		# the L2 bench's black-box list and ROM check (HERE, for this call only)
		HS_DIR=$d HS_ROM=$ROM_SIM HS_VB=832_bridge.vhd HS_VC=cfide.vhd HS_E832=$E832
		# shellcheck disable=SC2086
		HERE=$L2 hs_ghdl_convert "$run" "$riscv" "$XW" $CFIDE_GENERICS
		grep -qE '^ *i2c_master_mmio +[a-z0-9_]+ *\(' "$d/cfide.v" && i2c=$I2C_V
		HS_NAME=$snap HS_VLT="$HERE/l3.vlt"
		HS_VFLAGS="-GEXTRA_WS=$XW -I$ROOT/sim/common -I$HERE -I$MM_INC -I$ROOT/rtl/minimig"
		# shellcheck disable=SC2086
		hs_verilate "$run" tb_l3 "-DL3_GHDL -D$def" \
			"$d/bridge.v" "$d/cfide.v" "${cpuv[@]}" src/hostcache.v src/dpram_inf_generic.v \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" $i2c \
			"${mm[@]}" "$HERE/bfm_audio.v" "$HERE/bfm_keys.v" "$HERE/bfm_floppy.v" "$HERE/bfm_ide.v" "$HERE/bfm_akiko.v" "$HERE/rtc_model.v" "$HERE/tb_l3.v"
		echo "$key" > "$run/buildkey_$snap"
	else
		X xvlog -sv $I2C_V
		X xvhdl src/cfide.vhd
		X xvlog -d "$def" "${cpuv[@]}" src/hostcache.v src/dpram_inf_generic.v
		if [ "$CPU" = 832 ]; then
			l3_e832_xsim
			X xvhdl "${E832_XSIM[@]}" "$ROOT/$HS_E832_STUB"
		fi
		X xvhdl src/832_bridge.vhd
		X xvhdl "$ROM_SIM"
		# --relax: rtl/minimig/gayle_port.v uses the wire err before its
		# declaration (an error for xvlog, accepted by synthesis and Verilator)
		X xvlog --relax -i "$MM_INC" -i "$ROOT/rtl/minimig" "${mm[@]}"
		X xvlog -d "$def" -i "$ROOT/sim/common" -i "$HERE" \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" "$HERE/bfm_audio.v" \
			"$HERE/bfm_keys.v" "$HERE/bfm_floppy.v" "$HERE/bfm_ide.v" "$HERE/bfm_akiko.v" "$HERE/rtc_model.v" "$HERE/tb_l3.v"
		hs_xsim_build "$run" "$snap" "$XW" tb_l3
	fi
}


# milestones <scenario> <log>: the milestone file of the scenario, spitrace
# check of its UART / SPI lines, and its "NOT UART <text>" lines.  A line
# "CPU=<cpu> <milestone>" is a milestone of that CPU only (rv or 832): it is
# kept, without the prefix, for that CPU and dropped for the other; a line
# "CARD=<card> <milestone>" likewise for the scenario's card (MSCARD)
milestones() {
	local s=$1 log=$2 ms="$run/milestones_$1.txt" t
	if [ "$s" = boot_short ]; then
		sed '/^#@ boot_short end/q' "$HERE/milestones_boot.txt"
	else
		cat "$HERE/milestones_boot.txt"
	fi | sed -n -e "s/^CARD=${MSCARD:-boot} //p" -e t -e '/^CARD=/d' -e p \
		| sed -n -e "s/^CPU=$CPU //p" -e t -e '/^CPU=/d' -e p > "$ms"
	grep -E '^CPU=' "$HERE/milestones_boot.txt" | grep -vE '^CPU=(rv|832) ' | sed 's/^/BAD  milestones_boot.txt: a CPU= line for neither rv nor 832: /'
	grep -E '^CARD=' "$HERE/milestones_boot.txt" | grep -vE '^CARD=(boot|fdd|hdd|cd_cue|cd_iso|cdhdd) ' \
		| sed 's/^/BAD  milestones_boot.txt: a CARD= line for none of boot, fdd, hdd, cd_cue, cd_iso, cdhdd: /'
	grep -v '^NOT ' "$ms" > "$ms.check"
	l3_check milestones "$run/milestones.txt" '^milestones: [0-9]+ of [0-9]+ found in order$' \
		python3 -I "$L2/spitrace.py" check "$ms.check" "$log" "$run/spi.txt"
	grep '^NOT UART ' "$ms" | sed 's/^NOT UART //' | while IFS= read -r t; do
		if grep -E '^UART: ' "$log" | grep -qF -- "$t"; then echo "BAD  a UART line contains '$t'"
		else echo "ok   no UART line contains '$t'"; fi
	done
}

# margins <scenario> <log>: every MARGINS line once, none LOW, and each of
# MARGIN_REQ_<scenario> with events (ok; n/a or rec there is BAD)
margins() {
	local s=$1 log=$2 m re line v req k=0 bad=0
	req=$(eval "echo \${MARGIN_REQ_$s:-}")
	for m in $MARGINS; do
		re="^=== MARGIN ${m%%:*} ${m#*:} min "
		k=$((k + 1))
		if [ "$(grep -c -E -- "$re" "$log")" != 1 ]; then
			echo "BAD  not exactly one line '=== MARGIN ${m%%:*} ${m#*:} ...'"; bad=1; continue
		fi
		line=$(grep -E -- "$re" "$log")
		v=$(printf '%s\n' "$line" | sed -n 's/.*(bound [-0-9]*, \([a-zA-Z/]*\)) over .*/\1/p')
		# a value of "none" is no event, whatever the verdict says
		case "$line" in *" min none "*) v=n/a ;; esac
		case "$v" in
			ok|rec|n/a) ;;
			LOW) echo "BAD  MARGIN ${m%%:*} ${m#*:} LOW"; bad=1; continue ;;
			*) echo "BAD  MARGIN ${m%%:*} ${m#*:}: no verdict in '$line'"; bad=1; continue ;;
		esac
		case " $(echo $req) " in
			*" $m "*) [ "$v" = ok ] || { echo "BAD  MARGIN ${m%%:*} ${m#*:} is $v: scenario $s must check it (MARGIN_REQ_$s)"; bad=1; } ;;
		esac
	done
	[ "$bad" = 0 ] && echo "ok   MARGIN lines: all $k present, none LOW, $(echo $req | wc -w) required ones ok"
}

# scenario <name>: build, run, checks
scenario() {
	local s=$1 to snap="tb_l3_x$XW" pa=() st x
	local log="$run/tb_${s}_x${XW}_s${SL}_j${SJ}.log"
	case "$s" in
		boot) to=${TIMEOUT:-$L3_BOOT_TO}; pa=("SD_LOG=1") ;;
		boot_short) to=${TIMEOUT:-$L3_SHORT_TO} ;;
		keys) to=${TIMEOUT:-$L3_KEYS_TO}; pa=("KEYS=$(realpath -m -- "${KEYS:-$HERE/keys/menu_tour.txt}")" "TICKDIV=643" "TICKDIV_AT=scenario") ;;
		fdd_rd) to=${TIMEOUT:-$L3_FDD_TO}
			pa=("KEYS=$(realpath -m -- "${KEYS:-$HERE/keys/insert_df0.txt}")" "TICKDIV=643" "TICKDIV_AT=scenario"
			    "FDD_DUMP=$run/fdd_rd") ;;
		fdd_wr) to=${TIMEOUT:-$L3_FDDW_TO}
			pa=("KEYS=$(realpath -m -- "${KEYS:-$HERE/keys/insert_df0.txt}")" "TICKDIV=643" "TICKDIV_AT=scenario"
			    "FDD_WFILE=$run/fdd_wr" "SD_SAVE=$run/card_saved.img") ;;
		hdd) to=${TIMEOUT:-$L3_HDD_TO}; pa=("IDE_DUMP=$run/hdd" "SD_SAVE=$run/card_saved.img") ;;
		cd) to=${TIMEOUT:-$L3_CD_TO}; pa=("IDE_DUMP=$run/cd" "CDCFG=$CDCFG" "TICKDIV=643" "TICKDIV_AT=scenario") ;;
		cdda|cdda_load) to=${TIMEOUT:-$L3_CDDA_TO}
			pa=("IDE_DUMP=$run/cdda" "CDDA_DUMP=$run/cdda_half" "TICKDIV=643" "TICKDIV_AT=scenario") ;;
		akiko) to=${TIMEOUT:-$L3_AKIKO_TO}
			pa=("KEYS=$(realpath -m -- "${KEYS:-$HERE/keys/insert_df0.txt}")" "TICKDIV=643" "TICKDIV_AT=scenario"
			    "FDD_DUMP=$run/akiko") ;;
		*) die "unknown scenario $s" ;;
	esac
	# tb_l3.v reads +TIMEOUT into a 32-bit integer: a larger value wraps
	# negative and ends the run at once (Task 19, grid run p4g_rv_ws64_fdd_rd)
	case "$to" in ''|*[!0-9]*) die "TIMEOUT=$to: not a number of cycles" ;; esac
	[ "${#to}" -lt 10 ] || [ "$to" -le 2147483647 ] || die "TIMEOUT=$to: above 2147483647 (tb_l3.v's 32-bit integer)"
	if git -C "$ROOT" diff --quiet HEAD -- "${ROM#$ROOT/}"; then st="unmodified (= git HEAD)"; else st="BAD  MODIFIED against git HEAD"; fi
	{
		echo "=== CPU $CPU"
		echo "boot ROM: ${ROM#$ROOT/} $st, sha256 $(sha256sum "$ROM" | cut -c1-16)$( [ "$ROM_SIM" != "$ROM" ] && echo ", simulated as $ROM_SIM (hs_rom832)")"
		echo "firmware: $FWBIN, $(stat -c %s "$FWBIN") bytes, sha256 $(sha256sum "$FWBIN" | cut -c1-16)"
		if [ -n "$FW832BIN" ]; then
			echo "firmware 832: $FW832BIN, $(stat -c %s "$FW832BIN") bytes, sha256 $(sha256sum "$FW832BIN" | cut -c1-16)"
			[ -f "$run/fw832/832OSDAD.txt" ] && sed 's/^/  /' "$run/fw832/832OSDAD.txt"
		else
			echo "firmware 832: the card's stand-in"
		fi
		[ "$CPU" = 832 ] && echo "EightThirtyTwo RTL: $E832"
		echo "card: $CARD$( [ "${NOKICK:-0}" = 1 ] && echo " (NOKICK=1: no KICK.ROM)")"
		[ "${PAULA_TXPOP:-0}" = 1 ] && echo "PAULA_TXPOP=1: $(sed -n 's/^PAULA_TXPOP: //p' "$run/compile.log")"
		[ -n "${PATCH:-}" ] && echo "PATCH: $PATCHF, sha256 $(sha256sum "$PATCHF" | cut -c1-16)"
		[ "$s" = cd ] && echo "cd config: $CDCFG"
		echo "scenario: $s"
	} | tee "$run/results.txt"
	build "$snap"
	# plusargs without the +: FAST_HW's model timing first (the first match
	# wins in $value$plusargs), then the run's, then XARGS
	case " ${XARGS:-} " in
		*" +FAST_HW=1 "*) pa=(SD_TOKEN_DLY=0 SD_BUSY=1 SD_NCR=1 SLAT=2 SJIT=0 "${pa[@]}") ;;
	esac
	pa+=("SCENARIO=$s" "SLAT=$SL" "SJIT=$SJ" "SEED=${SEED:-1}" "SD_IMG=$CARD" "TIMEOUT=$to"
	     "SPI_LOG=$run/spi.txt" "SPI_T_LOG=$run/spi_t.txt" "HW_LOG=$run/hw.txt" "UART_LOG=$run/uart.txt"
	     "SDRAM_DUMP=$run/sdram.bin")
	for x in ${XARGS:-}; do pa+=("${x#+}"); done
	local t0=$SECONDS
	hs_simrun "$run" "$snap" tb_l3 "$log" "${pa[@]}"
	local secs=$((SECONDS - t0))
	python3 -I "$L2/spitrace.py" summary "$run/spi.txt" > "$run/spi_summary.txt" 2>&1
	{
		grep -E '^=== (BOOT|MAIN|END|STATS|HW accesses|cycle limit|HandleFpga|SPI frames|OSD GAP|OSD EARLY|OSD REPLY|STACK|RTC|KICK|MARGIN|KEYS script|FDD|IDE|CD|AKIKO block)' "$log"
		grep -E '^BENCH ERROR' "$log" | sed 's/^/BAD  /'
		margins "$s" "$log"
		grep -q '^SD: image .* loaded' "$log" || echo "BAD  the SD model did not load $CARD"
		milestones "$s" "$log"
		grep -E '^UART: .*(EXC |TRAP )' "$log" | sed 's/^/BAD  /'
		l3_check memhash "$run/memhash.txt" '^PASS memhash: ' python3 -I "$L3CHECK" memhash "$run"
		if [ "$s" = boot ] || [ "$s" = keys ] || [ "$s" = fdd_rd ] || [ "$s" = fdd_wr ] || [ "$s" = hdd ] \
			|| [ "$s" = cd ] || [ "$s" = cdda ] || [ "$s" = cdda_load ] || [ "$s" = akiko ]; then
			l3_check kick "$run/kick.txt" '^PASS kick: ' python3 -I "$L3CHECK" kick "$run"
			l3_check order "$run/order.txt" '^PASS order: ' python3 -I "$L3CHECK" order "$run"
		fi
		[ "$s" = boot ] && l3_check mmc "$run/mmc.txt" '^PASS mmc: ' python3 -I "$L3CHECK" mmc "$run"
		if [ "$s" = keys ]; then
			l3_check keys "$run/keys.txt" '^PASS keys: ' python3 -I "$L3CHECK" keys "$run"
			grep -E '^REPLY ' "$run/keys.txt"
		fi
		if [ "$s" = fdd_rd ]; then
			l3_check fdd_rd "$run/fdd_rd.txt" '^PASS fdd_rd: ' python3 -I "$L3CHECK" fdd_rd "$run"
			grep -E '^ok   ' "$run/fdd_rd.txt"
		fi
		if [ "$s" = fdd_wr ]; then
			l3_check fdd_wr "$run/fdd_wr.txt" '^PASS fdd_wr: ' python3 -I "$L3CHECK" fdd_wr "$run"
			grep -E '^(ok   |HEADER )' "$run/fdd_wr.txt"
		fi
		if [ "$s" = hdd ]; then
			l3_check hdd "$run/hdd.txt" '^PASS hdd: ' python3 -I "$L3CHECK" hdd "$run"
			grep -E '^ok   ' "$run/hdd.txt"
		fi
		if [ "$s" = cd ]; then
			l3_check cd "$run/cd.txt" '^PASS cd: ' python3 -I "$L3CHECK" cd "$run"
			grep -E '^(ok   |INFO )' "$run/cd.txt"
		fi
		if [ "$s" = cdda ] || [ "$s" = cdda_load ]; then
			l3_check cdda "$run/cdda.txt" '^PASS cdda: ' python3 -I "$L3CHECK" cdda "$run"
			grep -E '^(ok   |INFO )' "$run/cdda.txt"
		fi
		if [ "$s" = akiko ]; then
			l3_check akiko "$run/akiko.txt" '^PASS akiko: ' python3 -I "$L3CHECK" akiko "$run"
			grep -E '^ok   ' "$run/akiko.txt"
		fi
		if grep -q '^=== PASS' "$log"; then echo "ok   bench verdict: === PASS"
		else echo "BAD  bench verdict: $(grep -m1 -E '^=== (PASS|FAIL)' "$log" || echo none) ($log)"; fi
		echo "$SIM wall time ${secs} s, $(sed -n 's/.*, cycles \([0-9]*\)$/\1/p' "$log") cycles"
	} | tee -a "$run/results.txt"
	if grep -q 'BAD' "$run/results.txt"; then echo "=== $s FAILED"; return 1; fi
	echo "=== $s PASS"
}

# nokick: boot on the card without KICK.ROM must fail at the main-loop
# milestone (the fatal-error loop has no HandleFpga frames after its first)
nokick() {
	if scenario boot; then echo "BAD  NOKICK=1: boot passed without a kickstart"; return 1; fi
	if grep -q '^BAD  SPI>=21 10 00 00 00 00 00 00' "$run/milestones.txt" \
		&& grep -q '^UART: .*ROM loading failed' "$run"/tb_boot_*.log; then
		echo "=== NOKICK=1: boot FAILED as expected (main-loop milestone missing, 'ROM loading failed')"
		return 0
	fi
	echo "BAD  NOKICK=1: boot failed, but not at the main-loop milestone ($run/milestones.txt)"
	return 1
}

case "${1:-}" in
	""|-h|--help) sed -n '2,/^set -u$/{/^set -u$/!p}' "$0"; exit 0 ;;
	compare)
		[ $# -eq 3 ] || { echo "usage: run.sh compare <RUNTAG a> <RUNTAG b>"; exit 2; }
		for t in "$2" "$3"; do [ -d "$HERE/run_$t" ] || { echo "no run directory $HERE/run_$t"; exit 2; }; done
		hs_compare "$HERE/run_$2" "$HERE/run_$3"
		exit $?
		;;
	diff)
		shift
		unused=() twin=0
		while :; do
			case "${1:-}" in
				--unused-rules) unused=(--unused-rules); shift ;;
				--twin) twin=1; shift ;;
				*) break ;;
			esac
		done
		[ $# -eq 2 ] || { echo "usage: run.sh diff [--unused-rules] [--twin] <RUNTAG rv> <RUNTAG 832>"; exit 2; }
		cards=() meta=()
		for t in "$1" "$2"; do
			d="$HERE/run_$t"
			[ -d "$d" ] || { echo "no run directory $d"; exit 2; }
			for f in spi.txt hw.txt uart.txt results.txt; do
				[ -f "$d/$f" ] || { echo "no $d/$f (a run before hw.txt / uart.txt: run it again)"; exit 2; }
			done
			# what the run was (results.txt): its CPU, scenario, CD config,
			# and that it passed (final review M5).  The scenario: the
			# "scenario:" line, or (a run before that line) the one
			# tb_<scenario>_x*.log of the run directory
			cpu=$(sed -n 's/^=== CPU \([a-z0-9]*\)$/\1/p' "$d/results.txt" | head -1)
			sc=$(sed -n 's/^scenario: //p' "$d/results.txt" | head -1)
			if [ -z "$sc" ]; then
				sc=$(for l in "$d"/tb_*_x*_s*_j*.log; do [ -f "$l" ] && basename "$l" | sed 's/^tb_\(.*\)_x[0-9]*_s[0-9]*_j[0-9]*\.log$/\1/'; done | sort -u)
				[ "$(printf '%s\n' "$sc" | grep -c .)" = 1 ] || { echo "run_$t: no 'scenario:' line in results.txt and not exactly one tb_<scenario>_x*.log"; exit 2; }
			fi
			cdc=$(sed -n 's/^cd config: //p' "$d/results.txt" | head -1)
			grep -qx 'ok   bench verdict: === PASS' "$d/results.txt" && ! grep -q 'BAD' "$d/results.txt" \
				|| { echo "run_$t did not PASS (results.txt: a BAD line or no bench verdict PASS): no diff"; exit 2; }
			meta+=("$cpu" "$sc" "${cdc:-none}")
		done
		if [ "$twin" = 1 ]; then
			[ "${meta[0]}" = "${meta[3]}" ] || { echo "--twin: run_$1 is CPU ${meta[0]}, run_$2 CPU ${meta[3]}"; exit 2; }
		else
			[ "${meta[0]}" = rv ] && [ "${meta[3]}" = 832 ] \
				|| { echo "run_$1 must be CPU rv and run_$2 CPU 832 (they are ${meta[0]:-?} and ${meta[3]:-?}; --twin for two runs of one CPU)"; exit 2; }
		fi
		[ "${meta[1]}" = "${meta[4]}" ] || { echo "run_$1 ran scenario ${meta[1]}, run_$2 ${meta[4]}"; exit 2; }
		[ "${meta[2]}" = "${meta[5]}" ] || { echo "run_$1 has cd config ${meta[2]}, run_$2 ${meta[5]}"; exit 2; }
		for t in "$1" "$2"; do
			d="$HERE/run_$t"
			# the card the run booted (results.txt "card: <image>")
			c=$(sed -n 's/^card: \([^ ]*\).*/\1/p' "$d/results.txt" | head -1)
			[ -f "$c" ] || { echo "no card image for $d (results.txt: '${c}')"; exit 2; }
			cards+=("$c")
			python3 -I "$L2/spitrace.py" norm "$d/spi.txt" "$d/hw.txt" "$d/uart.txt" \
				-r "$HERE/expected_diff.txt" --card "$c" > "$d/norm.txt" \
				|| { echo "spitrace.py norm failed for $d"; exit 2; }
		done
		# the same card in both runs (FW= and FW832= the same images), or
		# the SD reads differ for that reason alone
		cmp -s "${cards[0]}" "${cards[1]}" \
			|| { echo "the cards of run_$1 and run_$2 differ: give both runs the same FW= and FW832="; exit 2; }
		python3 -I "$L2/spitrace.py" diff "${unused[@]}" "$HERE/run_$1/norm.txt" "$HERE/run_$2/norm.txt"
		exit $?
		;;
	xpair)
		[ $# -eq 2 ] || { echo "usage: run.sh xpair <scenario>"; exit 2; }
		[ "$SIM" = verilator ] || { echo "xpair needs SIM=verilator"; exit 2; }
		rt=${RUNTAG:-wt}
		RUNTAG=$rt XRAND=0 bash "$0" "$2" > "$HERE/.xpair_$rt.out" 2>&1 & p1=$!
		RUNTAG=${rt}_xr XRAND=1 bash "$0" "$2" > "$HERE/.xpair_${rt}_xr.out" 2>&1 & p2=$!
		wait $p1; r1=$?
		wait $p2; r2=$?
		for t in "$rt" "${rt}_xr"; do
			echo "--- RUNTAG=$t"; cat "$HERE/.xpair_$t.out"
			if [ -d "$HERE/run_$t" ]; then mv "$HERE/.xpair_$t.out" "$HERE/run_$t/run.out"; else rm -f "$HERE/.xpair_$t.out"; fi
		done
		echo "--- compare $rt ${rt}_xr"
		hs_compare "$HERE/run_$rt" "$HERE/run_${rt}_xr"; rc=$?
		if [ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ $rc -eq 0 ]; then echo "=== xpair $2 PASS"; exit 0; fi
		echo "=== xpair $2 FAILED (runs $r1 / $r2, compare $rc)"
		exit 1
		;;
	boot|boot_short|keys|fdd_rd|fdd_wr|hdd|cd|cdda|cdda_load|akiko)
		SCEN=$1
		[ "${NOKICK:-0}" = 1 ] && [ "$1" != boot ] && die "NOKICK=1 is for boot only"
		setup
		if [ "${NOKICK:-0}" = 1 ]; then nokick; else scenario "$1"; fi
		exit $?
		;;
	*) echo "unknown target $1 (run.sh --help)"; exit 2 ;;
esac
