#!/bin/bash
# L3 bench: the host CPU (bridge, cfide) with the real Minimig SPI slaves
# (userio_osd, paula_floppy, gayle) boots the real boot ROM and firmware from
# an SD card image.  See tb_l3.v, scenarios.vh, README.md.
#
#   bash sim/l3/run.sh <scenario>        boot, boot_short, keys, fdd_rd, fdd_wr, hdd,
#                                        cd, cdda, cdda_load, akiko; sdc_boot,
#                                        sdc_boot_short, sdc_hdd (SD_ENGINE=1)
#   bash sim/l3/run.sh xpair <scenario>  the scenario and its XRAND twin
#                                        (run_$RUNTAG, run_${RUNTAG}_xr; in
#                                        parallel), then compare: both PASS
#                                        and SAME
#   bash sim/l3/run.sh compare <RUNTAG a> <RUNTAG b>
#                                        every tb_*.log and spi.txt of both
#                                        run directories (sim/common/hostsim.sh
#                                        hs_compare; exit 1 unless all SAME)
#
# The host CPU is rv_hostcpu (VexRiscv RV32IMC) with the boot ROM
# fw/ctrl_boot and the firmware RV32OSDB.BIN (fw/ctrl; the name:
# fw/ctrl/fwname.mk, read through hostsim.sh's hs_fwname); the logs say
# "=== CPU rv".
#
# Environment:
#   SIM      xsim (default, 4-state, the X-checking reference) or verilator
#            (GHDL --synth converts the VHDL, as sim/host_bridge)
#   RUNTAG   run directory sim/l3/run_${RUNTAG:-wt}; a new one per code change
#   FW       a firmware image to put on the card (as RV32OSDB.BIN); default: built from
#            fw/ctrl into <run>/fwrv under a date shim (hs_fwrv, L3_DATE)
#   L3_DATE  the date of the firmware build (default 2026-01-01)
#   EXTRA_WS the bridge's rv_extra_ws (0)
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
#            include files, the ROM, the tools' versions, EXTRA_WS,
#            XRAND; <run>/buildkey_<snapshot>, written by every Verilator
#            build) equals this run's; else it builds its own (results.txt
#            says so).  Plusargs (the
#            scenario, the card, skew, FAST_HW, SLAT, SJIT) are not build
#            inputs (sim/l3/grid.sh)
#   TIMEOUT  clk_114 cycles (default per scenario below), at most
#            2147483647 (tb_l3.v's integer)
#   L3CHECK  tests of run.sh only: the l3check.py to run (default sim/l3's)
#   EXPECT_RETRY, EXPECT_RETRY_N  sdc_* with an injection (+SD_ERR_ in
#            XARGS): the ERE every retry line on the UART must match (the
#            firmware's "SD: <row>, row <r>, retry <k> of <n>, lba <l>", the
#            ROM's "SD read <lba>: <what> <v>, try <t>") and their exact
#            count (default 1); required with an injection (README "sdc")
#   SD_ENGINE=1  the SD card engine wired in (tb_l3.v `SD_ENGINE: sdcard_spi on
#            cfide's ext port with the card on its pins, sdcard_gayle + mux
#            between paula_floppy and gayle, as minimig_virtual_top with
#            SD_ENGINE = 1).  Default 0, except for the sdc_* scenarios,
#            which always run with it (SD_ENGINE=0 is refused there).  The
#            boot ROM since plan Task 12 needs the engine: the scenarios
#            without the sdc_ prefix stop in the ROM's "SD init" on this tree
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
#   sdc_boot, sdc_boot_short, sdc_hdd   boot, boot_short and hdd on the SD
#               card engine (SD_ENGINE=1; README "sdc"): the boot ROM and the
#               firmware reach the card through sdcard_spi, the HDD sectors
#               go through sdcard_gayle's DMA.  The bench runs +SCENARIO=boot,
#               boot_short or hdd; the checks are that scenario's, with
#               milestones_boot.txt's SDE=1 lines (the ROM's and the
#               firmware's SD lines) and MARGIN item 3 n/a (no direct-mode
#               transfer: the card is not on cfide's SPI), plus (sdc_check):
#               the lock-step line = fw/ctrl/sdc.h's SDC_VERSION on both
#               sides and the firmware file's trailer, no card frame (cs 02)
#               in spi.txt, the SD error lines (none without +SD_ERR_ in
#               XARGS; with it exactly EXPECT_RETRY_N (1) retry lines, all
#               matching EXPECT_RETRY, and nothing out of retries), sdc_hdd:
#               to_gayle / from_gayle words = the plan's sectors, no g_err.
#               +SD_ERR_AT=scenario (XARGS) counts the model's
#               +SD_ERR_<kind>=n from the main-loop milestone
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
# (sim/common/hostmon.vh +HW_LOG / +UART_LOG; hw.txt's MEM lines
# hashed from sdram.bin by l3check.py memhash), sdram.bin, milestones.txt,
# results.txt (with the wall time); fdd_wr also fdd_wr_<cyl>_<head>.hex (the
# write streams) and card_saved.img (the card as the run left it).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
L2="$ROOT/sim/host_bridge"
VIVADO_PATH=${VIVADO_PATH:-/opt/Xilinx/Vivado/2023.2}
SIM=${SIM:-xsim}
GHDL=${GHDL:-ghdl}
VERILATOR=${VERILATOR:-verilator}
JOBS=${JOBS:-$(nproc)}
case "$SIM" in
	xsim|verilator) ;;
	*) echo "SIM=$SIM: must be xsim or verilator"; exit 2 ;;
