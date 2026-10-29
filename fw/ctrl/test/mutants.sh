#!/usr/bin/env bash
# Mutants of the host tests (make -C fw/ctrl/test mutants).
#
# A mutant is a sed on a fresh copy of the firmware sources (mut/<name>/src),
# the test sources (mut/<name>/t) or the gold files (mut/<name>/gold); the
# copy is built and run by the Makefile's own targets (SRC= TD= GOLD= B=
# point it at the copy), so the check that must turn red is the real one.
#   killed    the build of the mutant succeeded and the real test target failed
#   SURVIVED  the build succeeded and the test target passed
#   BROKEN    the sed changed nothing, or the mutant does not build (a build
#             failure is never a kill: the test did not run)
# -Wno-error: a mutant must be killed by the test, not by an unused-variable
# warning.  Every run starts from a fresh copy; mut/<name>/log keeps the last
# output.  The controls (the unmutated copy) build and pass first.
# Environment: ISO, HOSTCC (make -C fw/ctrl/test mutants passes them);
# ONLY=<extended regex>: only the unit mutants whose name matches (the
# controls still run; a partial run while working on one test).
set -u
cd "$(dirname "$0")" || exit 1
HERE=$PWD
CARD=$HERE/out/card.img
# the fat_test images, built once from the unmutated scripts (FATIMG_DEPS=: as they are)
FATIMG=$HERE/out
bad=0
nkilled=0

# one make in the test directory, quiet, on the copy of mutant $1
mk() {
  local n=$1; shift
  make -s -f Makefile SRC="mut/$n/src" TD="mut/$n/t" GOLD="mut/$n/gold" B="mut/$n/b" \
       WERROR=-Wno-error CARD="$CARD" FATIMG="$FATIMG" FATIMG_DEPS= "$@"
}

