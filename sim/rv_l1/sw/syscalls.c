/* newlib-nano system calls for the L1 bench: stdout/stderr -> UART byte
 * stores, heap after _end, _exit -> DONE.  Used by sim/rv_l1/prog. */
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "l1.h"

extern char _end;
extern char __heap_limit;
static char *heap_top;

int _write(int fd, const char *buf, int len)
{
    int i;
    (void)fd;
    for (i = 0; i < len; i++)
        l1_putc(buf[i]);
    return len;
}

void *_sbrk(int incr)
{
    char *old;
    if (!heap_top)
        heap_top = &_end;
    if (heap_top + incr > &__heap_limit) {
        errno = ENOMEM;
        return (void *)-1;
    }
    old = heap_top;
    heap_top += incr;
    return old;
}

void _exit(int code) { l1_done((unsigned)code); }

int _close(int fd)                       { (void)fd; return -1; }
int _fstat(int fd, struct stat *st)      { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd)                      { (void)fd; return 1; }   /* unbuffered stdout */
int _lseek(int fd, int off, int whence)  { (void)fd; (void)off; (void)whence; return 0; }
int _read(int fd, char *buf, int len)    { (void)fd; (void)buf; (void)len; return 0; }
int _getpid(void)                        { return 1; }
int _kill(int pid, int sig)              { (void)pid; (void)sig; errno = EINVAL; return -1; }
