#ifndef AKIKO_H
#define AKIKO_H


#define AKIKOBASE 0xFFFFFF80
#define HW_AKIKO(x) *(volatile unsigned short *)(AKIKOBASE+x)

#define REG_AKIKO_ADDR 0
#define REG_AKIKO_DATA 4

#define AKIKO_REQ 0x8000
#define AKIKO_WRITE 0x4000

void akiko_inthandler();

#endif

