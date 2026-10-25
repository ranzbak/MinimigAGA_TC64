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
/* the IDE command pickup (HandleFpga's status byte c1): a command is
   picked up only while no HDD command is in progress; READ / WRITE
   (MULTIPLE) start the data path's state machine, the others run to their
   end here */
void HandleHDD(unsigned int c1, unsigned int c2);
/* The HDD data path (findings/sdcard-engine Task 11a): READ / WRITE
   (MULTIPLE) as a state machine advanced from the main loop (PollDisks):
   the Amiga waits are status polls, the card work async SD ops
   (sdproto.h; to_gayle reads, from_gayle CMD25 runs of at most 16 sectors
   split at cluster boundaries), the main loop runs between them.  No IDE
   command on cs 0x10 while a Gayle op runs (sd_gayle_busy()). */
void hdd_poll(void);
/* 1 while an IDE command is in progress on either port, this state
   machine's or the CD drive's (cdrom.c CD_Busy): the pickup waits (one IDE
   command at a time, findings/sdcard-engine ruling T11-R4) */
int hdd_busy(void);
/* end an ATA command in progress: its card op finished (a run closed),
   END | IRQ | ERR (ABRT) unless the Amiga left it; for the callers that
   change what the command works on (OpenHardfile, ColdBoot) */
void hdd_cancel(void);

/* The data paths' shared helpers (the HDD state machine and the CD drive's
   DATA2048 read, cdrom.c; findings/sdcard-engine Task 11b): */
struct sd_op;
/* start an async card op (sdproto.h): kind SD_READ / SD_WRITE, n blocks at
   card sector lba into / from buf, or with buf 0 to / from Gayle's FIFO of
   port (to_gayle / from_gayle).  0, or -1 when another op holds the card
   (try again on the next pass); an op that cannot start ends at once (0,
   op->err set).  A card to be initialised again after an error first
   (sd_init, synchronous: the one wait in the data paths) */
int hdd_op_go(struct sd_op *op, int kind, unsigned long lba, unsigned n, unsigned char *buf, int port);
/* the file position of h to 512-byte sector target without a wait:
   hdd_seek_begin does HardFileSeek's index jump (once per seek),
   hdd_seek_step FileSeek's walk on the FAT sector cached in the data path's
   buffer, reading a missing one by an async op (op).  hdd_seek_step: 1 at
   target, 0 a FAT read runs or the card is busy (call again on the next
   pass), -1 a FAT read failed (op->err), -2 the end of the chain (inside
   the file's size: a guard).  One seek at a time (one IDE command) */
void hdd_seek_begin(hdfTYPE *h, unsigned long target);
int hdd_seek_step(struct sd_op *op);
/* the card sector of h's file position; *n cut to the sectors left in its
   cluster (a run never crosses a cluster: the chain may jump) */
unsigned long hdd_file_run(hdfTYPE *h, unsigned *n);
/* dbg_flags DBG_ATA (diskstat.h): one UART line for an IDE command at its
   end, "ATA <cmd> lba <lba> n <count> port <ide_port> <what> st <status> t <TIMER counts>" */
void ata_trace(unsigned cmd, unsigned long lba, unsigned n, const char *what, unsigned st, unsigned t);

void GetHardfileGeometry(hdfTYPE *hdf);
/* 0 when a FAT read failed (a card error) or the cluster chain is shorter
   than the file's size: the index would hold wrong clusters, the file must
   not be used */
unsigned char BuildHardfileIndex(hdfTYPE *hdf);
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
