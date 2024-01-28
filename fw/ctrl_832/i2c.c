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

// Read status
unsigned int i2c_read_status()
{
  return I2C(HW_I2C_STATUS);
}

// Busy wait the bus is no longer busy
void i2c_wait_not_busy()
{
  while (I2C(HW_I2C_STATUS) & STATUS_I2C_BUSY)
    ;
}