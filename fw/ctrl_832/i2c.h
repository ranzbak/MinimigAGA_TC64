#ifndef I2C_H_INCLUDED
#define I2C_H_INCLUDED

/*
 * I2C functionality
 */
// Base memory address
#define I2C_BASE 0x0fffff60

// Memory offsets
// #define HW_I2C_DATA         0x00000000 // Short pointer, 2bytes, per 4 bytes, so +2 per register.
// #define HW_I2C_STATUS       0x00000002
// #define HW_I2C_PRESCALE     0x00000004
// #define HV_I2C_ID           0x00000006
#define HW_I2C_DATA 0x00000000 // Short pointer, 2bytes, per 4 bytes, so +2 per register.
#define HW_I2C_STATUS 0x00000004
#define HW_I2C_PRESCALE 0x00000008
#define HV_I2C_ID 0x0000000C

// Status bit masks
#define STATUS_I2C_WBUF_EMPTY 0x0001
#define STATUS_I2C_WBUF_FULL 0x0002
#define STATUS_I2C_RBUF_EMPTY 0x0004
#define STATUS_I2C_RBUF_FULL 0x0008
#define STATUS_I2C_BUSY 0x0010
#define STATUS_I2C_ERROR 0x0020
#define STATUS_I2C_BUS_ACTIVE 0x0040
#define STATUS_I2C_BUS_STOP_ON_IDLE 0x0180
#define STATUS_I2C_BUS_MISSED_ACK 0x0200

// Commands (rtl/host/i2c_master_mmio.sv)
#define CMD_I2C_READ 0x01
#define CMD_I2C_READ_NEXT 0x0a
#define CMD_I2C_WRITE 0x02
#define CMD_I2C_WRITEMULTI 0x03
#define CMD_I2C_START 0x04
#define CMD_I2C_STOP 0x05
#define CMD_I2C_SET_ADDR 0x0b
#define CMD_I2C_SET_SCL_L 0x0c
#define CMD_I2C_SET_SCL_H 0x0d

#define CMD_I2C_LAST_BYTE 0x10

#define HW_I2C(x) (*(volatile unsigned int *)(I2C_BASE + x))
#define I2C(x) (HW_I2C(x))

void i2c_set_divider(unsigned short div);
void i2c_set_address(unsigned char addr);
void i2c_start();
void i2c_stop();
void i2c_write(unsigned char byte);
void i2c_write_multi(unsigned char *byte, unsigned char size);
unsigned char i2c_read_reg(unsigned char dev, unsigned char reg);

#endif
