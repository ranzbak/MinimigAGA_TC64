/*
Copyright 2008, 2009 Jakub Bednarski

This file is part of Minimig

Minimig is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

Minimig is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// 2009-11-22 - read/write multiple implemented

// 2020-11-14 - AMR: Simplified and combined read / readm + write / writem.  AROS IDE now works.

//#include "AT91SAM7S256.h"
//#include "stdio.h"
//#include "string.h"
#include "errors.h"
#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "hdd_internal.h"
#include "mmc.h"
#include "sdproto.h"
#include "menu.h"
#include "fpga.h"
#include "config.h"
#include "drivesounds.h"
#include "cdrom.h"
#include "swap.h"
#include "diskstat.h"

#include <stdio.h>
#include <string.h>

// hardfile structure, one per IDE slot (port << 1 | slave)
hdfTYPE hdf[HDD_SLOTS];

// IDE port of the HDD SPI commands below (bit 0 of every command byte)
// ide_port: defined in mmc.c (a read with no buffer goes to its FIFO), hdd.h

char debugmsg[40];
char debugmsg2[40];

#undef SERIALDEBUG

#define DEBUG1(x) {if(DebugMode) DebugMessage(x);}
#define DEBUG2(x,y) {if(DebugMode) { sprintf(debugmsg2,x,y); DebugMessage(debugmsg2); }}
#define DEBUG3(x,y,z) {if(DebugMode) { sprintf(debugmsg2,x,y,z); DebugMessage(debugmsg2); }}

static int lastcyl;

static char filename[12];


// The block's longs are big-endian (the Amiga's order); the sum wraps
// modulo 2^32 (uint32_t: no signed overflow).
static void RDBChecksum(uint32_t *p)
{
	uint32_t count=be32(p[1]);
	uint32_t c2;
	uint32_t result=0;
	DEBUG1("Generating checksum");
	p[2]=0;
	for(c2=0;c2<count;++c2)
		result+=be32(p[c2]);
	p[2]=be32(-result);
}


// If the hardfile doesn't have a RigidDiskBlock,
// we synthesize one (into buf, 512 bytes).
static void FakeRDB(int unit,int block,unsigned char *buf)
{
	int i;
	DEBUG1("Clearing sector buffer");
	// Start by clearing the sector buffer
	for(i=0;i<512;++i)
		buf[i]=0;

	// If we're asked for LBA 0 we create an RDSK block, and if LBA 1, a PART block.
	switch(block)
	{
		case 0: // RDB
			{
				struct RigidDiskBlock *rdb=(struct RigidDiskBlock *)buf;
				DEBUG1("Creating RDB...");
				// every long big-endian (be32), as the Amiga reads it
				rdb->rdb_ID = be32('R'<<24 | 'D' << 16 | 'S' << 8 | 'K');
				
				rdb->rdb_Summedlongs=be32(0x40);
				rdb->rdb_HostID=be32(0x07);
				rdb->rdb_BlockBytes=be32(0x200);
				rdb->rdb_Flags=be32(0x12); // (Disk ID valid, no LUNs after this one)
				rdb->rdb_BadBlockList=0xffffffff; // We don't provide a bad block list
				rdb->rdb_PartitionList=be32(1);
				rdb->rdb_FileSysHeaderList=0xffffffff;
				rdb->rdb_DriveInit=0xffffffff;
				rdb->rdb_Reserved1[0]=0xffffffff;
				rdb->rdb_Reserved1[1]=0xffffffff;
				rdb->rdb_Reserved1[2]=0xffffffff;
				rdb->rdb_Reserved1[3]=0xffffffff;
				rdb->rdb_Reserved1[4]=0xffffffff;
				rdb->rdb_Reserved1[5]=0xffffffff;
				rdb->rdb_Cylinders=be32(hdf[unit].cylinders);
				rdb->rdb_Sectors=be32(hdf[unit].sectors);
				rdb->rdb_Heads=be32(hdf[unit].heads);
				rdb->rdb_Interleave=be32(1);
				rdb->rdb_Park=rdb->rdb_Cylinders;	// copies of a big-endian long
				rdb->rdb_WritePreComp=rdb->rdb_Cylinders;
				rdb->rdb_ReducedWrite=rdb->rdb_Cylinders;
				rdb->rdb_StepRate=be32(3);
				rdb->rdb_RDBBlocksLo=0;
				rdb->rdb_RDBBlocksHi=be32(1);
				rdb->rdb_LoCylinder=be32(1);
				rdb->rdb_HiCylinder=be32(hdf[unit].cylinders-1);
				rdb->rdb_CylBlocks=be32(hdf[unit].heads * hdf[unit].sectors);
				rdb->rdb_AutoParkSeconds=0;
				rdb->rdb_HighRDSKBlock=be32(1);
				strcpy(rdb->rdb_DiskVendor,"Do not ");
				strcpy(rdb->rdb_DiskProduct, "repartition!");

				RDBChecksum((uint32_t *)rdb);
			}
			break;
		case 1: // Partition
			{
				struct PartitionBlock *pb=(struct PartitionBlock *)buf;
				DEBUG1("Creating RDB...");
				// every long big-endian (be32), as the Amiga reads it
				pb->pb_ID = be32('P'<<24 | 'A' << 16 | 'R' << 8 | 'T');
			
				pb->pb_Summedlongs=be32(0x40);
				pb->pb_HostID=be32(0x07);
				pb->pb_Next=0xffffffff;
				pb->pb_Flags=be32(0x1); // Bootable
				pb->pb_DevFlags=0;
				strcpy(pb->pb_DriveName," DH0");
				pb->pb_DriveName[0]=3;	// BCPL string

				pb->pb_Environment.de_TableSize=be32(0x10);
				pb->pb_Environment.de_SizeBlock=be32(0x80);
				pb->pb_Environment.de_Surfaces=be32(hdf[unit].heads);
				pb->pb_Environment.de_SectorPerBlock=be32(1);
				pb->pb_Environment.de_BlocksPerTrack=be32(hdf[unit].sectors);
				pb->pb_Environment.de_Reserved=be32(2);
				pb->pb_Environment.de_LowCyl=be32(1);
				pb->pb_Environment.de_HighCyl=be32(hdf[unit].cylinders-1);
				pb->pb_Environment.de_NumBuffers=be32(30);
				pb->pb_Environment.de_MaxTransfer=be32(0x1fffe);
				pb->pb_Environment.de_Mask=be32(0x7ffffffe);
				pb->pb_Environment.de_DosType=be32(0x444f5301);

				RDBChecksum((uint32_t *)pb);
			}
			break;
			break;
		default:
			break;
	}
}


void IdentifyDevice(unsigned short *pBuffer, int unit)
{ // builds Identify Device struct
    char *p;
    hardfileTYPE *hf;
	int i, x;
    unsigned long total_sectors = hdf[unit].cylinders * hdf[unit].heads * hdf[unit].sectors;

    memset(pBuffer, 0, 512);

	switch(hdf[unit].type)
	{
		case HDF_FILE | HDF_SYNTHRDB:
		case HDF_FILE:
			DEBUG1("Identify - Type: HDF_FILE");
			pBuffer[0] = 1 << 6; // hard disk
			pBuffer[1] = hdf[unit].cylinders; // cyl count
			pBuffer[3] = hdf[unit].heads; // head count
			pBuffer[6] = hdf[unit].sectors; // sectors per track
			// FIXME - can get serial no from card itself.
			memcpy((char*)&pBuffer[10], "1234567890ABCDEFGHIJ", 20); // serial number - byte swapped
			memcpy((char*)&pBuffer[23], ".100    ", 8); // firmware version - byte swapped
			p = (char*)&pBuffer[27];
			// FIXME - likewise the model name can be fetched from the card.
			if(hdf[unit].type & HDF_SYNTHRDB)
			{
				memcpy(p, "DON'T                                   ", 40);
				p += 8;
				memcpy(p, "REPARTITION!    ", 16);
			}
			else
			{
				memcpy(p, "YAQUBE                                  ", 40); // model name - byte swapped
				p += 8;
				hf = SlotConfig(unit);
				if (hf->long_name[0])
				{
					for (i = 0; i < 16 && (x = hf->long_name[i]); i++) // copy file name as model name
						p[i] = x;
				}
				else
				{
					memcpy(p, hf->name, 8); // copy file name as model name
				}
			}
		//    SwapBytes((char*)&pBuffer[27], 40); //not for 68000
			break;
		case HDF_CARD:
		case HDF_CARDPART0:
		case HDF_CARDPART1:
		case HDF_CARDPART2:
		case HDF_CARDPART3:
			DEBUG1("Identify - Type: HDF_CARD");
			pBuffer[0] = 1 << 6; // hard disk
			pBuffer[1] = hdf[unit].cylinders; // cyl count
			pBuffer[3] = hdf[unit].heads; // head count
			pBuffer[6] = hdf[unit].sectors; // sectors per track
			// FIXME - can get serial no from card itself.
			memcpy((char*)&pBuffer[10], "TC64MiniMigSD0      ", 20); // serial number - byte swapped
			pBuffer[23]+=hdf[unit].type-HDF_CARD;
			memcpy((char*)&pBuffer[23], ".100    ", 8); // firmware version - byte swapped
			p = (char*)&pBuffer[27];
			// FIXME - likewise the model name can be fetched from the card.
			memcpy(p, "YAQUBE                                  ", 40); // model name - byte swapped
			p += 8;
			if(hdf[unit].type==HDF_CARD)
				memcpy(p, "SD/MMC Card", 11); // copy file name as model name
			else
			{
				memcpy(p, "Card Part 1", 11); // copy file name as model name
				p[10]+=hdf[unit].partition;
			}
			//    SwapBytes((char*)&pBuffer[27], 40); //not for 68000
			break;
	}

	// ATA strings (serial 10-19, firmware 23-26, model 27-46): the first
	// character in bits 15:8 of each word.  The memcpy above stored them in
	// memory order, which is ATA's on a big-endian CPU; on this little-endian
	// one each word is swapped (be16), so the stream ATA_IdentifyDevice sends
	// (every word low byte first) has the strings in ATA's order.  The numeric
	// words are values.
	for (i = 10; i < 20; i++)
		pBuffer[i] = be16(pBuffer[i]);
	for (i = 23; i < 47; i++)
		pBuffer[i] = be16(pBuffer[i]);

    pBuffer[47] = 0x8010; //maximum sectors per block in Read/Write Multiple command
    pBuffer[53] = 1;
    pBuffer[54] = hdf[unit].cylinders;
    pBuffer[55] = hdf[unit].heads;
    pBuffer[56] = hdf[unit].sectors;
    pBuffer[57] = (unsigned short)total_sectors;
    pBuffer[58] = (unsigned short)(total_sectors >> 16);
}

unsigned long chs2lba(int cylinder, int head, int sector, int unit)
{
    return(cylinder * hdf[unit].heads + head) * hdf[unit].sectors + sector - 1;
}

void WriteTaskFile(int error,int sector_count,int sector_number,int cylinder_low,int cylinder_high,int drive_head)
{
    EnableFpga();

    SPI(CMD_IDE_REGS_WR | ide_port); // write task file registers command
    SPI(0x00);
    SPI(0x00); // dummy
    SPI(0x00);
    SPI(0x00); // dummy
    SPI(0x00);



    SPI(0x00); // dummy

    SPI(0x00);
    SPI(0x00);
    SPI(error); // error
    SPI(0x00);
    SPI(sector_count); // sector count
    SPI(0x00);
    SPI(sector_number); //sector number
    SPI(0x00);
    SPI(cylinder_low); // cylinder low
    SPI(0x00);
    SPI(cylinder_high); // cylinder high
    SPI(0x00);
    SPI(drive_head); // drive/head

    DisableFpga();
}

void WriteStatus(unsigned int status)
{
    EnableFpga();

    SPI(CMD_IDE_STATUS_WR | ide_port);
    SPI(status);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);

    DisableFpga();
}

// Packet-mode data phase (two-port Gayle): reset the port's FIFO, set the
// transfer length in words and packet mode; a WriteStatus then sets the
// direction.  Three words, so the direct SD transfer that may follow does
// not find a half-decoded command (see paula_floppy.v).
void WriteXfer(unsigned int words, int pkt)
{
    EnableFpga();
    SPI(CMD_IDE_XFER_WR | ide_port);
    SPI(0x00);
    SPI((pkt ? 0x80 : 0x00) | ((words >> 8) & 0x1f));
    SPI(words & 0xff);
    SPI(0x00);
    SPI(0x00);
    DisableFpga();
}

// Read the 8 task file registers of a port; returns the flags.  The read
// clears the sticky ones (rst_seen, dev_wr): pass them on (CD_Flags).
unsigned char ReadTaskFile(int port, unsigned char *tfr)
{
    int i;
    unsigned char flags = 0;
    EnableFpga();
    SPI(CMD_IDE_REGS_RD | port); // read task file registers
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    for (i = 0; i < 8; i++)
    {
        flags = SPI(0);
        tfr[i] = SPI(0);
    }
    DisableFpga();
    return flags;
}

// Only the flags (registers 0 and 1): the packet-mode wait loops.
unsigned char ReadIDEFlags(int port)
{
    unsigned char flags;
    EnableFpga();
    SPI(CMD_IDE_REGS_RD | port);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    flags = SPI(0);
    SPI(0);
    DisableFpga();
    return flags;
}

// Data into the FIFO of ide_port (pio in), bytes in buffer order; an odd
// count is padded to a whole word.
void WriteIDEData(const unsigned char *buf, unsigned int bytes)
{
    unsigned int i;
    EnableFpga();
    SPI(CMD_IDE_DATA_WR | ide_port);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    for (i = 0; i < bytes; i++)
        SPI(buf[i]);
    if (bytes & 1)
        SPI(0x00);
    DisableFpga();
}

// Data out of the FIFO of ide_port (pio out); buf 0 discards it.
void ReadIDEData(unsigned char *buf, unsigned int bytes)
{
    unsigned int i;
    unsigned char c;
    EnableFpga();
    SPI(CMD_IDE_DATA_RD | ide_port);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    SPI(0x00);
    for (i = 0; i < ((bytes + 1) & ~1u); i++)
    {
        c = SPI(0xFF);
        if (buf && i < bytes)
            buf[i] = c;
    }
    DisableFpga();
}

static unsigned short id[256];
static unsigned char  tfr[8];


// ATA_Recalibrate()
static inline void ATA_Recalibrate(unsigned char* tfr, int unit)
{
	(void)unit;
  // Recalibrate 0x10-0x1F (class 3 command: no data)
	DEBUG1("Recalibrate");
	WriteTaskFile(0, 0, 1, 0, 0, tfr[6] & 0xF0);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
}


// ATA_Diagnostic()
static inline void ATA_Diagnostic(unsigned char* tfr)
{
	(void)tfr;
	// Execute Drive Diagnostic (0x90): the ATA signature (error 01, count 1,
	// sector 1, cylinder 0).  IDE_STATUS_SIG makes the two-port Gayle show
	// each device's own signature (ATAPI for a CD on the same port).
	DEBUG1("IDE: Drive Diagnostic");
	WriteTaskFile(1, 1, 1, 0, 0, 0);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_SIG);
}


// ATA_IdentifyDevice()
void ATA_IdentifyDevice(unsigned char* tfr, int unit, unsigned short* id)
{
  int i;
  // Identify Device (0xec)
  DEBUG2("IDE%d: Identify Device", unit);
  IdentifyDevice(id, unit);
  WriteTaskFile(0, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
  WriteStatus(IDE_STATUS_RDY); // pio in (class 1) command type
  EnableFpga();
  SPI(CMD_IDE_DATA_WR | ide_port); // write data command
  SPI(0x00);
  SPI(0x00);
  SPI(0x00);
  SPI(0x00);
  SPI(0x00);
  for (i = 0; i < 256; i++) {
    SPI((unsigned char)id[i]);
    SPI((unsigned char)(id[i] >> 8));
  }
  DisableFpga();
  WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
}


// ATA_Initialize()
void ATA_Initialize(unsigned char* tfr, int unit)
{
	(void)unit;
	// Initialize Device Parameters (0x91)
	printf("Initialize Device Parameters\r");
	WriteTaskFile(0, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
}


// ATA_SetMultipleMode()
void ATA_SetMultipleMode(unsigned char* tfr, int unit)
{
    hdf[unit].sectors_per_block = tfr[2];
    printf("Set Multiple Mode %d\r",tfr[2]);
    WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
}


/* ---- the HDD data path: READ / WRITE (MULTIPLE) as a state machine ------
 * findings/sdcard-engine Task 11a (design 5.1, 5.2, 11).  HandleHDD picks a
 * command up and starts it; hdd_poll(), from the main loop (main.c
 * PollDisks), advances it a step at a time and returns: the Amiga
 * waits are one status poll per pass, the card work async SD ops
 * (sdproto.h), and the main loop (keys, OSD, CD audio, drive sounds, the
 * floppy) runs between them.  Never sdc_wait / sd_sync here (one exception:
 * a card to be initialised again after an error, sd_init, before the op
 * that needs it).
 *
 * READ: per group (READ MULTIPLE: sectors_per_block sectors, else 1) the
 *   status RDY, then -- after the Amiga drained the previous group
 *   (hdd_cmd_req: "drain, then refill"; Gayle fires the Amiga's interrupt on
 *   a rising DRQ) -- the group's sectors into Gayle's FIFO: FakeRDB blocks
 *   and an HDF's own RDB block (patched) by the CPU (CMD_IDE_DATA_WR), the
 *   others in to_gayle runs (one RX_TO_GAYLE per block after its CRC).
 * WRITE: the status REQ, then per sector: hdd_dat_req (its data in Gayle's
 *   FIFO), then a from_gayle CMD25 run started with it, each next block's go
 *   after its own hdd_dat_req (ruling T11-R1: a Gayle op only when its data
 *   is there); the group's IRQ (the last one END | IRQ) only after its runs
 *   ended, i.e. the stop token's busy is over (write-done timing as before,
 *   no write-back).  A sector of the FakeRDB region (or of an HDF without a
 *   file) is taken from the FIFO by the CPU and dropped.
 * Runs: at most HDD_RUN_MAX sectors, inside one cluster (HDF: the cluster
 *   index of HardFileSeek; the FAT walk reads its FAT sectors into hdd_blk
 *   by async ops of its own), inside one group.  A write run parked longer
 *   than HDD_PARK_COUNTS for the Amiga's next sector is closed (sd_close: the
 *   stop token); the group goes on in a new run.  sd_sync users (the CD
 *   refill, the menu, the floppy) get the card between runs.
 * The Amiga leaving a command (a new command, Ctrl-Amiga-Amiga): a Gayle
 *   error on an op (the bridge's cmd_since), or hdd_cmd_req without
 *   hdd_dat_req while a write waits for a sector: no status for it (it would
 *   end the NEW command), a write run is ended on the card first (stop
 *   token, sd_close).  The flags (amiga_left: CMD_IDE_REGS_RD, IDEF_RST_SEEN
 *   or IDEF_DEV_WR) are looked at before what the bridge's cmd_since does not
 *   guard: a write's END, every error status, a block the CPU writes into
 *   the FIFO (FakeRDB, the patched RDB) and a READ group's RDY after the
 *   first (a reset in the drain wait makes the new command's request look
 *   like "drained").
 * Errors: WriteTaskFile with the error register (UNC for a read, ABRT for a
 *   write, IDNF past the end of the file), END | IRQ | ERR; a card error
 *   also ERROR_SDCARD (MMC_OpResult, the OSD's error page).
 * The Amiga polls of diskstat are the status polls of these waits (one per
 * pass).  dbg_flags DBG_ATA: one UART line per ATA command at its end.
 * One IDE command at a time across both ports (ruling T11-R4): hdd_poll()
 *   is the dispatcher of the one in progress, this state machine's or the CD
 *   drive's DATA2048 read (cdrom.c CD_Step, findings/sdcard-engine Task
 *   11b), and hdd_busy() covers both, so the pickup (HandleHDD) waits.  The
 *   two share the card op start (hdd_op_go), the file seek with its async
 *   FAT reads (hdd_seek_begin / hdd_seek_step, the FAT sector cache in
 *   hdd_blk) and the cluster cut of a run (hdd_file_run). */
