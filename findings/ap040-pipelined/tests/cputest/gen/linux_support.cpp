/* Linux replacement for od-win32/unicode.cpp: TCHAR is char, so every
 * conversion is a copy. */
#include "sysconfig.h"
#include "sysdeps.h"

#include <string.h>
#include <ctype.h>

char *ua(const TCHAR *s) { return strdup(s ? s : ""); }
TCHAR *au(const char *s) { return strdup(s ? s : ""); }
char *uacp(const TCHAR *s, unsigned int) { return ua(s); }
TCHAR *aucp(const char *s, unsigned int) { return au(s); }
char *ua_fs(const TCHAR *s, int) { return ua(s); }
TCHAR *au_fs(const char *s) { return au(s); }
char *uutf8(const TCHAR *s) { return ua(s); }
TCHAR *utf8u(const char *s) { return au(s); }
TCHAR *my_strdup_ansi(const char *s) { return au(s); }

static char *copy_n(char *dst, int maxlen, const char *src)
{
	if (maxlen <= 0)
		return dst;
	strncpy(dst, src ? src : "", maxlen - 1);
	dst[maxlen - 1] = 0;
	return dst;
}
char *ua_copy(char *dst, int maxlen, const TCHAR *src) { return copy_n(dst, maxlen, src); }
TCHAR *au_copy(TCHAR *dst, int maxlen, const char *src) { return copy_n(dst, maxlen, src); }
char *ua_fs_copy(char *dst, int maxlen, const TCHAR *src, int) { return copy_n(dst, maxlen, src); }
TCHAR *au_fs_copy(TCHAR *dst, int maxlen, const char *src) { return copy_n(dst, maxlen, src); }

void unicode_init(void) { }
void to_lower(TCHAR *s, int len)
{
	for (int i = 0; s[i] && (len < 0 || i < len); i++)
		s[i] = tolower((unsigned char)s[i]);
}
void to_upper(TCHAR *s, int len)
{
	for (int i = 0; s[i] && (len < 0 || i < len); i++)
		s[i] = toupper((unsigned char)s[i]);
}
int same_aname(const TCHAR *an1, const TCHAR *an2) { return !strcasecmp(an1, an2); }
int uaestrlen(const char *s) { return (int)strlen(s); }
int uaetcslen(const TCHAR *s) { return (int)strlen(s); }