# prep <name>: fresh copies
prep() {
  local n=$1
  rm -rf "mut/$n"
  mkdir -p "mut/$n/src" "mut/$n/t"
  cp ../*.c ../*.h ../check_io.awk "mut/$n/src/"
  cp -r ../arch "mut/$n/src/arch"
  mkdir -p "mut/$n/src/tools"
  cp -r ../tools/cfgconv "mut/$n/src/tools/cfgconv"
  cp ./*.c ./*.h ./*.sh "mut/$n/t/"
  cp -r check_io "mut/$n/t/check_io"
  cp -r gold "mut/$n/gold"
}

# mutate <name> <src|t|gold> <file> <sed expression>: 0 = changed
mutate() {
  local n=$1 where=$2 file=$3 orig
  case $where in src) orig=../$file ;; t) orig=./$file ;; gold) orig=gold/$file ;; esac
  sed -i "$4" "mut/$n/$where/$file"
  if cmp -s "$orig" "mut/$n/$where/$file"; then
    echo "mutant $n: BROKEN (the sed changed nothing)"; bad=1; return 1
  fi
}

verdict() {  # <name> <rc of the check> <what>
  if [ "$2" -ne 0 ]; then echo "mutant $1: killed ($3)"; nkilled=$((nkilled + 1))
  else echo "mutant $1: SURVIVED ($3 passed)"; bad=1; fi
}

# unit <name> <test> <src|t|gold> <file> <sed> [text...]: the test must fail,
# native; with [text], a failure whose log does not hold it (each of them,
# when there are several) is BROKEN (the mutant must be killed by that case)
unit() {
  local n=$1 test=$2
  if [ -n "${ONLY:-}" ] && ! [[ $n =~ $ONLY ]]; then return; fi
  prep "$n"; mutate "$n" "$3" "$4" "$5" || return
  if ! mk "$n" "mut/$n/b/$test" > "mut/$n/log" 2>&1; then
    echo "mutant $n: BROKEN (does not build: mut/$n/log)"; bad=1; return
  fi
  # a mutant may hang a loop that waits for the mock: the timeout is a kill.
  # 300 s: hdd_card_error needs ~106 s of CPU before its own hang check
  # speaks, more under nice 19 on a loaded machine (120 s cut it short)
  timeout 300 make -s -f Makefile SRC="mut/$n/src" TD="mut/$n/t" GOLD="mut/$n/gold" B="mut/$n/b" \
       WERROR=-Wno-error CARD="$CARD" FATIMG="$FATIMG" FATIMG_DEPS= "run64-$test" > "mut/$n/log" 2>&1
  local rc=$? text
  if [ $rc -ne 0 ]; then
    for text in "${@:6}"; do
      if ! grep -q -- "$text" "mut/$n/log"; then
        echo "mutant $n: BROKEN (run64-$test failed, but not with \"$text\": mut/$n/log)"; bad=1; return
      fi
    done
  fi
  verdict "$n" $rc "run64-$test"
}

# fmt <name> <src|t|gold> <file> <sed> [expected text in the output]
fmt() {
  local n=$1
  prep "$n"; mutate "$n" "$2" "$3" "$4" || return
  if ! mk "$n" "mut/$n/b/fmt_glibc_64.txt" "mut/$n/b/fmt_glibc_32.txt" > "mut/$n/log" 2>&1; then
    echo "mutant $n: BROKEN (producers do not build: mut/$n/log)"; bad=1; return
  fi
  mk "$n" fmt > "mut/$n/log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && [ -n "${5:-}" ] && ! grep -q -- "$5" "mut/$n/log"; then
    echo "mutant $n: BROKEN (fmt failed, but not with \"$5\": mut/$n/log)"; bad=1; return
  fi
  verdict "$n" $rc "make fmt"
}

# checkio <name> <src|t> <file> <sed> [expected text]: the check_io fixture
# target (check_io.awk on check_io/*.dis) must fail
checkio() {
  local n=$1
  prep "$n"; mutate "$n" "$2" "$3" "$4" || return
  mk "$n" check_io > "mut/$n/log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && [ -n "${5:-}" ] && ! grep -q -- "$5" "mut/$n/log"; then
    echo "mutant $n: BROKEN (check_io failed, but not with \"$5\": mut/$n/log)"; bad=1; return
  fi
  verdict "$n" $rc "make check_io"
}

# controls: the unmutated copy passes every test target
control() {
  prep control
  local t rc=0
  for t in mock_selftest cue_test cdaudio_test atapi_test cdrom_test openhf_test lib_test hwmap_test spireply_test diskstat_test swap_test fat_test mmc_test config_test hdd_test cdpath_test fdd_test drivesounds_test boot_test sdc_test sdproto_test rom_test osd2_test ui_test migrate_test; do
    mk control "run64-$t" > "mut/control/log.$t" 2>&1 || { echo "control: run64-$t FAILED (mut/control/log.$t)"; rc=1; }
  done
  mk control fmt > mut/control/log.fmt 2>&1 || { echo "control: fmt FAILED (mut/control/log.fmt)"; rc=1; }
  mk control check_io > mut/control/log.check_io 2>&1 || { echo "control: check_io FAILED (mut/control/log.check_io)"; rc=1; }
  if [ $rc -ne 0 ]; then echo "=== MUTANTS FAILED (the unmutated copy is red)"; exit 1; fi
  echo "controls: the unmutated copy passes"
}

mkdir -p out
# (the targets as the Makefile names them: out/card.img is $(B)/card.img)
make -s -f Makefile out/card.img > /dev/null || { echo "no card image"; exit 1; }
make -s -f Makefile FATIMG="$FATIMG" "$FATIMG/fatimg.ok" > /dev/null || { echo "no fat_test images"; exit 1; }
control

# ---- the C library: format parity (Task 3) -----------------------------------
# the real fmt.ok comparison runs on the mutant
fmt buf16 src rvlibc.h 's/^#define RV_PRINTF_BUF .*/#define RV_PRINTF_BUF 16/' "disagrees"
fmt model_upper gold fmtcheck.py "s/digs = '0123456789abcdef' if c == 'x'/digs = '0123456789ABCDEF' if c == 'x'/" "disagrees"
fmt formats_stale gold formats.txt '$d' "differ\|EOF"
# (a format still in the sources: the classic menu's "          1 %s" went in
# OSD Phase 6, and a case of a format nobody uses is no gap)
fmt cover_case t fmt_cases.h '/^FMT_CASE("  Start: %ld"/d' "no case"

# ---- lib_test ----------------------------------------------------------------
unit notrunc lib_test src rvlibc.c 's/rv_printf_truncations++;/;/'
unit sendfull lib_test src rvlibc.c 's/send = size - 1;/send = size;/'
unit nonest lib_test src rvlibc.c 's/char \*buf = depth ? printf_irq_buf : printf_buf;/char *buf = printf_buf;/; s/size_t size = depth ? sizeof printf_irq_buf : sizeof printf_buf;/size_t size = sizeof printf_buf;/'
unit nodepthrestore lib_test src rvlibc.c 's/printf_depth = depth;/;/'
unit heapcount lib_test src rvlibc.c 's/rv_libc_heap_calls++;/;/'
unit retval lib_test src rvlibc.c 's/return n;/return 0;/'

# ---- the CD tests ------------------------------------------------------------
unit cue_msf cue_test src cue.c 's/\* 75 + f;/* 75 + f + 1;/'
unit cue_sec59 cue_test src cue.c 's/sec > 59/sec > 60/'
unit cue_audio_tail cue_test src cue.c 's/(type == CD_AUDIO \&\& bytes % size) ? 1 : 0/(type == CD_AUDIO \&\& bytes % size) ? 0 : 0/'
unit cdaudio_frames cdaudio_test src cdaudio.c 's/cda.played \* 256;/cda.played * 255;/'
unit cdaudio_vol cdaudio_test src cdaudio.c 's/left > 255 ? 255 : left/left > 255 ? 254 : left/'
unit atapi_capacity atapi_test src atapi.c 's/put32(atapi_buf + 4, ATAPI_SECTOR_SIZE)/put32(atapi_buf + 4, ATAPI_SECTOR_SIZE + 1)/'
unit atapi_msf atapi_test src atapi.c 's/p\[3\] = (uint8_t)(f % 75);/p[3] = (uint8_t)(f % 74);/'
unit cdrom_marker cdrom_test src cdrom.c 's/CD_PRESENT_CUE ? "CUE" : "ISO"/CD_PRESENT_CUE ? "ISO" : "CUE"/'
unit openhf_cdslot openhf_test src hdd.c '/case HDF_CDROM:/,/return 0;/ s/return 0;/hf->present = 0; return 0;/'

# ---- byte order (swap_test) and FAT/MBR (fat_test) ---------------------------
unit swap_rdle32 swap_test src swap.h 's/(uint32_t)b\[3\] << 24;/(uint32_t)b[3] << 16;/'
unit swap_wrbe16 swap_test src swap.h 's/b\[0\] = (uint8_t)(v >> 8);/b[0] = (uint8_t)v; b[1] = (uint8_t)(v >> 8); return;/'
unit swap_be32 swap_test src swap.h 's/static inline uint32_t be32(uint32_t v) { return swap_bytes32(v); }/static inline uint32_t be32(uint32_t v) { return v; }/'
unit swap_le16 swap_test src swap.h '0,/static inline uint16_t le16(uint16_t v) { return v; }/s//static inline uint16_t le16(uint16_t v) { return swap_bytes16(v); }/'
unit swap_signext swap_test src swap.c 's/\tunsigned long result=(i>>24)\&0xff;/\tint result=(i>>24)\&0xff;/'
# the brief's mutant: StartCluster read with the 68000 swap again -> the listing
unit fat_startcluster fat_test src fat.c 's/le16(pEntry->StartCluster)/SwapBB(pEntry->StartCluster)/g'
unit fat_startcluster_scan fat_test src fat.c 's/pEntry->StartCluster = le16(pEntry->StartCluster);/pEntry->StartCluster = SwapBB(pEntry->StartCluster);/'
unit fat_filesize fat_test src fat.c 's/pEntry->FileSize = le32(pEntry->FileSize);/pEntry->FileSize = SwapBBBB(pEntry->FileSize);/'
unit fat_link16 fat_test src fat.c 's/unsigned long next = le16(fat_buffer.fat16\[i\]);/unsigned long next = SwapBB(fat_buffer.fat16[i]);/'
unit fat_link32 fat_test src fat.c 's/le32(fat_buffer.fat32\[i\]) \& 0x0FFFFFFF : le16/SwapBBBB(fat_buffer.fat32[i]) \& 0x0FFFFFFF : le16/'
unit fat_eoc32 fat_test src fat.c 's/= le32(0x0FFFFFFF);/= 0xFFFFFF0F;/'
unit fat_mbr_sig fat_test src fat.c 's/case 0x55aa:/case 0xFFFF0:/; s/case 0xaa55:/case 0x55aa:/; s/case 0xFFFF0:/case 0xaa55:/'
unit fat_newcluster fat_test src fat.c 's/pEntry->StartCluster = le16((unsigned short)cluster);/pEntry->StartCluster = SwapBB(cluster);/'
unit fat_newsize fat_test src fat.c 's/^      pEntry->FileSize = le32(file->size); \/\/ little-endian on disk/      pEntry->FileSize = SwapBBBB(file->size);/'
# HighCluster (FAT32 HIGH.BIN and NEWFILE.BIN above cluster 65535): every read,
# FileOpen's alone, and FileCreate's write (fat.c:1648)
unit fat_highcluster fat_test src fat.c 's/le16(pEntry->HighCluster)/SwapBB(pEntry->HighCluster)/g' "fat32"
unit fat_highcluster_open fat_test src fat.c 's/file->start_cluster = le16(pEntry->StartCluster) + (fat32 ? (le16(pEntry->HighCluster)/file->start_cluster = le16(pEntry->StartCluster) + (fat32 ? (SwapBB(pEntry->HighCluster)/' "HIGH.BIN"
unit fat_highcluster_new fat_test src fat.c 's/pEntry->HighCluster = fat32 ? le16((unsigned short)(cluster >> 16)) : 0;/pEntry->HighCluster = fat32 ? SwapBB(cluster >> 16) : 0;/' "fat32"
# FileCreate's dates: ModifyDate by mdir (fat_check.sh), CreateDate by the raw entry
unit fat_modifydate fat_test src fat.c 's/pEntry->ModifyDate = le16(FILEDATE(2009, 9, 1));/pEntry->ModifyDate = SwapBB(FILEDATE(2009, 9, 1));/' "mdir: NEWFILE.BIN is not"
unit fat_createdate fat_test src fat.c 's/pEntry->CreateDate = le16(FILEDATE(2009, 9, 1));/pEntry->CreateDate = SwapBB(FILEDATE(2009, 9, 1));/' "FAIL entry CreateDate"
# GetFATLink (fat.c:1366): the second cluster of "Many Long Names" (DELTA) and FAT32's root chain
unit fat_getfatlink fat_test src fat.c 's/return(fat32 ? le32(fat_buffer.fat32\[buffer_index\]) \& 0x0FFFFFFF : le16(fat_buffer.fat16\[buffer_index\]));/return(fat32 ? SwapBBBB(fat_buffer.fat32[buffer_index]) \& 0x0FFFFFFF : SwapBB(fat_buffer.fat16[buffer_index]));/'

# ---- the SD protocol and mmc.c on it (sdproto_test, mmc_test; sdcard-engine Task 10)
# the plan's two: a retry count off by one, the read CRC result ignored
unit sdp_rdcrc_retries sdproto_test src sdproto.c 's/if (s.rd_crc >= 4) {/if (s.rd_crc >= 3) {/' "FAIL read_crc_exhaust: 5 read CRC errors"
unit sdp_crc_ignored sdproto_test src sdproto.c 's/if (!(st \& SDC_ST_CRC_OK)) {/if (0) {/' "FAIL read_crc_retry: data right"
# the other rows' retry counts, the SCK step at the 3rd retry
unit sdp_wrcrc_retries sdproto_test src sdproto.c 's/if (s.wr_crc >= 4) {/if (s.wr_crc >= 5) {/' "FAIL write exhaust: err"
unit sdp_cmd_retries sdproto_test src sdproto.c '/^static void cmd_fail(/,/^}/ s/if (\*n < 3) {/if (*n < 2) {/' "FAIL timeout_cmd13_gone: R1 timeouts 4"
unit sdp_slower_at sdproto_test src sdproto.c 's/if (s.rd_crc == 3)/if (s.rd_crc == 4)/' "FAIL read_crc_exhaust: the SCK line with retry 3"
# CRC on, CRC7, the TX keep (a retry without TX_REWIND sends what follows the block)
unit sdp_nocmd59 sdproto_test src sdproto.c 's/r1 = icmd(59, 1, 0, 0);/r1 = icmd(59, 0, 0, 0);/' "FAIL init_crc_on: the card checks CRCs"
unit sdp_crc7 sdproto_test src sdproto.c 's/((((c >> 6) ^ (b >> 7)) \& 1) ? 0x09 : 0)/((((c >> 6) ^ (b >> 7)) \& 1) ? 0x0B : 0)/' "FAIL init_crc_on: sd_init = SDHC"
unit sdp_norewind sdproto_test src sdproto.c 's/^\t\tstart(SDC_OP_TX_REWIND, 0);$/\t\t;/' "sdc_wait: the mock can make no progress"
# CMD25: no ACMD22 resume after a rejected block; an abandoned Gayle read
# reported as a card error; card gone mid-op not seen
unit sdp_noresume sdproto_test src sdproto.c 's/s.retry22 = 1;/s.retry22 = 0;/' "FAIL cmd25_acmd22"
unit sdp_noabandon sdproto_test src sdproto.c 's/s.fail = SD_E_GAYLE;/s.fail = SD_E_RETRIES;/' "FAIL gayle abandon: SD_E_GAYLE"
unit sdp_gone sdproto_test src sdproto.c 's/if (s.gone || (st \& SDC_ST_GONE)) {/if (s.gone) {/' "FAIL gone: SD_E_GONE"
unit sdp_noprobe sdproto_test src sdproto.c '/^static void cmd_fail(/,/^}/ s/^\tprobe();$/\tfinish(SD_E_GONE);/' "FAIL cmdcrc exhaust: err"
# the bounds (design 11): one unit off each (mmc_test, in peripheral time),
# and under the spec's maxima (sdproto_test busy_500ms, token_100ms)
unit sdp_t_ncr mmc_test src sdproto.c 's/^#define T_NCR    16$/#define T_NCR    15/' "FAIL no answer: MMC_Read: ended after"
unit sdp_t_token mmc_test src sdproto.c 's/^#define T_TOKEN  1732$/#define T_TOKEN  1731/' "FAIL no token: MMC_Read: ended after"
unit sdp_t_busy mmc_test src sdproto.c 's/^#define T_BUSY   6926$/#define T_BUSY   6927/' "FAIL busy for ever: MMC_Write: ended after"
unit sdp_t_token_spec sdproto_test src sdproto.c 's/^#define T_TOKEN  1732$/#define T_TOKEN  600/' "FAIL token_100ms: no error"
unit sdp_t_busy_spec sdproto_test src sdproto.c 's/^#define T_BUSY   6926$/#define T_BUSY   3000/' "FAIL busy_500ms: no timeout"
# mmc.c: the OSD's error, the Gayle port of a to-Gayle read
unit mmc_noseterror mmc_test src mmc.c 's/SetError(ERROR_SDCARD, (char \*)what, (int)(op->lba + op->done_blocks), MMCErr);/;/' "ERROR_SDCARD set, not fatal"
unit mmc_port mmc_test src mmc.c 's/op.port = ide_port \& 1;/op.port = 0;/' "FAIL ... 512 bytes there"

# ---- Task 10 fix round 1 (sdproto_test, mmc_test, hdd_test, cdrom_test, rom_test, fdd_test, config_test, boot_test)
# a read of the file's last cluster: FileReadEx 0 at the end of the chain (blocks left only); FileSeek storing the EOC mark
# (since Task 11a hdd.c reads by its own runs, not FileReadEx: fat_test's case)
unit fat_readex_end fat_test src fat.c 's/\&\& (nSize > bc || MMCErr != SD_OK))/\&\& 1)/' "FAIL FileReadEx(the whole last cluster): 1"
# fix round 3: a card error in FileReadEx's last seek dropped; a write ending at the file's last sector failed; a short chain indexed
unit fat_readex_mmcerr fat_test src fat.c 's/\&\& (nSize > bc || MMCErr != SD_OK))/\&\& nSize > bc)/' "FAIL FileReadEx(cluster 2), its FAT read fails: 0"
unit hdd_index_short hdd_test src hdd.c 's/if (!FileSeek(file, i >> 9, SEEK_SET)) \/\/ FileSeek seeks in 512-byte sectors/FileSeek(file, i >> 9, SEEK_SET); if (0)/' "FAIL short chain: OpenHardfile(1) fails"
unit cd_eoc cdrom_test src cdrom.c '/^\tcase C_SEEK:/,/^\tcase C_PHASE:/ s/if (r < 0) {/if (r == -1) {/' "the end of the file's chain"
# fix round 2: sectors past the end of the HDF served / written from its last cluster
unit hdd_past_end_rd hdd_test src hdd.c 's/lba + hdf\[unit\].offset + sector_count > (long)(hdf\[unit\].file.size >> 9)/0/' "FAIL past the end: READ SECTORS 8191+2"
unit hdd_past_end_wr hdd_test src hdd.c 's/lba + hdf\[unit\].offset + sector_count > (long)(hdf\[unit\].file.size >> 9))/!write \&\& &/' "FAIL past the end: WRITE SECTORS 8191+2"
unit fat_eoc_cluster fat_test src fat.c 's/if (next == 0xFFFF) \/\/ FAT16 EOC/if ((file->cluster = next) == 0xFFFF) \/\/ FAT16 EOC/' "FAIL FileSeek(past the end): 0"
# the card swap: no CID compare, the lock not sticky, the OSD's text
unit sdp_nocid sdproto_test src sdproto.c 's/if (inited \&\& (op.err || !cid_known || memcmp(cid, sd_cid, 16))) {/if (0) {/' "FAIL cid: another card: read SD_E_GONE"
unit sdp_cid_unsticky sdproto_test src sdproto.c 's/^\tif (changed) {\t\t\t\/\* another card: nothing goes to it \*\/$/\tif (0) {/' "FAIL cid: write SD_E_GONE"
unit mmc_changed_msg mmc_test src mmc.c 's/SetError(ERROR_SDCARD, "SD card changed - reboot"/SetError(ERROR_SDCARD, "SD card read"/' "FAIL swap: the OSD's error"
# the idle bit, the ACMD22 loss bound (a hang: the 120 s timeout), the probe's line, the SCK floor
unit sdp_noidle sdproto_test src sdproto.c 's/if (r \& 0x01) {\t\t\/\* idle/if (0) {\t\t\/* idle/' "FAIL reset: read SD_E_RESET"
unit sdp_noloss_bound sdproto_test src sdproto.c 's/if (s.lost >= 4) {/if (0) {/'
unit sdp_probe_line sdproto_test src sdproto.c 's/printf("SD: CMD13 probe: no answer, lba %lu\\n", err_lba());/;/' "FAIL timeout_cmd13_gone: the probe's line"
unit sdp_floor sdproto_test src sdproto.c 's/if (sd_sck_step >= SD_SCK_STEPS - 1 || sdc_set_div(sd_sck_divs\[sd_sck_step + 1\]))/if (sd_sck_step >= SD_SCK_STEPS)/'
# ROM loads: the block read, the copies, the key file
unit rom_sendfile rom_test src fpga.c 's/if (!RARead(file, adr, 512)) {/if (!RARead(file, adr, 512) \&\& 0) {/' "FAIL block read fails"
unit rom_upload rom_test src config.c 's/if (!SendFileV2(\&romfile, NULL, 0, 0xf80000, romfile.size>>9))/if (!SendFileV2(\&romfile, NULL, 0, 0xf80000, romfile.size>>9) \&\& 0)/' "FAIL block read fails: UploadKickstart 0"
unit rom_key rom_test src config.c 's/if (!RARead(\&romfile, \&romkey\[0\],romfile.size)) {/if (0) {/' "FAIL ... the message"
# the floppy: the wrong checksum, the lost position, the write error; the config read; the copper list
unit fdd_badsum fdd_test src fdd.c 's/^        checksum\[3\] ^= 0x01;/        ;/' "FAIL read error: sector 3's data checksum"
unit fdd_lost fdd_test src fdd.c 's/bad = lost || !FileRead(\&file, sector_buffer);/bad = !FileRead(\&file, sector_buffer);/' "FAIL FAT error"
unit fdd_wrerr fdd_test src fdd.c 's/SetError(ERROR_FDD, "Floppy write error", drive->track, sector);/;/' "the card fails the 2nd write"
unit cfg_readerr config_test src config.c 's/if (file.size <= sizeof(config) \&\& !FileRead(\&file, sector_buffer))/if (file.size <= sizeof(config) \&\& (FileRead(\&file, sector_buffer), 0))/' "FAIL (f) the message"
unit boot_copper_err boot_test src boot.c 's/if (!RAOpen(\&file, COPPER_FILE) || !RARead(\&file, adr, COPPER_SIZE)) {/if (!RAOpen(\&file, COPPER_FILE) || (RARead(\&file, adr, COPPER_SIZE), 0)) {/' "FAIL COPPER_FILE read error"

# ---- the config file's byte order (config_test) ------------------------------
# the brief's mutant: cfg_swap without hdfdir[3] -> its field differs in cfgconv's RV file
unit cfg_swap_hdfdir3 config_test src cfgswap.c 's/^\tCFG_OFF_HDFDIR + 12,$/\t/' "cfgconv --check distinct.rv: other fields"
unit cfg_order_be config_test src cfgswap.c 's/^\t\treturn CFG_BE;$/\t\treturn CFG_BAD;/' "FAIL: cfgconv --check defaults.cfg"
# LoadConfiguration: the BE file not swapped, saved over, the old names, no message, no fallback
unit cfg_noswap config_test src config.c 's/^\t\t\t\tcfg_swap(sector_buffer);/\t\t\t\t;/' "FAIL (b) LoadConfiguration slot 0"
unit cfg_savebe config_test src config.c 's/SaveConfiguration(filename);\t\/\/ creates/SaveConfiguration((char *)oldname);\t\/\/ creates/' "FAIL (b): MINMGAA CFG data cluster unchanged"
unit cfg_namebe config_test src config.c 's/"MINMGAR%dCFG"/"MINMGAA%dCFG"/; s/"MINMGAR CFG"/"MINMGAA CFG"/' "FAIL (a) LoadConfiguration"
unit cfg_nomsg config_test src config.c 's/ConfigMessage("(832 byte order)");/;/' "FAIL (c) BootPrint: wrong format, BE byte order"
unit cfg_exists config_test src config.c 's/if ((oldname = OldConfigName(filename, oldbuf)) \&\& FileOpen(\&file, oldname))/if (0)/' "FAIL (b) ConfigurationExists(slot 0), BE file only"
unit cfg_anyorder config_test src config.c 's/if (oldname \&\& order!=CFG_BE)/if (0)/' "FAIL (e) LoadConfiguration"
# cfgconv's refusals (without the order check its internal check still refuses, with another message)
unit cfgconv_same config_test src tools/cfgconv/cfgconv.c 's/if (same_file(argv\[2\], argv\[3\])) {/if (0) {/' "wrote over its input"
unit cfgconv_order config_test src tools/cfgconv/cfgconv.c 's/if (order == to) {/if (0) {/' "FAIL: cfgconv --to-be defaults.cfg: cfgconv:"

# ---- the hard disk emulation (hdd_test) -------------------------------------
# the brief's two: the RDB checksum summed over native longs, IDENTIFY's strings unswapped
unit hdd_cksum hdd_test src hdd.c 's/result+=be32(p\[c2\]);/result+=p[c2];/' "FAIL FakeRDB small RDSK (unit 0)"
unit hdd_identswap hdd_test src hdd.c 's/pBuffer\[i\] = be16(pBuffer\[i\]);/;/' "FAIL IDENTIFY WORK.HDF long name"
# the patch of an HDF's own RDB on native longs
unit hdd_patch hdd_test src hdd.c 's/rdb->rdb_ChkSum = be32(be32(rdb->rdb_ChkSum) + be32(rdb->rdb_Flags) - 0x12);/rdb->rdb_ChkSum = rdb->rdb_ChkSum + rdb->rdb_Flags - 0x12;/' "FAIL WORK.HDF unit 0 lba 0 (own RDB, patched)"
# the FakeRDB boundary (hdd.c, Task 4's parenthesis): file block 0 taken for a fake one ...
unit hdd_boundary hdd_test src hdd.c 's/if (v < 0 || (hc.unit == 0/if (v <= 0 || (hc.unit == 0/' "FAIL ODD.HDF READ MULTIPLE 248+8: block 4 (lba 252)"
# ... and a card run not bounded by its group (Task 11a): more than a group
# into Gayle's FIFO (a refill before the drain), reads past the file
unit hdd_run_group hdd_test src hdd.c 's/return hc.grp < HDD_RUN_MAX ? hc.grp : HDD_RUN_MAX;/return HDD_RUN_MAX;/' "FAIL"

# sector count 0 = 256
unit hdd_count0 hdd_test src hdd.c 's/if (sector_count == 0) sector_count = 0x100;/if (sector_count == 0) sector_count = 0xFF;/' "FAIL ODD.HDF READ MULTIPLE 252+0 (256)"
# the mock bridge's words (RX_TO_GAYLE): the Gayle model's FIFO misses the card's blocks
unit mock_gayle_into hdd_test t mock_sdc.c 's/buf_put(\&gay.into\[port\], w, 2);/;/' "the firmware polls a Gayle that never gets ready"
# card errors end the ATA command with ERR; an abandoned read with nothing
unit hdd_card_error hdd_test src hdd.c '/^static void hdd_fail(/,/^}/ s/WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);/;/' "the command never ends"
# the brief's (Task 11a): an END | ERR after an abandon (the NEW command would end with it)
unit hdd_abandon hdd_test src hdd.c 's/if (hc.op.err == SD_E_GAYLE || hc.abandoned) {/if (0) {/' "FAIL abandoned: status RDY only" "FAIL wr_abandon: no status after the abandon"
unit cd_abandon cdrom_test src cdrom.c '/^\tcase C_RUN:/,/^\tcase C_WAIT:/ s/if (cc.op.err == SD_E_GAYLE)$/if (0)/' "an abandoned READ"

# ---- the interrupt-driven HDD data path (hdd_test, cdrom_test, sdproto_test; findings/sdcard-engine Task 11a)
# the brief's: an IRQ before the stop token's busy end (the op ends at the stop token, not after its busy)
unit hdd_irq_stopbusy hdd_test src sdproto.c '/case ST_STOP_TX:/,/return;/ s/waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_STOP_BUSY);/finish(s.fail);/' "every IRQ after its group was programmed"
# the brief's: the refill before the drain (the next group into the FIFO without waiting for hdd_cmd_req)
unit hdd_refill_early hdd_test src hdd.c 's/if (!(GetFPGAStatus() \& CMD_IDECMD)) \/\/ wait for empty sector buffer/if (0)/' "a refill before the drain"
# a write run started before the sector's hdd_dat_req (ruling T11-R1), and a go given before the previous block was taken
unit hdd_no_r1 hdd_test src hdd.c 's/if (!(st \& CMD_IDEDAT)) {\t\/\/ wait for full write buffer/if (0) {/' "no Gayle op started before its data was there"
unit sdp_go_early hdd_test src sdproto.c 's/!s.fail \&\& s.gsig == s.gtaken \&\&/!s.fail \&\&/' "no Gayle op started before its data was there"
# fix round 1: the stall assert of sdproto_test (its feeder: a block taken without its go)
unit sdp_nogo sdproto_test src sdproto.c 's/if (cur->from_gayle \&\& s.gsig == s.gtaken) {/if (0) {/' "FAIL gayle late: no Gayle op waited for the Amiga"
# fix round 1 (a): the staged first block (an abandon during it sends nothing to the card), its TX_COMMIT, sd_gayle_busy over it
unit sdp_staged sdproto_test src sdproto.c 's/if (cur->from_gayle \&\& !s.kept \&\& !s.unsent) {/if (0) {/' "FAIL gayle abandon 1st: no command reached the card"
unit sdp_staged_commit sdproto_test src sdproto.c 's/^\t\t\tstart(SDC_OP_TX_COMMIT, 0);$/\t\t\t;/' "FAIL gayle staged"
unit sdp_staged_busy hdd_test src sdproto.c 's/ || s.st == ST_WR_GSTAGE);/);/' "no FPGA frame (IDE command) while a Gayle op runs"
# fix round 1 (b): the flags look before the CPU's blocks and before a READ group's RDY (a reset in a drain wait)
unit hdd_cpu_block_guard hdd_test src hdd.c '/^\tcase H_RNEXT:/,/^\tcase H_RRUNGO:/ s/if (amiga_left()) {/if (0) {/' "FAIL rd_reset_to_write: nothing of the old command"
unit hdd_rdy_early_guard hdd_test src hdd.c '/^\tcase H_RRUN:/,/^\tcase H_RPATCHGO:/ s/if (amiga_left())$/if (0)/' "FAIL rd_reset_rdy: no RDY of the old command"
# fix round 1 (c): one card step per main-loop pass again
unit pd_steps1 hdd_test src main.c 's/^#define DISK_STEPS 8$/#define DISK_STEPS 1/' "FAIL disk_passes: a quarter of the card steps"
unit hdd_rdy_group_guard hdd_test src hdd.c '/^\tcase H_GROUP:/,/^\tcase H_DRAIN:/ s/if (hc.left < hc.count \&\& amiga_left()) {/if (0) {/' "FAIL rd_reset_group: no RDY of the old command"
# PollDisks: an FPGA command during a Gayle op; CD_AudioPoll (a CD port flags read) during an HDD command
unit hdd_gate hdd_test src main.c 's/if (fpga \&\& !sd_gayle_busy())/if (fpga)/' "no FPGA frame (IDE command) while a Gayle op runs"
unit hdd_cd_poll hdd_test src main.c 's/^\tif (hdd_busy())$/\tif (0)/' "inside the command"
# no cluster split of a run; no park bound; the abandon by hdd_cmd_req not seen
unit hdd_cluster hdd_test src hdd.c '/^unsigned long hdd_file_run(/,/^}/ s/if (\*n > rest)/if (0)/' "FAIL wr_cluster_split: a run from each cluster boundary"
unit hdd_park_bound hdd_test src hdd.c 's/} else if (CheckTimer(hc.park_t))/} else if (0)/' "FAIL wr_pause: one run per cluster and one more"
unit hdd_cmdreq_abandon hdd_test src hdd.c 's/if (st \& CMD_IDECMD)\t\/\* a new command, a reset/if (0)\t\/* a new command, a reset/' "the command never ends"
# the flags look before the last END dropped (a reset while the last group is programmed)
unit hdd_reset_end hdd_test src hdd.c '/^\tcase H_WNEXT:/,/hdd_done/ s/if (amiga_left()) {/if (0) {/' "FAIL wr_reset_end: no END for the old command"
# the error register not set; the trace without its flag
unit hdd_err_reg hdd_test src hdd.c '/^static void hdd_fail(/,/^}/ s/WriteTaskFile(err,/WriteTaskFile(0,/' "the error register"
unit hdd_trace_quiet hdd_test src hdd.c '/^void ata_trace(/,/^}/ s/if (dbg_flags \& DBG_ATA)/if (1)/' "FAIL dbg_flags 0: no UART output from a READ"
# sdproto: a parked run not closed by an sd_sync user (a deadlock), a Gayle error without the stop token, a card-detect change while parked
unit sdp_sync_close hdd_test src sdproto.c '/^static void sync_cur(/,/^}/ s/sd_close(cur);/;/' "the CD refill's card read failed"
unit sdp_gerr_stop sdproto_test src sdproto.c '/case ST_WR_GAYLE:/,/return;/ s/stop_token();/finish(s.fail);/' "FAIL gayle abandon 2nd: the stop token's busy ended"
unit sdp_park_gone sdproto_test src sdproto.c 's/finish(SD_E_GONE);\t\/\* no op runs: no DONE will come \*\//;/' "FAIL gayle gone parked: SD_E_GONE"
# CD_Locked's flags read during an HDD command (the port latch)
unit cd_locked_guard cdrom_test src cdrom.c 's/if (cdrom.unit.locked \&\& !hdd_busy()) {/if (cdrom.unit.locked) {/' "the lock dropped while the HDD command runs"

# ---- the interrupt-driven CD data path (cdpath_test, cdrom_test; findings/sdcard-engine Task 11b)
# the brief's three: the refill before the drain (the next block's phase without the host's XFER_DONE)
unit cd_refill_early cdpath_test src cdrom.c 's/r = cd_look(cc.port, cc.timeout);/r = CD_DONE;/' "a refill before the drain"
unit cd_refill_early_f cdrom_test src cdrom.c 's/r = cd_look(cc.port, cc.timeout);/r = CD_DONE;/' "a refill before the drain"
# a status after an abandon (the end writes one for CD_GONE too)
unit cd_status_abandon cdpath_test src cdrom.c '/^static int cd_end(/,/^}/ s/^\tif (r != CD_GONE)$/\tif (1)/' "while not busy"
unit cd_status_abandon_f cdrom_test src cdrom.c '/^static int cd_end(/,/^}/ s/^\tif (r != CD_GONE)$/\tif (1)/' "a status for the abandoned command"
# a cs 0x10 frame during a Gayle op: a run's end not waited for and the
# flags look's sd_gayle_busy() guard gone (either one alone holds the rule);
# the main loop's FPGA poll not gated during the CD's runs
unit cd_gayle_cs cdpath_test src cdrom.c '/^\tcase C_RUN:/,/^\tcase C_WAIT:/ s/if (cc.op.state)$/if (0)/; /^\tcase C_WAIT:/,/^\t}/ s/if (sd_gayle_busy())$/if (0)/' "no FPGA frame (IDE command) while a Gayle op runs"
unit cd_gayle_cs_f cdrom_test src cdrom.c '/^\tcase C_RUN:/,/^\tcase C_WAIT:/ s/if (cc.op.state)$/if (0)/; /^\tcase C_WAIT:/,/^\t}/ s/if (sd_gayle_busy())$/if (0)/' "while a Gayle op runs"
unit cd_gate cdpath_test src main.c 's/if (fpga \&\& !sd_gayle_busy())/if (fpga)/' "no FPGA frame (IDE command) while a Gayle op runs"
# no flags look before a card error's status; before a block's phase
unit cd_left_error cdpath_test src cdrom.c '/^static int cd_card_failed(/,/^}/ s/if (cd_left())/if (0)/' "FAIL cd_error_after_reset"
unit cd_left_error_f cdrom_test src cdrom.c '/^static int cd_card_failed(/,/^}/ s/if (cd_left())/if (0)/' "a card error at an Amiga reset"
unit cd_left_phase cdpath_test src cdrom.c '/^\tcase C_PHASE:/,/^\tcase C_RUNGO:/ s/if (cd_left())/if (0)/' "FAIL cd_reset_in_gap"
# ruling T11-R4: hdd_busy() without the CD's READ; hdd_poll not dispatching it
unit cd_one_cmd cdpath_test src hdd.c 's/return hc.st != H_IDLE || CD_Busy();/return hc.st != H_IDLE;/' "one IDE command at a time"
unit cd_dispatch cdpath_test src hdd.c 's/} else if (CD_Busy()) {/} else if (0) {/' "a hang"
# a run not cut at its cluster (the ISO's chain jumps); a run past its data-in block
unit cd_cluster cdpath_test src hdd.c '/^unsigned long hdd_file_run(/,/^}/ s/if (\*n > rest)/if (0)/' "the data (TEST.ISO sectors 5..13)"
unit cd_run_block cdpath_test src cdrom.c 's/^\t\tk = cc.bleft;$/\t\tk = (unsigned)cc.left;/' "FAIL"
unit cd_run_block_f cdrom_test src cdrom.c 's/^\t\tk = cc.bleft;$/\t\tk = (unsigned)cc.left;/' "a card run of"
# a seek's failure ignored; a seek that waits for its FAT read taken as there
unit cd_seek_err cdrom_test src cdrom.c '/^\tcase C_SEEK:/,/^\tcase C_PHASE:/ s/if (r < 0) {/if (0) {/' "a seek's FAT read fails"
unit cd_seek_wait cdrom_test src cdrom.c 's/r = hdd_seek_step(\&cc.op);/r = 1; hdd_seek_step(\&cc.op);/' "seeks that wait for FAT reads"
# the OSD's eject without ending the READ first
unit cd_cancel cdpath_test src cdrom.c 's/^\tCD_Cancel();\t\/\* a READ in progress ends before its file goes \*\/$/\t;/' "FAIL cd_osd_eject"
unit cd_cancel_f cdrom_test src cdrom.c 's/^\tCD_Cancel();\t\/\* a READ in progress ends before its file goes \*\/$/\t;/' "OSD eject during a READ"
# the CD READ's trace line
unit cd_trace_end cdpath_test src cdrom.c '/^static int cd_end(/,/^}/ s/ata_trace(0xA0,/(void)(0xA0,/' "FAIL cd_trace: DBG_ATA: the READ(10)'s line"
# fix round 1: the main loop's other work inside a part-delivered block (the Amiga held by nrdy)
unit pd_in_block cdpath_test src main.c 's/^\tif (hdd_in_block())$/\tif (0)/' "inside a part-delivered data-in block"
unit pd_in_block_hdd hdd_test src main.c 's/^\tif (hdd_in_block())$/\tif (0)/' "inside a part-delivered READ group"
unit hdd_ingrp hdd_test src hdd.c 's/if (hc.st != H_IDLE \&\& !hc.write \&\& hc.ingrp \&\& hc.gsize > 1) {/if (0) {/' "inside a part-delivered READ group"
unit cd_inblock cdpath_test src cdrom.c 's/if ((cc.st != C_SEEK \&\& cc.st != C_RUNGO \&\& cc.st != C_RUN) || !cc.bleft || cc.bsize < 2)/if (1)/' "inside a part-delivered data-in block"
# the gate from the first sector in, not from the phase: an sd_sync user finishes the run itself
unit cd_inblock_late cdpath_test src cdrom.c 's/return d < cc.bleft;/return d \&\& d < cc.bleft;/' "inside a part-delivered data-in block"

# ---- the floppy emulation (fdd_test) -----------------------------------------
# the brief's mutant: SendSector one byte short (the odd data bits loop) -> mfm.py's stream
unit fdd_short_sector fdd_test src fdd.c '0,/i = DATA_SIZE \/ 2;/s//i = DATA_SIZE \/ 2 - 1;/' \
  "FAIL ReadTrack track 0 side 0: the stream != mfm.py" "FAIL ReadTrack track 79 side 1: the stream != mfm.py"
# the write-FIFO gap (Phase 4 Task 14) one TIMER read short (a site removed is wrfifo.ok's)
unit fdd_wrfifo_gap fdd_test src hardware.h 's/for (i_ = 0; i_ < WRFIFO_GAP_READS; i_++)/for (i_ = 1; i_ < WRFIFO_GAP_READS; i_++)/' \
  "FAIL WriteTrack full159 (track 159, 11 sectors), FIFO +2048 words per poll: TIMER reads between two FIFO words"
# the write-FIFO gap constant halved: the test's literal floor must catch it
unit fdd_wrfifo_gap8 fdd_test src hardware.h 's/^#define WRFIFO_GAP_READS 16$/#define WRFIFO_GAP_READS 8/' \
  "FAIL WriteTrack full159 (track 159, 11 sectors), FIFO +2048 words per poll: TIMER reads between two FIFO words"
# the Copy Lock workaround gone: the Amiga's 0x8914 is sent as it is
unit fdd_copylock fdd_test src fdd.c 's/if (dsksync == 0x0000 || dsksync == 0x8914 || dsksync == 0xA144)/if (0)/' \
  "FAIL ReadTrack copy lock dsksync 8914: the stream != mfm.py"
# track/side arithmetic: the sector of tracks 128..159 taken modulo 128
unit fdd_track_sector fdd_test src fdd.c '0,/file.sector = drive->track \* SECTOR_COUNT;/s//file.sector = (drive->track \& 0x7F) * SECTOR_COUNT;/' \
  "FAIL ReadTrack track 128 (cylinder 64 side 0): FileRead: cluster"
# the header's sector number decoded from the wrong bits (GetHeader)
unit fdd_header_sector fdd_test src fdd.c 's/c3 |= c \& 0x55;$/c3 |= c \& 0x54;/' \
  "FAIL WriteTrack subset1 (track 1, 3 sectors), FIFO +2048 words per poll: the ADF differs"
# GetData: one data bit of the even half lost
unit fdd_data_even fdd_test src fdd.c '0,/\*p++ |= c \& 0x55;/s//*p++ |= c \& 0x54;/' \
  "FAIL WriteTrack full159 (track 159, 11 sectors), FIFO +2048 words per poll: the ADF differs"
# WriteTrack going back to the start of the track one sector off (subset1 writes 2 after 5)
unit fdd_rewind fdd_test src fdd.c '/while (sector != Sector)/,/^                }/ s/file.sector = drive->track \* 11;/file.sector = drive->track * 11 + 1;/' \
  "FAIL WriteTrack subset1 (track 1, 3 sectors), FIFO +2048 words per poll: file layer"
# the header checksum not checked: the bad sector is written
unit fdd_header_checksum fdd_test src fdd.c '0,/if (c1 != checksum\[0\] || c2 != checksum\[1\] || c3 != checksum\[2\] || c4 != checksum\[3\])/s//if (0)/' \
  "FAIL WriteTrack subset1 bad header checksum (sector 5): the ADF differs"
# GetData waiting for one word fewer than the sector holds: it reads past the FIFO count
unit fdd_getdata_count fdd_test src fdd.c 's/if (n >= 0x204)/if (n >= 0x203)/' \
  "FIFO +7 words per poll: reads past the FIFO count"
# the committed golden streams are mfm.py's: a stale one fails the regeneration
unit fdd_gold_stale fdd_test gold mfm_c79_s1.hex '100s/^/0/' "differ"

# ---- drive sounds, copper list, CheckSum, hexdump (drivesounds_test, boot_test)
# the brief's two: the previous firmware's per-sample swap kept (all three loops) -> the ring;
# the header read as *(long *) -> LP64: an 8-byte load at SYNTH.BIN's 4 mod 8
# size field (the sanitizer stops it); as RV32 reads a long (4 bytes, *(int *)):
# little-endian sizes, the test's load check
unit ds_swap drivesounds_test src drivesounds.c 's/c=(c\&0xffff)\*0x10001;/c=((c\&255)<<8) | ((c>>8)\&255); c=c*0x10001;/' "FAIL synth fill"
unit ds_header_long drivesounds_test src drivesounds.c 's/rd_be32(buf)/*(long *)buf/g' "load of misaligned address"
unit ds_header_int drivesounds_test src drivesounds.c 's/rd_be32(buf)/*(int *)buf/g' "FAIL synth: load"
unit ds_noconvert drivesounds_test src drivesounds.c 's/samples\[i\]=(short)rd_be16(\&samples\[i\]);/;/' "FAIL synth fill"
unit ds_nomask drivesounds_test src drivesounds.c 's/c=(c\&0xffff)\*0x10001;/c=c*0x10001;/' "FAIL synth fill"
# the bounded in-place conversion (final review I1): the oversize clamp (TRUNC:
# the conversion runs into the ring), the odd file length (ODDLEN: halfword
# stores at odd addresses, a trap on RV; x86 takes them: the return value),
# the odd and negative size (the list goes on: the load lines differ), the
# negative id (sounds[-1]: UBSan)
unit ds_noclamp drivesounds_test src drivesounds.c 's/ || size>end-buf//' "FAIL bad TRUNC   BIN: ring written"
unit ds_oddfile drivesounds_test src drivesounds.c 's/if(file.size\&1)/if(0)/' "FAIL bad ODDLEN  BIN: drivesounds_init"
unit ds_oddsize drivesounds_test src drivesounds.c 's/ || (size\&1)//' "FAIL bad ODDSND  BIN: load"
unit ds_negsize drivesounds_test src drivesounds.c 's/if(size<0 || /if(/' "FAIL bad NEGSIZE BIN: load"
unit ds_negid drivesounds_test src drivesounds.c 's/ \&\& id>=0 \&\& / \&\& /' "index -1 out of bounds"
# Task 4's parentheses: each (enabled & DRIVESOUNDS_FLOPPY) site taken always
unit ds_floppy_start drivesounds_test src drivesounds.c '/case DRIVESOUND_MOTORSTART:/,/break;/ s/if ((drivesounds.enabled \& DRIVESOUNDS_FLOPPY))/if (1)/' "FAIL real fill"
unit ds_floppy_stop drivesounds_test src drivesounds.c '/case DRIVESOUND_MOTORSTOP:/,/break;/ s/if ((drivesounds.enabled \& DRIVESOUNDS_FLOPPY))/if (1)/' "FAIL real fill"
unit ds_floppy_step drivesounds_test src drivesounds.c '/case DRIVESOUND_STEP:/,/break;/ s/if ((drivesounds.enabled \& DRIVESOUNDS_FLOPPY))/if (1)/' "FAIL real fill"
unit ds_floppy_default drivesounds_test src drivesounds.c '/default:/,/break;/ s/if ((drivesounds.enabled \& DRIVESOUNDS_FLOPPY))/if (1)/' "FAIL real fill"
unit boot_copper boot_test src boot.c 's/be16(\(0x[0-9a-f]*\))/\1/g' "FAIL default copper list, big-endian words"
unit boot_checksum boot_test src main.c 's/sum+=rd_be32(adr);/sum+=*(unsigned int *)adr;/' "FAIL CheckSum of a 512-byte block (aligned)"
unit boot_hexdump boot_test src hexdump.c 's/unsigned int t=rd_be32(p);/unsigned int t=*(unsigned int *)p;/' "FAIL hexdump: the big-endian word view (aligned)"

# ---- SPI_reply() on HOST_REQ (spireply_test, Phase 4 Task 11) ---------------
# the brief's two: the poll removed -> the order (no HOST_REQ read before the
# write); the bound 0 -> the stuck case returns at once (TIMER reads)
unit spireply_nopoll spireply_test src hardware.c 's/if (!(HOST_REQ \& HOST_REQ_OSD_RDY)) {/if (0) {/' "FAIL 1 zeros: order"
unit spireply_bound0 spireply_test src hardware.c 's/GetTimer(2)/GetTimer(0)/' "FAIL stuck, TIMER step 1: TIMER reads"
# a bound one count too long, the timeout not counted, the wrong bit
unit spireply_bound3 spireply_test src hardware.c 's/GetTimer(2)/GetTimer(3)/' "FAIL stuck, TIMER step 1: TIMER reads"
unit spireply_nocount spireply_test src hardware.c 's/osd_rdy_timeouts++;/;/' "FAIL stuck, TIMER step 1: osd_rdy_timeouts"
unit spireply_bit spireply_test src hardware.h 's/define HOST_REQ_OSD_RDY 0x0001/define HOST_REQ_OSD_RDY 0x0002/' "FAIL ready: order"

# ---- the disk statistics of the SD baseline (diskstat_test, findings/sdcard-engine Task 1)
# the brief's mutant: a bucket bound off by one -> 16 sectors counted as 17-64
unit diskstat_bucket diskstat_test src diskstat.c 's/{ 1, 2, 4, 8, 16, 64, 256 }/{ 1, 2, 4, 8, 15, 64, 256 }/' "FAIL w 16 sectors: hist\[1\]\[4\]"
# the hook: ATA_WriteSectors' Gayle wait without the polls that found the
# FIFO not ready (MMC_Write's busy polls went with cfide's SPI, Task 10)
unit diskstat_amiga hdd_test src hdd.c '/^static int hdd_step(/,/^}/ s/hc.polls++;/;/' "diskstat amiga polls >= the waits"

# ---- the SD peripheral driver, the interrupt migration and the mock (sdc_test, sdcard-engine Task 9)
# the driver (sdc.c / sdc.h)
unit sdc_noack sdc_test src sdc.c 's/SDC_W(SDC_IRQACK, p);/;/' "interrupt storm"
unit sdc_nooneshot sdc_test src sdc.c 's/SDC_W(SDC_IRQEN, en \& ~(p \& (SDC_IRQ_RXHI | SDC_IRQ_TXLO)));/;/' "interrupt storm"
unit sdc_norefuse sdc_test src sdc.c 's/if (op != SDC_OP_ABORT \&\& (SDC_R(SDC_STATUS) \& SDC_ST_REFUSED)) {/if (0) {/' "FAIL refuse: cycle after an op end -> -1"
unit sdc_nobusy sdc_test src sdc.c 's/if (op != SDC_OP_ABORT \&\& (st \& SDC_ST_BUSY)) {/if (0) {/' "FAIL refuse: busy -> trace BUSY"
unit sdc_stale_done sdc_test src sdc.c 's/sdc_events = sdc_events \& ~(SDC_IRQ_DONE | SDC_IRQ_ERR);/;/' "FAIL brief: RXLVL after an RX XFER of 8"
unit sdc_wait_noerr sdc_test src sdc.c 's/unsigned m = mask | SDC_IRQ_ERR | SDC_IRQ_CD, e;/unsigned m = mask | SDC_IRQ_CD, e;/'
unit sdc_wait_nocd sdc_test src sdc.c 's/unsigned m = mask | SDC_IRQ_ERR | SDC_IRQ_CD, e;/unsigned m = mask | SDC_IRQ_ERR, e;/'
unit sdc_bound sdc_test src sdc.h 's/define SDC_WAIT_BOUND 1800/define SDC_WAIT_BOUND 1799/' "FAIL wait bound: TIMER reads"
unit sdc_clamp sdc_test src sdc.c 's/if (div < SDC_DIV_MIN)/if (div < 1)/' "FAIL cfg: div 1 -> 2"
unit sdc_trace_head sdc_test src sdc.c 's/sdc_trace_head = sdc_trace_head + 1;/;/' "FAIL trace: two entries"
unit sdc_edge sdc_test src sdc.c 's/IrqSetMode(IRQ_SDCARD, 1);/IrqSetMode(IRQ_SDCARD, 0);/' "FAIL init: controller bit 4 LEVEL"
unit sdc_init_noabort sdc_test src sdc.c 's/SDC_W(SDC_CMD, SDC_OP_ABORT);/;/' "FAIL init: not busy (ABORT)"
# fix round 1: the trace stamp takes no TIMER read on the host, misuse is
# counted, sdc_wait waits for its ABORT, events name their op
unit sdc_trace_tick sdc_test src sdc.h 's/define SDC_TRACE_TIME() hosttest_timer_peek()/define SDC_TRACE_TIME() TIMER/' "FAIL default step: still busy after sdc_start"
unit sdc_misuse_count sdc_test src sdc.c 's/sdc_misuse = sdc_misuse + 1;/;/' "FAIL misuse: sdc_misuse counts it"
unit sdc_noabortwait sdc_test src sdc.c 's/^\t\t\tabort_wait();$/\t\t\t;/' "FAIL wait bound, byte in flight: stopped"
unit sdc_event_op sdc_test src sdc.c 's/trace_put(SDC_TR_EVENT | sdc_cmd,/trace_put(SDC_TR_EVENT,/' "FAIL trace: event names its op"
unit mock_misuse_nonfatal sdc_test t mock_sdc.c 's/if (sdc.misuse_fatal)/if (0)/' "FAIL misuse: fatal in the mock by default"
# the interrupt migration (main.c IrqSetupSources, cut out by the Makefile)
unit irq_swap sdc_test src main.c 's/IrqSetHandler(IRQ_VBLANK, c64keys_inthandler);/IrqSetHandler(IRQ_VBLANK, akiko_inthandler);/' "FAIL irq: vblank -> c64keys_inthandler"
unit irq_noakiko sdc_test src main.c 's/^\tIrqEnable(IRQ_AKIKO);$/\t;/' "FAIL irq: MASK = vblank + Akiko"
# the mock against the contract texts
unit mock_sdc_nocrc sdc_test t mock_sdc.c 's/if (sdc.crc == 0) {/if (1) {/' "FAIL read bad: no crc_ok"
unit mock_sdc_nointerlock sdc_test t mock_sdc.c 's/!sdc.poisoned \&\& sdc.verified >= sdc.len;/1;/' "FAIL read bad: RX_TO_GAYLE refused"
unit mock_sdc_noahead sdc_test t mock_sdc.c 's/if (rxop \&\& sdc.ahead_ok) sdc.verified/if (rxop) sdc.verified/' "FAIL interlock: nothing verified"
unit mock_sdc_notimeout sdc_test t mock_sdc.c 's/\&\& t > sdc.deadline) sdc_end(END_TMO);/\&\& 0) sdc_end(END_TMO);/' "FAIL wait: wakes on ERR"
unit mock_sdc_rxhigh sdc_test t mock_sdc.c 's/if ((rxlvl() >> 4) >= sdc.wm_rx)/if ((rxlvl() >> 4) > sdc.wm_rx)/' "FAIL reset: IRQPEND 0006"
unit mock_sdc_rewind sdc_test t mock_sdc.c 's/case OP_TXRW: sdc.tx_snd = sdc.tx_cm;/case OP_TXRW: sdc.tx_snd = sdc.tx_snd - 1;/' "FAIL txkeep: REWIND: from the commit point"
unit mock_sdc_bytetime sdc_test t mock_sdc.c 's/return 16u \* (sdc.div + 1);/return 16u * sdc.div;/' "FAIL timing"
unit mock_sdc_gone sdc_test t mock_sdc.c 's/if (!present \&\& sdc.busy) sdc_end(END_GONE);/;/' "FAIL gone: ended at once"
unit mock_sdc_rollback sdc_test t mock_sdc.c 's/if (sdc.op == OP_G2TX \&\& why != END_NORMAL) sdc.tx_wr = sdc.tx_wr0;/;/' "FAIL g_err: TX back"
unit mock_sdc_lock sdc_test t mock_sdc.c 's/if (gayle_op_busy()) { misuse(); break; }\t\/\* the data port is locked \*\//;/' "FAIL locked: push dropped"
unit mock_card_crc7 sdc_test t mock_hw.c 's/(card.crc_on \&\& (unsigned)(card.cmdb\[5\] >> 1) != c7)/(0)/' "FAIL crc7 bad: R1 08"
unit mock_card_wcrc sdc_test t mock_hw.c 's/else if (card.crc_on \&\& card.wrx != card.wcrc) resp = 0x0B;/else if (0) resp = 0x0B;/' "FAIL write bad crc16: 0B"
unit mock_card_rdcrc sdc_test t mock_hw.c 's/card.txb ^= 0x01;/card.txb ^= 0x00;/' "FAIL read bad: no crc_ok"
unit mock_card_acmd22 sdc_test t mock_hw.c 's/if (card.wmulti) card.wr_ok++;/;/' "FAIL acmd22: 1 block written"
unit mock_card_noresp sdc_test t mock_hw.c 's/return;\t\t\t\t\/\* no response, no effect \*\//;/' "FAIL noresp: no R1"
unit mock_idle_traps sdc_test t mock_sdc.c 's/irqc_traps != idle_traps/0/g' "sdc_wait: the mock can make no progress"
unit mock_irq_edge sdc_test t mock_sdc.c 's/irqc_edge \&= ~p;/;/' "interrupt storm"

# ---- the check_io.awk fixture (check_io.sh, exec-3 deferred #18) --------------
# no forgetting after a j: good.dis's stale s1 is taken for the UART (b)
checkio checkio_j src check_io.awk 's/(j|jr|ret|mret)/(jr|ret|mret)/' "FAIL check_io fixture"
# (c) by 2 instead of 4: HOST_REQ at -74 passes
checkio checkio_c src check_io.awk 's/(-a) % 4 != 0/(-a) % 2 != 0/' "FAIL check_io fixture"
# (b) without 0xFFFFFFF0: the UART read through a4 passes
checkio checkio_b src check_io.awk 's/a >= -16 \&\& a <= -13/a >= -15 \&\& a <= -13/' "FAIL check_io fixture"
# li not tracked: the accesses through a4 are not seen
checkio checkio_li src check_io.awk 's/if (op == "li") { val\[rd\] = v32(num(p\[2\])); next }/if (op == "li") { delete val[rd]; next }/' "FAIL check_io fixture"

# ---- the mock itself (mock_selftest) -----------------------------------------
unit mock_token mock_selftest t mock_hw.c 's/c_push(0xFE);/c_push(0xFF);/'
unit mock_r7 mock_selftest t mock_hw.c 's/c_push(0x01); c_push(0xAA);/c_push(0x01); c_push(0xAB);/'
unit mock_ncr mock_selftest t mock_hw.c 's/card.ncr = 1;/card.ncr = 0;/'
unit mock_write mock_selftest t mock_hw.c 's/memcpy(card.mem + (size_t)card.wlba \* 512, card.wbuf, 512);/;/'
unit mock_cmd12 mock_selftest t mock_hw.c 's/card.qh = card.qt;	\/\* drop the rest of the stream \*\//;/'
unit mock_trace_sep mock_selftest t mock_hw.c 's/buf_put(dst, " \/", 2);/buf_put(dst, " |", 2);/'
unit mock_trace_cs mock_selftest t mock_hw.c 's/fr_cs = scs \& 0xFE;/fr_cs = scs;/'
unit mock_timer_step mock_selftest t mock_hw.c 's/timer_step = 1;/timer_step = 0;/'
unit mock_slot mock_selftest t mock_hw.c 's/for (int i = 7; i >= 1; i--)/for (int i = 1; i <= 7; i++)/'

# ---- hwmap_test: every register class ----------------------------------------
# <name> ## <file under src> ## <sed>; address and width of each register,
# the CS/SPEED values and SPI()/RS232() themselves
hwmap() {  # <name> <file> <sed>
  unit "hw_$1" hwmap_test src "$2" "$3"
}
hwmap spi_data   hardware.h 's/define HW_SPI_DATA 0/define HW_SPI_DATA 4/'
hwmap spi_cs     hardware.h 's/define HW_SPI_CS 4/define HW_SPI_CS 6/'
hwmap spi_speed  hardware.h 's/define HW_SPI_SPEED 8/define HW_SPI_SPEED 12/'
hwmap spi_base   hardware.h 's/0xFFFFFFE0+(x)/0xFFFFFFE1+(x)/'
hwmap spi_width  hardware.h 's/HW_SPI(x) (\*(volatile unsigned char/HW_SPI(x) (*(volatile unsigned short/'
hwmap spi_order  hardware.h 's/define SPI(x) (HW_SPI(HW_SPI_DATA)=x,HW_SPI(HW_SPI_DATA))/define SPI(x) (HW_SPI(HW_SPI_DATA)=x)/'
hwmap spi_swap   hardware.h 's/define SPI(x) (HW_SPI(HW_SPI_DATA)=x,HW_SPI(HW_SPI_DATA))/define SPI(x) (HW_SPI(HW_SPI_DATA),HW_SPI(HW_SPI_DATA)=x)/'
hwmap rdspi      hardware.h 's/define RDSPI  HW_SPI(HW_SPI_DATA)/define RDSPI  HW_SPI(HW_SPI_CS)/'
hwmap uart_addr  hardware.h 's/unsigned char \*)0xFFFFFFF0)/unsigned char *)0xFFFFFFF3)/'
hwmap uart_width hardware.h 's/unsigned char \*)0xFFFFFFF0)/unsigned short *)0xFFFFFFF0)/'
hwmap rs232_val  hardware.h 's/define RS232(x) (UART_TX=(x))/define RS232(x) (UART_TX=(x)+1)/'
hwmap rs232_drop hardware.h 's/define RS232(x) (UART_TX=(x))/define RS232(x) ((void)(x))/'
hwmap rs232_twice hardware.h 's/define RS232(x) (UART_TX=(x))/define RS232(x) (UART_TX=(x),UART_TX=(x))/'
hwmap rs232_wide hardware.h 's/define RS232(x) (UART_TX=(x))/define RS232(x) (*(volatile unsigned short *)0xFFFFFFF0=(x))/'
hwmap timer_addr hardware.h 's/unsigned short \*)0xFFFFFFD0/unsigned short *)0xFFFFFFD2/'
hwmap timer_width hardware.h 's/unsigned short \*)0xFFFFFFD0/unsigned int *)0xFFFFFFD0/'
hwmap platform_addr hardware.h 's/unsigned short \*)0xFFFFFFC0/unsigned short *)0xFFFFFFC2/'
hwmap platform_width hardware.h 's/unsigned short \*)0xFFFFFFC0/unsigned int *)0xFFFFFFC0/'
hwmap audio_addr hardware.h 's/unsigned char \*)0xFFFFFFB0/unsigned char *)0xFFFFFFB1/'
hwmap audio_width hardware.h 's/unsigned char \*)0xFFFFFFB0/unsigned short *)0xFFFFFFB0/'
hwmap host_req_addr hardware.h 's/unsigned short \*)0xFFFFFFB4/unsigned short *)0xFFFFFFB6/'
hwmap host_req_width hardware.h 's/unsigned short \*)0xFFFFFFB4/unsigned char *)0xFFFFFFB4/'
hwmap temp_addr  hardware.h 's/unsigned short \*)0xFFFFFF40/unsigned short *)0xFFFFFF42/'
hwmap temp_width hardware.h 's/unsigned short \*)0xFFFFFF40/unsigned int *)0xFFFFFF40/'
hwmap vscale_addr hardware.h 's/unsigned int \*)0xFFFFFF50/unsigned int *)0xFFFFFF54/'
hwmap vscale_width hardware.h 's/unsigned int \*)0xFFFFFF50/unsigned short *)0xFFFFFF50/'
hwmap reconf_addr hardware.h 's/unsigned short \*)0xDEE016/unsigned short *)0xDEE018/'
hwmap reconf_width hardware.h 's/unsigned short \*)0xDEE016/unsigned int *)0xDEE016/'
# the CS values: flip bit 2 of each
for pair in EnableCard:02 DisableCard:03 EnableFpga:10 DisableFpga:11 EnableOsd:20 DisableOsd:21 \
            EnableDMode:40 DisableDMode:41 EnableRTC:80 DisableRTC:81; do
  fn=${pair%%:*}; v=${pair##*:}
  nv=$(printf '%02x' $((0x$v ^ 0x04)))
  hwmap "cs_$fn" hardware.h "s/\\(define $fn() *HW_SPI(HW_SPI_CS)=0x\\)$v/\\1$nv/"
done
hwmap speed_slow hardware.h 's/\(define SPI_slow() *HW_SPI(HW_SPI_SPEED)=0x\)3f/\13e/'
hwmap speed_fast hardware.h 's/\(define SPI_fast() *HW_SPI(HW_SPI_SPEED)=0x\)1$/\12/'
# keyboard, Akiko, RTC, I2C, interrupt controllers
hwmap kbd_base   c64keys.h 's/KEYBOARDBASE 0xFFFFFF90/KEYBOARDBASE 0xFFFFFF94/'
hwmap kbd_width  c64keys.h 's/unsigned short \*)(KEYBOARDBASE/unsigned int *)(KEYBOARDBASE/'
hwmap kbd_word1  c64keys.h 's/WORD1 4/WORD1 6/'
hwmap kbd_word2  c64keys.h 's/WORD2 8/WORD2 10/'
hwmap kbd_word3  c64keys.h 's/WORD3 0xc/WORD3 0xe/'
hwmap kbd_out    c64keys.h 's/REG_KEYBOARD_OUT 0/REG_KEYBOARD_OUT 2/'
hwmap kbd_word0  c64keys.h 's/REG_KEYBOARD_WORD0 0/REG_KEYBOARD_WORD0 2/'
hwmap akiko_base akiko.h 's/AKIKOBASE 0xFFFFFF80/AKIKOBASE 0xFFFFFF84/'
hwmap akiko_width akiko.h 's/unsigned short \*)(AKIKOBASE/unsigned int *)(AKIKOBASE/'
hwmap akiko_addr akiko.h 's/ADDR 0/ADDR 2/'
hwmap akiko_data akiko.h 's/DATA 4/DATA 6/'
hwmap rtc_base   rtc.h 's/RTCBASE 0xFFFFFF70/RTCBASE 0xFFFFFF74/'
hwmap rtc_width  rtc.h 's/unsigned short \*)(RTCBASE/unsigned int *)(RTCBASE/'
hwmap i2c_base   i2c.h 's/I2C_BASE 0xFFFFFF60/I2C_BASE 0xFFFFFF64/'
hwmap i2c_width  i2c.h 's/unsigned int \*)(I2C_BASE/unsigned short *)(I2C_BASE/'
hwmap i2c_data   i2c.h 's/^#define HW_I2C_DATA 0x00000000/#define HW_I2C_DATA 0x00000002/'
hwmap i2c_status i2c.h 's/^#define HW_I2C_STATUS 0x00000004/#define HW_I2C_STATUS 0x00000006/'
hwmap i2c_prescale i2c.h 's/^#define HW_I2C_PRESCALE 0x00000008/#define HW_I2C_PRESCALE 0x0000000A/'
hwmap i2c_id     i2c.h 's/^#define HV_I2C_ID 0x0000000C/#define HV_I2C_ID 0x0000000E/'
hwmap irq_base   arch/irq.h 's/INTERRUPTBASE      0xFFFFFFA0/INTERRUPTBASE      0xFFFFFFA4/'
hwmap irq_width  arch/irq.h 's/HW_INTERRUPT(x)    (\*(volatile unsigned int/HW_INTERRUPT(x)    (*(volatile unsigned short/'
hwmap irq_ctrl   arch/irq.h 's/REG_INTERRUPT_CTRL 0x0/REG_INTERRUPT_CTRL 0x4/'
hwmap irqctl_base arch/irq.h 's/IRQCTLBASE         0xFFFFFF30/IRQCTLBASE         0xFFFFFF34/'
hwmap irqctl_pending arch/irq.h 's/IRQCTLBASE + 0x0))/IRQCTLBASE + 0x2))/'
hwmap irqctl_mask arch/irq.h 's/IRQCTLBASE + 0x4))/IRQCTLBASE + 0x6))/'
hwmap irqctl_raw arch/irq.h 's/IRQCTLBASE + 0x8))/IRQCTLBASE + 0xA))/'
hwmap irqctl_mode arch/irq.h 's/IRQCTLBASE + 0xC))/IRQCTLBASE + 0xE))/'
hwmap sdc_base   sdc.h 's/define SDC_BASE    0xFFFFFF00/define SDC_BASE    0xFFFFFF02/'
hwmap sdc_width  sdc.h 's/(\*(volatile unsigned short \*)(SDC_BASE/(*(volatile unsigned int *)(SDC_BASE/'
hwmap sdc_cfg    sdc.h 's/define SDC_CFG     0x20/define SDC_CFG     0x24/'
hwmap sdc_ver    sdc.h 's/define SDC_VER     0x2C/define SDC_VER     0x28/'
hwmap sdc_wr     sdc.h 's/define SDC_W(x, v)  (SDC(x) = (v))/define SDC_W(x, v)  ((void)(v))/'
hwmap sdc_version sdc.h 's/define SDC_VERSION 0x5D02/define SDC_VERSION 0x5D01/'
hwmap irq_sdcard arch/irq.h 's/define IRQ_SDCARD         4/define IRQ_SDCARD         5/'
hwmap irqctl_width arch/irq.h 's/HW_IRQ_MASK        (\*(volatile unsigned int/HW_IRQ_MASK        (*(volatile unsigned short/'
# uart.c
unit puts_nl hwmap_test src uart.c 's/++result;/++result; if (!*msg) putchar(10);/'
unit puts_words hwmap_test src uart.c 's/(c=(unsigned char)\*msg++)/(c=(unsigned char)*msg++) \&\& result < 1/'

# ---- the final review's fix wave (findings/sdcard-engine, 2026-10-25) -------
# M7: SET MULTIPLE MODE above 16 accepted (groups larger than Gayle's FIFO)
unit hdd_setmult_max hdd_test src hdd.c 's/if (tfr\[2\] > HDD_MULTIPLE_MAX) {/if (0) {/' "FAIL SET MULTIPLE MODE 17"
# M2: amiga_left ignores IDEF_CMD_WR (a command without drive/head write before its look)
unit hdd_cmd_wr hdd_test src hdd.c 's/return (flags \& (IDEF_RST_SEEN | IDEF_DEV_WR | IDEF_CMD_WR)) != 0;/return (flags \& (IDEF_RST_SEEN | IDEF_DEV_WR)) != 0;/' "FAIL rd_newcmd_rdy: no RDY of the old command after the new command"
# M1: a push that does not fit TX dropped (the XFER after it waits for ever)
unit sdp_tx_room sdproto_test src sdproto.c 's/if (lvl + n > SDC_FIFO) {/if (0) {/' "FIFO misuse"
# M3: no stop sequence before a re-init's CMD0, or parts of it
unit sdp_no_stop_any sdproto_test src sdproto.c 's/(inited \&\& stop_any() < 0)/0/' "FAIL bounce"
unit sdp_no_fill sdproto_test src sdproto.c 's/if (run(SDC_OP_XFER, 520) < 0 || busy_end() < 0)/if (busy_end() < 0)/' "FAIL bounce"
unit sdp_no_fd sdproto_test src sdproto.c 's/static const unsigned char fd = 0xFD;/static const unsigned char fd = 0xFF;/' "FAIL bounce"
unit sdp_no_cmd12 sdproto_test src sdproto.c 's/frame(f, 12, 0);/frame(f, 63, 0);/' "FAIL bounce rd"
# M6: CMD12's R1 after a fully delivered CMD18 counted (error bits, idle bit)
unit sdp_cmd12_r1 sdproto_test src sdproto.c 's/if (s.r1 \&\& !s.fail \&\& !stop_done())/if (s.r1 \&\& !s.fail)/' "FAIL cmd12 stale 04: read ok"
unit sdp_cmd12_idle sdproto_test src sdproto.c 's/if (stop_done()) {\t\/\* every block/if (0) {\t\/* every block/' "FAIL cmd12 stale 01: read ok"
# M4: no going on after a card-detect bounce; going on although the op left
# data part-way; no re-init before going on (the last run's END | IRQ)
unit hdd_bounce hdd_test src hdd.c 's/if (hc.op.err == SD_E_GONE \&\& hc.op.intact \&\& !hc.bounced \&\& !sd_card_changed()) {/if (0) {/' "FAIL rd_bounce" "FAIL wr_bounce"
unit hdd_bounce_intact hdd_test src hdd.c 's/if (hc.op.err == SD_E_GONE \&\& hc.op.intact \&\& /if (hc.op.err == SD_E_GONE \&\& /' "the command never ends"
unit sdp_intact hdd_test src sdproto.c 's/op->intact = s.st != ST_RD_GAYLE/op->intact = 1 || s.st != ST_RD_GAYLE/' "the command never ends"
unit hdd_bounce_reinit hdd_test src hdd.c 's/ || (!sd_card_type() \&\& !sd_init())) {/) {/' "FAIL wr_bounce_last"

# ---- the OSD text layer driver (osd2_test; findings/osd-redesign Phase 2) ----
# lane swap: a chars-only run sent as attrs and the other way round
unit osd2_lanes osd2_test src osd2.c 's/k == K_CHR ? OSD2_TXT_CHARS : OSD2_TXT_ATTRS/k == K_CHR ? OSD2_TXT_ATTRS : OSD2_TXT_CHARS/' "FAIL attrs only: mode 2"
# a flush that skips every dirty row after the first
unit osd2_skiprow osd2_test src osd2.c 's/if (!k)$/if (!k || r > 2)/' "FAIL init flush: frames"
# no compare: an unchanged redraw is sent again
unit osd2_nocompare osd2_test src osd2.c 's/if ((kinds \& K_CHR) \&\& osd2_chr\[row\]\[col\] != ch)/if (kinds \& K_CHR)/' "FAIL unchanged redraw: bytes"
# osd2_char marks a cell that does not change
unit osd2_charnocmp osd2_test src osd2.c '/^void osd2_char/,/^}/s/^\tif (osd2_chr\[row\]\[col\] != ch) {$/\tif (1) {/' "FAIL osd2_char unchanged: bytes"
# the commit sends the palette but never the window
unit osd2_nowin osd2_test src osd2.c 's/^\tsend_win();$/\t;/' "FAIL commit: entry 5 blend"

# ---- the new OSD menu (ui_test; findings/osd-redesign Phase 3,
# the sidebar layout of 2026-10-27) ----
# the long name's start held 250 ms instead of 500
unit ui_scrollhold ui_test src ui.h 's/^#define UI_T_SCROLL_HOLD UI_T(500)/#define UI_T_SCROLL_HOLD UI_T(250)/' "FAIL scroll: the start held 500 ms"
# a cursor move does not restart the scroll
unit ui_scrollkeep ui_test src ui.c '/^static void key_files/,/^}/s/^\tscroll_reset();$/\t;/' "FAIL scroll: a cursor move resets it"
# closing leaves the layer on
unit ui_noclose ui_test src ui.c '/^void ui_close(void)/,/^}/s/^\t\tosd2_disable();$/\t\t;/' "FAIL closing: the window off"
# debug mode: closing the menu leaves the layer without the debug page (it
# belongs on the layer since osd-p2's 5ab0e127; the bitmap OSD it once went
# back to is gone, Phase 6)
unit ui_debugbitmap ui_test src ui.c '/^void ui_close(void)/,/^}/s/^\t\tdebug2_show(1);  /\t\tosd2_disable();  /' "FAIL closing in debug mode: the debug page back on the layer"
# debug mode: a toast's end switches the layer off instead of the debug page back
unit ui_debugtoast ui_test src ui.c 's/^\t\t\t\tdebug2_show(1);     \/\* the debug page back over/\t\t\t\tosd2_disable();     \/* the debug page back over/' "FAIL debug mode toast ends: the debug page back"
# opening sets OSD control bit 0 too (the bitmap OSD's enable before Phase 6;
# the firmware keeps it 0)
unit ui_bitmap ui_test src ui.c 's/SPI(to_osd ? DISABLE_KEYBOARD : 0);/SPI(to_osd ? DISABLE_KEYBOARD | 1 : 0);/' "FAIL open: OSD_CMD_OSD 0x02"
# Left on an item without a value stays in the list (a joystick's way back
# to the sidebar)
unit ui_noback ui_test src ui.c '/^static void key_list/,/^}/s/^\tcase KEY_LEFT:              \/\* back to the sidebar, whatever the item \*\/$/\tcase KEY_LEFT: break;/' "FAIL Left on DF0 (no value): back to the sidebar"
# Left on a value item changes it instead of going back (the pre-10-27 model)
unit ui_leftchange ui_test src ui.c '/^static void key_list/,/^}/s/^\tcase KEY_LEFT:              \/\* back to the sidebar, whatever the item \*\/$/\tcase KEY_LEFT: if (it \&\& has_value(it)) { change(it, -1); break; }/' "FAIL Left on Chip RAM (a value): back to the sidebar"
# EDIT never ends on Enter
unit ui_editstuck ui_test src ui.c 's/^\t\t\tui_edit = 0;        \/\* done: the change stays \*\//\t\t\t;/' "FAIL Enter in EDIT: done"
# the help field never switches from the key hints to the focused item's help
unit ui_nohelp ui_test src ui.c 's/^\tui_hints_on = 0;  /\tui_hints_on = 1;  /' "FAIL Up/Down in the list: the item's help"
# the sidebar's Up/Down do not show the category's items until the list has the focus
unit ui_nopreview ui_test src ui.c 's/^\t\t\tui_draw_item(i);$/\t\t\tif (ui_focus != UI_F_SIDEBAR) ui_draw_item(i);/' "FAIL sidebar Down: Storage's items shown at once"
# F12 in the list goes back to the sidebar instead of closing
unit ui_f12back ui_test src ui.c '/^static void key_open/,/^}/s/^\t\tif (ui_focus == UI_F_FILESEL)$/\t\tif (ui_focus == UI_F_LIST) { ui_focus = UI_F_SIDEBAR; return; }\n\t\tif (ui_focus == UI_F_FILESEL)/' "FAIL F12 in the list: closed"
# the file selector ignores sort_table
unit ui_nosort ui_test src ui.c 's/name = entry_name(sort_table\[i\], /name = entry_name(i, /' "FAIL screen filesel"
# leaving System after a memory change: no reset offered
unit ui_noprompt ui_test src ui.c 's/(config.memory != sys_mem || /(0 \&\& /' "FAIL leaving System after a change: the dialog"
# ---- OSD redesign Phase 4: Storage, Video, Acceleration, the error page,
# the migration check (ui_test, migrate_test) ----
# leaving Storage after a change of the IDE slots: no reset offered (and so
# nothing applied)
unit ui_hdfnoprompt ui_test src ui.c 's/^\t\tif (mm_hdf_needs_reset()) {$/\t\tif (0) {/' "FAIL leaving Storage after a change: the reset dialog"
# the hardfile prompt's default Yes (the classic menu's is No)
unit ui_hdfdefault ui_test src ui.c 's/"Reset the Amiga?", b, 2, 1, leave_hdf_done/"Reset the Amiga?", b, 2, 0, leave_hdf_done/' "FAIL No: config unchanged"
# the slot type's Left steps forward too
unit ui_hdfleft ui_test src ui_tabs.c 's/^\tif (dir > 0) {$/\tif (dir) {/' "FAIL type Left twice: backwards round to SD partition 1"
# the RTG pair edited while PAL is on (the position items always RTG's)
unit ui_rtgpal ui_test src ui_tabs.c 's/mm_step_pos(vertical, dir, ui_rtg);/mm_step_pos(vertical, dir, 1);/' "FAIL H Right: -8 -> 0"
# byte 14 asked on a version-1 layer (its MINION_VER taken as the status)
unit osd2_statusgate ui_test src osd2.c 's/^\tif (osd2_caps < OSD2_V_STATUS)$/\tif (0)/' "FAIL version-1 layer: byte 14 never asked"
# the position's label not following the RTG status
unit ui_rtglabel ui_test src ui_tabs.c 's/memcpy(pos_h_label + POS_MODE, m, 3);/;/' "FAIL RTG on: the label says RTG"
# Bloom never greyed
unit ui_bloomavail ui_test src menu_model.c 's/return (config.scanlines \& 3) || (config.crt_beam \& 3) || /return 1 || /' "FAIL no scanlines, no beam, line rate: Bloom greyed"
# the HDMI readback not refreshed while the item is focused
unit ui_hdmilive ui_test src ui.c 's/^\t\t\tui_draw_help(); \/\* a live help/\t\t\t; \/* a live help/' "FAIL HDMI: the readback live, every second"
# the error page's OK does not clear the error (main()'s error loop never ends)
unit ui_errnoclear ui_test src ui.c 's/^\t\t\tClearError(ERROR_ALL);$/\t\t\t;/' "FAIL error Enter: the error cleared"
# a fixed 68040's CPU line selectable
unit ui_cpufixed ui_test src ui_tabs.c 's/return !CORE_CPU_FIXED_040();/return 1;/' "FAIL fixed 68040: the CPU line not selectable"
# the migration check sees a wrong field: Bloom's set writes the beam width
unit mig_wrongfield migrate_test src menu_model.c 's/config.crt_bloom = v > 2 ? 2 : v;/config.crt_beam = v > 2 ? 2 : v;/' "FAIL Bloom off -> high: config"
# ... a wrong value: Chip slots' bit one place off
unit mig_wrongbit migrate_test src menu_model.c 's/\[MMF_CHIPSLOTS\]   = { offsetof(configTYPE, cpu),         4, 1, F_CPU },/[MMF_CHIPSLOTS]   = { offsetof(configTYPE, cpu),         5, 1, F_CPU },/' "FAIL Chip slots Fast: config"
# ... a Config* call missing: the Storage floppy turbo set applies nothing
unit mig_noapply migrate_test src menu_model.c 's/^    case F_FLOPPY:  ConfigFloppy(config.floppy.drives, config.floppy.speed); break;$/    case F_FLOPPY:  break;/' "FAIL Floppy turbo on: the Config\* SPI stream"
# ... the new menu's hardfile prompt resets without applying the slots
unit mig_hdfnoapply migrate_test src ui.c '/^static void leave_hdf_done/,/^}/s/^\t\tmm_hdf_apply();$/\t\tOsdReset();/' "FAIL IDE off, reset Yes: config"
# the shared hardfile apply without its reset: both menus lose it alike (the
# migration check cannot see a fault both share), ui_test's sequence must
unit ui_hdfnoreset ui_test src menu_model.c '/^void mm_hdf_apply(void)/,/^}/s/^    OsdReset();$/    ;/' "FAIL Yes: closed, slot 1 opened, CD, ports, reset"
# ... the RTG register written on a version-1 layer (an old core takes it as PAL)
unit mig_rtgalways migrate_test src osd.c 's/^\tif (osd2_caps >= OSD2_V_STATUS)$/\tif (1)/' "FAIL Video Pos: the RTG register not written on a version-1 layer"
# ... the PAL register given the RTG pair
unit mig_rtgorder migrate_test src osd.c 's/^\tVIDEOSCALE_SET_POS = (config.videopos.hpos + ((unsigned short)config.videopos.vpos << 8));$/\tVIDEOSCALE_SET_POS = (config.videopos_rtg.hpos + ((unsigned short)config.videopos_rtg.vpos << 8));/' "FAIL RTG: VIDEOSCALE = the PAL pair"
# ---- the About and Supporters pages (ui_test; findings/osd-redesign Phase 7) ----
# the effect never advances
unit ui_fxfrozen ui_test src ui.c '/^static void page_tick/,/^}/s/^\tpage->step();$/\t;/' "FAIL About: a step after 3 counts"
# closing a page leaves its glyphs in the font
unit ui_fxnorestore ui_test src ui.c '/^static void page_end/,/^}/s/^\tui_fx_font(0, n < 64 ? n : 64, /\tif (0) ui_fx_font(0, n < 64 ? n : 64, /' "FAIL About Esc: the font as before"
# the slots past 0xBF run into the icons (0xC0-0xC9)
unit ui_fxicons ui_test src ui.c 's/return (unsigned char)(slot < 64 ? 0x80 + slot : 0xCA + (slot - 64));/return (unsigned char)(slot < 64 ? 0x80 + slot : 0xC0 + (slot - 64));/' "FAIL About: the icons (0xC0-0xC9) untouched"
# closing a page leaves its palette
unit ui_fxnopal ui_test src ui.c '/^static void page_end/,/^}/s/^\tmenu_pal();$/\t;/' "FAIL About Esc: the palette as before"
# the menu drawn over a page
unit ui_fxmenu ui_test src ui.c '/^void ui_draw_all(void)/,/^}/s/^\tif (ui_focus == UI_F_PAGE) {$/\tif (0) {/' "FAIL screen about"
# Esc does not close a page
unit ui_fxnoesc ui_test src ui.c '/^static void key_page/,/^}/s/^\tcase KEY_ESC:$/\tcase 0xfe:/' "FAIL About Esc: the list"
# stars over the text
unit ui_fxstars ui_test src ui_about.c 's/sky\[r\]\[c\] = r != R_BAR \&\& blank(r, c - 2)/sky[r][c] = r != R_BAR || blank(r, c - 2)/' "FAIL About: never on the logo, the text, the bar or the help"
# the copper never turns
unit ui_fxcopper ui_test src ui_about.c '/^static void about_step/,/^}/s/^\tphase++;$/\t;/' "FAIL About: the copper moved one step"
# a step redraws the whole page (the per-step bound)
unit ui_fxcost ui_test src ui_about.c '/^static void about_step/,/^}/s/^\tphase++;$/\tphase++;\n\tosd2_invalidate();/' "FAIL About: a step at most 640 SPI bytes"
# the plasma's palette never cycles
unit ui_fxplasma ui_test src ui_supporters.c 's/^\tt = (unsigned char)((t + 1) % RAMP);$/\t;/' "FAIL Supporters: 16 steps cycle the plasma one colour"
# the names never fade in
unit ui_fxfade ui_test src ui_supporters.c 's/^\tif (fade < 255)$/\tif (0)/' "FAIL Supporters: faded in: the names white"
# ---- F6 see-through (ui_test) ----
# F6 ignored
unit ui_f6ignored ui_test src ui.c 's/^\tif (c == KEY_F6 \&\& ui_focus != UI_F_PAGE) {$/\tif (0) {/' "FAIL F6: entry 0 transparent"
# F6 ends EDIT (handled after EDIT's key filter)
unit ui_f6editend ui_test src ui.c 's/^\tif (c == KEY_F6 \&\& ui_focus != UI_F_PAGE) {$/\tif (c == KEY_F6) ui_edit = 0;\n\tif (c == KEY_F6 \&\& ui_focus != UI_F_PAGE) {/' "FAIL F6 in EDIT: EDIT stays"
# the toggle not re-applied after About / Supporters
unit ui_f6pagelost ui_test src ui.c '/^static void page_end/,/^}/s/^\tmenu_pal();$/\tosd2_pal_default();/' "FAIL About Esc with see-through: entry 0 transparent again"
# the toggle not re-applied when the menu opens again
unit ui_f6openlost ui_test src ui.c '/^static void ui_open(void)/,/^}/s/^\tmenu_pal();$/\tosd2_pal_default();/' "FAIL reopened with see-through: entry 0 transparent"
# a page shown see-through (its black not forced opaque)
unit ui_f6pageclear ui_test src ui.c 's/^\tosd2_pal(OSD2_C_BLACK, OSD2_OPAQUE, 0x000000);$/\t;/' "FAIL About with see-through: entry 0 opaque"
# EDIT's black value on the background's entry (see-through inside its strokes)
unit ui_f6ink ui_test src ui.c 's/^#define A_EDIT    A(INK, YELLOW) /#define A_EDIT    A(BLACK, YELLOW) /' "FAIL EDIT: the value's black on the ink"

# ---- OSD redesign Phase 5: the ROM font, OSD size and position ------------------
# the firmware's copy of the font is not osd_font.mem (a glyph of 'A' changed)
unit font_copy ui_test src font8x16.h 's/^        {0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xFE,0xC6,/        {0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xFE,0xC7,/' "FAIL ROM font: osd_font.mem = font8x16.h"
# the menu's bar glyphs not the ROM font's (one row more)
unit font_bar ui_test src ui.c 's/(r >= 3 \&\& r <= 12) ? (unsigned char)(0xff00u >> i)/(r >= 2 \&\& r <= 12) ? (unsigned char)(0xff00u >> i)/' "FAIL open: the font RAM still osd_font.mem"
# About's slots restored from the wrong part of the ROM font
unit font_restore ui_test src ui.c 's/ui_fx_font(0, n < 64 ? n : 64, (const unsigned char \*)font8x16 + 0x80 \* 16);/ui_fx_font(0, n < 64 ? n : 64, (const unsigned char *)font8x16 + 0x40 * 16);/' "FAIL About Esc: the font RAM = osd_font.mem again"
# OSD size not applied: always scale 2
unit ui_osdscale ui_test src ui.c 's/osd2_commit(1, small ? 1 : UI_SCALE, small ? UI_X0_SMALL : UI_X0,/osd2_commit(1, UI_SCALE, small ? UI_X0_SMALL : UI_X0,/' "FAIL OSD size small: the window at once, scale 1, (48, 25)"
# OSD position not applied: always centred
unit ui_osdpos ui_test src ui.c 's/y0\[small\]\[CONFIG_OSD_POS(config.autofire)\], UI_COLS, UI_ROWS);/y0[small][0], UI_COLS, UI_ROWS);/' "FAIL OSD position top: small at (48, 4)"
# not live: the window only at the next open
unit ui_osdlive ui_test src ui_tabs.c '/^static void osd_set/,/^}/s/^\tui_window();$/\t;/' "FAIL OSD size small: the window at once"
# the setting not in the config (not saved): kept in a variable of its own
unit ui_osdnotsaved ui_test src ui_tabs.c '/^static void osd_set/,/^}/s/^\tmm_set_field(arg, v);$/\tstatic unsigned char k; k = v; (void)k;/' "FAIL OSD size Right: small"
# the position's unwritten value 3 shown as is
unit ui_osdpos3 ui_test src ui_tabs.c 's/return arg == MMF_OSDPOS \&\& v > CONFIG_OSD_BOTTOM ? CONFIG_OSD_CENTRE : v;/return v;/' "FAIL position bits 3: shown as centre"
# Ctrl-Alt-keypad 0 clears the OSD bits (as it did)
unit ui_osdkp0 ui_test src ui.c 's/config.autofire = (config.autofire \& ~0x03) | ((config.autofire + 1) \& 0x03);/config.autofire = (config.autofire \& 0x04) | ((config.autofire + 1) \& 0x03);/' "FAIL Ctrl-Alt-keypad 0: the OSD bits kept"
# the toast with the menu closed ignores the size
unit ui_osdtoast ui_test src ui.c 's/^\t\tif (config.autofire \& CONFIG_OSD_SMALL)$/\t\tif (0)/' "FAIL small: the toast's window at scale 1"
# the OSD bits dropped when a config file loads
unit cfg_osdbits config_test src config.c 's/^\t\t\ttmpconf->filter.lores=tmpconf->filter.hires=0;/\t\t\ttmpconf->autofire \&= 7; tmpconf->filter.lores=tmpconf->filter.hires=0;/' "FAIL (a) the OSD bits loaded as the file holds them"

echo "$nkilled mutants killed"
if [ $bad -eq 0 ]; then echo "=== MUTANTS PASS"; else echo "=== MUTANTS FAILED"; fi
exit $bad
