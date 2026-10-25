#include "swap.h"

/* The results are unsigned: an int result was sign-extended into a 64-bit
   unsigned long (LP64 host tests) when bit 31 was set; on RV32 the bits are
   the same either way. */
unsigned long SwapBBBB(unsigned long i)
{
#ifdef _M68K
	asm volatile
	(
		"rol.w #8,%0\n\t"
		"swap %0\n\t"
		"rol.w #8,%0\n\t"
	: "=r" (i) /* out */
	: "r" (i) 
	: /* no clobber */
	);	
	return i;
#else
	unsigned long result=(i>>24)&0xff;
	result|=(i>>8)&0xff00;
	result|=(i<<8)&0xff0000;
	result|=(i<<24)&0xff000000;
	return(result);
#endif
}

unsigned int SwapBB(unsigned int i)
{
	unsigned int result=(i>>8)&0xff;
	result|=(i<<8)&0xff00;
	return(result);
}

unsigned long SwapWW(unsigned long i)
{
	unsigned long result=(i>>16)&0xffff;
	result|=(i<<16)&0xffff0000;
	return(result);
}