esac
# CPU: the RV is the only host CPU (a leftover CPU=rv is accepted)
[ "${CPU:-rv}" = rv ] || { echo "CPU=$CPU: the host CPU is the RV (rv_hostcpu) only"; exit 2; }
export LC_ALL=C LANG=C
export LD_LIBRARY_PATH="$HOME/lib/tinfo5${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
GHDLFLAGS="--std=93c --ieee=synopsys -fexplicit"
I2C_V="$ROOT/rtl/host/i2c_master_mmio.sv $ROOT/rtl/openaars/adv7511/i2c_master.v"
XW=${EXTRA_WS:-0}
SL=${SLAT:-8} SJ=${SJIT:-0}
run="$HERE/run_${RUNTAG:-wt}"
# the committed boot ROM (checked against git HEAD; the simulators read it
# as it is)
ROM="$ROOT/fw/ctrl_boot/OSDBoot_rv_ROM.vhd"

# the Minimig RTL the bench simulates (copied into <run>/src), after the
# board's global include (rtl/soc/openaars_defines.vh)
MM_FILES="rtl/soc/openaars_defines.vh rtl/minimig/userio_osd.v rtl/minimig/userio_osd_spi.v
          rtl/minimig/paula_floppy.v rtl/minimig/paula_floppy_fifo.v rtl/minimig/gayle.v
          rtl/minimig/gayle_port.v rtl/minimig/gayle_fifo.v rtl/minimig/minimig_syscontrol.v"
MM_INC="$ROOT/fpga/openaars"     # minimig_version.vh (the board's)
# SD_ENGINE=1 (header): the bridge joins the slaves; sdcard_spi.v (in the
# run copies from hs_copy_rtl) is compiled too
SDE=${SD_ENGINE:-0}
case "$SDE" in 0|1) ;; *) echo "SD_ENGINE=$SDE: must be 0 or 1"; exit 2 ;; esac
# the sdc_* scenarios run on the engine
case "${1:-}" in
	sdc_*)
		[ "${SD_ENGINE:-1}" = 1 ] || { echo "SD_ENGINE=$SD_ENGINE: the $1 scenario runs on the SD card engine only"; exit 2; }
		SDE=1 ;;
esac
[ "$SDE" = 1 ] && MM_FILES="$MM_FILES rtl/minimig/sdcard_gayle.v"

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
# sdc_*: as their base scenario, but no direct-mode transfer (item 3 must be
# n/a, sdc_check): the HDF sectors go through sdcard_gayle's DMA
MARGIN_REQ_sdc_boot=$MARGIN_REQ_boot
MARGIN_REQ_sdc_boot_short=$MARGIN_REQ_boot_short
MARGIN_REQ_sdc_hdd=$MARGIN_REQ_boot

# fdd_wr's tracks, in order (= scenarios.vh FDD_WPLAN, l3check.py
# FDD_WR_TRACKS): "<cylinder>:<head>[:<sector with a bad header checksum>]"
FDD_WR_PLAN="0:0 1:0 2:0 39:0 41:0 77:0 78:0 79:0 79:1 40:0:3"

