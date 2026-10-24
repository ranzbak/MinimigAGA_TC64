/* boot_test: Amiga-facing words of boot.c, main.c and hexdump.c (Task 14).
 *   boot_test
 *   - BootUploadCopper() without a COPPER_FILE on the card: the default copper
 *     list, as the 68k reads it (big-endian words), at COPPER_ADDRESS ^
 *     HOSTMAP_ADDR -- the host address the firmware writes to.  That page is
 *     mapped here at its own address (mmap MAP_FIXED_NOREPLACE: the window
 *     the firmware sees as Amiga memory), and nothing outside the 24 bytes of
 *     the list changes.  With a COPPER_FILE: its bytes as they are; when its
 *     read fails (a card error, Task 10 fix round 1): the default list.
 *   - CheckSum() (main.c, cut out by the Makefile into checksum.inc: main.c
 *     holds main()), the kickstart checksum the menu shows as checksum_pre: the
 *     sum of the block's big-endian 32-bit words (the 68k's view of the
 *     bytes); at an aligned and at an odd address (VexRiscv traps a misaligned
 *     word load; UBSan stops one here).
 *   - hexdump(): the bytes as big-endian words (the 68k's memory order), at an aligned and at an odd address.
 * The expected values are written out here from the 68k's byte order, not
 * computed by the code under test.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "hardware.h"
#include "boot.h"
#include "rafile.h"
#include "swap.h"		/* checksum.inc: main.c's rd_be32 */
#include "mock_hw.h"

/* ---- what boot.c needs from the rest of the firmware ---- */
unsigned char sector_buffer[1024] __attribute__((aligned(4)));
static const unsigned char *copper_file;   /* NULL: no COPPER_FILE on the card */
static int copper_read_fails;               /* the read gives half, then fails (a card error) */
int RAOpen(RAFile *file, const char *filename)
{
	(void)file;
	return copper_file && !strcmp(filename, COPPER_FILE);
}
int RARead(RAFile *file, unsigned char *pBuffer, unsigned long bytes)
{
	(void)file;
	if (copper_read_fails) {
		memcpy(pBuffer, copper_file, bytes / 2);
		return 0;
	}
	memcpy(pBuffer, copper_file, bytes);
	return 1;
}
void ClearError(int category) { (void)category; }
void BootUploadCopper();
void hexdump(unsigned char *p, unsigned int l);

#include "checksum.inc"

static int fails;

static void check_mem(const char *what, const unsigned char *got, const unsigned char *want, size_t n)
{
	for (size_t i = 0; i < n; i++)
		if (got[i] != want[i]) {
			printf("FAIL %s: byte %zu is %02x, want %02x\n", what, i, got[i], want[i]);
			fails++;
			return;
		}
	printf("ok   %s (%zu bytes)\n", what, n);
}

static void check_val(const char *what, unsigned long got, unsigned long want)
{
	if (got != want) {
		printf("FAIL %s: got %08lx, want %08lx\n", what, got, want);
		fails++;
		return;
	}
	printf("ok   %s = %08lx\n", what, got);
}

