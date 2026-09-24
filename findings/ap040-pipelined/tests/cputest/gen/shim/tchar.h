/* Linux shim for MSVC <tchar.h>: TCHAR is plain char (the Windows build is
 * UNICODE with 16-bit wchar_t; on Linux wchar_t is 32-bit and wprintf's %s
 * means a narrow string, so going narrow everywhere is the safe mapping).
 * Only the names cputestgen/gencpu/build68k actually use are mapped. */
#ifndef CPUTEST_LINUX_TCHAR_H
#define CPUTEST_LINUX_TCHAR_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef TCHAR
typedef char TCHAR;
#endif
typedef char WCHAR;

#define _T(x) x
#define _TEXT(x) x

#define _stprintf sprintf
#define _sntprintf snprintf
#define _vsntprintf vsnprintf
#define _vsnprintf vsnprintf
#define _vstprintf vsprintf
#define _tprintf printf
#define _ftprintf fprintf
#define _tcslen strlen
#define _tcscpy strcpy
#define _tcsncpy strncpy
#define _tcscat strcat
#define _tcsncat strncat
#define _tcsicmp strcasecmp
#define _tcsnicmp strncasecmp
#define _tcscmp strcmp
#define _tcsncmp strncmp
#define _tcschr strchr
#define _tcsrchr strrchr
#define _tcsstr strstr
#define _tcscspn strcspn
#define _tcsspn strspn
#define _tcsdup strdup
#define _tcstol strtol
#define _tcstoul strtoul
#define _tcstod strtod
#define _tstol atol
#define _tstoi atoi
#define _ttoi atoi
#define _totupper toupper
#define _totlower tolower
#define _istspace isspace
#define _istdigit isdigit
#define _istalpha isalpha
/* MSVC mode strings: drop "t" and ", ccs=UTF-8" (glibc would make the
 * stream wide-oriented and the narrow fgets below would then fail) */
static inline FILE *cputest_linux_fopen(const char *path, const char *mode)
{
	char m[8];
	int n = 0;
	for (const char *p = mode; *p && *p != ',' && n < 7; p++)
		if (*p != 't')
			m[n++] = *p;
	m[n] = 0;
	return fopen(path, m);
}
#define _tfopen cputest_linux_fopen
#define fgetws fgets
#define fputws fputs
#define _tunlink unlink
#define _tremove remove
#define _trename rename
#define _fgetts fgets
#define _fputts fputs
#define _stricmp strcasecmp
#define _strnicmp strncasecmp
#define stricmp strcasecmp
#define strnicmp strncasecmp
#define _strdup strdup
#define _fseeki64 fseeko
#define _ftelli64 ftello

/* narrow replacements for the wide calls cputest.cpp makes directly */
#define wprintf printf
#define _wmkdir(p) mkdir((p), 0777)

#endif
