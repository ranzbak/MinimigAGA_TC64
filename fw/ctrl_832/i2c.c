/*
Copyright 2021 Paul Honig

This file is part of Minimig

Minimig is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

Minimig is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

This is the Minimig I2C handler.

2021-03-16 - Start implementation memory mapped I2C driver.

*/

#include "i2c.h"

void i2c_set_divider(unsigned short div)
{
  unsigned int divout;
  // unsigned int divout = ((div & 0xff)<<16) |  ((div & 0xff00)<<16) | 0xaaaa;
  divout = (CMD_I2C_SET_SCL_L << 8) | div | 0xaaaa0000;
  I2C(HW_I2C_DATA) = divout;
  divout = (CMD_I2C_SET_SCL_H << 8) | ((0xff00 & div) >> 8) | 0xaaaa0000;
  I2C(HW_I2C_DATA) = divout;
}

void i2c_set_address(unsigned char addr)
{
  I2C(HW_I2C_DATA) = CMD_I2C_SET_ADDR << 8 | addr | 0xaaa0000;
}

void i2c_start()
{
  I2C(HW_I2C_DATA) = CMD_I2C_START << 8 | 0xaaaa0000;
}

void i2c_stop()
{
  I2C(HW_I2C_DATA) = CMD_I2C_STOP << 8 | 0xaaaa0000;
}

void i2c_write(unsigned char byte)
{
  I2C(HW_I2C_DATA) = CMD_I2C_WRITE << 8 | (unsigned short)byte | 0xaaaa0000;
}

// Be aware, the send buffer is only 8 bytes!
void i2c_write_multi(unsigned char *byte, unsigned char size)
{
  for (unsigned char pos = 0; pos < size; pos++)
  {
    if (pos + 1 == size)
    {
      // last byte
      I2C(HW_I2C_DATA) = (CMD_I2C_WRITEMULTI | CMD_I2C_LAST_BYTE) << 8 | (unsigned short)*(byte + pos);
    }
    else
    {
      I2C(HW_I2C_DATA) = CMD_I2C_WRITEMULTI << 8 | (unsigned short)*(byte + pos);
    }
  }
}

// Read one register of an I2C device: write the register pointer, repeated
// start, read one byte with a NAK.  The read result appears in the master's
// read buffer and is fetched from HW_I2C_DATA (rtl/host/i2c_master_mmio.sv).
unsigned char i2c_read_reg(unsigned char dev, unsigned char reg)
{
  unsigned int guard;

  i2c_set_address(dev);
  i2c_write(reg);               // the core starts the transaction itself
  // Read one byte WITH the stop: the stop has to ride on the read command,
  // a stand-alone CMD_I2C_STOP is ignored by the master core.  Without it the
  // bus stays held and everything after this fails.
  I2C(HW_I2C_DATA) = (CMD_I2C_READ | CMD_I2C_LAST_BYTE) << 8 | 0xaaaa0000;

  // NEVER SPIN FOR EVER: this runs in the OSD's main loop, and a device that
  // does not answer (no monitor, or the RTL's own I2C master mid-burst on the
  // same pins) must not take the firmware down with it.
  guard = 200000;
  while ((I2C(HW_I2C_STATUS) & STATUS_I2C_BUSY) && --guard)
    ;
  if (!guard)
    return 0xff;
  guard = 200000;
  while ((I2C(HW_I2C_STATUS) & STATUS_I2C_RBUF_EMPTY) && --guard)
    ;
  if (!guard)
    return 0xff;
  return (unsigned char)(I2C(HW_I2C_DATA) & 0xff);
}

// Read status
unsigned int i2c_read_status()
{
  return I2C(HW_I2C_STATUS);
}

// Busy wait the bus is no longer busy.
//
// BOUNDED, and it has to be.  This runs from HandleUI, so a bus that never
// goes idle does not just lose an I2C transfer -- it stops the 832 returning
// to its main loop at all.  The OSD freezes on whatever it was showing, and an
// Amiga reset cannot clear it, because nothing on the Amiga side resets the
// 832 (see findings/reset/2026-09-19-reset-logic-review.md).  That is exactly
// how LSHIFT + keypad '.' left its notification on screen for good: it calls
// adv7511_init(), which is all writes, and every write waited here forever.
//
// The read path was bounded when it caused the same hang on 2026-09-18; the
// write path was missed.  The guard is deliberately generous -- a real
// transfer finishes far inside it -- so this only fires when the bus is
// genuinely stuck, and then the caller carries on rather than taking the whole
// firmware down with it.
void i2c_wait_not_busy()
{
  unsigned int guard = 200000;   // same bound the read path above uses
  while ((I2C(HW_I2C_STATUS) & STATUS_I2C_BUSY) && --guard)
    ;
}