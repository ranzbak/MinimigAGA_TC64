/* Linux shim for od-win32/sysconfig.h, cut down to what the CPU tester
 * generator (cputestgen), gencpu and build68k need.  The feature set mirrors
 * the Windows cputester build: FPU emulation through softfloat, the 68040/60
 * MMU headers present but no MMU core, no JIT, no chipset. */
#ifndef CPUTEST_LINUX_SYSCONFIG_H
#define CPUTEST_LINUX_SYSCONFIG_H

#include <stdint.h>
#include <limits.h>

#define MAX_DPATH 1000
#define FPUEMU
#define FPU_UAE
#define WITH_SOFTFLOAT
#define MMUEMU
#define FULLMMU
#define DEBUGGER

#define UAE_RAND_MAX RAND_MAX

#define SIZEOF_VOID_P 8
#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF___INT64 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

#define STDC_HEADERS 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRING_H 1
#define HAVE_STRDUP 1
#define HAVE_STRINGS_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_DIRENT_H 1
#define HAVE_UTIME_H 1
#define TIME_WITH_SYS_TIME 1
#define HAVE_SYS_TIME_H 1
#define HAVE_GETTIMEOFDAY 1

#define PACKAGE_STRING "WinUAE-cputestgen-linux"

typedef long uae_atomic;

#define __cdecl

/* MSVC intrinsics used by od-win32/machdep/maccess.h */
#define _byteswap_uint64 __builtin_bswap64
#define _byteswap_ulong __builtin_bswap32
#define _byteswap_ushort __builtin_bswap16

#endif
