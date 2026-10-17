#include <stdio.h>

#include "errors.h"

void ClearError(int category)
{
	int i,a,b;
	ErrorFatal=0;
	if(category!=ERROR_ALL)
	{
		ErrorMask&=~(1<<category);
		a=b=category;
	}
	else
	{
		a=0;
		b=ERROR_MAX;
		ErrorMask=0;
	}
	for(i=a;i<=b;++i)
	{
		Errors[i].string="";
		Errors[i].a=0;
		Errors[i].b=0;
	}
}

int ErrorFatal=0;
int ErrorMask=0;

char *ErrorMessages[ERROR_MAX+1]=
{
	"SD Card",
	"Filesystem",
	"Kickstart ROM",
	"Floppy emulation",
	"Harddrive emulation"
};


struct Error Errors[ERROR_MAX+1];

