#ifndef ERRORS_H
#define ERRORS_H

#define ERROR_SDCARD 0
#define ERROR_FILESYSTEM 1
#define ERROR_ROM 2
#define ERROR_FDD 3
#define ERROR_HDD 4
#define ERROR_MAX 4
#define ERROR_ALL 5

#define SetError(x,s,y,z) {ErrorMask|=(1<<x); Errors[x].string=s; Errors[x].a=y; Errors[x].b=z;}
#define FatalError(x,s,y,z) {ErrorMask|=(1<<x); Errors[x].string=s; Errors[x].a=y; Errors[x].b=z; ErrorFatal=1; }
#define FDDError(s,a) SetError(ERROR_FDD,s,a,0)
#define SetSubError(x) SubError=x
#define SetSubError2(x) SubError2=x
#define SetSubErrorString(x) SubErrorString=x

extern int ErrorMask;
extern int ErrorFatal;
extern char *ErrorMessages[ERROR_MAX+1];
struct Error
{
	char *string;
	int a;
	int b;
};
extern struct Error Errors[ERROR_MAX+1];

void ClearError(int category);

#endif

