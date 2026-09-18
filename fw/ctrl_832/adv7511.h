#ifndef ADV7511_H
#define ADV7511_H

#define ADV_CTRL_ADDR 0x72
#define ADV_PACKET_ADDR 0x70

// initialize the ADV7511 video chip
void adv7511_init();

// Hot-plug handling; see adv7511.c.  adv7511_poll() re-initialises the part
// when a sink appears and returns non-zero when it did.
unsigned char adv7511_status(void);     // register 0x42: [6] HPD, [5] mon sense
unsigned char adv7511_int_flags(void);  // register 0x96: [7] HPD, [6] mon sense
int adv7511_poll(void);

#endif