# cycles per scenario (clk_114): 1.5 x the measured end event (README "boot",
# Verilator 2026-10-19: boot 158,155,012, boot_short 57,659,090; README
# "keys": 164,959,781); fdd_rd: 1.5 x the estimate of README "fdd_rd" (Task
# 13's measured end 393,222,555 plus bfm_floppy's drive-ready waits of Task
# 14: 500 ms after motor on and 15 ms per head change, 59 M: 452 M); fdd_wr:
# 1.5 x the estimate of README "fdd_wr" (470 M); hdd: 1.5 x the estimate
# 200 M (README "hdd"); cd: 1.5 x the estimate 210 M (measured, README
# "cd": 185,153,365); cdda, cdda_load: 1.5 x the estimate 345 M (the plan
# start as cd, then 7 halves of the board's 21.1 M and the refills;
# measured, README "cdda": 337,017,061); akiko: 520 M
L3_BOOT_TO=${L3_BOOT_TO:-237300000}
L3_SHORT_TO=${L3_SHORT_TO:-86500000}
L3_KEYS_TO=${L3_KEYS_TO:-247400000}
L3_FDD_TO=${L3_FDD_TO:-680000000}
L3_FDDW_TO=${L3_FDDW_TO:-700000000}
L3_HDD_TO=${L3_HDD_TO:-300000000}
L3_CD_TO=${L3_CD_TO:-315000000}
L3_CDDA_TO=${L3_CDDA_TO:-520000000}
L3_AKIKO_TO=${L3_AKIKO_TO:-520000000}
# sdc_*: 1.5 x the measured end events on the SD card engine (README "sdc",
# Verilator 2026-10-25: sdc_boot 131,750,230, sdc_boot_short 27,971,124,
# sdc_hdd 165,702,565 with a write retry, 165,090,989 without)
L3_SDC_BOOT_TO=${L3_SDC_BOOT_TO:-197700000}
L3_SDC_SHORT_TO=${L3_SDC_SHORT_TO:-42000000}
L3_SDC_HDD_TO=${L3_SDC_HDD_TO:-248600000}

# shellcheck source=../common/hostsim.sh
. "$ROOT/sim/common/hostsim.sh"
# every fatal step, hostsim.sh's hs_* included (they call hs_die), ends the
# run with the scenario's verdict line: no step failure is silent
hs_die() { echo "FAILED: $*"; echo "=== ${SCEN:-run.sh} FAILED"; exit 1; }
die() { hs_die "$@"; }
# the firmware's file name (fw/ctrl/fwname.mk): the build output's name and
# the name the card builder gives it on the card
FWNAME=$(hs_fwname) || die "fw/ctrl/fwname.mk: no 8.3 FW_FILE"
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

