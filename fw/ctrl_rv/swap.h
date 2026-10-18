#ifndef SWAP_H
#define SWAP_H

#include <stdint.h>

/* Byte order.  The code says what the data's order is, not what to do:
 *   le16/le32  a field that is little-endian in memory (FAT, MBR): the
 *              identity on this little-endian CPU, a swap on a big-endian one
 *   be16/be32  a field that is big-endian in memory (Amiga data, RDB): a swap
 *              here, the identity on a big-endian CPU
 * Each converts in both directions (disk -> value and value -> disk).
 *   rd_le16/rd_le32/rd_be16/rd_be32(p)  the value at p, read byte by byte
 *   wr_be16/wr_be32(p, v)               v stored at p byte by byte
 * The rd_/wr_ forms are for data at an address that may be misaligned:
 * VexRiscv traps a misaligned load or store (mcause 4 / 6). */

static inline uint16_t swap_bytes16(uint16_t v)
{
	return (uint16_t)(v >> 8 | v << 8);
}

static inline uint32_t swap_bytes32(uint32_t v)
{
	return v >> 24 | (v >> 8 & 0xff00) | (v << 8 & 0xff0000) | v << 24;
}

/* defined(): a compiler without __BYTE_ORDER__ reaches the #error, it does not
   take the first branch by 0 == 0 */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
static inline uint16_t le16(uint16_t v) { return v; }
static inline uint32_t le32(uint32_t v) { return v; }
static inline uint16_t be16(uint16_t v) { return swap_bytes16(v); }
static inline uint32_t be32(uint32_t v) { return swap_bytes32(v); }
#elif defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
static inline uint16_t le16(uint16_t v) { return swap_bytes16(v); }
static inline uint32_t le32(uint32_t v) { return swap_bytes32(v); }
static inline uint16_t be16(uint16_t v) { return v; }
static inline uint32_t be32(uint32_t v) { return v; }
#else
#error "swap.h: unknown byte order (__BYTE_ORDER__)"
#endif

static inline uint16_t rd_le16(const void *p)
{
	const uint8_t *b = p;
	return (uint16_t)(b[0] | b[1] << 8);
}

static inline uint32_t rd_le32(const void *p)
{
	const uint8_t *b = p;
	return b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

static inline uint16_t rd_be16(const void *p)
{
	const uint8_t *b = p;
	return (uint16_t)(b[0] << 8 | b[1]);
}

static inline uint32_t rd_be32(const void *p)
{
	const uint8_t *b = p;
	return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
}

static inline void wr_be16(void *p, uint16_t v)
{
	uint8_t *b = p;
	b[0] = (uint8_t)(v >> 8);
	b[1] = (uint8_t)v;
}

static inline void wr_be32(void *p, uint32_t v)
{
	uint8_t *b = p;
	b[0] = (uint8_t)(v >> 24);
	b[1] = (uint8_t)(v >> 16);
	b[2] = (uint8_t)(v >> 8);
	b[3] = (uint8_t)v;
}

/* The 832's swaps, for a caller that really means "swap these bytes"
   (fat.c SwapPartitionBytes: an MBR whose signature reads 0x55aa). */
unsigned long SwapBBBB(unsigned long i);
unsigned int SwapBB(unsigned int i);
unsigned long SwapWW(unsigned long i);

#endif

