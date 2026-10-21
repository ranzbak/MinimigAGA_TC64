
#include "swap.h"

char putchar(char c);

/* The bytes as 32-bit words in memory order (the Amiga's big-endian
   view), read byte by byte (any alignment). */
void hexdump(unsigned char *p,unsigned int l)
{
	l=(l/4);
	while(l--)
	{
		int i;
		unsigned int t=rd_be32(p);
		p+=4;
		for(i=0;i<8;++i)
		{
			unsigned int t2=(t>>28);
			t2+='0';
			if(t2>'9')
				t2+='@'-'9';
			putchar(t2);
			t<<=4;
		}
		putchar(' ');
		if((l&3)==0)
			putchar('\n');
	}
	putchar('\n');
}


