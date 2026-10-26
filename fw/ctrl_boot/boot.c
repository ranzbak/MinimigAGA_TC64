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
#include "lockstep.h"

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

/* one two-byte command frame to the OSD (userio_osd.v) on cfide's SPI */
void osd_cmd(unsigned char cmd, unsigned char v)
{
	EnableOsd();
	HW_SPI(HW_SPI_DATA)=cmd;
	HW_SPI(HW_SPI_DATA)=v;
	DisableOsd();
}

void ErrorCode(int code)
{
#ifndef STANDALONE
	unsigned char *upload=(unsigned char *)(0x780000^0x680000);
	osd_cmd(OSD_CMD_RST, SPI_RST_CPU|SPI_CPU_HLT); // Reset the chipset to allow the NTSC flag to take effect.
	upload[10]=code>>8;
	upload[11]=code&255;
	osd_cmd(OSD_CMD_RST, 0); // Reset the chipset to allow the NTSC flag to take effect.
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

/* The end of the ROM's road (lockstep.c): interrupts off (they are never
   on in the ROM; this states it), park. */
void boot_halt(void)
{
	__asm__ volatile("csrci mstatus, 8" ::: "memory");
	for(;;)
		;
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
	int err=0;
	int size;
	SPI_slow();

#ifndef STANDALONE
	osd_cmd(OSD_CMD_RST, SPI_RST_CPU|SPI_CPU_HLT); // Allow the Chipset to start up

	PLATFORM=(1<<PLATFORM_SCANDOUBLER);

	osd_cmd(OSD_CMD_CHIP, CONFIG_NTSC);

	osd_cmd(OSD_CMD_RST, SPI_RST_USR|SPI_RST_CPU|SPI_CPU_HLT); // Reset the chipset to allow the NTSC flag to take effect.

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
				if((size=LoadFile(OSDNAME,(unsigned char *)prg_start)))
					fw_start((unsigned char *)prg_start,size);	/* boots, or ErrorCode(0x0ff) and halts */
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

