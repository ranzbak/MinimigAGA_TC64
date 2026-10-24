#ifndef C64KEYS_H
#define C64KEYS_H

#define KEYBOARDBASE 0xFFFFFF90
#define HW_KEYBOARD(x) *(volatile unsigned short *)(KEYBOARDBASE+x)

#define REG_KEYBOARD_WORD0 0
#define REG_KEYBOARD_WORD1 4
#define REG_KEYBOARD_WORD2 8
#define REG_KEYBOARD_WORD3 0xc

#define REG_KEYBOARD_OUT 0

#define C64KEY_RINGBUFFER_SIZE 16

struct c64keyboard
{
	int active;
	int frame;
	int layer;
	int qualifiers;
	unsigned short keys[12];
	volatile int out_hw;
	volatile int out_cpu;
	unsigned int outbuf[C64KEY_RINGBUFFER_SIZE];
};

extern struct c64keyboard c64keys;

void c64keyboard_init(struct c64keyboard *r);
void c64keyboard_write(struct c64keyboard *r,int in);
int c64keyboard_checkreset();
void c64keys_inthandler(void);  /* IRQ_VBLANK (main.c IrqSetupSources) */

#endif