#define HDD_RUN_MAX 16		/* sectors of one card run (the Gayle FIFO's 16) */
#define HDD_PARK_COUNTS 3	/* GetTimer counts a write run waits parked for the Amiga's next sector: 17.4..23.2 ms */
#define ATA_ERR_UNC  0x40	/* error register: uncorrectable data (a read the card failed) */
#define ATA_ERR_IDNF 0x10	/* ID not found: past the end of the hardfile */
#define ATA_ERR_ABRT 0x04	/* aborted: a write the card failed, a command given up */

enum {
	H_IDLE,
	H_GROUP,	/* the next group: READ RDY, WRITE its first sector */
	H_DRAIN,	/* READ: the Amiga drains the previous group (hdd_cmd_req) */
	H_RNEXT,	/* READ: the group's next sector(s) */
	H_RRUNGO,	/* READ: a run from the file position */
	H_RRUN,		/* READ: a to_gayle op runs */
	H_RPATCHGO,	/* READ: the HDF's own RDB block into hdd_blk */
	H_RPATCH,	/* READ: that op runs */
	H_WNEXT,	/* WRITE: the group's next sector (or its IRQ) */
	H_WDATA,	/* WRITE: its data in Gayle's FIFO (hdd_dat_req), then the run */
	H_WRUN,		/* WRITE: a from_gayle run */
	H_SEEK		/* the file position (hdd_seek_step): the FAT walk, its FAT reads */
};

