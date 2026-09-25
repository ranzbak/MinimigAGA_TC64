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

// Video clock delay, register 0xBA bits 7:5: step 0..7 = -1.2 .. +1.6 ns in
// 0.4 ns steps (3 = 0 ns).  Kept here so every (re-)initialisation, including
// the hot-plug one, applies it.  set_ writes the register at once.
#define ADV_CLKDELAY_DEFAULT 0  // -1.2 ns: clean on the board (OSD slider, 2026-09-25), matches the RTL table
extern unsigned char adv_clkdelay;
void adv7511_set_clkdelay(unsigned char step);
// Register 0xBA as the chip holds it now.  The RTL's own I2C master
// (rtl/openaars/adv7511/i2c_sender.vhd) shares the bus and re-sends its table,
// with its own 0xBA, on every edge of the interrupt pin -- this shows who won.
unsigned char adv7511_read_clkdelay(void);

// Last status byte (register 0x42) the poll read, for the OSD to display.
// Bit 6 is Hot Plug Detect; 0xff means the device did not answer at all.
extern unsigned char adv_last_status;

// Last four status bytes that changed, newest in the low byte.  Survives the
// display being off, which a live readout cannot: the OSD is unreadable then.
extern unsigned long adv_status_hist;

#endif