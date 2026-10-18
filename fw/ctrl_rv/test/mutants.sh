#!/usr/bin/env bash
# Mutants of the host tests (make -C fw/ctrl_rv/test mutants).
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
# Environment: LIB832, ISO, HOSTCC (make -C fw/ctrl_rv/test mutants passes them).
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
  cp ../*.c ../*.h "mut/$n/src/"
  cp -r ../arch "mut/$n/src/arch"
  cp ./*.c ./*.h ./*.sh "mut/$n/t/"
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

# unit <name> <test> <src|t|gold> <file> <sed> [text]: the test must fail,
# native; with [text], a failure whose log does not hold it is BROKEN (the
# mutant must be killed by that case)
unit() {
  local n=$1 test=$2
  prep "$n"; mutate "$n" "$3" "$4" "$5" || return
  if ! mk "$n" "mut/$n/b/$test" > "mut/$n/log" 2>&1; then
    echo "mutant $n: BROKEN (does not build: mut/$n/log)"; bad=1; return
  fi
  # a mutant may hang a loop that waits for the mock: the timeout is a kill
  timeout 120 make -s -f Makefile SRC="mut/$n/src" TD="mut/$n/t" GOLD="mut/$n/gold" B="mut/$n/b" \
       WERROR=-Wno-error CARD="$CARD" FATIMG="$FATIMG" FATIMG_DEPS= "run64-$test" > "mut/$n/log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && [ -n "${6:-}" ] && ! grep -q -- "$6" "mut/$n/log"; then
    echo "mutant $n: BROKEN (run64-$test failed, but not with \"$6\": mut/$n/log)"; bad=1; return
  fi
  verdict "$n" $rc "run64-$test"
}

# fmt <name> <src|t|gold> <file> <sed> [expected text in the output]
fmt() {
  local n=$1
  prep "$n"; mutate "$n" "$2" "$3" "$4" || return
  if ! mk "$n" "mut/$n/b/fmt_glibc_64.txt" "mut/$n/b/fmt_glibc_32.txt" "mut/$n/b/fmt_832.txt" > "mut/$n/log" 2>&1; then
    echo "mutant $n: BROKEN (producers do not build: mut/$n/log)"; bad=1; return
  fi
  mk "$n" fmt > "mut/$n/log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && [ -n "${5:-}" ] && ! grep -q -- "$5" "mut/$n/log"; then
    echo "mutant $n: BROKEN (fmt failed, but not with \"$5\": mut/$n/log)"; bad=1; return
  fi
  verdict "$n" $rc "make fmt"
}

# controls: the unmutated copy passes every test target
control() {
  prep control
  local t rc=0
  for t in mock_selftest cue_test cdaudio_test atapi_test cdrom_test openhf_test lib_test hwmap_test swap_test fat_test mmc_test; do
    mk control "run64-$t" > "mut/control/log.$t" 2>&1 || { echo "control: run64-$t FAILED (mut/control/log.$t)"; rc=1; }
  done
  mk control fmt > mut/control/log.fmt 2>&1 || { echo "control: fmt FAILED (mut/control/log.fmt)"; rc=1; }
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
fmt expected gold fmt_diff_expected.txt '7d' '^[0-9][0-9,]*[acd][0-9]'
fmt formats_stale gold formats.txt '$d' "differ\|EOF"
fmt cover_case t fmt_cases.h '/^FMT_CASE("          1 %s"/d' "no case"

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
unit fat_link16 fat_test src fat.c 's/file->cluster = le16(fat_buffer.fat16\[i\]);/file->cluster = SwapBB(fat_buffer.fat16[i]);/'
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

# ---- the SD driver (mmc_test) -------------------------------------------------
# the brief's mutant: no time at all for the data token -> the 200-byte delay fails
unit mmc_timeout0 mmc_test src mmc.c 's/^#define SD_TIMEOUT 173$/#define SD_TIMEOUT 0/' "FAIL MMC_Read lba 300, token delay 200"
# too long a bound passes silently under the auto-advancing TIMER: the byte bound catches it
unit mmc_timeout_long mmc_test src mmc.c 's/^#define SD_TIMEOUT 173$/#define SD_TIMEOUT 1000/' "FAIL CMD17: wait bytes"
# each of the five bounds on its own
unit mmc_bound_read mmc_test src mmc.c '/^unsigned char MMC_Read(/,/^}/ s/GetTimer(SD_TIMEOUT)/GetTimer(2 * SD_TIMEOUT)/' "FAIL CMD17: wait bytes"
unit mmc_bound_csd mmc_test src mmc.c '/^unsigned char MMC_GetCSD(/,/^}/ s/GetTimer(SD_TIMEOUT)/GetTimer(2 * SD_TIMEOUT)/' "FAIL CMD9: wait bytes"
unit mmc_bound_multi mmc_test src mmc.c '/^unsigned char MMC_ReadMultiple(/,/^}/ s/GetTimer(SD_TIMEOUT)/GetTimer(2 * SD_TIMEOUT)/' "FAIL CMD18: wait bytes"
unit mmc_bound_write mmc_test src mmc.c '/^unsigned char MMC_Write(/,/^}/ s/GetTimer(SD_TIMEOUT)/GetTimer(2 * SD_TIMEOUT)/' "FAIL CMD24: wait bytes"
unit mmc_bound_cmd12 mmc_test src mmc.c '/^unsigned char MMC_CMD12(/,/^}/ s/GetTimer(SD_TIMEOUT)/GetTimer(2 * SD_TIMEOUT)/' "FAIL CMD12: wait bytes"
# MMC_Init: the command golden (ACMD41 without HCS) and the speed switch
unit mmc_init_hcs mmc_test src mmc.c 's/MMC_Command(CMD41, 1 << 30)/MMC_Command(CMD41, 0)/' "FAIL the card's commands"
unit mmc_init_slow mmc_test src mmc.c 's/^\tSPI_slow();$/\t;/' "FAIL SPI slow before CMD0"
# direct mode: one byte instead of cfide's 4096 clocks -> gold/dmode.txt
unit mmc_dmode mmc_test t mock_hw.c 's/for (int n = 0; n < 512; n++) {/for (int n = 0; n < 1; n++) {/' "FAIL the direct-mode trace"

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
hwmap irqctl_width arch/irq.h 's/HW_IRQ_MASK        (\*(volatile unsigned int/HW_IRQ_MASK        (*(volatile unsigned short/'
# uart.c
unit puts_nl hwmap_test src uart.c 's/++result;/++result; if (!*msg) putchar(10);/'
unit puts_words hwmap_test src uart.c 's/(c=(unsigned char)\*msg++)/(c=(unsigned char)*msg++) \&\& result < 1/'

echo "$nkilled mutants killed"
if [ $bad -eq 0 ]; then echo "=== MUTANTS PASS"; else echo "=== MUTANTS FAILED"; fi
exit $bad