static struct {
	unsigned char st, after;	/* the state; H_SEEK's next one */
	unsigned char write, multiple, unit, port, cmd;
	unsigned char discard;		/* WRITE: this sector goes nowhere */
	unsigned char parked;		/* WRITE: park_t runs */
	unsigned char abandoned;	/* the Amiga left the command during a run */
	unsigned char rdy;		/* READ: the next group's RDY is written already */
	long lba;			/* the Amiga LBA of the next sector */
	unsigned left, grp, n;		/* sectors left in the command, in the group; of the run */
	long lba0;			/* the trace: the first LBA, the count */
	unsigned count;
	unsigned polls;			/* status polls of the current Amiga wait */
	unsigned short t0;		/* the trace: TIMER at the pickup */
	int cyl;			/* the last sector's cylinder (the drive sound) */
	unsigned char tf[6];		/* the task file written at the pickup */
	unsigned long park_t;
	sd_op op;
} hc;
/* the HDD path's own buffer: the FAT sector of its seeks (hdd_fat_sb, ~0:
   none), or an RDB block (FakeRDB, the HDF's own patched one).  Not
   sector_buffer or fat_buffer: an sd_sync user between two steps would
   overwrite those */
static unsigned char hdd_blk[512] __attribute__((aligned(4)));
static unsigned long hdd_fat_sb = ~0ul;

