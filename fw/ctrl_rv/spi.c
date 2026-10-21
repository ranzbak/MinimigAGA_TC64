#include "hardware.h"
#include "spi.h"

/* generic helper */
unsigned char spi_in() {
  return SPI(0);
}

void spi8(unsigned char parm) {
  SPI(parm);
}

void spi16(unsigned short parm) {
  SPI(parm >> 8);
  SPI(parm >> 0);
}

void spi24(unsigned long parm) {
  SPI(parm >> 16);
  SPI(parm >> 8);
  SPI(parm >> 0);
}

void spi32(unsigned long parm) {
  SPI(parm >> 24);
  SPI(parm >> 16);
  SPI(parm >> 8);
  SPI(parm >> 0);
}

// little endian: lsb first
void spi32le(unsigned long parm) {
  SPI(parm >> 0);
  SPI(parm >> 8);
  SPI(parm >> 16);
  SPI(parm >> 24);
}

void spi_n(unsigned char value, unsigned short cnt) {
  while(cnt--) 
    SPI(value);
}


/* OSD related SPI functions */
#if 0
void spi_osd_cmd_cont(unsigned char cmd) {
  EnableOsd();
  SPI(cmd);
}

void spi_osd_cmd(unsigned char cmd) {
  spi_osd_cmd_cont(cmd);
  DisableOsd();
}

void spi_osd_cmd8_cont(unsigned char cmd, unsigned char parm) {
  EnableOsd();
  SPI(cmd);
  SPI(parm);
}

void spi_osd_cmd8(unsigned char cmd, unsigned char parm) {
  spi_osd_cmd8_cont(cmd, parm);
  DisableOsd();
}

void spi_osd_cmd32_cont(unsigned char cmd, unsigned long parm) {
  EnableOsd();
  SPI(cmd);
  spi32(parm);
}

void spi_osd_cmd32(unsigned char cmd, unsigned long parm) {
  spi_osd_cmd32_cont(cmd, parm);
  DisableOsd();
}

void spi_osd_cmd32le_cont(unsigned char cmd, unsigned long parm) {
  EnableOsd();
  SPI(cmd);
  spi32le(parm);
}

void spi_osd_cmd32le(unsigned char cmd, unsigned long parm) {
  spi_osd_cmd32le_cont(cmd, parm);
  DisableOsd();
}
#endif
#if 0
/* User_io related SPI functions */
void spi_uio_cmd_cont(unsigned char cmd) {
  EnableIO();
  SPI(cmd);
}

void spi_uio_cmd(unsigned char cmd) {
  spi_uio_cmd_cont(cmd);
  DisableIO();
}

void spi_uio_cmd8_cont(unsigned char cmd, unsigned char parm) {
  EnableIO();
  SPI(cmd);
  SPI(parm);
}

void spi_uio_cmd8(unsigned char cmd, unsigned char parm) {
  spi_uio_cmd8_cont(cmd, parm);
  DisableIO();
}

void spi_uio_cmd32(unsigned char cmd, unsigned long parm) {
  EnableIO();
  SPI(cmd);
  SPI(parm);
  SPI(parm>>8);
  SPI(parm>>16);
  SPI(parm>>24);
  DisableIO();
}
#endif

#if 0

volatile void EnableCard()
{
	HW_SPI(HW_SPI_CS)=0x02;
}

volatile void DisableCard()
{
	HW_SPI(HW_SPI_CS)=0x03;
}

volatile void EnableFpga()
{
	HW_SPI(HW_SPI_CS)=0x10;
}

volatile void DisableFpga()
{
	HW_SPI(HW_SPI_CS)=0x11;
}

volatile void EnableOsd()
{
	HW_SPI(HW_SPI_CS)=0x20;
}

volatile void DisableOsd()
{
	HW_SPI(HW_SPI_CS)=0x21;
}

volatile void EnableDMode()
{
	HW_SPI(HW_SPI_CS)=0x40;
}

volatile void DisableDMode()
{
	HW_SPI(HW_SPI_CS)=0x41;
}

#endif

