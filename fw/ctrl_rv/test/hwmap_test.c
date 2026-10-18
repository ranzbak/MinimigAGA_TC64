/* hwmap_test: the I/O register map of the RISC-V host CPU (plan 5.3), with
 * the REAL macros: -DHOSTTEST is undefined here, so hardware.h expands to the
 * target's register accesses.  No register is accessed through its address
 * (this is the host, nothing is mapped there):
 *   - the address and width of every register macro are asserted from
 *     &(reg) and sizeof(reg);
 *   - the CS / SPEED / DATA values of Enable*()/Disable*()/SPI_slow()/
 *     SPI()/RDSPI go to a mock array (HW_SPI is redefined after the address
 *     checks), the real RS232() expansion to a UART_TX that hands out a
 *     fresh byte per store;
 *   - uart.c's puts() runs over those.
 *   make -C fw/ctrl_rv/test run-hwmap_test
 */
#undef HOSTTEST
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "c64keys.h"
#include "akiko.h"
#include "rtc.h"
#include "arch/irq.h"

static int fails;

#define CHECK_REG(name, expr, addr, size) do { \
	uintptr_t a_ = (uintptr_t)&(expr); \
	if (a_ != (uintptr_t)(addr) || sizeof(expr) != (size)) { \
		printf("FAIL %-28s at %08lx size %zu, want %08lx size %d\n", name, \
		       (unsigned long)a_, sizeof(expr), (unsigned long)(addr), (int)(size)); \
		fails++; \
	} } while (0)

/* all the addresses and widths, from the real macros */
static void check_addresses(void)
{
	CHECK_REG("SPI DATA",        HW_SPI(HW_SPI_DATA),  0xFFFFFFE0u, 1);
	CHECK_REG("SPI CS",          HW_SPI(HW_SPI_CS),    0xFFFFFFE4u, 1);
	CHECK_REG("SPI SPEED",       HW_SPI(HW_SPI_SPEED), 0xFFFFFFE8u, 1);
	CHECK_REG("UART_TX",         UART_TX,              0xFFFFFFF0u, 1);
	CHECK_REG("TIMER",           TIMER,                0xFFFFFFD0u, 2);
	CHECK_REG("PLATFORM",        PLATFORM,             0xFFFFFFC0u, 2);
	CHECK_REG("AUDIO",           AUDIO,                0xFFFFFFB0u, 1);
	CHECK_REG("INTERRUPT",       HW_INTERRUPT(REG_INTERRUPT_CTRL), 0xFFFFFFA0u, 4);
	CHECK_REG("KEYBOARD WORD0",  HW_KEYBOARD(REG_KEYBOARD_WORD0), 0xFFFFFF90u, 2);
	CHECK_REG("KEYBOARD WORD1",  HW_KEYBOARD(REG_KEYBOARD_WORD1), 0xFFFFFF94u, 2);
	CHECK_REG("KEYBOARD WORD2",  HW_KEYBOARD(REG_KEYBOARD_WORD2), 0xFFFFFF98u, 2);
	CHECK_REG("KEYBOARD WORD3",  HW_KEYBOARD(REG_KEYBOARD_WORD3), 0xFFFFFF9Cu, 2);
	CHECK_REG("KEYBOARD OUT",    HW_KEYBOARD(REG_KEYBOARD_OUT),   0xFFFFFF90u, 2);
	CHECK_REG("AKIKO ADDR",      HW_AKIKO(REG_AKIKO_ADDR), 0xFFFFFF80u, 2);
	CHECK_REG("AKIKO DATA",      HW_AKIKO(REG_AKIKO_DATA), 0xFFFFFF84u, 2);
	CHECK_REG("RTC +0",          HW_RTC(0x00), 0xFFFFFF70u, 2);
	CHECK_REG("RTC +4",          HW_RTC(0x04), 0xFFFFFF74u, 2);
	CHECK_REG("RTC +8",          HW_RTC(0x08), 0xFFFFFF78u, 2);
	CHECK_REG("RTC +c",          HW_RTC(0x0c), 0xFFFFFF7Cu, 2);
	CHECK_REG("I2C DATA",        HW_I2C(HW_I2C_DATA),      0xFFFFFF60u, 4);
	CHECK_REG("I2C STATUS",      HW_I2C(HW_I2C_STATUS),    0xFFFFFF64u, 4);
	CHECK_REG("I2C PRESCALE",    HW_I2C(HW_I2C_PRESCALE),  0xFFFFFF68u, 4);
	CHECK_REG("I2C ID",          HW_I2C(HV_I2C_ID),        0xFFFFFF6Cu, 4);
	CHECK_REG("VIDEOSCALE",      VIDEOSCALE,    0xFFFFFF50u, 4);
	CHECK_REG("FPGA_TEMP_RAW",   FPGA_TEMP_RAW, 0xFFFFFF40u, 2);
	CHECK_REG("IRQ PENDING",     HW_IRQ_PENDING, 0xFFFFFF30u, 4);
	CHECK_REG("IRQ MASK",        HW_IRQ_MASK,    0xFFFFFF34u, 4);
	CHECK_REG("IRQ RAW",         HW_IRQ_RAW,     0xFFFFFF38u, 4);
	CHECK_REG("IRQ MODE",        HW_IRQ_MODE,    0xFFFFFF3Cu, 4);
	CHECK_REG("RECONFIGURE",     RECONFIGURE,   0xDEE016u,   2);
	/* RS232(x) is a store to UART_TX (its address and width above): the
	   expression has the width of that store */
	if (sizeof(RS232(0)) != 1) { printf("FAIL RS232(x) is not a one-byte store\n"); fails++; }

}