int hdd_busy(void)
{
	return hc.st != H_IDLE || CD_Busy();
}

void ata_trace(unsigned cmd, unsigned long lba, unsigned n, const char *what, unsigned st, unsigned t)
{
	if (dbg_flags & DBG_ATA)
		printf("ATA %02x lba %lu n %u port %u %s st %02x t %u\n", cmd, lba, n, (unsigned)ide_port, what, st, t);
}

/* the command is over (st: the last status written, 0 none) */
static void hdd_end(const char *what, unsigned st)
{
	ata_trace(hc.cmd, (unsigned long)hc.lba0, hc.count, what, st,
	          (dbg_flags & DBG_ATA) ? (unsigned short)(TIMER - hc.t0) : 0);	/* the TIMER only for the trace */
	hc.st = H_IDLE;
	DISKLED_OFF;
}

/* a good end: the drive sound of a cylinder change */
static void hdd_done(unsigned st)
{
	if (hc.cyl != lastcyl)
		drivesounds_queueevent(DRIVESOUND_HDDSTEP);
	lastcyl = hc.cyl;
	hdd_end("ok", st);
}

/* Did the Amiga leave the command since the pickup?  The flags of the
   port: IDEF_RST_SEEN (a reset), IDEF_DEV_WR (the host wrote drive/head:
   a new command's set-up; no host touches the task file during a command);
   the CD unit gets them too (CD_Flags).  Before what the bridge's cmd_since
   does not guard: an END or error status, a block the CPU writes into the
   FIFO, a READ group's RDY.  The CMD_IDE_REGS_RD clears cmd_since; what
   happens after it sets it again, what happened before it these flags
   report (findings/sdcard-engine Task 11a fix round 1) */
static int amiga_left(void)
{
	unsigned char flags = ReadIDEFlags(hc.port);
	CD_Flags(hc.port, flags);
	return (flags & (IDEF_RST_SEEN | IDEF_DEV_WR)) != 0;
}

