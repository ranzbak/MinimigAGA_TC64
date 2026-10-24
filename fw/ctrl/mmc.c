/*
Copyright 2005, 2006, 2007 Dennis van Weeren
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

// --== based on the work by Dennis van Weeren and Jan Derogee ==--
// 2008-10-03 - adaptation for ARM controller
// 2009-07-23 - clean-up and some optimizations
// 2009-11-22 - multiple sector read implemented
//
// findings/sdcard-engine Task 10: the card is on the SD card peripheral
// (sdc.h); the protocol, CRC on, the retries and the timeouts are
// sdproto.c's.  Every MMC_* call is one sd_sync() op: it returns 1, or 0
// on any card error (never FatalError: a card error must not wedge the
// firmware).  MMCErr holds the sd_err code of the last call (sdproto.h);
// a card error also sets ERROR_SDCARD (SetError, the OSD's error page),
// an abandoned Gayle transfer (SD_E_GAYLE) does not: it is no error.

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "sdproto.h"

unsigned char CardType;
unsigned char CSDData[16];
unsigned char MMCErr;
// the IDE port of the ATA command in progress (hdd.c sets it, hdd.h); a
// read with no buffer goes into that port's Gayle FIFO
unsigned char ide_port;

static unsigned char op_run(sd_op *op, const char *what)
{
    MMCErr = (unsigned char)sd_sync(op);
    if (MMCErr == SD_OK)
        return 1;
    if (MMCErr != SD_E_GAYLE)
        SetError(ERROR_SDCARD, (char *)what, (int)(op->lba + op->done_blocks), MMCErr);
    return 0;
}

// init memory card: the card type, CARDTYPE_NONE (0) when there is none
unsigned char MMC_Init(void)
{
    CardType = (unsigned char)sd_init();
    if (CardType)
        for (int i = 0; i < 16; i++)
            CSDData[i] = sd_csd[i];
    return CardType;
}

// count 512-byte blocks from lba into buf; buf 0: into the Gayle FIFO of
// ide_port (what was cfide's direct mode), each block only after its CRC
static unsigned char read_blocks(unsigned long lba, unsigned char *buf, unsigned long count)
{
    sd_op op = { 0 };

    op.kind = SD_READ;
    op.lba = lba;
    op.count = count;
    op.buf = buf;
    op.to_gayle = buf == 0;
    op.port = ide_port & 1;
    return op_run(&op, "SD card read");
}

unsigned char MMC_Read(unsigned long lba, unsigned char *pReadBuffer)
{
    return read_blocks(lba, pReadBuffer, 1);
}

unsigned char MMC_ReadMultiple(unsigned long lba, unsigned char *pReadBuffer, unsigned long nBlockCount)
{
    return read_blocks(lba, pReadBuffer, nBlockCount);
}

unsigned char MMC_WriteMultiple(unsigned long lba, unsigned char *pWriteBuffer, unsigned long nBlockCount)
{
    sd_op op = { 0 };

    op.kind = SD_WRITE;
    op.lba = lba;
    op.count = nBlockCount;
    op.buf = pWriteBuffer;
    return op_run(&op, "SD card write");
}

unsigned char MMC_Write(unsigned long lba, unsigned char *pWriteBuffer)
{
    return MMC_WriteMultiple(lba, pWriteBuffer, 1);
}

// Read CSD register into CSDData
unsigned char MMC_GetCSD()
{
    sd_op op = { 0 };

    op.kind = SD_CSD;
    op.buf = CSDData;
    return op_run(&op, "SD card CSD");
}

// the capacity in 512-byte blocks; 0 when the CSD cannot be read
unsigned long MMC_GetCapacity()
{
	unsigned long result=0;
	if (!MMC_GetCSD())
		return 0;
    if ((CSDData[0] & 0xC0)==0x40)   //CSD Version 2.0 - SDHC
    {
			result=(CSDData[7]&0x3f)<<26;
			result|=CSDData[8]<<18;
			result|=CSDData[9]<<10;
			result+=1024;
			return(result);
	}
	else
	{
			int blocksize=CSDData[5]&15;	// READ_BL_LEN
			blocksize=1<<(blocksize-9);		// Now a scalar:  physical block size / 512.
			result=(CSDData[6]&3)<<10;
			result|=CSDData[7]<<2;
 			result|=(CSDData[8]>>6)&3;		// result now contains C_SIZE
			int cmult=(CSDData[9]&3)<<1;
			cmult|=(CSDData[10]>>7) & 1;
			++result;
			result<<=cmult+2;
			result*=blocksize;	// Scale by the number of 512-byte chunks per block.
			return(result);
    }
}
