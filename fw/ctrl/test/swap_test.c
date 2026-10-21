/* swap_test: the byte-order helpers of ../swap.h and the swaps of ../swap.c.
 *   make -C fw/ctrl/test run-swap_test
 * le16/le32 name a field that is little-endian in memory, be16/be32 one that
 * is big-endian: whatever the host, storing le32(v) must give v's bytes
 * least significant first, be32(v) most significant first.  rd_* / wr_* are
 * checked at offsets 0..3 of an aligned buffer: a helper that cast the
 * pointer to a wider type would be a misaligned access there, which UBSan
 * (-fsanitize=alignment, part of undefined) stops the run on. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "swap.h"

static int fails;
static int cases;

static void check(const char *what, unsigned long got, unsigned long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got 0x%lx, want 0x%lx\n", what, got, want);
		fails++;
	}
}

/* the bytes of an object, as stored */
static void check_bytes(const char *what, const void *obj, const unsigned char *want, size_t n)
{
	cases++;
	if (memcmp(obj, want, n)) {
		const unsigned char *o = obj;
		printf("FAIL %s: bytes", what);
		for (size_t i = 0; i < n; i++) printf(" %02x", o[i]);
		printf(", want");
		for (size_t i = 0; i < n; i++) printf(" %02x", want[i]);
		printf("\n");
		fails++;
	}
}

static void memory_order(void)
{
	static const unsigned char le_16[] = { 0x34, 0x12 }, be_16[] = { 0x12, 0x34 };
	static const unsigned char le_32[] = { 0x44, 0x33, 0x22, 0x11 }, be_32[] = { 0x11, 0x22, 0x33, 0x44 };
	static const unsigned char le_hi[] = { 0x01, 0x00, 0x00, 0x80 }, be_hi[] = { 0x80, 0x00, 0x00, 0x01 };
	uint16_t h;
	uint32_t w;

	h = le16(0x1234); check_bytes("le16(0x1234) in memory", &h, le_16, 2);
	h = be16(0x1234); check_bytes("be16(0x1234) in memory", &h, be_16, 2);
	w = le32(0x11223344); check_bytes("le32(0x11223344) in memory", &w, le_32, 4);
	w = be32(0x11223344); check_bytes("be32(0x11223344) in memory", &w, be_32, 4);
	w = le32(0x80000001); check_bytes("le32(0x80000001) in memory", &w, le_hi, 4);
	w = be32(0x80000001); check_bytes("be32(0x80000001) in memory", &w, be_hi, 4);

	/* reading: the value of bytes stored in that order */
	memcpy(&h, le_16, 2); check("le16 of LE bytes 34 12", le16(h), 0x1234);
	memcpy(&h, be_16, 2); check("be16 of BE bytes 12 34", be16(h), 0x1234);
	memcpy(&w, le_32, 4); check("le32 of LE bytes 44 33 22 11", le32(w), 0x11223344);
	memcpy(&w, be_32, 4); check("be32 of BE bytes 11 22 33 44", be32(w), 0x11223344);
	memcpy(&w, be_hi, 4); check("be32 of BE bytes 80 00 00 01", be32(w), 0x80000001);

	/* the types: 16 and 32 bits, unsigned, on every ABI */
	check("sizeof le16()", sizeof le16(0), 2);
	check("sizeof le32()", sizeof le32(0), 4);
	check("sizeof be16()", sizeof be16(0), 2);
	check("sizeof be32()", sizeof be32(0), 4);
	check("be16(0x8001) unsigned", be16(0x8001), 0x0180);
	check("be32(0x000000FF) no sign extension", be32(0x000000FF), 0xFF000000ul);

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	/* this host (and RV32) is little-endian: le* is the identity, be* a swap */
	check("LE host: le16 identity", le16(0xA55A), 0xA55A);
	check("LE host: le32 identity", le32(0x89ABCDEF), 0x89ABCDEF);
	check("LE host: be16 swaps", be16(0xA55A), 0x5AA5);
	check("LE host: be32 swaps", be32(0x89ABCDEF), 0xEFCDAB89);
#endif
}

static void byte_access(void)
{
	/* 4-aligned, so that p + off is misaligned for off = 1..3 */
	static unsigned char buf[16] __attribute__((aligned(4)));
	char what[64];

	for (int i = 0; i < 16; i++) buf[i] = (unsigned char)(0x81 + i);
	for (int off = 0; off < 4; off++) {
		const unsigned char *b = buf + off;
		unsigned long le_16 = b[0] | (unsigned long)b[1] << 8;
		unsigned long be_16 = (unsigned long)b[0] << 8 | b[1];
		unsigned long le_32 = b[0] | (unsigned long)b[1] << 8 | (unsigned long)b[2] << 16 | (unsigned long)b[3] << 24;
		unsigned long be_32 = (unsigned long)b[0] << 24 | (unsigned long)b[1] << 16 | (unsigned long)b[2] << 8 | b[3];
		snprintf(what, sizeof what, "rd_le16 at offset %d", off); check(what, rd_le16(b), le_16);
		snprintf(what, sizeof what, "rd_be16 at offset %d", off); check(what, rd_be16(b), be_16);
		snprintf(what, sizeof what, "rd_le32 at offset %d", off); check(what, rd_le32(b), le_32);
		snprintf(what, sizeof what, "rd_be32 at offset %d", off); check(what, rd_be32(b), be_32);
	}

	for (int off = 0; off < 4; off++) {
		unsigned char want[16];
		memset(buf, 0xEE, sizeof buf);
		memset(want, 0xEE, sizeof want);
		wr_be16(buf + off, 0xC1C2);
		want[off] = 0xC1; want[off + 1] = 0xC2;
		snprintf(what, sizeof what, "wr_be16 at offset %d (and nothing else)", off);
		check_bytes(what, buf, want, sizeof buf);

		memset(buf, 0xEE, sizeof buf);
		memset(want, 0xEE, sizeof want);
		wr_be32(buf + off, 0x81828384);
		want[off] = 0x81; want[off + 1] = 0x82; want[off + 2] = 0x83; want[off + 3] = 0x84;
		snprintf(what, sizeof what, "wr_be32 at offset %d (and nothing else)", off);
		check_bytes(what, buf, want, sizeof buf);
		snprintf(what, sizeof what, "rd_be32 of wr_be32 at offset %d", off);
		check(what, rd_be32(buf + off), 0x81828384);
	}
}

/* the plain byte swaps (kept for callers that mean "swap"): 32-bit results on
   every ABI, no sign extension of bit 15 / bit 31 */
static void legacy_swaps(void)
{
	check("SwapBB(0x1234)", SwapBB(0x1234), 0x3412);
	check("SwapBB(0x80FF)", SwapBB(0x80FF), 0xFF80);
	check("SwapBBBB(0x11223344)", SwapBBBB(0x11223344), 0x44332211);
	check("SwapBBBB(0x000000FF)", SwapBBBB(0x000000FF), 0xFF000000ul);
	check("SwapBBBB(0x80000001)", SwapBBBB(0x80000001), 0x01000080);
	check("SwapWW(0x11223344)", SwapWW(0x11223344), 0x33441122);
	check("SwapWW(0x0000FFFF)", SwapWW(0x0000FFFF), 0xFFFF0000ul);
}

int main(void)
{
	memory_order();
	byte_access();
	legacy_swaps();
	printf("%d cases: %d failed\n", cases, fails);
	if (fails) { printf("swap_test FAIL\n"); return 1; }
	printf("swap_test PASS\n");
	return 0;
}
