#ifndef SWAP_H
#define SWAP_H

unsigned int SwapBBBB(unsigned int i);
unsigned int SwapBB(unsigned int i);
unsigned int SwapWW(unsigned int i);

/* On-disk FAT/MBR fields are little-endian.  le16/le32 convert them to host order:
   identity on a little-endian host (the RISC-V boot ROM), a byte swap on a
   big-endian one (the 832). */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define le16(x) ((unsigned int)(x) & 0xffffu)
#define le32(x) ((unsigned int)(x))
/* big-endian 32-bit word -> host order */
#define be32(x) SwapBBBB((unsigned int)(x))
#else
#define le16(x) SwapBB(x)
#define le32(x) SwapBBBB(x)
#define be32(x) ((unsigned int)(x))
#endif

#endif

