#ifndef HDD_H
#define HDD_H

#define CMD_IDECMD 0x04
#define CMD_IDEDAT 0x08

/* HDD SPI commands.  Bit 0 of the command byte (bit 8 of the first SPI
   word) selects the IDE port: OR in ide_port (findings/cdrom/plan.md 7.3). */
#define CMD_IDE_REGS_RD 0x80
#define CMD_IDE_REGS_WR 0x90
#define CMD_IDE_DATA_WR 0xA0
#define CMD_IDE_DATA_RD 0xB0
#define CMD_IDE_XFER_WR 0xC0	/* packet mode: {pkt, 2'b0, words[12:0]} */
#define CMD_IDE_STATUS_WR 0xF0

/* Flags in bits 15:8 of every task file register read (two-port Gayle). */
#define IDEF_PORT      0x01	/* the port this read came from */
#define IDEF_XFER_DONE 0x02	/* the packet-mode transfer is complete */
#define IDEF_DEV_WR    0x04	/* the host wrote drive/head (read clears) */
#define IDEF_RST_SEEN  0x08	/* the Amiga was reset (read clears) */
#define IDEF_PKT       0x10	/* packet mode is on */
#define IDEF_BSY0      0x20	/* port 1 has a command waiting */
#define IDEF_BSY1      0x40	/* port 2 has a command waiting */

#define IDE_STATUS_END 0x80
#define IDE_STATUS_SIG 0x20	/* the host reads the ATA/ATAPI signature (two-port Gayle) */
#define IDE_STATUS_IRQ 0x10
#define IDE_STATUS_RDY 0x08
#define IDE_STATUS_REQ 0x04
#define IDE_STATUS_ERR 0x01

#define ACMD_RECALIBRATE 0x10
#define ACMD_IDENTIFY_DEVICE 0xEC
#define ACMD_INITIALIZE_DEVICE_PARAMETERS 0x91
#define ACMD_READ_SECTORS 0x20
#define ACMD_WRITE_SECTORS 0x30
#define ACMD_READ_MULTIPLE 0xC4
#define ACMD_WRITE_MULTIPLE 0xC5
#define ACMD_SET_MULTIPLE_MODE 0xC6
#define ACMD_DIAGNOSTIC 0x90

#define HDF_DISABLED 0
#define HDF_FILE 1
#define HDF_CARD 2
#define HDF_CARDPART0 3
#define HDF_CARDPART1 4
#define HDF_CARDPART2 5
#define HDF_CARDPART3 6
#define HDF_CDROM 7		/* ATAPI CD-ROM drive with an ISO (cdrom.c) */
#define HDF_TYPEMASK 15
#define HDF_SYNTHRDB 128	// Flag to indicate whether we should auto-synthesize a RigidDiskBlock

typedef struct
{
	int			   type;	// Are we using a file, the entire SD card or a partition on the SD card?
    fileTYPE       file;
    unsigned short cylinders;
    unsigned short heads;
    unsigned short sectors;
    unsigned short sectors_per_block;
	unsigned short partition;	// Partition no.
	long  offset;	// If a partition, the lba offset of the partition.  Can be negative if we've synthesized an RDB.
    unsigned long  index[1024];
    unsigned long  index_size;
} hdfTYPE;

void IdentifyDevice(unsigned short *pBuffer, int unit);
unsigned long chs2lba(int cylinder, int head, int sector, int unit);
void WriteTaskFile(int error,int sector_count,int sector_number,int cylinder_low,int cylinder_high,int drive_head);
void WriteStatus(unsigned int status);
void WriteXfer(unsigned int words, int pkt);
unsigned char ReadTaskFile(int port, unsigned char *tfr);
unsigned char ReadIDEFlags(int port);
void WriteIDEData(const unsigned char *buf, unsigned int bytes);
void ReadIDEData(unsigned char *buf, unsigned int bytes);
void HandleHDD(unsigned int c1, unsigned int c2);
void GetHardfileGeometry(hdfTYPE *hdf);
void BuildHardfileIndex(hdfTYPE *hdf);
unsigned char HardFileSeek(hdfTYPE *hdf, unsigned long lba);
unsigned char OpenHardfile(unsigned int unit);

#define HDF_FILETYPE_UNKNOWN 0
#define HDF_FILETYPE_NOTFOUND 1
#define HDF_FILETYPE_RDB 2
#define HDF_FILETYPE_DOS 3

unsigned char GetHDFFileType(char *filename);

extern char debugmsg[40];
extern char debugmsg2[40];

/* IDE slots: port << 1 | slave.  0/1 = config.hardfile[], 2/3 =
   config.secondaryhardfile[] (port 2). */
#define HDD_SLOTS 4
extern hdfTYPE hdf[HDD_SLOTS];

/* The IDE port the HDD SPI commands go to (0 or 1); set before each command.
   A card read with no buffer (mmc.h) goes into its Gayle FIFO.  Defined in
   mmc.c. */
extern unsigned char ide_port;

#endif
