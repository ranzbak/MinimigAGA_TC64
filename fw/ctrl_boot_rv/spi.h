#ifndef SPI_H
#define SPI_H

#define SPIBASE 0xffffffe0
#define HW_SPI(x) *(volatile unsigned char *)(SPIBASE+x)

/* SPI registers */
/* cfide window: the value sits at offset 0 of each 16-byte window, 8-bit access. */
#define HW_SPI_DATA 0x00 /* Blocks on both reads and writes, making BUSY signal redundant. */
#define HW_SPI_CS 0x04
#define HW_SPI_SPEED 0x08

#define EnableOsd()   HW_SPI(HW_SPI_CS)=0x20
#define DisableOsd()  HW_SPI(HW_SPI_CS)=0x21

#define EnableCard()  HW_SPI(HW_SPI_CS)=0x02
#define DisableCard() HW_SPI(HW_SPI_CS)=0x03

#define SPI_slow()  HW_SPI(HW_SPI_SPEED)=0xef
#define SPI_fast()  HW_SPI(HW_SPI_SPEED)=0x07

#define OSD_CMD_WR        0x1c

#define OSD_CMD_RST       0x08

#define SPI_RST_USR         0x1
#define SPI_RST_CPU         0x2
#define SPI_CPU_HLT         0x4


#define OSD_CMD_CHIP      0x04

#define CONFIG_TURBO     1
#define CONFIG_NTSC      2
#define CONFIG_A1000     4
#define CONFIG_ECS       8
#define CONFIG_AGA      16

#define PLATFORM (*(volatile unsigned short *)0xffffffc0)
#define PLATFORM_SCANDOUBLER 0



int spi_init();
int sd_read_sector(unsigned long lba,unsigned char *buf);
int sd_write_sector(unsigned long lba,unsigned char *buf); // FIXME - stub

#endif
