/* Minimal printf for the boot ROM: %d %u %x %X %p %c %s %%, optional 0 flag and
   width, 'l' ignored.  Output goes to putchar() (the UART).  Written for this
   ROM (the 832 copy gets printf from lib832); kept small, no libc. */
#include <stdarg.h>
#include "uart.h"
#include "small_printf.h"

static int emit_num(unsigned int val,unsigned int base,int width,int padzero,int neg)
{
	char tmp[12];
	int n=0,len=0;
	do {
		unsigned int d=val%base;
		tmp[n++]=d<10 ? '0'+d : 'A'+d-10;
		val/=base;
	} while(val);
	if(neg)
		tmp[n++]='-';
	while(n<width)
		tmp[n++]=padzero ? '0' : ' ';
	while(n)
	{
		putchar(tmp[--n]);
		++len;
	}
	return len;
}

int small_printf(const char *fmt,...)
{
	va_list ap;
	int ret=0;
	int c;
	va_start(ap,fmt);
	while((c=*fmt++))
	{
		int width=0,padzero=0;
		if(c!='%')
		{
			putchar(c);
			++ret;
			continue;
		}
		c=*fmt++;
		if(c=='0')
		{
			padzero=1;
			c=*fmt++;
		}
		while(c>='0' && c<='9')
		{
			width=width*10+(c-'0');
			c=*fmt++;
		}
		while(c=='l')
			c=*fmt++;
		switch(c)
		{
			case 'd':
			case 'D':
			{
				int v=va_arg(ap,int);
				ret+=emit_num(v<0 ? -(unsigned int)v : (unsigned int)v,10,v<0 && width>0 ? width-1 : width,padzero,v<0);
				break;
			}
			case 'u':
				ret+=emit_num(va_arg(ap,unsigned int),10,width,padzero,0);
				break;
			case 'x':
			case 'X':
			case 'p':
				ret+=emit_num(va_arg(ap,unsigned int),16,width,padzero,0);
				break;
			case 'c':
				putchar(va_arg(ap,int));
				++ret;
				break;
			case 's':
			{
				const char *s=va_arg(ap,const char *);
				while(*s)
				{
					putchar(*s++);
					++ret;
				}
				break;
			}
			case '%':
				putchar('%');
				++ret;
				break;
			case 0:
				--fmt;
				break;
			default:
				break;
		}
	}
	va_end(ap);
	return ret;
}
