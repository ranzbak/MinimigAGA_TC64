#include "uart.h"

int putchar(int c)
{
	HW_UART(REG_UART)=c;
	return(c);
}


int puts(const char *msg)
{
	int c;
	int result=0;
	while((c=*msg++))
	{
		putchar(c);
		++result;
	}
	return(result);
}

