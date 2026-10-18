#ifndef CFGSWAP_H
#define CFGSWAP_H

/* The config file's byte order (plan 5.2 item 5, decision 12.4).
 *
 * The file is configTYPE (config.h) as it is in memory: 212 bytes, id
 * "MNMGCFGA", CONFIG_VERSION 4.  The 832 firmware writes it big-endian
 * (MINMGAA.CFG, MINMGAA<n>.CFG), the RISC-V firmware little-endian
 * (MINMGAR.CFG, MINMGAR<n>.CFG).  The only multi-byte fields are seven 32-bit
 * ones, at the CFG_OFF_* offsets below (config.c checks them against
 * configTYPE).  Which order a file is in is told by version: 1..4 read
 * little-endian = RV, 1..4 read big-endian = 832.
 *
 * Pure C: shared by the firmware (config.c) and the host tool
 * (tools/cfgconv). */

#include <stddef.h>
#include <stdint.h>

#define CFG_SIZE        212         /* sizeof(configTYPE) */
#define CFG_MIN_SIZE    156         /* up to the end of hdfdir[3]: every 32-bit field */
#define CFG_ID          "MNMGCFGA"  /* 8 bytes, no NUL in the file */
#define CFG_ID_LEN      8
#define CFG_VERSION_MAX 4           /* CONFIG_VERSION */

#define CFG_OFF_VERSION   8
#define CFG_OFF_KICKDIR   132
#define CFG_OFF_EXTROMDIR 136
#define CFG_OFF_HDFDIR    140       /* hdfdir[0..3]: 140, 144, 148, 152 */

enum { CFG_BAD = 0, CFG_RV = 1, CFG_832 = 2 };

/* The byte order of a config file of len bytes: CFG_RV, CFG_832, or CFG_BAD
 * (len outside CFG_MIN_SIZE..CFG_SIZE, another id, or a version that is
 * 1..CFG_VERSION_MAX in neither order). */
int cfg_order(const uint8_t *buf, size_t len);

/* Swaps the seven 32-bit fields of buf (CFG_SIZE bytes) in place, byte by
 * byte (any alignment): 832 <-> RV.  Every other byte stays. */
void cfg_swap(uint8_t *buf);

#endif
