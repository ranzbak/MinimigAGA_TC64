/* hwmap_test: the I/O register map of the RISC-V host CPU (plan 5.3).
 * Takes only addresses and sizes of the register macros (no register is
 * accessed: this is the host, nothing is mapped there) and runs uart.c's
 * puts() over a mock for the UART store.
 *   make -C fw/ctrl_rv/test hwmap_test && ./hwmap_test
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "c64keys.h"
#include "akiko.h"
#include "rtc.h"
#include "arch/irq.h"

/* uart.c over a mock UART: RS232() records the byte instead of storing it */
static char tx[64];
static int ntx;
static void mock_tx(int c) { tx[ntx++] = (char)c; tx[ntx] = 0; }
#undef RS232
#define RS232(x) mock_tx(x)
#include "uart.c"

static int fails;

#define CHECK_REG(name, expr, addr, size) do { \
	uintptr_t a_ = (uintptr_t)&(expr); \
	if (a_ != (uintptr_t)(addr) || sizeof(expr) != (size)) { \
		printf("FAIL %-28s at %08lx size %zu, want %08lx size %d\n", name, \
		       (unsigned long)a_, sizeof(expr), (unsigned long)(addr), (int)(size)); \
		fails++; \
	} } while (0)

int main(void)
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
	CHECK_REG("RECONFIGURE",     RECONFIGURE,   0xDEE016u,   2);

	/* RS232(x) is a one-byte store to UART_TX (here: the mock) */
	ntx = 0;
	RS232('x');
	if (ntx != 1 || tx[0] != 'x') { printf("FAIL RS232 mock\n"); fails++; }

	/* puts() over the mock, string at offsets 0..3 of an aligned buffer;
	 * no newline appended, returns the byte count */
	{
		static char buf[16] __attribute__((aligned(4)));
		for (int off = 0; off < 4; off++) {
			memset(buf, 'Z', sizeof buf);
			memcpy(buf + off, "ab\0", 3);
			ntx = 0; tx[0] = 0;
			int r = puts(buf + off);
			if (r != 2 || ntx != 2 || strcmp(tx, "ab") != 0) {
				printf("FAIL puts offset %d: returned %d, sent %d bytes \"%s\"\n", off, r, ntx, tx);
				fails++;
			}
		}
		ntx = 0; tx[0] = 0;
		if (puts("") != 0 || ntx != 0) { printf("FAIL puts empty\n"); fails++; }
		ntx = 0; tx[0] = 0;
		if (puts("hello, world") != 12 || strcmp(tx, "hello, world") != 0) { printf("FAIL puts long\n"); fails++; }
		ntx = 0;
		if (putchar('q') != 'q' || ntx != 1 || tx[0] != 'q') { printf("FAIL putchar\n"); fails++; }
	}

	if (fails) { printf("hwmap_test FAIL (%d)\n", fails); return 1; }
	printf("hwmap_test PASS\n");
	return 0;
}
