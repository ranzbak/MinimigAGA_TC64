/* rom_test: a failed card read during a ROM load (findings/sdcard-engine
 * Task 10 fix round 1).  SendFileV2 (fpga.c) and UploadKickstart (config.c),
 * cut out by the Makefile (both files pull in the OSD and boot code), on
 * stub files: RAOpen / RARead serve ROM files of the sizes UploadKickstart
 * knows, RARead fails on a chosen call.  The Amiga window SendFileV2 writes
 * to (address & 0x7fffff ^ HOSTMAP_ADDR: 0x080000..0x17ffff for the
 * 0xe00000 and 0xf80000 copies) is mapped here at its own address.
 *   - a good 512 KB load: 512 returned, both copies the file's bytes, no error
 *   - a failed block read: SendFileV2 0 at once (no further read), ERROR_ROM
 *     ("ROM read error", the block's address and number), UploadKickstart 0
 *   - a failed read of the second copy, of a keyed ROM's header, of the
 *     ROM key file: UploadKickstart 0, ERROR_ROM set
 * ERROR_ROM is what the error page reboots on (menu.c MENU_ERROR2). */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "hardware.h"
#include "errors.h"
#include "rafile.h"
#include "config.h"
#include "fpga.h"
#include "fat.h"
#include "boot.h"

/* ---- what the two functions need ---- */
int ErrorMask, ErrorFatal;
struct Error Errors[ERROR_MAX + 1];
void ClearError(int category)
{
	if (category == ERROR_ALL) { ErrorMask = 0; ErrorFatal = 0; }
	else ErrorMask &= ~(1 << category);
}
configTYPE config;
char s[40];
unsigned char sector_buffer[1024];
RAFile romfile;
unsigned char romkey[3072];
int checksum_pre;
const char *kickfoundstr, *applypatchstr;
int CheckSum(char *adr, int size) { (void)adr; (void)size; return 0; }
void PatchKick1xMemoryDetection(unsigned char *buf) { (void)buf; }
int ValidateDirectory(unsigned long directory) { (void)directory; return 1; }
void ChangeDirectory(unsigned long iStartCluster) { (void)iStartCluster; }
char BootPrint(const char *text) { (void)text; return 0; }
void BootPrintEx(char *str) { (void)str; }
static void ClearVectorTable(void) { }
static void ClearKickstartMirrorE0(void) { }

/* the stub files: KICK.ROM (512 KB), KEYED.ROM (0x8000b), ROM KEY (11 bytes) */
static unsigned long rom_size = 0x80000, key_size = 11;
static int have_key;
static int reads, fail_at = -1;
static unsigned char file_byte(const RAFile *f, unsigned long off)
{
	return (unsigned char)(off * 7 + (off >> 9) + (f->size & 0xFF));
}
int RAOpen(RAFile *file, const char *filename)
{
	memset(file, 0, sizeof *file);
	if (!strcmp(filename, "ROM     KEY")) {
		if (!have_key) return 0;
		file->size = key_size;
	} else if (!strncmp(filename, "KICK    ROM", 11))
		file->size = rom_size;
	else
		return 0;
	file->file.size = file->size;
	return 1;
}
int RARead(RAFile *file, unsigned char *pBuffer, unsigned long bytes)
{
	if (reads++ == fail_at)
		return 0;
	for (unsigned long i = 0; i < bytes; i++)
		pBuffer[i] = file_byte(file, file->ptr + i);
	file->ptr += bytes;
	return 1;
}

#include "sendfile.inc"
#include "uploadkick.inc"

/* ---- reporting ---- */
static int fails, cases;
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
	} else
		say("ok   %s = %ld\n", what, got);
}

#define WIN_LO 0x080000UL
#define WIN_SIZE 0x100000UL
static unsigned char *amiga(unsigned long a) { return (unsigned char *)(((a & 0x7fffff) ^ HOSTMAP_ADDR)); }

static void fresh(void)
{
	ErrorMask = 0;
	ErrorFatal = 0;
	memset(Errors, 0, sizeof Errors);
	memset((void *)WIN_LO, 0, WIN_SIZE);
	reads = 0;
	fail_at = -1;
	have_key = 0;
	rom_size = 0x80000;
}

static int copy_ok(unsigned long a)
{
	RAFile f = { 0 };
	f.size = rom_size;
	for (unsigned long i = 0; i < 0x80000; i++)
		if (amiga(a)[i] != file_byte(&f, i)) return 0;
	return 1;
}

int main(void)
{
	void *w;
	setvbuf(stdout, NULL, _IOLBF, 0);
	w = mmap((void *)WIN_LO, WIN_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	if (w != (void *)WIN_LO) { say("FAIL cannot map the Amiga window at %lx\n", WIN_LO); return 1; }

	fresh();
	check("good: UploadKickstart 512 KB", UploadKickstart(0, "KICK    "), 512);
	check("good: the 0xf80000 copy", copy_ok(0xf80000), 1);
	check("good: the 0xe00000 copy", copy_ok(0xe00000), 1);
	check("good: no error", ErrorMask, 0);

	fresh();
	fail_at = 100;			/* block 100 of the first copy */
	check("block read fails: UploadKickstart 0", UploadKickstart(0, "KICK    "), 0);
	check("... ERROR_ROM set (the Reboot path)", (ErrorMask >> ERROR_ROM) & 1, 1);
	check("... the message", !strcmp(Errors[ERROR_ROM].string ? Errors[ERROR_ROM].string : "", "ROM read error"), 1);
	check("... the block number", Errors[ERROR_ROM].b, 100);
	check("... no read after the failed one", reads, 101);

	fresh();
	fail_at = 1024 + 7;		/* the second copy (after the reopen) */
	check("second copy fails: UploadKickstart 0", UploadKickstart(0, "KICK    "), 0);
	check("... ERROR_ROM set", (ErrorMask >> ERROR_ROM) & 1, 1);

	fresh();
	{
		RAFile f = { 0 };
		f.size = rom_size;
		fail_at = 3;
		check("SendFileV2 alone: 0", SendFileV2(&f, NULL, 0, 0xf80000, 0x80000 >> 9), 0);
		check("... ERROR_ROM set", (ErrorMask >> ERROR_ROM) & 1, 1);
		check("... the address", Errors[ERROR_ROM].a, 0xf80000);
	}

	fresh();
	have_key = 1;
	rom_size = 0x8000b;
	fail_at = 0;			/* the key file's read */
	check("key read fails: UploadKickstart 0", UploadKickstart(0, "KICK    "), 0);
	check("... ERROR_ROM set", (ErrorMask >> ERROR_ROM) & 1, 1);
	check("... the message", !strcmp(Errors[ERROR_ROM].string ? Errors[ERROR_ROM].string : "", "ROM Key file read error"), 1);
	check("... no ROM read", reads, 1);

	fresh();
	have_key = 1;
	rom_size = 0x8000b;
	fail_at = 1;			/* the keyed ROM's 11-byte header */
	check("keyed header read fails: UploadKickstart 0", UploadKickstart(0, "KICK    "), 0);
	check("... ERROR_ROM set", (ErrorMask >> ERROR_ROM) & 1, 1);

	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails ? 1 : 0;
}