/* END | IRQ | ERR with the error register; nothing when the Amiga left */
static void hdd_fail(unsigned char err)
{
	if (amiga_left()) {
		hdd_end("abandoned", 0);
		return;
	}
	WriteTaskFile(err, hc.tf[1], hc.tf[2], hc.tf[3], hc.tf[4], hc.tf[5]);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
	hdd_end("error", IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
}

/* the command's op ended with an error: the abandon (Gayle error), or a
   card error (ERROR_SDCARD) */
static void hdd_op_failed(unsigned char err)
{
	if (hc.op.err == SD_E_GAYLE || hc.abandoned) {
		hdd_end("abandoned", 0);
		return;
	}
	MMC_OpResult(&hc.op, hc.write ? "SD card write" : "SD card read");
	hdd_fail(err);
}

/* start a data path's card op (hdd.h): 0, or -1 when another op holds the
   card (the next pass tries again).  A card to be initialised again after
   an error first (sd_init, synchronous: the one wait in these paths) */
int hdd_op_go(struct sd_op *op, int kind, unsigned long lba, unsigned n, unsigned char *buf, int port)
{
	if (!sd_card_type() && !sd_card_changed())
		sd_init();
	memset(op, 0, sizeof *op);
	op->kind = kind;
	op->lba = lba;
	op->count = n;
	op->buf = buf;
	op->port = port;
	if (!buf) {
		op->to_gayle = kind == SD_READ;
		op->from_gayle = kind == SD_WRITE;
	}
	return sd_submit(op);
}

/* the HDD command's card op */
static int op_go(int kind, unsigned long lba, unsigned n, unsigned char *buf)
{
	return hdd_op_go(&hc.op, kind, lba, n, buf, hc.port);
}

static void sectors_done(unsigned k)
{
	hc.lba += k;
	hc.grp -= k;
	hc.left -= k;
}

/* The file seek of the command in progress (one at a time: the HDD's or
   the CD's), hdd.h: HardFileSeek's index jump once (hdd_seek_begin), then
   FileSeek's walk forward (hdd_seek_step) on hdd_blk's FAT sector, a missing
   one read by the caller's op */
static struct {
	hdfTYPE *h;
	unsigned long target, sb;	/* the sector to go to; the FAT sector being read */
	unsigned char reading;		/* sb is being read into hdd_blk */
} sk;

void hdd_seek_begin(hdfTYPE *h, unsigned long target)
{
	fileTYPE *f = &h->file;
	if ((f->sector ^ target) & cluster_mask) {
		if ((f->sector > target) || ((f->sector ^ target) & (cluster_mask << (fat32 ? 7 : 8)))) {
			f->cluster = h->index[target >> (h->index_size - 9)];
			f->sector = target & (int)(~0U << (h->index_size - 9));
		}
	}
	if (f->sector > target) {
		if ((f->sector ^ target) & cluster_mask) {
			f->cluster = f->start_cluster;
			f->sector = 0;
		} else
			f->sector = target;
	}
	sk.h = h;
	sk.target = target;
	sk.reading = 0;
}

int hdd_seek_step(struct sd_op *op)
{
	fileTYPE *f = &sk.h->file;
	unsigned long t = sk.target, sb, next;
	unsigned i;
	if (sk.reading) {
		if (op->state)
			return 0;
		sk.reading = 0;
		if (op->err)
			return -1;
		hdd_fat_sb = sk.sb;
	}
	while ((f->sector ^ t) & cluster_mask) {
		sb = fat32 ? f->cluster >> 7 : f->cluster >> 8;
		i = fat32 ? (f->cluster & 0x7F) : (f->cluster & 0xFF);
		if (sb != hdd_fat_sb) {
			hdd_fat_sb = ~0ul;	/* hdd_blk is being overwritten */
			if (hdd_op_go(op, SD_READ, fat_start + sb, 1, hdd_blk, 0))
				return 0;	/* the card is another op's: the next pass */
			sk.sb = sb;
			sk.reading = 1;
			return 0;
		}
		next = fat32 ? le32(((uint32_t *)hdd_blk)[i]) & 0x0FFFFFFF : le16(((uint16_t *)hdd_blk)[i]);
		if (fat32 ? next == 0x0FFFFFFF : next == 0xFFFF)
			return -2;	/* the end of the chain inside the file's size */
		f->cluster = next;
		f->sector += cluster_size;
	}
	f->sector = t;
	return 1;
}

unsigned long hdd_file_run(hdfTYPE *h, unsigned *n)
{
	fileTYPE *f = &h->file;
	unsigned off = f->sector & ~cluster_mask, rest = cluster_size - off;
	if (*n > rest)
		*n = rest;
	return data_start + cluster_size * (f->cluster - 2) + off;
}

/* the hardfile's position to sector target, then state `after` */
static void seek(unsigned long target, unsigned char after)
{
	hdd_seek_begin(&hdf[hc.unit], target);
	hc.after = after;
	hc.st = H_SEEK;
}

/* the card sector of the hardfile's position, n cut at its cluster's end */
static unsigned long file_run(unsigned *n)
{
	return hdd_file_run(&hdf[hc.unit], n);
}

static int is_file(void)
{
	return (hdf[hc.unit].type & ~HDF_SYNTHRDB) == HDF_FILE;
}

/* the run's length: the group's rest, at most HDD_RUN_MAX */
static unsigned run_len(void)
{
	return hc.grp < HDD_RUN_MAX ? hc.grp : HDD_RUN_MAX;
}

/* one step; 1: the next one at once, 0: wait for the next pass */
static int hdd_step(void)
{
	hdfTYPE *h = &hdf[hc.unit];
	long v = hc.lba + h->offset;
	unsigned n, spb;
	unsigned char st;
	unsigned long card;
	int r;

	switch (hc.st) {
	case H_GROUP:
		spb = h->sectors_per_block;
		if (hc.multiple && !spb) {	/* READ / WRITE MULTIPLE before SET MULTIPLE MODE */
			hdd_fail(ATA_ERR_ABRT);
			return 0;
		}
		hc.grp = hc.multiple && spb < hc.left ? spb : (hc.multiple ? hc.left : 1);
		hc.polls = 0;
		if (hc.write) {
			hc.st = H_WNEXT;
			return 1;
		}
		if (!hc.rdy) {
			/* after the first group: a reset during the last drain wait
			   made that "drained" the new command's request */
			if (hc.left < hc.count && amiga_left()) {
				hdd_end("abandoned", 0);
				return 0;
			}
			WriteStatus(IDE_STATUS_RDY); // pio in (class 1) command type
		}
		hc.rdy = 0;
		hc.st = H_DRAIN;
		return 1;

	case H_DRAIN:
		if (sd_gayle_busy())
			return 0;
		hc.polls++;
		if (!(GetFPGAStatus() & CMD_IDECMD)) // wait for empty sector buffer
			return 0;
		diskstat_amiga_polls(hc.polls);
		hc.st = H_RNEXT;
		return 1;

	case H_RNEXT:
		if (!hc.grp) {
			if (!hc.left) {
				hdd_done(0);	/* Gayle ends the command when the Amiga read the last sector */
				return 0;
			}
			hc.st = H_GROUP;
			return 1;
		}
		if (!is_file()) {
			n = run_len();
			if (op_go(SD_READ, (unsigned long)v, n, 0))
				return 0;
			hc.n = n;
			hc.st = H_RRUN;
			return 0;
		}
		if (!h->file.size) {
			WriteStatus(IDE_STATUS_END|IDE_STATUS_RDY|IDE_STATUS_ERR);
			hdd_end("error", IDE_STATUS_END|IDE_STATUS_RDY|IDE_STATUS_ERR);
			return 0;
		}
		// Deal with FakeRDB and the potential for a read_multiple to cross the boundary into actual data.
		if (v < 0 || (hc.unit == 0 && h->type == HDF_FILE && hc.lba == 0)) {
			if (h->type == HDF_FILE) {
				// Patch flags and checksum of RDB.  Actually necessary?
				seek((unsigned long)v, H_RPATCHGO);
				return 1;
			}
			if (amiga_left()) {	/* the CPU's block: cmd_since does not guard it */
				hdd_end("abandoned", 0);
				return 0;
			}
			FakeRDB(hc.unit, hc.lba, hdd_blk);
			hdd_fat_sb = ~0ul;
			WriteIDEData(hdd_blk, 512);
			sectors_done(1);
			return 1;
		}
		seek((unsigned long)v, H_RRUNGO);
		return 1;

	case H_RRUNGO:
		n = run_len();
		card = file_run(&n);
		if (op_go(SD_READ, card, n, 0)) // NULL: into Gayle's FIFO (mmc.h)
			return 0;
		hc.n = n;
		hc.st = H_RRUN;
		return 0;

	case H_RRUN:
		if (hc.op.state) {
			/* the group's last block is in the FIFO (the card's CMD12 may
			   still run): the next group's RDY now, as the synchronous path
			   wrote it (rd_multi_order); before the drain is fine, Gayle
			   arms the interrupt for the next rising DRQ */
			if (!hc.rdy && !hc.abandoned && hc.op.done_blocks == (int)hc.n && hc.grp == hc.n &&
			    hc.left > hc.n && !sd_gayle_busy()) {
				if (amiga_left())
					hc.abandoned = 1;	/* ended when the op has (hc.op is the card's until then) */
				else {
					WriteStatus(IDE_STATUS_RDY);
					hc.rdy = 1;
				}
			}
			return 0;
		}
		if (hc.op.err || hc.abandoned) {
			hdd_op_failed(ATA_ERR_UNC);
			return 0;
		}
		sectors_done(hc.n);
		hc.st = H_RNEXT;
		return 1;

	case H_RPATCHGO:
		n = 1;
		card = file_run(&n);
		hdd_fat_sb = ~0ul;
		if (op_go(SD_READ, card, 1, hdd_blk))
			return 0;
		hc.st = H_RPATCH;
		return 0;

	case H_RPATCH:
		if (hc.op.state)
			return 0;
		if (hc.op.err) {
			hdd_op_failed(ATA_ERR_UNC);
			return 0;
		}
		if (amiga_left()) {	/* the CPU's block: cmd_since does not guard it */
			hdd_end("abandoned", 0);
			return 0;
		}
		{
			struct RigidDiskBlock *rdb = (struct RigidDiskBlock *)hdd_blk;
			rdb->rdb_ChkSum = be32(be32(rdb->rdb_ChkSum) + be32(rdb->rdb_Flags) - 0x12);	// big-endian longs
			rdb->rdb_Flags=be32(0x12);
		}
		WriteIDEData(hdd_blk, 512);
		sectors_done(1);
		hc.st = H_RNEXT;
		return 1;

	case H_WNEXT:
		if (!hc.grp) {	/* the group is on the card: its IRQ */
			if (hc.left) {
				WriteStatus(IDE_STATUS_IRQ);
				hc.st = H_GROUP;
				return 1;
			}
			if (amiga_left()) {
				hdd_end("abandoned", 0);
				return 0;
			}
			WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
			hdd_done(IDE_STATUS_END | IDE_STATUS_IRQ);
			return 0;
		}
		hc.discard = is_file() && (!h->file.size || v < 0);	// Don't attempt to write to fake RDB
		if (is_file() && !hc.discard) {
			seek((unsigned long)v, H_WDATA);
			return 1;
		}
		hc.st = H_WDATA;
		return 1;

	case H_WDATA:
		if (sd_gayle_busy())
			return 0;
		hc.polls++;
		st = GetFPGAStatus();
		if (!(st & CMD_IDEDAT)) {	// wait for full write buffer
			if (st & CMD_IDECMD)	/* a new command, a reset: the Amiga left this one */
				hdd_end("abandoned", 0);
			return 0;
		}
		diskstat_amiga_polls(hc.polls);
		hc.polls = 0;
		if (hc.discard) {
			ReadIDEData(0, 512);
			sectors_done(1);
			hc.st = H_WNEXT;
			return 1;
		}
		n = run_len();
		card = is_file() ? file_run(&n) : (unsigned long)v;
		if (op_go(SD_WRITE, card, n, 0))	/* its first block's go: the sector is there */
			return 0;
		hc.n = n;
		hc.parked = 0;
		hc.abandoned = 0;
		hc.st = H_WRUN;
		return 0;

	case H_WRUN:
		if (hc.op.state) {
			if (sd_gayle_need(&hc.op) && !sd_gayle_busy()) {
				hc.polls++;
				st = GetFPGAStatus();
				if (st & CMD_IDEDAT) {
					diskstat_amiga_polls(hc.polls);
					hc.polls = 0;
					sd_gayle_go(&hc.op);
				} else if (st & CMD_IDECMD) {	/* the Amiga left: end the run on the card */
					hc.abandoned = 1;
					sd_close(&hc.op);
				}
			}
			if (sd_gayle_parked(&hc.op)) {
				if (!hc.parked) {
					hc.parked = 1;
					hc.park_t = GetTimer(HDD_PARK_COUNTS);
				} else if (CheckTimer(hc.park_t))
					sd_close(&hc.op);	/* the group goes on in a new run */
			} else
				hc.parked = 0;
			return 0;
		}
		sectors_done((unsigned)hc.op.done_blocks);
		if (hc.op.err || hc.abandoned) {
			hdd_op_failed(ATA_ERR_ABRT);
			return 0;
		}
		hc.st = H_WNEXT;
		return 1;

	case H_SEEK:
		r = hdd_seek_step(&hc.op);
		if (!r)
			return 0;
		if (r == -1) {	/* a FAT read failed */
			hdd_op_failed(hc.write ? ATA_ERR_ABRT : ATA_ERR_UNC);
			return 0;
		}
		if (r == -2) {
			/* the end of the chain inside the file's size: a guard, the
			   bound checks and BuildHardfileIndex keep commands off it */
			hdd_fail(ATA_ERR_IDNF);
			return 0;
		}
		hc.st = hc.after;
		return 1;
	}
	return 0;
}

/* the dispatcher of the IDE command in progress: this state machine's, or
   the CD drive's (CD_Step); at most 8 immediate steps a pass */
void hdd_poll(void)
{
	int k;
	for (k = 0; k < 8; k++) {
		if (hc.st != H_IDLE) {
			if (!hdd_step())
				break;
		} else if (CD_Busy()) {
			if (!CD_Step())
				break;
		} else
			break;
	}
}

void hdd_cancel(void)
{
	hdd_fat_sb = ~0ul;	/* the card or the FAT may change now */
	if (hc.st == H_IDLE)
		return;
	if (hc.op.state) {
		sd_close(&hc.op);
		sd_drain();
	}
	hc.abandoned = 0;
	hdd_fail(ATA_ERR_ABRT);
}

/* READ / WRITE (MULTIPLE) picked up: the task file, the bound check, then
   the state machine */
static void hdd_start(unsigned char* tfr, int sector, int cylinder, int head, int unit, int sector_count, int multiple, int write)
{
	long lba;
	int blk;

	diskstat_cmd(write, sector_count);
	lba=chs2lba(cylinder, head, sector, unit);
	if (write)
		DEBUG3(multiple ? "WriteM %ld, %d" : "Write  %ld, %d",lba,sector_count)
	else
		DEBUG3(multiple ? "ReadM %ld, %d" : "Read  %ld, %d",lba,sector_count)

	/* Advance CHS values */
	blk=sector_count;
	while(--blk)
	{
		if (sector == hdf[unit].sectors)
		{
			sector = 1;
			head++;
			if (head == hdf[unit].heads)
			{
				head = 0;
				cylinder++;
			}
		}
		else
			sector++;
	}

	memset(&hc, 0, sizeof hc);
	hc.write = (unsigned char)write;
	hc.multiple = (unsigned char)multiple;
	hc.unit = (unsigned char)unit;
	hc.port = ide_port;
	hc.cmd = tfr[7];
	hc.lba = hc.lba0 = lba;
	hc.left = hc.count = (unsigned)sector_count;
	hc.cyl = cylinder;
	if (dbg_flags & DBG_ATA)
		hc.t0 = TIMER;
	hc.tf[0] = 0;
	hc.tf[1] = tfr[2];
	hc.tf[2] = (unsigned char)sector;
	hc.tf[3] = (unsigned char)cylinder;
	hc.tf[4] = (unsigned char)(cylinder >> 8);
	hc.tf[5] = (tfr[6] & 0xF0) | head;
	hc.st = H_GROUP;

	/* Update task file with CHS address */
	WriteTaskFile(0, tfr[2], sector, cylinder, (cylinder >> 8), (tfr[6] & 0xF0) | head);

	if (write) {
		WriteStatus(IDE_STATUS_REQ); // pio out (class 2) command type
		if(lba+hdf[unit].offset<0)
			SetError(ERROR_HDD,"Write to auto-generated RDB!",lba+hdf[unit].offset,0);
	}

	/* sectors past the end of a hardfile: ERR before any of them is served
	   or written (findings/sdcard-engine Task 10 fix round 2; a truncated
	   HDF, an RDB whose partitions run past the file) */
	if ((hdf[unit].type & ~HDF_SYNTHRDB) == HDF_FILE && hdf[unit].file.size &&
	    lba + hdf[unit].offset + sector_count > (long)(hdf[unit].file.size >> 9))
		hdd_fail(ATA_ERR_IDNF);
}


void trap()
{
	putchar('t');
}

void trap2()
{
	putchar('T');
}

void HandleHDD(unsigned int c1, unsigned int c2)
{
	(void)c2;
	int i;
	int sector;
	int cylinder;
	int head;
    int unit;
	int sector_count;

    if ((c1 & CMD_IDECMD) && !hdd_busy())	// one IDE command at a time, either port (HDD or CD: ruling T11-R4)
    {
        unsigned char flags;
        DISKLED_ON;
        // Port 1 first; its flags say whether port 2 has the command (a core
        // with one port answers 0 there, and port 1 it is).
        ide_port = 0;
        flags = ReadTaskFile(0, tfr);
        CD_Flags(0, flags);
        if ((flags & (IDEF_BSY0 | IDEF_BSY1)) == IDEF_BSY1)
        {
            ide_port = 1;
            CD_Flags(1, ReadTaskFile(1, tfr));
        }

        unit = (ide_port << 1) | (tfr[6] & 0x10 ? 1 : 0); // slot: port, master/slave
        if (unit == CD_SLOT())
        {
            CD_HandleCommand(ide_port, tfr);	/* a DATA2048 read goes on in CD_Step (hdd_poll) */
            if (!CD_Busy())
                ata_trace(tfr[7], 0, tfr[2], "done", 0, 0);	/* ran to its end here */
            DISKLED_OFF;
            return;
        }
		if (hdf[unit].type==HDF_DISABLED) {
		  WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
          DISKLED_OFF;
		  return;
		}
		sector = tfr[3];
		cylinder = tfr[4] | (tfr[5] << 8);
		head = tfr[6] & 0x0F;
		sector_count = tfr[2];
		if (sector_count == 0) sector_count = 0x100;

//		if (cylinder==444 && head==2 && sector==51)
//			trap();

#ifdef SERIALDEBUG
    printf("IDE:");
    for (i = 1; i<=7; i++)
        printf("%02X.",tfr[i]);
    printf(", C: %d, H: %d, S: %d, count: %d\r", cylinder,head,sector,sector_count);
#endif
		if ((tfr[7] & 0xF0) == ACMD_RECALIBRATE) {
		  ATA_Recalibrate(tfr,  unit);
		} else if (tfr[7] == ACMD_DIAGNOSTIC) {
		  ATA_Diagnostic(tfr);
		} else if (tfr[7] == ACMD_IDENTIFY_DEVICE) {
		  ATA_IdentifyDevice(tfr, unit, id);
		} else if (tfr[7] == ACMD_INITIALIZE_DEVICE_PARAMETERS) {
		  ATA_Initialize(tfr, unit);
		} else if (tfr[7] == ACMD_SET_MULTIPLE_MODE) {
		  ATA_SetMultipleMode(tfr, unit);
		} else if (tfr[7] == ACMD_READ_SECTORS || tfr[7] == ACMD_READ_MULTIPLE ||
		           tfr[7] == ACMD_WRITE_SECTORS || tfr[7] == ACMD_WRITE_MULTIPLE) {
		  /* the data path: its own trace line at its end */
		  hdd_start(tfr, sector, cylinder, head, unit, sector_count,
		            tfr[7] == ACMD_READ_MULTIPLE || tfr[7] == ACMD_WRITE_MULTIPLE,
		            tfr[7] == ACMD_WRITE_SECTORS || tfr[7] == ACMD_WRITE_MULTIPLE);
		  DISKLED_OFF;
		  return;
		} else {
            printf("Unknown ATA command\r");

            printf("IDE:");
            for (i = 1; i < 7; i++)
                printf("%02X.", tfr[i]);
            printf("%02X\r", tfr[7]);
            WriteTaskFile(0x04, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
            WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
        }
        ata_trace(tfr[7], 0, (unsigned)sector_count, "done", 0, 0);	/* ran to its end here */
        DISKLED_OFF;
		if(cylinder==444 && head==2 && sector==61)
			trap2();
    }
}

/* cyl/head/spt are set in the first pass of the loops (sptt[0] >= 0 always): a false positive */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
void GetHardfileGeometry(hdfTYPE *pHDF)
{ // this function comes from WinUAE, should return the same CHS as WinUAE

    unsigned long total=0;
    unsigned long i, head, cyl, spt;
    long sptt[] = { 63, 127, 255, -1 };
	unsigned long cyllimit=65535;

	switch(pHDF->type)
	{
		case (HDF_FILE | HDF_SYNTHRDB):
		    if (pHDF->file.size == 0)
    		    return;
			// For WinUAE generated hardfiles we have a fixed sectorspertrack of 32, number of heads and cylinders are variable.
			// Make a first guess based on 1 head, then refine that guess until the geometry gives a plausible number of
			// cylinders and also has the correct number of blocks.
		    total = pHDF->file.size / 512;
			pHDF->sectors = 32;
			head=1;
			cyl = total/32;
			cyllimit-=1;
			while(head<16 && (cyl>cyllimit || (head*cyl*32)!=total))
			{
				++head;
				cyl=total/(32*head);
			}
			pHDF->heads = head;
			pHDF->cylinders = cyl+1;	// Add a cylinder for the fake RDB.
		
			if ((head*cyl*32)==total)	// Does the geometry match the size of the underlying hard file?
				return;
			// If not, fall back to regular hardfile geometry aproximations...
			break;
		case HDF_FILE:
		    if (pHDF->file.size == 0)
    		    return;
		    total = pHDF->file.size / 512;
			break;
		case HDF_CARD:
		    total = MMC_GetCapacity();	// GetCapacity returns number of blocks, not bytes.
			break;
		case HDF_CARDPART0:
		case HDF_CARDPART1:
		case HDF_CARDPART2:
		case HDF_CARDPART3:
		    total = partitions[pHDF->partition].sectors;
			break;
		default:
			break;
	}

    for (i = 0; sptt[i] >= 0; i++)
    {
        spt = sptt[i];
        for (head = 4; head <= 16; head++)
        {
            cyl = total / (head * spt);
            if (total <= 1024 * 1024)
            {
                if (cyl <= 1023)
                    break;
            }
            else
            {
                if (cyl < 16383)
                    break;
                if (cyl < 32767 && head >= 5)
                    break;
                if (cyl <= cyllimit)
                    break;
            }
        }
        if (head <= 16)
            break;
    }
	if(pHDF->type == (HDF_FILE | HDF_SYNTHRDB))
		++cyl;	// Add an extra cylinder for the fake RDB
    pHDF->cylinders = (unsigned short)cyl;
    pHDF->heads = (unsigned short)head;
    pHDF->sectors = (unsigned short)spt;
	printf("Total sectors: %d, cyl: %d, heads: %d, sectors: %d\n",(int)total, (int)cyl, (int)head,(int)spt);
}
#pragma GCC diagnostic pop

unsigned char BuildHardfileIndex(hdfTYPE *pHDF)
{
    // builds index to speed up hard file seek

    fileTYPE *file = &pHDF->file;
    unsigned long *index = pHDF->index;
    unsigned long i;
    unsigned long j;

    pHDF->index_size = 16; // indexing size
    j = 1 << pHDF->index_size;
    i = pHDF->file.size >> 10; // divided by index table size (1024)
    while (j < i) // find greater or equal power of two
    {
        j <<= 1;
        pHDF->index_size++;
    }

    for (i = 0; i < file->size; i += j)
    {
        // every target lies inside the file: 0 is a failed FAT read or a
        // chain shorter than the file's size; either way this entry (and
        // HardFileSeek through it) would be wrong (findings/sdcard-engine
        // Task 10 fix rounds 1, 3)
        if (!FileSeek(file, i >> 9, SEEK_SET)) // FileSeek seeks in 512-byte sectors
            return 0;
        *index++ = file->cluster;
    }
    return 1;
}

unsigned char HardFileSeek(hdfTYPE *pHDF, unsigned long lba)
{
    if ((pHDF->file.sector ^ lba) & cluster_mask)
    { // different clusters
        if ((pHDF->file.sector > lba) || ((pHDF->file.sector ^ lba) & (cluster_mask << (fat32 ? 7 : 8)))) // 7: 128 FAT32 links per sector, 8: 256 FAT16 links per sector
        { // requested cluster lies before current pointer position or in different FAT sector
            pHDF->file.cluster = pHDF->index[lba >> (pHDF->index_size - 9)];// minus 9 because lba is in 512-byte sectors
            pHDF->file.sector = lba & (int)(~0U << (pHDF->index_size - 9));
        }
    }
    return FileSeek(&pHDF->file, lba, SEEK_SET);
}

unsigned char OpenHardfile(unsigned int unit)
{
    unsigned long time;
    hardfileTYPE *hf = SlotConfig(unit);

	hdd_cancel();	/* a command in progress ends before its file changes */
	hdf[unit].type = HDF_DISABLED;	// until opened: a stale type would serve the old file
	switch(hf->enabled)
	{
		case HDF_FILE | HDF_SYNTHRDB:
		case HDF_FILE:
			hdf[unit].type=hf->enabled;
			strncpy(filename, hf->name, 8);
			strcpy(&filename[8], "HDF");

			if (filename[0])
			{
				if(ValidateDirectory(config.hdfdir[unit]))
				{
					ChangeDirectory(config.hdfdir[unit]);
					if (FileOpen(&hdf[unit].file, filename))
					{
						GetHardfileGeometry(&hdf[unit]);

						printf("HARDFILE %d:\r", unit);
						printf("file: \"%.8s.%.3s\"\r", hdf[unit].file.name, &hdf[unit].file.name[8]);
						printf("size: %lu (%lu MB)\r", hdf[unit].file.size, hdf[unit].file.size >> 20);
						printf("CHS: %u.%u.%u", hdf[unit].cylinders, hdf[unit].heads, hdf[unit].sectors);
						printf(" (%lu MB)\r", ((((unsigned long) hdf[unit].cylinders) * hdf[unit].heads * hdf[unit].sectors) >> 11));

						time = GetTimer(0);
						if (!BuildHardfileIndex(&hdf[unit]))
						{	// wrong clusters in the index would read and write wrong places
							hdf[unit].type = HDF_DISABLED;
							hf->present = 0;
							SetError(ERROR_HDD, "Hardfile index read error", unit, 0);
							return 0;
						}
						time = GetTimer(0) - time;
						printf("Hardfile indexed in %lu ms\r", time >> 16);

						if(hf->enabled & HDF_SYNTHRDB)
							hdf[unit].offset=-(hdf[unit].heads*hdf[unit].sectors);
						else
							hdf[unit].offset=0;		

						hf->present = 1;
						return 1;
					}
				}
				else
				{
					hf->present = 0;
					SetError(ERROR_HDD,"Bad hardfile directory",config.hdfdir[unit],0);
				}
			}
			break;
		case HDF_CARD:
			hdf[unit].type=HDF_CARD;
		    hf->present = 1;
			hdf[unit].file.size=0;
			hdf[unit].offset=0;
		    GetHardfileGeometry(&hdf[unit]);
			return 1;
			break;
		case HDF_CARDPART0:
		case HDF_CARDPART1:
		case HDF_CARDPART2:
		case HDF_CARDPART3:
			hdf[unit].type=hf->enabled;
			hdf[unit].partition=hdf[unit].type-HDF_CARDPART0;
		    hf->present = 1;
			hdf[unit].file.size=0;
			hdf[unit].offset=partitions[hdf[unit].partition].startlba;
		    GetHardfileGeometry(&hdf[unit]);
			return 1;
			break;
		case HDF_CDROM:
			// The CD drive's slot: cdrom.c's CD_Open opens it (ApplyCDROM, after
			// this loop) and reads present as the ISO / CUE marker of the name;
			// clearing it here turned a CUE in the config into NAME.ISO.
			return 0;
	}
    hf->present = 0;
    return 0;
}


fileTYPE rdbfile;	// We scan for RDB without mounting the file as a unit, so need a file struct specifically for this task.

unsigned char GetHDFFileType(char *filename)
{
	if(FileOpen(&rdbfile,filename))
	{
		int i;
		DEBUG1("Hunting for RDB...");
		for(i=0;i<16;++i)
		{
			// a read that failed: stop, the buffer is stale (not an RDB);
			// a seek that hit a card error: the next read would be from a
			// wrong place (Task 10 fix round 1)
			MMCErr = SD_OK;
			if (!FileRead(&rdbfile,sector_buffer))
				return(HDF_FILETYPE_UNKNOWN);
			FileSeek(&rdbfile,512,SEEK_CUR);
			if (MMCErr != SD_OK)
				i = 16;	/* this sector is still looked at, no further one */
			if(sector_buffer[0]=='R' && sector_buffer[1]=='D' && sector_buffer[2]=='S' && sector_buffer[3]=='K')
				return(HDF_FILETYPE_RDB);
			if(sector_buffer[0]=='D' && sector_buffer[1]=='O' && sector_buffer[2]=='S')
				return(HDF_FILETYPE_DOS);
			if(sector_buffer[0]=='P' && sector_buffer[1]=='F' && sector_buffer[2]=='S')
				return(HDF_FILETYPE_DOS);
			if(sector_buffer[0]=='S' && sector_buffer[1]=='F' && sector_buffer[2]=='S')
				return(HDF_FILETYPE_DOS);
		}
		return(HDF_FILETYPE_UNKNOWN);
	}
	return(HDF_FILETYPE_NOTFOUND);
}


