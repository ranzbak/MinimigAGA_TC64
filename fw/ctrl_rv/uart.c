#include "hardware.h"

int putchar(int c)
{
	RS232(c);
	return(c);
}


int puts(const char *msg)
{
	int c;
	int result=0;
	// A byte loop (no newline appended, like the 832's puts).
	while((c=(unsigned char)*msg++))
	{
		putchar(c);
		++result;
	}
	return(result);
}