/* ---- from here on the registers are mocks ---- */
/* the SPI registers: CS and SPEED are plain bytes; the DATA register is two
   bytes, the first access since spi_start() is the write side, the second the
   read side (a reply), so that SPI()'s order (write, then read) shows */
static unsigned char spi_regs[16], data_wr, data_rd;
static int data_n;
static void spi_start(void) { data_n = 0; }
static volatile unsigned char *spi_reg(int off)
{
	if (off != HW_SPI_DATA) return &spi_regs[off];
	return (data_n++ & 1) ? &data_rd : &data_wr;
}
#undef HW_SPI
#define HW_SPI(x) (*spi_reg(x))

static unsigned char uart_slots[64];
static int uart_n;
static volatile unsigned char *uart_slot(void) { return &uart_slots[uart_n++]; }
#undef UART_TX
#define UART_TX (*uart_slot())

static void check_value(const char *name, unsigned got, unsigned want)
{
	if (got != want) { printf("FAIL %s: got 0x%02x, want 0x%02x\n", name, got, want); fails++; }
}

#define CHECK_CS(fn, want) do { spi_regs[HW_SPI_CS] = 0; fn(); check_value(#fn, spi_regs[HW_SPI_CS], want); } while (0)

/* the values the Enable/Disable macros write to the CS register, the SPEED
   values, and the order of SPI(): write DATA, then read it */
static void check_spi_values(void)
{
	CHECK_CS(EnableCard,    0x02);
	CHECK_CS(DisableCard,   0x03);
	CHECK_CS(EnableFpga,    0x10);
	CHECK_CS(DisableFpga,   0x11);
	CHECK_CS(EnableOsd,     0x20);
	CHECK_CS(DisableOsd,    0x21);
	CHECK_CS(EnableDMode,   0x40);
	CHECK_CS(DisableDMode,  0x41);
	CHECK_CS(EnableRTC,     0x80);
	CHECK_CS(DisableRTC,    0x81);
	memset(spi_regs, 0, sizeof spi_regs);
	SPI_slow(); check_value("SPI_slow", spi_regs[HW_SPI_SPEED], 0x3f);
	SPI_fast(); check_value("SPI_fast", spi_regs[HW_SPI_SPEED], 0x01);
	check_value("no write to CS/DATA by SPI_slow/fast", spi_regs[HW_SPI_CS] | spi_regs[HW_SPI_DATA], 0);
	spi_regs[HW_SPI_CS] = 0x55;
	data_wr = 0xEE; data_rd = 0xBB;
	spi_start();
	check_value("SPI(x) returns the read side after the write", SPI(0x5a), 0xBB);
	check_value("SPI(x) wrote the write side", data_wr, 0x5a);
	check_value("SPI(x) is a write and a read", data_n, 2);
	data_wr = 0xA5;
	spi_start();
	check_value("RDSPI reads DATA", RDSPI, 0xA5);
	check_value("RDSPI is one access", data_n, 1);
	check_value("SPI/RDSPI leave CS alone", spi_regs[HW_SPI_CS], 0x55);
}

/* uart.c over the slot-handing UART_TX: RS232() is exactly one store of x */
static char tx[64];
static int ntx;
#include "uart.c"

static const char *sent(void)
{
	for (int i = 0; i < uart_n; i++) tx[i] = (char)uart_slots[i];
	tx[uart_n] = 0;
	ntx = uart_n;
	return tx;
}

int main(void)
{
	check_addresses();
	check_spi_values();

	/* RS232(x) is one byte store to UART_TX */
	uart_n = 0;
	RS232('x');
	if (uart_n != 1 || uart_slots[0] != 'x') { printf("FAIL RS232: %d stores, first 0x%02x\n", uart_n, uart_slots[0]); fails++; }
	uart_n = 0;
	{ volatile int wide = 0x1A5; RS232(wide); }
	if (uart_n != 1 || uart_slots[0] != 0xA5) { printf("FAIL RS232 truncates to a byte\n"); fails++; }

		/* puts() over the mock, string at offsets 0..3 of an aligned buffer;
	 * no newline appended, returns the byte count */
	{
		static char buf[16] __attribute__((aligned(4)));
		for (int off = 0; off < 4; off++) {
			memset(buf, 'Z', sizeof buf);
			memcpy(buf + off, "ab\0", 3);
			uart_n = 0;
			int r = puts(buf + off);
			if (r != 2 || uart_n != 2 || strcmp(sent(), "ab") != 0) {
				printf("FAIL puts offset %d: returned %d, sent %d bytes \"%s\"\n", off, r, uart_n, sent());
				fails++;
			}
		}
		uart_n = 0;
		if (puts("") != 0 || uart_n != 0) { printf("FAIL puts empty\n"); fails++; }
		uart_n = 0;
		if (puts("hello, world") != 12 || strcmp(sent(), "hello, world") != 0) { printf("FAIL puts long\n"); fails++; }
		uart_n = 0;
		if (putchar('q') != 'q' || uart_n != 1 || uart_slots[0] != 'q') { printf("FAIL putchar\n"); fails++; }
	}

	if (fails) { printf("hwmap_test FAIL (%d)\n", fails); return 1; }
	printf("hwmap_test PASS\n");
	return 0;
}
