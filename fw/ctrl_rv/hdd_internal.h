#ifndef HDD_INTERNAL_H
#define HDD_INTERNAL_H

#include <stdint.h>

// Structure definitions for RDB emulation.
// For hardfiles that have no RDB information, we'll just create a single-partition RDB and Part block
// on blocks 0 and 1.  All other blocks within the first cylinder will be translated into the hardfile
//
// The Amiga reads these blocks as big-endian longs (devices/hardblocks.h):
// every long is stored and read with be32() (swap.h), and the fields are
// uint32_t / int32_t, the on-disk size on every ABI (host tests: LP64).

struct RigidDiskBlock {
    uint32_t   rdb_ID;	// "RDSK"
    uint32_t   rdb_Summedlongs; // 0x40
    int32_t			rdb_ChkSum;	// Sum to zero
    uint32_t   rdb_HostID;	// 0x07
    uint32_t   rdb_BlockBytes; // 0x200
    uint32_t   rdb_Flags;	// 0x12 (Disk ID valid, no LUNs after this one)
    uint32_t   rdb_BadBlockList;	// -1 since we don't provide one
    uint32_t   rdb_PartitionList;	// 1
    uint32_t   rdb_FileSysHeaderList;	// -1
    uint32_t   rdb_DriveInit;	// -1
    uint32_t   rdb_Reserved1[6];	// 0xffffffff
    uint32_t   rdb_Cylinders;
    uint32_t   rdb_Sectors;
    uint32_t   rdb_Heads;
    uint32_t   rdb_Interleave;	// 1
    uint32_t   rdb_Park;	// =Cylinder count
    uint32_t   rdb_Reserved2[3];
    uint32_t   rdb_WritePreComp;	// High cylinder ?
    uint32_t   rdb_ReducedWrite;	// High cylinder ?
    uint32_t   rdb_StepRate;	// 3 ?
    uint32_t   rdb_Reserved3[5];
    uint32_t   rdb_RDBBlocksLo;	// block zero
    uint32_t   rdb_RDBBlocksHi;	// block one
    uint32_t   rdb_LoCylinder;	// 1
    uint32_t   rdb_HiCylinder;	// From the hardfile: cylinder count -1
    uint32_t   rdb_CylBlocks;	// From the hardfile: heads * sectors
    uint32_t   rdb_AutoParkSeconds; // zero
    uint32_t   rdb_HighRDSKBlock;	// 1
    uint32_t   rdb_Reserved4;
    char    rdb_DiskVendor[8];	// "Don't"
    char    rdb_DiskProduct[16];	// " repartition!"
    char    rdb_DiskRevision[4];
    char    rdb_ControllerVendor[8];
    char    rdb_ControllerProduct[16];
    char    rdb_ControllerRevision[4];
    uint32_t   rdb_Reserved5[10];
};

struct DosEnvec {
    uint32_t de_TableSize;	     // Size of Environment vector - 0x10
    uint32_t de_SizeBlock;	     // in longwords - 0x80
    uint32_t de_SecOrg;	     // 0
    uint32_t de_Surfaces;		 // Heads?
    uint32_t de_SectorPerBlock; // 1
    uint32_t de_BlocksPerTrack;
    uint32_t de_Reserved;	     // 2 ?
    uint32_t de_PreAlloc;	     // 0
    uint32_t de_Interleave;     // 0
    uint32_t de_LowCyl;
    uint32_t de_HighCyl;
    uint32_t de_NumBuffers;     // 30
    uint32_t de_BufMemType;     // 0 - any available
    uint32_t de_MaxTransfer;    // 0x00ffffff
    uint32_t de_Mask;	// 0x7ffffffe
    int32_t	de_BootPri;	     // 0
    uint32_t de_DosType;	// 0x444f5301 or 3
	// Extra fields
    uint32_t de_Baud;
    uint32_t de_Control;
    uint32_t de_BootBlocks;
};


struct PartitionBlock {
    uint32_t   pb_ID;		// "PART"
    uint32_t   pb_Summedlongs;	// 0x40
    int32_t    pb_ChkSum;		// Sum to zero
    uint32_t   pb_HostID;		// 0x07
    uint32_t   pb_Next;		// -1
    uint32_t   pb_Flags;		// 1 - Bootable
    uint32_t   pb_Reserved1[2];	// 0
    uint32_t   pb_DevFlags;	 // 0
    char   pb_DriveName[32];	// 0x03"DH0"
    uint32_t   pb_Reserved2[15];
    struct DosEnvec pb_Environment;
    uint32_t   pb_EReserved[12];	/* reserved for future environment vector */
};

/* the 64 longs (SummedLongs 0x40) of devices/hardblocks.h */
_Static_assert(sizeof(struct RigidDiskBlock) == 256, "RigidDiskBlock is 64 longs");
_Static_assert(sizeof(struct PartitionBlock) == 256, "PartitionBlock is 64 longs");

#endif /* HDD_INTERNAL_H */

