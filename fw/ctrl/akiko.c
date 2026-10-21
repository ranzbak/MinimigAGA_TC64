#include <stdio.h>

#include "irq.h"

#include "akiko.h"

void akiko_inthandler()
{
	unsigned int aa;
	unsigned int ad;

	aa=HW_AKIKO(REG_AKIKO_ADDR);
	ad=HW_AKIKO(REG_AKIKO_DATA);
	if(aa&AKIKO_REQ)
	{
		if(aa&AKIKO_WRITE)
			printf("Akiko write: %X, %X\n",aa,ad);
		else
			printf("Akiko read: %X\n",aa);
		HW_AKIKO(REG_AKIKO_DATA)=0;
	}

}

__attribute__((constructor(102))) void akikoconstructor()
{
}