# l3_retire_tap: the run copy of rv_hostcpu.v gets a wire
# l3_retire = the VexOsd core's writeBack_arbitration_isFiring (one retired
# instruction), driven inside the DEBUG = 0 generate branch, for tb_l3.v's
# "=== RETIRED" count.  A reference from the bench into the branch does not
# resolve under Verilator 5.020 (every branch is labelled g_core, and the
# lookup does not pick the elaborated one); the wire is read from outside
# instead.  It drives nothing in the design; rtl/ is never edited
l3_retire_tap() {
	local v="$run/src/rv_hostcpu.v"
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
	[ "$SDE" = 1 ] && sed -i '1i `timescale 1ns/1ps' "$run/src/sdcard_spi.v"
	l3_pin_minimig
	l3_pin_async
	l3_retire_tap
	l3_rdy_mut
	l3_paula_txpop
	if [ -n "${FW:-}" ]; then
		FWBIN=$(realpath -m -- "$FW")
		[ -f "$FWBIN" ] || die "no firmware $FWBIN (FW=)"
	else
		hs_fwrv "$run"
		FWBIN="$run/fwrv/$FWNAME"
	fi
	[ "${NOKICK:-0}" = 1 ] && mk+=(NOKICK=1)
	# the card of the scenario (sim/l3/card): fdd_rd, fdd_wr and akiko the
	# fdd card, hdd the hdd card, cd the cd card with CDCFG's configs (image
	# cd.img or cd_iso.img), cdda the cd card (cue), cdda_load the cdhdd
	# card, the others boot.  MSCARD: milestones()'s "CARD=<card>" lines (cd:
	# cd_cue or cd_iso, the disc's files differ)
	CARDNAME=boot
	case "${BSCEN:-}" in fdd_rd|fdd_wr|akiko) CARDNAME=fdd ;; esac
	[ "${BSCEN:-}" = hdd ] && CARDNAME=hdd
	[ "${BSCEN:-}" = cd ] && CARDNAME=cd
	[ "${BSCEN:-}" = cdda ] && CARDNAME=cd
	[ "${BSCEN:-}" = cdda_load ] && CARDNAME=cdhdd
	case "${BSCEN:-}" in
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
	if [ "${BSCEN:-}" = fdd_wr ]; then
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
	        "$L2/verilator/romcheck.py" "$ROM" $I2C_V "$MM_INC"/*.vh "$ROOT"/rtl/minimig/*.vh "$HERE/run.sh")
	{
		echo "SIM=$SIM EXTRA_WS=$XW XRAND=${XRAND:-0} SD_ENGINE=$SDE generics=$CFIDE_GENERICS"
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
	# the core's files and define (rv_hostcpu's counters)
	local cpuv=(src/rv_hostcpu.v src/VexOsd.v) def=RV_HOSTCPU_STATS sdv=() sdd=()
	if [ "$SDE" = 1 ]; then sdv=(src/sdcard_spi.v); sdd=(-DSD_ENGINE); fi
	if [ "$SIM" = verilator ]; then
		# the L2 bench's black-box list and ROM check (HERE, for this call only)
		HS_DIR=$d HS_ROM=$ROM HS_VB=host_bridge.vhd HS_VC=cfide.vhd
		# shellcheck disable=SC2086
		HERE=$L2 hs_ghdl_convert "$run" "$XW" $CFIDE_GENERICS
		grep -qE '^ *i2c_master_mmio +[a-z0-9_]+ *\(' "$d/cfide.v" && i2c=$I2C_V
		HS_NAME=$snap HS_VLT="$HERE/l3.vlt"
		HS_VFLAGS="-GEXTRA_WS=$XW -I$ROOT/sim/common -I$HERE -I$MM_INC -I$ROOT/rtl/minimig"
		# shellcheck disable=SC2086
		hs_verilate "$run" tb_l3 "-DL3_GHDL -D$def ${sdd[*]}" \
			"$d/bridge.v" "$d/cfide.v" "${cpuv[@]}" "${sdv[@]}" src/hostcache.v src/dpram_inf_generic.v \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" $i2c \
			"${mm[@]}" "$HERE/bfm_audio.v" "$HERE/bfm_keys.v" "$HERE/bfm_floppy.v" "$HERE/bfm_ide.v" "$HERE/bfm_akiko.v" "$HERE/rtc_model.v" "$HERE/tb_l3.v"
		echo "$key" > "$run/buildkey_$snap"
	else
		X xvlog -sv $I2C_V
		X xvhdl src/cfide.vhd
		X xvlog -d "$def" "${cpuv[@]}" "${sdv[@]}" src/hostcache.v src/dpram_inf_generic.v
		X xvhdl src/host_bridge.vhd
		X xvhdl "$ROM"
		# --relax: rtl/minimig/gayle_port.v uses the wire err before its
		# declaration (an error for xvlog, accepted by synthesis and Verilator)
		X xvlog --relax -i "$MM_INC" -i "$ROOT/rtl/minimig" "${mm[@]}"
		[ "$SDE" = 1 ] && sdd=(-d SD_ENGINE)
		X xvlog -d "$def" "${sdd[@]}" -i "$ROOT/sim/common" -i "$HERE" \
			"$L2/sdram_host_model.v" "$ROOT/sim/common/sd_spi_model.v" "$HERE/bfm_audio.v" \
			"$HERE/bfm_keys.v" "$HERE/bfm_floppy.v" "$HERE/bfm_ide.v" "$HERE/bfm_akiko.v" "$HERE/rtc_model.v" "$HERE/tb_l3.v"
		hs_xsim_build "$run" "$snap" "$XW" tb_l3
	fi
}


# milestones <scenario> <log>: the milestone file of the scenario, spitrace
# check of its UART / SPI lines, and its "NOT UART <text>" lines.  A line
# "SDE=<0|1> <milestone>" is a milestone of that SD_ENGINE only (the boot
# ROM's and the firmware's SD lines), "CARD=<card> <milestone>" one of that
# card only: each is kept, without the prefix, for the run's engine (SDE)
# and the scenario's card (MSCARD) and dropped for the others (an SDE= line
# may carry a CARD= prefix after it).  The 't clr' after the SDE= step
# clears sed's substitution flag: without it a kept SDE= line (flag set by
# its own s///) took the CARD= step's 't' to the end of the script and -n
# dropped it -- every SDE= line was lost (Task 13 review)
milestones() {
	local s=$1 log=$2 ms="$run/milestones_$1.txt" t
	if [ "$s" = boot_short ]; then
		sed '/^#@ boot_short end/q' "$HERE/milestones_boot.txt"
	else
		cat "$HERE/milestones_boot.txt"
	fi | sed -n -e "s/^SDE=$SDE //" -e '/^SDE=/d' -e 't clr' -e ':clr' \
		-e "s/^CARD=${MSCARD:-boot} //p" -e t -e '/^CARD=/d' -e p > "$ms"
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

# sdc_check <scenario> <base> <log> (SDE=1): the SD card engine's checks
# (header, the sdc_* entry; README "sdc").  Prints ok / BAD lines.
#   - lock-step: fw/ctrl/sdc.h's SDC_VERSION is the trailer of the firmware
#     file on the card ('SDCV' 00 00 hi lo), the VERSION the ROM read ("SD
#     init: VERSION <v>, card 1") and both sides of the ROM's "Firmware SDC
#     <have>, bitstream SDC <need>" (fw/ctrl_boot/lockstep.c)
#   - no frame with sd_cs[1] low in spi.txt (cs 02: the card on cfide's
#     SPI) and MARGIN item 3 without events (no direct-mode transfer)
#   - the SD error lines on the UART (the ROM's "SD CMD<n>: R1 ..., try"
#     and "SD read <lba>: ..., try", "SD: SCK div 13"; the firmware's "SD:
#     ..." lines, "SD init: CMD10 / CMD9 <err>", "card changed", "CID
#     unreadable"): none unless XARGS injects (+SD_ERR_); with an
#     injection the retry lines (the firmware's "SD: <row>, row <r>, retry
#     <k> of <n>, lba <l>" or the ROM's "SD read <lba>: <what> <v>, try
#     <t>", each a failed try the ROM tries again: out of tries it stops
#     the boot, which the milestones see) exactly EXPECT_RETRY_N (1), all
#     matching EXPECT_RETRY, and none of "retries out", "op failed", "CMD13
#     probe", "card changed", "CID unreadable"
#   - "=== SDC gayle": no g_err; hdd: every card sector the plan moves to
#     or from the Amiga goes through the bridge, in words: to_gayle
#     SDC_HDD_RD_SECTORS x 256, from_gayle SDC_HDD_WR_SECTORS x 256 (README
#     "hdd": the plan reads 274 sectors, 3 of them built by the CPU: the
#     FakeRDB RDSK and PART and RDB.HDF's patched block 0; it writes 96);
#     boot, boot_short: no Gayle op
SDC_HDD_RD_SECTORS=271
SDC_HDD_WR_SECTORS=96
sdc_check() {
	local s=$1 b=$2 log=$3 v t w ls inj=0 rx re n
	v=$(sed -n 's/^#define SDC_VERSION 0x\([0-9A-Fa-f]\{4\}\).*/\1/p' "$ROOT/fw/ctrl/sdc.h" | tr a-f A-F)
	[ ${#v} = 4 ] || { echo "BAD  sdc: no SDC_VERSION in fw/ctrl/sdc.h"; return; }
	t=$(tail -c 8 "$FWBIN" | od -An -v -tx1 | tr -d ' \n' | tr a-f A-F)
	if [ "$t" = "534443560000$v" ]; then
		echo "ok   sdc: the firmware file's trailer SDCV 00 00 $v (fw/ctrl/sdc.h SDC_VERSION 0x$v)"
	else
		echo "BAD  sdc: the firmware file's last 8 bytes are $t, want 534443560000$v (SDCV 00 00, SDC_VERSION 0x$v)"
	fi
	if grep -qE "^UART: SD init: VERSION $v, card 1\$" "$log"; then echo "ok   sdc: the boot ROM read VERSION $v, card present"
	else echo "BAD  sdc: no UART line 'SD init: VERSION $v, card 1' (the ROM's)"; fi
	if grep -qF "Firmware SDC $v, bitstream SDC $v" "$log"; then
		echo "ok   sdc: lock-step 'Firmware SDC $v, bitstream SDC $v'"
	else
		echo "BAD  sdc: no lock-step line 'Firmware SDC $v, bitstream SDC $v': $(grep -m1 -E 'Firmware (SDC|does not match)' "$log" || echo none)"
	fi
	# a frame's first field is its cs byte (~sd_cs, bit 1 = sd_cs[1] low)
	n=$(grep -cE '^[0-9a-f][2367abef] ' "$run/spi.txt")
	if [ "$n" = 0 ]; then echo "ok   sdc: no frame with sd_cs[1] low in spi.txt (the card is not on cfide's SPI)"
	else echo "BAD  sdc: $n frames with sd_cs[1] low in spi.txt"; fi
	if grep -qE '^=== MARGIN 3 dmode_release min none ' "$log"; then echo "ok   sdc: MARGIN 3 without events (no direct-mode transfer)"
	else echo "BAD  sdc: MARGIN 3 saw direct-mode transfers: $(grep -m1 '^=== MARGIN 3 dmode_release' "$log")"; fi
	# cfide's SPI after the jump to the firmware: SPI_fast (speed 1: SCK 6
	# clk_114) in every frame but the RTC's (tb_l3.v "=== SPI SCK period");
	# the boot ROM leaves it at 0xef (fw/ctrl main.c, Task 13 finding)
	n=$(sed -n 's/^=== SPI SCK period after the firmware.s start (no RTC frame): min [0-9]* max \([0-9]*\) clk_114 over [1-9][0-9]* bits.*/\1/p' "$log")
	if [ -n "$n" ] && [ "$n" -le 6 ]; then echo "ok   sdc: cfide's SCK period after the firmware's start at most $n clk_114 (SPI_fast: 6)"
	else echo "BAD  sdc: cfide's SCK slower than SPI_fast (6 clk_114) after the firmware's start: $(grep -m1 '^=== SPI SCK period' "$log" || echo 'no SPI SCK line')"; fi
	case " ${XARGS:-} " in *" +SD_ERR_"*) inj=1 ;; esac
	# the UART's lines, each also cut at the firmware's '\r's (hostmon prints
	# them as the two characters \r: "Set Multiple Mode 16\rSD: read CRC,
	# ..." is one UART line)
	re='^(SD CMD[0-9]+: R1 |SD read [0-9]+: |SD: |SD init: (CMD10|CMD9) )|card changed|CID unreadable'
	ls=$(sed -n 's/^UART: //p' "$log" | sed 's/\\r/\n/g' | grep -E "$re")
	if [ "$inj" = 0 ]; then
		if [ -z "$ls" ]; then echo "ok   sdc: no SD error line on the UART"
		else printf '%s\n' "$ls" | head -20 | sed 's/^/BAD  sdc: SD error line without an injection: /'; fi
	else
		# every retry line (the firmware's row lines, the ROM's "try" lines)
		# must be the leg's: EXPECT_RETRY (an ERE on the SD line), exactly
		# EXPECT_RETRY_N (1) of them, and no other retry line
		rx=$(printf '%s\n' "$ls" | grep -E ', row [0-9]+, retry [0-9]+ of [0-9]+, lba |, try [0-9]+$')
		printf '%s\n' "$rx" | grep . | head -20 | sed 's/^/info sdc: retry line (injection): /'
		if [ -z "${EXPECT_RETRY:-}" ]; then
			echo "BAD  sdc: XARGS injects an SD error, but EXPECT_RETRY (the retry line the leg must give) is not set"
		else
			n=$(printf '%s\n' "$rx" | grep -cE -- "$EXPECT_RETRY")
			t=$(printf '%s\n' "$rx" | grep -c .)
			if [ "$n" = "${EXPECT_RETRY_N:-1}" ] && [ "$t" = "$n" ]; then
				echo "ok   sdc: $n retry line(s) matching EXPECT_RETRY '$EXPECT_RETRY', no other retry line"
			else
				echo "BAD  sdc: $n retry line(s) matching EXPECT_RETRY '$EXPECT_RETRY' (want ${EXPECT_RETRY_N:-1}), $t retry line(s) in all"
			fi
		fi
		printf '%s\n' "$ls" | grep -E 'retries out|op failed|CMD13 probe|card changed|CID unreadable' | head -20 \
			| sed 's/^/BAD  sdc: the injection ran out of retries: /'
		printf '%s\n' "$ls" | grep -vE ', row [0-9]+, retry [0-9]+ of [0-9]+, lba |, try [0-9]+$|retries out|op failed|CMD13 probe|card changed|CID unreadable' \
			| grep . | head -20 | sed 's/^/info sdc: other SD line: /'
	fi
	w=$(grep -E '^=== SDC gayle ' "$log")
	if [ -z "$w" ]; then echo "BAD  sdc: no '=== SDC gayle' line"; return; fi
	set -- $(printf '%s\n' "$w" | sed -n 's/^=== SDC gayle to_gayle \([0-9]*\) ops \([0-9]*\) words, from_gayle \([0-9]*\) ops \([0-9]*\) words, g_err \([0-9]*\), .*/\1 \2 \3 \4 \5/p')
	[ $# = 5 ] || { echo "BAD  sdc: cannot read '$w'"; return; }
	[ "$5" = 0 ] && echo "ok   sdc: no g_err" || echo "BAD  sdc: $5 Gayle errors (g_err)"
	if [ "$b" = hdd ]; then
		if [ "$1" -gt 0 ] && [ "$2" = $((SDC_HDD_RD_SECTORS * 256)) ]; then
			echo "ok   sdc: to_gayle $1 ops, $2 words = $SDC_HDD_RD_SECTORS sectors (READ / READ MULTIPLE through the bridge)"
		else
			echo "BAD  sdc: to_gayle $1 ops $2 words, want > 0 ops and $((SDC_HDD_RD_SECTORS * 256)) words ($SDC_HDD_RD_SECTORS sectors)"
		fi
		if [ "$3" -gt 0 ] && [ "$4" = $((SDC_HDD_WR_SECTORS * 256)) ]; then
			echo "ok   sdc: from_gayle $3 ops, $4 words = $SDC_HDD_WR_SECTORS sectors (WRITE / WRITE MULTIPLE through the bridge)"
		else
			echo "BAD  sdc: from_gayle $3 ops $4 words, want > 0 ops and $((SDC_HDD_WR_SECTORS * 256)) words ($SDC_HDD_WR_SECTORS sectors)"
		fi
	elif [ "$1$3" = 00 ]; then
		echo "ok   sdc: no Gayle op ($s)"
	else
		echo "BAD  sdc: Gayle ops in $s: to_gayle $1, from_gayle $3"
	fi
}

# scenario <name>: build, run, checks.  An sdc_<b> scenario is the bench's
# scenario b on the SD card engine (SDE=1): b's plusargs, card and checks
# (with b's timeout L3_SDC_<B>_TO), plus sdc_check
scenario() {
	local s=$1 b=${1#sdc_} to snap="tb_l3_x$XW" pa=() st x
	local log="$run/tb_${s}_x${XW}_s${SL}_j${SJ}.log"
	case "$b" in
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
	case "$s" in
		sdc_boot) to=${TIMEOUT:-$L3_SDC_BOOT_TO} ;;
		sdc_boot_short) to=${TIMEOUT:-$L3_SDC_SHORT_TO} ;;   # no SD_LOG: the xsim twin (compare) differs in its spacing
		sdc_hdd) to=${TIMEOUT:-$L3_SDC_HDD_TO}; pa+=("SD_LOG=1") ;;
	esac
	# tb_l3.v reads +TIMEOUT into a 32-bit integer: a larger value wraps
	# negative and ends the run at once (Task 19, grid run p4g_rv_ws64_fdd_rd)
	case "$to" in ''|*[!0-9]*) die "TIMEOUT=$to: not a number of cycles" ;; esac
	[ "${#to}" -lt 10 ] || [ "$to" -le 2147483647 ] || die "TIMEOUT=$to: above 2147483647 (tb_l3.v's 32-bit integer)"
	if git -C "$ROOT" diff --quiet HEAD -- "${ROM#$ROOT/}"; then st="unmodified (= git HEAD)"; else st="BAD  MODIFIED against git HEAD"; fi
	{
		echo "=== CPU rv"
		echo "boot ROM: ${ROM#$ROOT/} $st, sha256 $(sha256sum "$ROM" | cut -c1-16)"
		echo "firmware: $FWBIN, $(stat -c %s "$FWBIN") bytes, sha256 $(sha256sum "$FWBIN" | cut -c1-16)"
		echo "card: $CARD$( [ "${NOKICK:-0}" = 1 ] && echo " (NOKICK=1: no KICK.ROM)")"
		[ "${PAULA_TXPOP:-0}" = 1 ] && echo "PAULA_TXPOP=1: $(sed -n 's/^PAULA_TXPOP: //p' "$run/compile.log")"
		[ -n "${PATCH:-}" ] && echo "PATCH: $PATCHF, sha256 $(sha256sum "$PATCHF" | cut -c1-16)"
		[ "$b" = cd ] && echo "cd config: $CDCFG"
		echo "scenario: $s$( [ "$s" != "$b" ] && echo " (the bench's $b, SD_ENGINE=1)")"
	} | tee "$run/results.txt"
	build "$snap"
	# plusargs without the +: FAST_HW's model timing first (the first match
	# wins in $value$plusargs), then the run's, then XARGS
	case " ${XARGS:-} " in
		*" +FAST_HW=1 "*) pa=(SD_TOKEN_DLY=0 SD_BUSY=1 SD_NCR=1 SLAT=2 SJIT=0 "${pa[@]}") ;;
	esac
	pa+=("SCENARIO=$b" "SLAT=$SL" "SJIT=$SJ" "SEED=${SEED:-1}" "SD_IMG=$CARD" "TIMEOUT=$to"
	     "SPI_LOG=$run/spi.txt" "SPI_T_LOG=$run/spi_t.txt" "HW_LOG=$run/hw.txt" "UART_LOG=$run/uart.txt"
	     "SDRAM_DUMP=$run/sdram.bin")
	for x in ${XARGS:-}; do pa+=("${x#+}"); done
	local t0=$SECONDS
	hs_simrun "$run" "$snap" tb_l3 "$log" "${pa[@]}"
	local secs=$((SECONDS - t0))
	python3 -I "$L2/spitrace.py" summary "$run/spi.txt" > "$run/spi_summary.txt" 2>&1
	{
		grep -E '^=== (BOOT|MAIN|END|STATS|HW accesses|cycle limit|HandleFpga|SPI frames|SPI SCK|OSD GAP|OSD EARLY|OSD REPLY|STACK|RTC|KICK|MARGIN|KEYS script|FDD|IDE|CD|AKIKO block|SDC|SD_ERR)' "$log"
		grep -E '^BENCH ERROR' "$log" | sed 's/^/BAD  /'
		margins "$s" "$log"
		grep -q '^SD: image .* loaded' "$log" || echo "BAD  the SD model did not load $CARD"
		milestones "$b" "$log"
		grep -E '^UART: .*(EXC |TRAP )' "$log" | sed 's/^/BAD  /'
		l3_check memhash "$run/memhash.txt" '^PASS memhash: ' python3 -I "$L3CHECK" memhash "$run"
		if [ "$b" = boot ] || [ "$b" = keys ] || [ "$b" = fdd_rd ] || [ "$b" = fdd_wr ] || [ "$b" = hdd ] \
			|| [ "$b" = cd ] || [ "$b" = cdda ] || [ "$b" = cdda_load ] || [ "$b" = akiko ]; then
			l3_check kick "$run/kick.txt" '^PASS kick: ' python3 -I "$L3CHECK" kick "$run"
			l3_check order "$run/order.txt" '^PASS order: ' python3 -I "$L3CHECK" order "$run"
		fi
		[ "$b" = boot ] && l3_check mmc "$run/mmc.txt" '^PASS mmc: ' python3 -I "$L3CHECK" mmc "$run"
		[ "$SDE" = 1 ] && sdc_check "$s" "$b" "$log"
		if [ "$b" = keys ]; then
			l3_check keys "$run/keys.txt" '^PASS keys: ' python3 -I "$L3CHECK" keys "$run"
			grep -E '^REPLY ' "$run/keys.txt"
		fi
		if [ "$b" = fdd_rd ]; then
			l3_check fdd_rd "$run/fdd_rd.txt" '^PASS fdd_rd: ' python3 -I "$L3CHECK" fdd_rd "$run"
			grep -E '^ok   ' "$run/fdd_rd.txt"
		fi
		if [ "$b" = fdd_wr ]; then
			l3_check fdd_wr "$run/fdd_wr.txt" '^PASS fdd_wr: ' python3 -I "$L3CHECK" fdd_wr "$run"
			grep -E '^(ok   |HEADER )' "$run/fdd_wr.txt"
		fi
		if [ "$b" = hdd ]; then
			l3_check hdd "$run/hdd.txt" '^PASS hdd: ' python3 -I "$L3CHECK" hdd "$run"
			grep -E '^ok   ' "$run/hdd.txt"
		fi
		if [ "$b" = cd ]; then
			l3_check cd "$run/cd.txt" '^PASS cd: ' python3 -I "$L3CHECK" cd "$run"
			grep -E '^(ok   |INFO )' "$run/cd.txt"
		fi
		if [ "$b" = cdda ] || [ "$b" = cdda_load ]; then
			l3_check cdda "$run/cdda.txt" '^PASS cdda: ' python3 -I "$L3CHECK" cdda "$run"
			grep -E '^(ok   |INFO )' "$run/cdda.txt"
		fi
		if [ "$b" = akiko ]; then
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
	if grep -qE '^BAD  SPI(>=[0-9]+)? 10 00 00 00 00 00 00' "$run/milestones.txt" \
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
	boot|boot_short|keys|fdd_rd|fdd_wr|hdd|cd|cdda|cdda_load|akiko|sdc_boot|sdc_boot_short|sdc_hdd)
		SCEN=$1 BSCEN=${1#sdc_}
		[ "${NOKICK:-0}" = 1 ] && [ "$1" != boot ] && die "NOKICK=1 is for boot only"
		setup
		if [ "${NOKICK:-0}" = 1 ]; then nokick; else scenario "$1"; fi
		exit $?
		;;
	*) echo "unknown target $1 (run.sh --help)"; exit 2 ;;
esac
