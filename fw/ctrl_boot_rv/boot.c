/*	Firmware for loading files from SD card.
	Part of the MinimigAGA core TC64 port by Alastair M. Robinson.
	SPI and FAT code borrowed from the Minimig project.
*/

#include "spi.h"
#include "swap.h"
#include "minfat.h"
#include "checksum.h"
#include "small_printf.h"
#include "uart.h"

/* #define STANDALONE to disable anything that requires the Minimig core to be functional,
   to reduce build times when debugging host facilities. */
/*#define STANDALONE*/

#include "bootdiag.h"

#ifndef STANDALONE
void BootDiag()
{
	unsigned char *upload=(unsigned char *)(0x780000^0x680000);
	const unsigned char *src=bootdiag_bin;
	int i=bootdiag_bin_len;
	while(i--)
		*upload++=*src++;
}
#endif

void ErrorCode(int code)
{
#ifndef STANDALONE
	unsigned char *upload=(unsigned char *)(0x780000^0x680000);
	EnableOsd();
	HW_SPI(HW_SPI_DATA)=OSD_CMD_RST;
	HW_SPI(HW_SPI_DATA)=SPI_RST_CPU|SPI_CPU_HLT; // Reset the chipset to allow the NTSC flag to take effect.
	DisableOsd();
	upload[10]=code>>8;
	upload[11]=code&255;
	EnableOsd();
	HW_SPI(HW_SPI_DATA)=OSD_CMD_RST;
	HW_SPI(HW_SPI_DATA)=0; // Reset the chipset to allow the NTSC flag to take effect.
	DisableOsd();
#endif
}

void _boot()
{
	void (*entry)(void);
	entry=(void (*)(void))prg_start;
	/* The program was just written through the data side; make the fetch side see it. */
	__asm__ volatile("fence.i" ::: "memory");
	entry();
}

static void puthex8(unsigned int v)
{
	int i;
	for(i=0;i<8;++i)
	{
		unsigned int c=(v>>28)&0xf;
		putchar(c>9 ? c+'A'-10 : c+'0');
		v<<=4;
	}
}

/* Called from boot_trap in crt0.S (stack already reset): report and park. */
void boot_trap_c(unsigned int mcause,unsigned int mepc,unsigned int mtval)
{
	puts("TRAP ");
	puthex8(mcause);
	putchar(' ');
	puthex8(mepc);
	putchar(' ');
	puthex8(mtval);
	putchar('\n');
	ErrorCode(0xf0f);
	while(1)
		;
}

void _break();


char printbuf[32];

void cvx(int val,char *buf)
{
	int i;
	int c;
	for(i=0;i<8;++i)
	{
		c=(val>>28)&0xf;
		val<<=4;
		if(c>9)
			c+='A'-10;
		else
			c+='0';
		*buf++=c;
	}
}


int main(int argc,char **argv)
{
	int i;
	int err=0;
	SPI_slow();

#ifndef STANDALONE
	EnableOsd();
	HW_SPI(HW_SPI_DATA)=OSD_CMD_RST;
	HW_SPI(HW_SPI_DATA)=SPI_RST_CPU|SPI_CPU_HLT; // Allow the Chipset to start up
	DisableOsd();

	PLATFORM=(1<<PLATFORM_SCANDOUBLER);

	EnableOsd();
	HW_SPI(HW_SPI_DATA)=OSD_CMD_CHIP;
	HW_SPI(HW_SPI_DATA)=CONFIG_NTSC;
	DisableOsd();

	EnableOsd();
	HW_SPI(HW_SPI_DATA)=OSD_CMD_RST;
	HW_SPI(HW_SPI_DATA)=SPI_RST_USR|SPI_RST_CPU|SPI_CPU_HLT; // Reset the chipset to allow the NTSC flag to take effect.
	DisableOsd();

	BootDiag();
	ErrorCode(0xfff);
#endif

	while(1)
	{
		err=0xf00;
		puts("Initializing SD card\n");
		if(spi_init())
		{
			err=0xff0;
			puts("Hunting for partition\n");
			if(FindDrive())
			{
				err=0x0f0;
				int romsize;
				int *checksums;
				if(romsize=LoadFile(OSDNAME,(unsigned char *)prg_start))
				{
					int error=0;
					char *sector=(char *)prg_start;
					int offset=0;
					err=0x0ff;
					_boot();
				}
				else
					puts("Can't load firmware\n");
			}
			else
			{
				puts("Unable to locate partition\n");
			}
		}
		else
			puts("Failed to initialize SD card\n");
		ErrorCode(err);
	}
	return(0);
}