static void check_str(const char *what, const char *got, const char *want)
{
	if (strcmp(got, want)) {
		printf("FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
		fails++;
		return;
	}
	printf("ok   %s\n", what);
}

/* The default copper list as 68k words: the bitplane 1 pointer 0x00080000
   (BPL1PTH 0x0e0 / BPL1PTL 0x0e2), bitplane 2 0x00085000 (0x0e4 / 0x0e6),
   BPLCON0 0xa200 (0x100), the end of the list 0xffff 0xfffe. */
static const unsigned char copper_be[24] = {
	0x00, 0xe0, 0x00, 0x08,  0x00, 0xe2, 0x00, 0x00,
	0x00, 0xe4, 0x00, 0x08,  0x00, 0xe6, 0x50, 0x00,
	0x01, 0x00, 0xa2, 0x00,  0xff, 0xff, 0xff, 0xfe,
};

static void test_copper(void)
{
	uintptr_t adr = COPPER_ADDRESS ^ HOSTMAP_ADDR;
	uintptr_t page = adr & ~(uintptr_t)0xfff, len = 0x2000;
	unsigned char *win = mmap((void *)page, len, PROT_READ | PROT_WRITE,
	                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	unsigned char *cop = (unsigned char *)adr, file[COPPER_SIZE], want[0x2000];
	if (win == MAP_FAILED || win != (unsigned char *)page) {
		printf("FAIL cannot map the Amiga window at %lx (COPPER_ADDRESS ^ HOSTMAP_ADDR %lx)\n",
		       (unsigned long)page, (unsigned long)adr);
		fails++;
		return;
	}
	memset(win, 0x5a, len);
	memcpy(want, win, len);
	memcpy(want + (adr - page), copper_be, sizeof copper_be);
	copper_file = NULL;
	BootUploadCopper();
	check_mem("default copper list, big-endian words", cop, copper_be, sizeof copper_be);
	check_mem("default copper list in its window (nothing else written)", win, want, len);

	for (size_t i = 0; i < sizeof file; i++)
		file[i] = (unsigned char)(i * 7 + 1);
	memcpy(want + (adr - page), file, sizeof file);
	copper_file = file;
	BootUploadCopper();
	check_mem("COPPER_FILE: its bytes as they are", win, want, len);
	/* the file's read fails half way (Task 10 fix round 1): the default
	   list, not a part one */
	copper_read_fails = 1;
	BootUploadCopper();
	copper_read_fails = 0;
	check_mem("COPPER_FILE read error: the default list", cop, copper_be, sizeof copper_be);
	munmap(win, len);
}

/* 512 bytes from an LCG: x = x * 1103515245 + 12345 mod 2^31 (x0 = 1), byte i
   = bits 23:16 of the i-th x (c6 7e 81 6b 4b fb e2 fb ...).  Their 128
   big-endian words summed mod 2^32, by python3:
     x = 1; b = bytearray()
     for i in range(512): x = (x * 1103515245 + 12345) & 0x7fffffff; b.append((x >> 16) & 255)
     hex(sum(int.from_bytes(b[i:i+4], "big") for i in range(0, 512, 4)) % 2**32)
   The little-endian sum would be 0xff1d0ae8. */
#define BLOCK_SUM_BE 0x25081ac3UL
static void test_checksum(void)
{
	static unsigned char buf[520] __attribute__((aligned(4)));
	uint32_t x = 1;
	for (int i = 0; i < 512; i++) {
		x = (x * 1103515245u + 12345u) & 0x7fffffffu;
		buf[i] = (unsigned char)(x >> 16);
	}
	check_val("CheckSum of a 512-byte block (aligned)", (uint32_t)CheckSum((char *)buf, 512), BLOCK_SUM_BE);
	memmove(buf + 1, buf, 512);
	check_val("CheckSum of a 512-byte block (odd address)", (uint32_t)CheckSum((char *)buf + 1, 512), BLOCK_SUM_BE);
}

static void test_hexdump(void)
{
	static unsigned char buf[24] __attribute__((aligned(4)));
	static const unsigned char bytes[20] = {
		0x00, 0xe0, 0x00, 0x08, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
		0xff, 0xfe, 0x01, 0x80, 0x44, 0x89, 0x44, 0x89,
	};
	/* hexdump breaks the line when the words left are a multiple of 4 */
	const char *want = "00E00008 \n12345678 9ABCDEF0 FFFE0180 44894489 \n\n";
	memcpy(buf, bytes, sizeof bytes);
	mock_uart_clear();
	hexdump(buf, sizeof bytes);
	check_str("hexdump: the big-endian word view (aligned)", mock_uart(), want);
	memcpy(buf + 3, bytes, sizeof bytes);
	mock_uart_clear();
	hexdump(buf + 3, sizeof bytes);
	check_str("hexdump: the big-endian word view (odd address)", mock_uart(), want);
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);   /* the lines before a sanitizer stop stay */
	mock_reset();
	test_copper();
	test_checksum();
	test_hexdump();
	printf("%s: boot_test, %d failed\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
